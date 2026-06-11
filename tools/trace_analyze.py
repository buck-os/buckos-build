#!/usr/bin/env python3
"""trace_analyze.py — analyze a kbuild_trace exec log for host-tool leakage.

Reads a JSON-lines exec trace produced by libkbuild_trace.so (see
tools/kbuild_trace/trace.c) and reports two things:

  1. Host-tool leakage — every exec whose *resolved* binary path lies
     OUTSIDE the set of allowed hermetic prefixes (the buckos toolchain
     and declared deps under buck-out, plus an allowlist of safe system
     dirs).  A leak means the build invoked a host tool from /usr/bin,
     /bin, /usr/sbin, etc. instead of a hermetic one — the recurring
     hermeticity bug class this tool exists to catch.

  2. A tool-usage summary — which distinct tools the build actually
     invoked, with counts.  Useful for working out the right `host_deps`
     for a package.

Each trace record looks like (one JSON object per line):

    {"ts":<ns>,"pid":1234,"ppid":1233,"call":"execve","cwd":"/abs",
     "path":"/usr/bin/gcc","argv":["gcc","-c","foo.c"],
     "env":["PATH=/usr/bin","HOME=/root"]}

The shim records `path` (argv0/file as passed to exec) and `cwd`; for the
PATH-searching exec variants (execvp/execvpe/posix_spawnp) `path` may be
a bare name like "gcc" rather than an absolute path.  We resolve it the
same way the kernel would: absolute paths and ./relative paths are taken
as-is (relative to `cwd`); bare names are searched along that record's
captured PATH (extracted from its `env`).  The resolved absolute path is
what we classify as hermetic-or-not.

Exit codes:
  0 — no host-tool leaks (or --no-fail)
  1 — host-tool leaks found
  2 — usage / input error

Stdlib-only; no third-party deps.  Mirrors the style of tools/elf_audit.py.
"""

import argparse
import json
import os
import sys


# Directories that are always considered "host" — a resolved binary under
# any of these is a leak unless the user explicitly allowlists it.  These
# are the classic contamination sources called out by the hermeticity gate
# (tools/check_hermeticity.sh, tools/elf_audit.py).
DEFAULT_HOST_PREFIXES = (
    "/usr/bin",
    "/usr/sbin",
    "/bin",
    "/sbin",
    "/usr/local/bin",
    "/usr/local/sbin",
    "/opt",
)

# Binary basenames that are benign even when they resolve to a host path.
# These are shell/coreutils builtins or kernel-provided helpers that the
# trace shim may record before the hermetic PATH is fully in effect, and
# which never link host libraries in a way that contaminates output.
# Conservative — extend via --allow-tool rather than growing this blindly.
DEFAULT_ALLOWED_TOOLS = frozenset(
    {
        "env",
        "unshare",
    }
)


def _parse_env_list(env_list):
    """Turn a trace record's env array (["K=V", ...]) into a dict.

    Only the first '=' splits key from value, so values may contain '='.
    Malformed entries (no '=') are skipped.
    """
    env = {}
    for entry in env_list or []:
        key, sep, value = entry.partition("=")
        if sep and key:
            env[key] = value
    return env


def _resolve_binary(path, cwd, env):
    """Resolve a trace record's exec target to an absolute binary path.

    Mirrors how execvp(3)/the kernel would find the binary:
      * absolute path           -> normalized as-is
      * contains a '/' (e.g. ./configure, sub/tool) -> resolved vs cwd
      * bare name (e.g. "gcc")  -> searched along this record's PATH,
                                   each dir taken relative to cwd if the
                                   PATH entry is itself relative

    Returns the resolved absolute path if found, otherwise the best-effort
    normalized path (so unresolved bare names still surface in the report
    rather than vanishing).  The second return value is True when the path
    was resolved to an existing executable, False when it is a guess.
    """
    if not path:
        return "", False

    if os.path.isabs(path):
        return os.path.normpath(path), True

    if "/" in path:
        # Relative path like ./configure or build/tool — anchor to cwd.
        base = cwd if cwd else os.getcwd()
        resolved = os.path.normpath(os.path.join(base, path))
        return resolved, os.path.isfile(resolved)

    # Bare name — walk the captured PATH.
    path_env = env.get("PATH", "")
    for entry in path_env.split(":"):
        if not entry:
            continue
        # A relative PATH entry is interpreted relative to the exec's cwd.
        if not os.path.isabs(entry) and cwd:
            entry = os.path.join(cwd, entry)
        candidate = os.path.normpath(os.path.join(entry, path))
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate, True

    # Could not resolve against PATH — return the bare name unchanged so
    # the caller can still surface it (as unresolved) in the summary.
    return path, False


def _under_any(path, prefixes):
    """True if path equals or is nested under any of prefixes."""
    for pfx in prefixes:
        if pfx and (path == pfx or path.startswith(pfx.rstrip("/") + "/")):
            return True
    return False


