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
    args = parser.parse_args()

    if not os.path.isdir(args.source_dir):
        print(f"error: source directory not found: {args.source_dir}", file=sys.stderr)
        sys.exit(1)

    if not args.patches:
        print(f"error: no patches specified", file=sys.stderr)
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


if __name__ == "__main__":
    main()
