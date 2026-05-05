#!/usr/bin/env python3
"""kernel_replay_action.py — execute one captured kbuild command.

Invoked by Buck via the kernel_replay rule's dynamic_output, once per
captured action.  Reads the plan, finds the action by id, materialises
a working tree (rooted at the captured build_tree path), runs the
captured shell command, and copies declared outputs to their
Buck-allocated paths.

A single canonical workdir path is used inside BUCK_SCRATCH_PATH so
captured commands that reference paths relative to (or absolute
within) the original build_tree resolve correctly.

Usage:
    kernel_replay_action.py \\
        --plan /buck-out/.../build_plan.json \\
        --build-tree /buck-out/.../build-tree \\
        --action-id 1234 \\
        --output OUT_PATH:BUCK_DECLARED_PATH \\
        [--output OUT_PATH:BUCK_DECLARED_PATH ...] \\
        [--upstream OUT_PATH:UPSTREAM_BUCK_PATH ...]
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


def main() -> int:
    p = argparse.ArgumentParser(description="Replay one captured kbuild action")
    p.add_argument("--plan", required=True)
    p.add_argument("--build-tree", required=True,
                   help="Captured build tree (Buck input artifact)")
    p.add_argument("--action-id", type=int, required=True)
    p.add_argument("--output", action="append", dest="outputs", default=[],
                   help="REL_PATH:DECLARED_PATH (repeatable). REL_PATH is "
                        "relative to the build tree root; DECLARED_PATH is the "
                        "Buck-allocated output path the wrapper copies to.")
    p.add_argument("--upstream", action="append", dest="upstreams", default=[],
                   help="REL_PATH:ARTIFACT_PATH (repeatable). Layered into the "
                        "workdir at REL_PATH so the captured cmd sees upstream "
                        "actions' outputs.")
    p.add_argument("--workdir", default="",
                   help="Explicit workdir (default: $BUCK_SCRATCH_PATH/replay)")
    p.add_argument("--dry-run", action="store_true",
                   help="Print what would run, don't exec")
    args = p.parse_args()

    plan = json.loads(Path(args.plan).read_text())
    build_tree = Path(args.build_tree).resolve()
    action = find_action(plan, args.action_id)
    if action is None:
        die(f"action id {args.action_id} not found in plan")

    workdir = setup_workdir(args, build_tree)
    layer_upstreams(args.upstreams, workdir)

    cmd_str = action_command(action)
    if not cmd_str:
        die(f"action {args.action_id} has no executable command")

    cwd = workdir
    if action.get("cwd"):
        captured_cwd = Path(action["cwd"])
        # If the captured cwd is inside the original build_tree, mirror
        # the same relative subdir inside the workdir.  Otherwise stick
        # with workdir root.
        captured_bt = Path(plan.get("build_tree", str(build_tree)))
        try:
            rel = captured_cwd.relative_to(captured_bt)
            cwd = workdir / rel
            cwd.mkdir(parents=True, exist_ok=True)
        except ValueError:
            pass

    # Sanitise env: take captured env, drop our shim hooks, force
    # workdir-relative PWD so make/sh use the right paths.
    env = build_env(action, workdir)

    log(f"action {args.action_id}: outputs={[o.split(':',1)[0] for o in args.outputs]}")
    if args.dry_run:
        log(f"  cmd: {cmd_str[:200]}")
        log(f"  cwd: {cwd}")
        return 0

    rc = subprocess.run(["sh", "-c", cmd_str], cwd=str(cwd), env=env).returncode
    if rc != 0:
        log(f"action {args.action_id} failed (rc={rc})")
        return rc

    copy_outputs(args.outputs, workdir)
    return 0


def find_action(plan: dict, action_id: int):
    for a in plan["actions"]:
        if a["id"] == action_id:
            return a
    return None


def action_command(action: dict) -> str:
    """Pick the best executable form of a captured action.

    Prefer the kbuild .cmd `cmd` string when available — it's the resolved
    shell recipe make would have run.  Fall back to joining argv.
    """
    if action.get("cmd_str"):
        return action["cmd_str"]
    argv = action.get("argv") or []
    if not argv:
        return ""
    return " ".join(shell_quote(a) for a in argv)


def shell_quote(s: str) -> str:
    """Conservative POSIX shell quoting."""
    if not s:
        return "''"
    safe = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-"
    if all(c in safe for c in s):
        return s
    return "'" + s.replace("'", "'\\''") + "'"


def setup_workdir(args, build_tree: Path) -> Path:
    """Create a writable workdir mirroring build_tree.

    Uses hardlinks where possible (cheap) and falls back to copy_tree
    for symlinks.  build_tree contents are read-only inputs from Buck;
    we need a writable view because the captured command may rewrite
    intermediate files.
    """
    if args.workdir:
        wd = Path(args.workdir).resolve()
    else:
        scratch = os.environ.get("BUCK_SCRATCH_PATH",
                                  os.environ.get("TMPDIR", "/tmp"))
        wd = Path(scratch) / "kernel-replay-action"
    if wd.exists():
        shutil.rmtree(wd)
    # cp -al preserves symlinks and hardlinks regular files.  Falls back
    # to copy_tree if cp isn't available or hardlinks fail (e.g., across
    # filesystems).
    try:
        rc = subprocess.run(["cp", "-al", str(build_tree), str(wd)]).returncode
        if rc != 0:
            raise RuntimeError("cp -al failed")
    except (FileNotFoundError, RuntimeError):
        shutil.copytree(build_tree, wd, symlinks=True)
    return wd


def layer_upstreams(upstreams: list, workdir: Path) -> None:
    """Overlay upstream artifacts on top of the workdir at their captured paths."""
    for spec in upstreams:
        if ":" not in spec:
            die(f"--upstream requires REL:PATH, got {spec}")
        rel, src = spec.split(":", 1)
        dst = workdir / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        if dst.exists() or dst.is_symlink():
            dst.unlink()
        # Hardlink if possible (same fs), copy otherwise.
        try:
            os.link(src, dst)
        except OSError:
            shutil.copy2(src, dst)


def build_env(action: dict, workdir: Path) -> dict:
    env_list = action.get("env") or []
    env = {}
    for entry in env_list:
        if "=" not in entry:
            continue
        k, v = entry.split("=", 1)
        env[k] = v
    # Strip the shim so the replay action doesn't re-trace.
    env.pop("LD_PRELOAD", None)
    env.pop("KBUILD_TRACE_FILE", None)
    env.pop("KBUILD_TRACE_FD", None)
    # Keep determinism overrides set during capture.
    env.setdefault("KBUILD_BUILD_TIMESTAMP", "Thu Jan  1 00:00:00 UTC 1970")
    env.setdefault("KBUILD_BUILD_USER", "buckos")
    env.setdefault("KBUILD_BUILD_HOST", "buckos")
    env["PWD"] = str(workdir)
    return env


def copy_outputs(outputs: list, workdir: Path) -> None:
    """Copy each REL:DEST output from workdir to Buck's declared path."""
    for spec in outputs:
        if ":" not in spec:
            die(f"--output requires REL:DEST, got {spec}")
        rel, dest = spec.split(":", 1)
        src = workdir / rel
        if not src.exists():
            die(f"action declared output not produced: {rel} (workdir: {workdir})")
        dest_p = Path(dest)
        dest_p.parent.mkdir(parents=True, exist_ok=True)
        if src.is_dir():
            if dest_p.exists():
                shutil.rmtree(dest_p)
            shutil.copytree(src, dest_p, symlinks=True)
        else:
            shutil.copy2(src, dest_p)


def log(msg: str) -> None:
    print(f"[replay-action] {msg}", file=sys.stderr, flush=True)


def die(msg: str):
    print(f"[replay-action] error: {msg}", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    sys.exit(main())