def _is_hermetic(resolved, allowed_prefixes, host_prefixes, strict):
    """Classify a resolved binary path as hermetic (True) or a leak (False).

    Two policies, chosen by `strict`:

      * strict=True (an allowlist is authoritative): a path is hermetic
        ONLY if it is under one of allowed_prefixes.  Everything else —
        host dirs, /usr/libexec, unresolved bare names — is a leak.
        This is the gating mode (pass the buck-out root / dep prefixes
        as --allow-prefix).

      * strict=False (no allowlist, or default host-dir mode): a path is
        a leak only if it is under one of host_prefixes (the classic
        /usr/bin, /bin, ... contamination dirs) or is an unresolved bare
        name.  Conservative — won't flag things like gcc's cc1 under
        /usr/libexec.  allowed_prefixes still override host_prefixes.

    Unresolved bare names (no '/') are always leaks: the build invoked a
    tool that wasn't found along its hermetic PATH — the "undeclared dep /
    fell through to host" signal.
    """
    if not resolved:
        return True  # nothing to classify
    # Explicit hermetic allow always wins.
    if _under_any(resolved, allowed_prefixes):
        return True
    # Unresolved bare name (couldn't be located on the hermetic PATH).
    if "/" not in resolved:
        return False
    if strict:
        # Authoritative allowlist: anything not allowed above is a leak.
        return False
    # Lenient: only the known host dirs count as leaks.
    return not _under_any(resolved, host_prefixes)


