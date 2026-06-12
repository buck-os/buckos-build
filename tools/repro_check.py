#!/usr/bin/env python3
"""Reproducibility check: build targets twice independently, compare outputs.

For each target, build it under buck2's default isolation and again under a
separate ``--isolation-dir``, then assert the two materialized outputs are
byte-identical.  A separate isolation dir forces fully independent action
execution: it changes output paths and therefore action cache keys, so the
second build shares neither the local nor the remote cache and runs from
clean.  An identical result means the build is reproducible; a difference
exposes non-determinism -- embedded build timestamps, absolute build paths,
$RANDOM, parallel-make ordering -- that the hermeticity gate alone misses.

Because the second build cannot reuse the cache, it rebuilds the whole
dependency closure (including the toolchain).  This is therefore a heavy,
dedicated job (nightly / manual), not a per-PR gate.

Usage:
    tools/repro_check.py [--isolation-dir NAME] [--buck2 PATH] TARGET [TARGET ...]

Exit status is non-zero if any target's two builds differ or fail to build.
"""

import argparse
import hashlib
import os
import stat
import subprocess
import sys


def _run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def buck2_output(buck2, target, isolation=None):
    """Build ``target`` (optionally under ``isolation``); return its output path."""
    cmd = [buck2]
    if isolation:
        cmd += ["--isolation-dir", isolation]
    cmd += ["build", target, "--show-full-output"]
    res = _run(cmd)
    if res.returncode != 0:
        sys.stderr.write(res.stderr[-4000:])
        where = f" (isolation {isolation})" if isolation else ""
        raise RuntimeError(f"build failed: {target}{where}")
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            return parts[-1]
    raise RuntimeError(f"no --show-full-output path for {target}")


def _hash_file(path, h):
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b""):
            h.update(chunk)


def hash_path(path):
    """Stable content hash of a file, symlink, or directory tree.

    Hashes relative paths, file modes, symlink targets, and file contents so
    that two builds materialized under different buck-out roots compare equal
    iff their content (not their location) is identical.
    """
    h = hashlib.sha256()
    if os.path.islink(path):
        return hashlib.sha256(b"L" + os.readlink(path).encode()).hexdigest()
    if os.path.isfile(path):
        _hash_file(path, h)
        return h.hexdigest()
    for root, dirs, files in os.walk(path):
        dirs.sort()
        for name in sorted(files):
            fp = os.path.join(root, name)
            rel = os.path.relpath(fp, path)
            h.update(b"\0F" + rel.encode())
            if os.path.islink(fp):
                h.update(b"\0L" + os.readlink(fp).encode())
            else:
                mode = stat.S_IMODE(os.lstat(fp).st_mode)
                h.update(f"\0m{mode:o}".encode())
                _hash_file(fp, h)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(
        description="Build each target twice independently and compare outputs."
    )
    ap.add_argument("targets", nargs="+", help="buck2 target labels to check")
    ap.add_argument(
        "--isolation-dir",
        default="buckos-repro",
        help="isolation dir for the second, independent build (default: buckos-repro)",
    )
    ap.add_argument("--buck2", default="buck2", help="path to the buck2 binary")
    args = ap.parse_args()

    results = []
    for target in args.targets:
        print(f"\n=== {target} ===", flush=True)
        try:
            print("  build 1 (default isolation)...", flush=True)
            out1 = buck2_output(args.buck2, target)
            h1 = hash_path(out1)
            print(f"    {h1}  {out1}", flush=True)

            print(
                f"  build 2 (--isolation-dir {args.isolation_dir}, from clean)...",
                flush=True,
            )
            out2 = buck2_output(args.buck2, target, isolation=args.isolation_dir)
            h2 = hash_path(out2)
            print(f"    {h2}  {out2}", flush=True)

            ok = h1 == h2
            results.append((target, ok, None))
            print("  REPRODUCIBLE" if ok else "  NON-REPRODUCIBLE", flush=True)
        except (RuntimeError, OSError) as exc:
            results.append((target, False, str(exc)))
            print(f"  ERROR: {exc}", flush=True)

    print("\n=== summary ===")
    failed = 0
    for target, ok, err in results:
        print(f"  {'ok  ' if ok else 'FAIL'}  {target}" + (f"  ({err})" if err else ""))
        failed += 0 if ok else 1
    print(f"\n{len(results) - failed}/{len(results)} reproducible")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
