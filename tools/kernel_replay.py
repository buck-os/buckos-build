#!/usr/bin/env python3
"""kernel_replay.py — sequentially replay a captured kernel build.

Reads build_plan.json and re-executes captured exec records
in their original timestamp order to reproduce the build outputs.

Replay strategy: only replay records whose parent process was `make`
(either an explicit `make` exec in the trace, or the implicit outer
`make` we launched). Drop `make` execs themselves. This avoids double-
execution of nested processes (e.g., cc forks cc1/as/ld internally —
those are captured too, but cc's replay will fork them again on its own).

Path stability: replay assumes the build_tree is at the same absolute
path it was at capture time. Source must be pre-staged there. (Buck's kernel_replay rule does relocatable per-action replay
instead.)

Usage:
    kernel_replay.py --plan /tmp/cap/build_plan.json \
                     --source-dir /path/to/linux \
                     --config /path/to/.config \
                     [--fresh]
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


def main() -> int:
    p = argparse.ArgumentParser(description="Replay a captured kernel build")
    p.add_argument("--plan", required=True, help="build_plan.json")
    p.add_argument("--source-dir", required=True,
                   help="Pristine kernel source to stage into the build tree")
    p.add_argument("--config", required=True, help="Resolved .config")
    p.add_argument("--fresh", action="store_true",
                   help="Wipe build_tree and re-stage source before replay")
    p.add_argument("--limit", type=int, default=0,
                   help="Replay only the first N actions (debug)")
    p.add_argument("--dry-run", action="store_true",
                   help="Print what would be replayed; don't exec")
    p.add_argument("--strict", action="store_true",
                   help="Fail on first non-zero exit (default: log and continue, "
                        "since captured execs include feature probes that fail "
                        "intentionally — real exit codes are not yet recorded)")
    args = p.parse_args()

    plan = json.loads(Path(args.plan).read_text())
    build_tree = Path(plan["build_tree"])
    source_dir = Path(args.source_dir).resolve()
    config = Path(args.config).resolve()

    if args.fresh:
        if build_tree.exists():
            log(f"wiping build tree: {build_tree}")
            shutil.rmtree(build_tree)
        log(f"staging source: {source_dir} -> {build_tree}")
        shutil.copytree(source_dir, build_tree, symlinks=True)
        shutil.copy2(config, build_tree / ".config")

    if not build_tree.is_dir():
        die(f"build tree missing at {build_tree}; pass --fresh or pre-stage")

    actions = plan["actions"]
    log(f"loaded plan: {len(actions)} captured actions")
    replay_set = select_replayable(actions)
    log(f"selected for replay: {len(replay_set)} actions "
        f"(filtered out {len(actions) - len(replay_set)} make/internal records)")

    if args.limit:
        replay_set = replay_set[:args.limit]
        log(f"--limit applied: {len(replay_set)} actions")

    failures = 0
    for i, act in enumerate(replay_set):
        if args.dry_run:
            print(f"  [{i+1}/{len(replay_set)}] {act['phase']}/{act['category']}: "
                  f"{summarize(act)}")
            continue
        rc = replay_one(act)
        if rc != 0:
            failures += 1
            if args.strict:
                log(f"FAIL [{i+1}/{len(replay_set)}] rc={rc} {summarize(act)}")
                log(f"  cwd={act['cwd']}")
                log(f"  argv={act['argv'][:8]}...")
                return rc
            # Non-strict: many feature probes (cc-option, cc-disable-warning)
            # fail intentionally — make's $(call try-run,...) wraps them in
            # `||`. We can't distinguish here, so we keep going and rely on
            # final output verification.
            if failures <= 5 or failures % 50 == 0:
                log(f"  rc={rc} (non-fatal) [{i+1}/{len(replay_set)}] "
                    f"{summarize(act)[:80]}")
        if (i + 1) % 500 == 0:
            log(f"  progress: {i+1}/{len(replay_set)} ({failures} non-fatal failures)")

    log(f"replay complete: {len(replay_set)} actions, "
        f"{failures} non-fatal failures (mostly feature probes)")
    return 0


def select_replayable(actions: list) -> list:
    """Keep only direct children of `make` (excluding make itself).

    Identifies make-pids two ways:
      1. Explicit: any captured exec whose argv[0] basename is `make`.
         (Sub-makes invoked via $(MAKE) -C ... are themselves captured
         when the shim re-loads in the new process image.)
      2. Implicit: ppids that never appear as pids AND are the parent
         of >= 2 records. The outer make (which we launched from the
         capture driver before the shim took effect) spawns many recipes
         so its pid appears as ppid many times. Transient internal
         processes (e.g., the helper pid between gcc and cc1) appear
         as ppid only once and must NOT be treated as make.
    """
    pids = {a["pid"] for a in actions}
    explicit_make_pids = {
        a["pid"] for a in actions
        if a["argv"] and os.path.basename(a["argv"][0]) == "make"
    }
    ppid_counts = {}
    for a in actions:
        ppid_counts[a["ppid"]] = ppid_counts.get(a["ppid"], 0) + 1
    implicit_make_pids = {
        ppid for ppid, count in ppid_counts.items()
        if ppid not in pids and count >= 2
    }
    make_pids = explicit_make_pids | implicit_make_pids

    out = []
    for a in actions:
        if not a["argv"]:
            continue
        if os.path.basename(a["argv"][0]) == "make":
            continue
        if a["ppid"] not in make_pids:
            continue
        out.append(a)
    out.sort(key=lambda a: a["ts"])
    return out


def replay_one(act: dict) -> int:
    """Re-execute one captured action."""
    env = env_list_to_dict(act["env"])
    # Strip the shim so children aren't re-traced.
    env.pop("LD_PRELOAD", None)
    env.pop("KBUILD_TRACE_FILE", None)
    env.pop("KBUILD_TRACE_FD", None)

    cwd = act["cwd"] or None
    if cwd and not os.path.isdir(cwd):
        log(f"WARN cwd missing: {cwd} — using current dir")
        cwd = None

    # `path` is the resolved binary; argv[0] is the originally-requested
    # name. Use path if absolute, else fall back to argv[0] via PATH.
    argv = list(act["argv"])
    path = act.get("path") or argv[0]

    try:
        r = subprocess.run([path] + argv[1:], cwd=cwd, env=env)
        return r.returncode
    except FileNotFoundError as e:
        log(f"missing exec: {path}: {e}")
        return 127


def env_list_to_dict(env_list: list) -> dict:
    """Captured env is list[str] of KEY=VALUE entries."""
    out = {}
    for entry in env_list:
        if "=" not in entry:
            continue
        k, v = entry.split("=", 1)
        out[k] = v
    return out


def summarize(act: dict) -> str:
    argv = act["argv"]
    head = " ".join(argv[:4])
    if len(argv) > 4:
        head += f" ... ({len(argv)} args)"
    return head


def log(msg: str) -> None:
    print(f"[replay] {msg}", file=sys.stderr, flush=True)


def die(msg: str):
    print(f"[replay] error: {msg}", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    sys.exit(main())