def _load_trace(trace_path):
    """Yield parsed records from a JSONL trace, skipping blanks/garbage.

    Returns a list of (lineno, record) tuples and a count of truncated
    records (which the shim marks when argv+env overflow its buffer).
    """
    records = []
    truncated = 0
    with open(trace_path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                # A truncated final write can leave a partial line; skip it
                # but don't abort the whole analysis.
                continue
            if rec.get("truncated"):
                truncated += 1
            records.append((lineno, rec))
    return records, truncated


def main():
    parser = argparse.ArgumentParser(
        description="Analyze a kbuild_trace JSONL for host-tool leakage",
    )
    parser.add_argument(
        "trace",
        help="Path to the kbuild_trace JSONL file (KBUILD_TRACE_FILE output)",
    )
    parser.add_argument(
        "--allow-prefix",
        action="append",
        dest="allow_prefixes",
        default=[],
        help="Hermetic prefix to treat as allowed (repeatable).  Typically "
        "the buck-out root or a toolchain/dep prefix.  A resolved binary "
        "under one of these is never a leak.",
    )
    parser.add_argument(
        "--allow-prefix-file",
        default=None,
        help="File of allowed hermetic prefixes, one per line.",
    )
    parser.add_argument(
        "--host-prefix",
        action="append",
        dest="host_prefixes",
        default=[],
        help="Additional host prefix to flag as a leak (repeatable).  "
        "Defaults already cover /usr/bin, /bin, /usr/sbin, etc.",
    )
    parser.add_argument(
        "--allow-tool",
        action="append",
        dest="allow_tools",
        default=[],
        help="Binary basename that is never a leak even if it resolves to "
        "a host path (repeatable).  E.g. env, unshare.",
    )
    parser.add_argument(
        "--no-default-host-prefixes",
        action="store_true",
        help="Don't seed the host prefix set with the built-in defaults "
        "(use only --host-prefix entries).  Implies --strict.",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Allowlist-authoritative mode: any resolved binary NOT under an "
        "--allow-prefix is a leak (catches /usr/libexec, etc.).  Requires at "
        "least one --allow-prefix.  Implied by --no-default-host-prefixes.",
    )
    parser.add_argument(
        "--summary-only",
        action="store_true",
        help="Print only the tool-usage summary; suppress per-leak detail.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit a machine-readable JSON report instead of text.",
    )
    parser.add_argument(
        "--max-examples",
        type=int,
        default=5,
        help="Max example execs to print per leaking tool (default: 5).",
    )
    parser.add_argument(
        "--no-fail",
        action="store_true",
        help="Always exit 0, even when leaks are found (report-only mode).",
    )
    args = parser.parse_args()

    if not os.path.isfile(args.trace):
        print(f"error: trace file not found: {args.trace}", file=sys.stderr)
        sys.exit(2)

    allow_prefixes = [os.path.normpath(p) for p in args.allow_prefixes if p]
    if args.allow_prefix_file:
        try:
            with open(args.allow_prefix_file) as f:
                for line in f:
                    line = line.strip()
                    if line:
                        allow_prefixes.append(os.path.normpath(line))
        except OSError as e:
            print(f"error: cannot read --allow-prefix-file: {e}", file=sys.stderr)
            sys.exit(2)

    host_prefixes = list(args.host_prefixes)
    if not args.no_default_host_prefixes:
        host_prefixes = list(DEFAULT_HOST_PREFIXES) + host_prefixes

    # Strict (allowlist-authoritative) mode: anything outside --allow-prefix
    # is a leak.  Explicit via --strict, or implied by dropping the default
    # host prefixes.  Guard against the footgun of strict mode with no
    # allowlist (which would flag literally every exec).
    strict = args.strict or args.no_default_host_prefixes
    if strict and not allow_prefixes:
        print(
            "error: --strict / --no-default-host-prefixes requires at least "
            "one --allow-prefix (otherwise every exec is a leak)",
            file=sys.stderr,
        )
        sys.exit(2)

    allow_tools = set(DEFAULT_ALLOWED_TOOLS) | set(args.allow_tools)

    records, truncated = _load_trace(args.trace)

    # tool_basename -> {"count": int, "hermetic": int, "leak": int,
    #                   "examples": [ {resolved, cwd, argv}, ... ]}
    tools = {}
    leaks = []  # flat list of leaking exec dicts

    for lineno, rec in records:
        argv = rec.get("argv") or []
        path = rec.get("path", "")
        cwd = rec.get("cwd", "")
        env = _parse_env_list(rec.get("env"))

        # Prefer the recorded path; fall back to argv[0] for the PATH-search
        # variants where the shim stored the bare file name in `path`.
        target = path or (argv[0] if argv else "")
        if not target:
            continue

        resolved, found = _resolve_binary(target, cwd, env)
        basename = os.path.basename(resolved) or os.path.basename(target)

        entry = tools.setdefault(
            basename,
            {"count": 0, "hermetic": 0, "leak": 0, "examples": []},
        )
        entry["count"] += 1

        hermetic = basename in allow_tools or _is_hermetic(
            resolved, allow_prefixes, host_prefixes, strict
        )
        if hermetic:
            entry["hermetic"] += 1
        else:
            entry["leak"] += 1
            leak_rec = {
                "tool": basename,
                "resolved": resolved,
                "found": found,
                "cwd": cwd,
                "argv": argv,
                "lineno": lineno,
                "pid": rec.get("pid"),
            }
            leaks.append(leak_rec)
            if len(entry["examples"]) < args.max_examples:
                entry["examples"].append(leak_rec)

    if args.json:
        report = {
            "trace": os.path.abspath(args.trace),
            "total_execs": len(records),
            "truncated_records": truncated,
            "leak_count": len(leaks),
            "leaking_tools": sorted({lk["tool"] for lk in leaks}),
            "tools": {
                name: {
                    "count": meta["count"],
                    "hermetic": meta["hermetic"],
                    "leak": meta["leak"],
                }
                for name, meta in tools.items()
            },
            "leaks": leaks,
        }
        print(json.dumps(report, indent=2))
        if leaks and not args.no_fail:
            sys.exit(1)
        sys.exit(0)

    # ── Text report ──────────────────────────────────────────────────
    print(f"trace: {os.path.abspath(args.trace)}")
    print(f"execs: {len(records)} total, {len(tools)} distinct tools")
    if truncated:
        print(f"warning: {truncated} truncated record(s) — argv/env may be incomplete")
    print("")

    # Tool-usage summary (sorted by count desc, then name).
    print("== tool usage ==")
    for name in sorted(tools, key=lambda n: (-tools[n]["count"], n)):
        meta = tools[name]
        flag = "  LEAK" if meta["leak"] else ""
        print(f"  {meta['count']:6d}  {name}{flag}")
    print("")

    if not args.summary_only:
        if leaks:
            leaking_tools = sorted({lk["tool"] for lk in leaks})
            print(
                f"== host-tool leaks ({len(leaks)} execs, "
                f"{len(leaking_tools)} tools) =="
            )
            for name in leaking_tools:
                meta = tools[name]
                print(f"  {name}  ({meta['leak']} exec(s))")
                for ex in meta["examples"]:
                    where = (
                        ex["resolved"]
                        if ex["found"]
                        else (ex["resolved"] + "  (UNRESOLVED on hermetic PATH)")
                    )
                    print(f"    -> {where}")
                    argv_str = " ".join(ex["argv"][:8])
                    if len(ex["argv"]) > 8:
                        argv_str += " ..."
                    print(f"       argv: {argv_str}")
                    print(f"       cwd:  {ex['cwd']}  (line {ex['lineno']})")
                if meta["leak"] > len(meta["examples"]):
                    print(
                        f"    ... and {meta['leak'] - len(meta['examples'])} "
                        f"more exec(s)"
                    )
            print("")
        else:
            print("== host-tool leaks ==")
            print("  none — all execs resolved to hermetic prefixes")
            print("")

    if leaks:
        print(f"FAIL: {len(leaks)} host-tool leak exec(s) found")
        if not args.no_fail:
            sys.exit(1)
    else:
        print("OK: no host-tool leakage detected")
    sys.exit(0)


if __name__ == "__main__":
    main()
