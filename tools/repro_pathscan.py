#!/usr/bin/env python3
"""Reproducibility build-root leak scan.

A cross-machine-reproducible build must not embed its absolute build location
(the buck2 project root) in its outputs.  If it does, the same source produces
different bytes on a different builder -- breaking content-addressed commits
(SPEC-006) and shared caching.

This scans a built artifact tree for the absolute build root (default: cwd) and
reports any file that contains it, with a sample of the surrounding bytes.
Unlike a double-build, it is cheap (one build + a scan) and tests the *real*
property -- root-independence -- rather than isolation-dir independence.

The known leak source today is RPATH/RUNPATH (binaries embed absolute buck-out
dep lib dirs); see SPEC-006.

Usage:
    tools/repro_pathscan.py [--root ABS] [--buck2 PATH] TARGET_OR_DIR [...]

A positional argument starting with "//" is built with buck2 and its output is
scanned; anything else is treated as a directory to scan directly.  Exits
non-zero if any artifact leaks the build root.
"""

import argparse
import fnmatch
import os
import subprocess
import sys

# Files that legitimately reference build paths (text manifests we don't ship as
# part of the booted system) can be ignored; keep the default empty and let the
# caller decide, but always skip these obviously-derived build logs.
_SKIP_SUFFIXES = (".pyc",)


def buck2_output(buck2, target):
    res = subprocess.run(
        [buck2, "build", target, "--show-full-output"],
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        sys.stderr.write(res.stderr[-4000:])
        raise RuntimeError(f"build failed: {target}")
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            return parts[-1]
    raise RuntimeError(f"no --show-full-output path for {target}")


def scan_tree(path, needle):
    """Return [(relpath, sample)] for files under path containing needle."""
    nb = needle.encode()
    hits = []
    files = (
        [path]
        if os.path.isfile(path)
        else (os.path.join(r, f) for r, _, fs in os.walk(path) for f in fs)
    )
    for fp in files:
        if os.path.islink(fp) or fp.endswith(_SKIP_SUFFIXES):
            continue
        try:
            with open(fp, "rb") as fh:
                data = fh.read()
        except OSError:
            continue
        idx = data.find(nb)
        if idx != -1:
            sample = (
                data[idx : idx + len(nb) + 48]
                .decode("latin-1", "replace")
                .replace("\n", " ")
            )
            rel = os.path.relpath(fp, path) if os.path.isdir(path) else fp
            hits.append((rel, sample))
    return hits


def main():
    ap = argparse.ArgumentParser(
        description="Scan built artifacts for absolute build-root leaks."
    )
    ap.add_argument(
        "items", nargs="+", help="buck2 targets (//...) or directories to scan"
    )
    ap.add_argument(
        "--root",
        default=os.getcwd(),
        help="absolute build root that must not appear in outputs (default: cwd)",
    )
    ap.add_argument("--buck2", default="buck2")
    ap.add_argument(
        "--max-report", type=int, default=12, help="max leaking files to print per item"
    )
    ap.add_argument(
        "--allow",
        action="append",
        default=[],
        metavar="GLOB",
        help="relpath glob of a known/accepted leak (repeatable); reported but "
        "does not fail the run -- use for residual leaks pending a fix",
    )
    args = ap.parse_args()

    def _allowed(rel):
        return any(fnmatch.fnmatch(rel, pat) for pat in args.allow)

    failed = 0
    for item in args.items:
        print(f"\n=== {item} ===", flush=True)
        try:
            path = buck2_output(args.buck2, item) if item.startswith("//") else item
            hits = scan_tree(path, args.root)
            new = [(rel, s) for rel, s in hits if not _allowed(rel)]
            allowed = [rel for rel, _ in hits if _allowed(rel)]
            if allowed:
                print(
                    f"  allowed (known) leaks: {len(allowed)} "
                    f"[{', '.join(sorted(allowed)[:6])}{'...' if len(allowed) > 6 else ''}]"
                )
            if new:
                failed += 1
                print(
                    f"  LEAK: {len(new)} NEW file(s) embed the build root {args.root!r}"
                )
                for rel, sample in new[: args.max_report]:
                    print(f"    {rel}")
                    print(f"      ...{sample}...")
                if len(new) > args.max_report:
                    print(f"    ... and {len(new) - args.max_report} more")
            else:
                print("  clean (no new absolute build-root leak)")
        except (RuntimeError, OSError) as exc:
            failed += 1
            print(f"  ERROR: {exc}")

    print(
        f"\n{'FAIL' if failed else 'PASS'}: {failed}/{len(args.items)} item(s) have new leaks"
    )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
