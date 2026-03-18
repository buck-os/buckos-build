#!/usr/bin/env python3
"""Apply patches in order to a source tree.

Copies source to output dir, then runs patch(1) for each patch file
in the order given.  Exits non-zero on first failure, identifying which
patch failed.
"""

import argparse
import os
import shutil
import subprocess
import sys

from _env import add_path_args, clean_env, setup_path


def main():
    parser = argparse.ArgumentParser(description="Apply patches in order")
    parser.add_argument("--source-dir", required=True, help="Source directory to patch")
    parser.add_argument("--output-dir", required=True, help="Output directory (copy of source + patches)")
    parser.add_argument("--patch", action="append", dest="patches", default=[],
                        help="Patch file to apply (repeatable, applied in order)")
    parser.add_argument("--strip", type=int, default=1,
                        help="Strip N leading path components from patch paths (default: 1)")
    parser.add_argument("--cmd", action="append", dest="cmds", default=[],
                        help="Shell command to run in source dir after patches (repeatable)")
    add_path_args(parser)
    args = parser.parse_args()

    # Save action-declared env vars before clean_env wipes them
    dep_base_dirs = os.environ.get("DEP_BASE_DIRS")
    host_path = os.environ.get("PATH", "")

    env = clean_env()
    setup_path(args, env, host_path=host_path)
    os.environ.clear()
    os.environ.update(env)

    # Restore action-declared vars after sanitization
    if dep_base_dirs is not None:
        os.environ["DEP_BASE_DIRS"] = dep_base_dirs

    if not os.path.isdir(args.source_dir):
        print(f"error: source directory not found: {args.source_dir}", file=sys.stderr)
        sys.exit(1)

    if not args.patches and not args.cmds:
        print(f"error: no patches or commands specified", file=sys.stderr)
        sys.exit(1)

    _final_output = os.path.abspath(args.output_dir)

    # Redirect patch operations to scratch — the declared output is written
    # once at the end (clean copy of the patched tree, never mutated).
    _scratch = os.path.abspath(os.environ.get("BUCK_SCRATCH_PATH",
                                              os.environ.get("TMPDIR", "/tmp")))
    output_dir = os.path.join(_scratch, "patch-tree")

    # Copy source to scratch
    if os.path.exists(output_dir):
        shutil.rmtree(output_dir)
    shutil.copytree(args.source_dir, output_dir, symlinks=True)

    # Reset timestamps to SOURCE_DATE_EPOCH to prevent autotools regeneration.
    # The copy changes mtime ordering, causing make to think configure.ac is
    # newer than generated files and attempt to re-run aclocal/autoconf.
    epoch = os.environ.get("SOURCE_DATE_EPOCH", "315576000")
    subprocess.run(
        ["find", ".", "-exec", "touch", "-h", "-d", f"@{epoch}", "{}", "+"],
        cwd=output_dir,
        capture_output=True,
    )

    # Apply each patch in order
    for patch_file in args.patches:
        if not os.path.isfile(patch_file):
            print(f"error: patch file not found: {patch_file}", file=sys.stderr)
            sys.exit(1)

        patch_abs = os.path.abspath(patch_file)
        result = subprocess.run(
            ["patch", f"-p{args.strip}", "-i", patch_abs],
            cwd=output_dir,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print(f"error: patch failed: {patch_file}", file=sys.stderr)
            if result.stdout:
                print(result.stdout, file=sys.stderr)
            if result.stderr:
                print(result.stderr, file=sys.stderr)
            sys.exit(1)
        print(f"applied: {os.path.basename(patch_file)}")

    # Run shell commands in the output directory
    # Set S to the output dir for compatibility with ebuild-style src_prepare scripts
    cmd_env = os.environ.copy()
    cmd_env["S"] = os.path.abspath(output_dir)
    cmd_env["WORKDIR"] = cmd_env.get("BUCK_SCRATCH_PATH", os.path.abspath(output_dir))

    # Resolve relative buck-out paths in DEP_BASE_DIRS to absolute
    if "DEP_BASE_DIRS" in cmd_env and cmd_env["DEP_BASE_DIRS"]:
        resolved = []
        for p in cmd_env["DEP_BASE_DIRS"].split(":"):
            p = p.strip()
            if p and not os.path.isabs(p):
                resolved.append(os.path.abspath(p))
            else:
                resolved.append(p)
        cmd_env["DEP_BASE_DIRS"] = ":".join(resolved)
    for shell_cmd in args.cmds:
        result = subprocess.run(
            ["bash", "-e", "-c", shell_cmd],
            cwd=output_dir,
            env=cmd_env,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print(f"error: command failed: {shell_cmd}", file=sys.stderr)
            if result.stdout:
                print(result.stdout, file=sys.stderr)
            if result.stderr:
                print(result.stderr, file=sys.stderr)
            sys.exit(1)
        if result.stdout:
            print(result.stdout, end="")

    # Copy finished patch tree from scratch to the declared output.
    if os.path.exists(_final_output):
        shutil.rmtree(_final_output)
    shutil.copytree(output_dir, _final_output, symlinks=True)


if __name__ == "__main__":
    main()
