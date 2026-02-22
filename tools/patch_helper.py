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
    args = parser.parse_args()

    if not os.path.isdir(args.source_dir):
        print(f"error: source directory not found: {args.source_dir}", file=sys.stderr)
        sys.exit(1)

    if not args.patches and not args.cmds:
        print(f"error: no patches or commands specified", file=sys.stderr)
        sys.exit(1)

    # Copy source to output
    if os.path.exists(args.output_dir):
        shutil.rmtree(args.output_dir)
    shutil.copytree(args.source_dir, args.output_dir, symlinks=True)

    # Apply each patch in order
    for patch_file in args.patches:
        if not os.path.isfile(patch_file):
            print(f"error: patch file not found: {patch_file}", file=sys.stderr)
            sys.exit(1)

        patch_abs = os.path.abspath(patch_file)
        result = subprocess.run(
            ["patch", f"-p{args.strip}", "-i", patch_abs],
            cwd=args.output_dir,
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
    cmd_env["S"] = os.path.abspath(args.output_dir)
    cmd_env["WORKDIR"] = cmd_env.get("BUCK_SCRATCH_PATH", os.path.abspath(args.output_dir))

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
            cwd=args.output_dir,
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


if __name__ == "__main__":
    main()
