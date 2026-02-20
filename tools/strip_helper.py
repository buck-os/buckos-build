#!/usr/bin/env python3
"""Strip ELF binaries and shared libraries.

Copies input directory to output, finds ELF files, and runs strip on them.
"""

import argparse
import os
import shutil
import subprocess
import sys


_ELF_MAGIC = b"\x7fELF"


def is_elf(path):
    """Check if a file is an ELF binary by reading its magic bytes."""
    try:
        with open(path, "rb") as f:
            return f.read(4) == _ELF_MAGIC
    except (OSError, IOError):
        return False


def main():
    parser = argparse.ArgumentParser(description="Strip ELF binaries")
    parser.add_argument("--input", required=True, help="Input directory")
    parser.add_argument("--output", required=True, help="Output directory")
    parser.add_argument("--strip", required=True, dest="strip_bin",
                        help="Path to strip binary")
    args = parser.parse_args()

    if not os.path.isdir(args.input):
        print(f"error: input directory not found: {args.input}", file=sys.stderr)
        sys.exit(1)

    # Copy input to output
    if os.path.exists(args.output):
        shutil.rmtree(args.output)
    shutil.copytree(args.input, args.output, symlinks=True)

    # Find and strip ELF files
    stripped = 0
    errors = 0
    for dirpath, _dirnames, filenames in os.walk(args.output):
        for filename in filenames:
            filepath = os.path.join(dirpath, filename)
            if os.path.islink(filepath):
                continue
            if not os.path.isfile(filepath):
                continue
            if not is_elf(filepath):
                continue

            result = subprocess.run(
                [args.strip_bin, filepath],
                capture_output=True,
                text=True,
            )
            if result.returncode != 0:
                # Some ELF files (e.g. static archives with debug info)
                # may fail to strip; warn but continue
                rel = os.path.relpath(filepath, args.output)
                print(f"warning: strip failed for {rel}: {result.stderr.strip()}", file=sys.stderr)
                errors += 1
            else:
                stripped += 1

    print(f"stripped {stripped} ELF files ({errors} warnings)")


if __name__ == "__main__":
    main()
