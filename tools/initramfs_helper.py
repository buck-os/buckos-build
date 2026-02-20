#!/usr/bin/env python3
"""Build a cpio.gz initramfs from a directory tree.

Takes a root directory and produces a gzip-compressed cpio archive
suitable for use as a Linux initramfs.
"""

import argparse
import gzip
import os
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description="Build cpio.gz initramfs")
    parser.add_argument("--root-dir", required=True, help="Root directory to pack")
    parser.add_argument("--output", required=True, help="Output file path (cpio.gz)")
    args = parser.parse_args()

    if not os.path.isdir(args.root_dir):
        print(f"error: root directory not found: {args.root_dir}", file=sys.stderr)
        sys.exit(1)

    output_dir = os.path.dirname(os.path.abspath(args.output))
    os.makedirs(output_dir, exist_ok=True)

    # Use find | cpio to build the archive, then gzip it.
    # cpio -o -H newc is the standard initramfs format.
    find_proc = subprocess.Popen(
        ["find", ".", "-print0"],
        cwd=args.root_dir,
        stdout=subprocess.PIPE,
    )
    cpio_proc = subprocess.Popen(
        ["cpio", "--null", "-o", "-H", "newc", "--quiet"],
        cwd=args.root_dir,
        stdin=find_proc.stdout,
        stdout=subprocess.PIPE,
    )
    find_proc.stdout.close()

    cpio_data, _ = cpio_proc.communicate()
    find_proc.wait()

    if find_proc.returncode != 0:
        print(f"error: find exited with code {find_proc.returncode}", file=sys.stderr)
        sys.exit(1)
    if cpio_proc.returncode != 0:
        print(f"error: cpio exited with code {cpio_proc.returncode}", file=sys.stderr)
        sys.exit(1)

    with gzip.open(args.output, "wb") as f:
        f.write(cpio_data)

    size_kb = os.path.getsize(args.output) // 1024
    print(f"initramfs: {args.output} ({size_kb}K)")


if __name__ == "__main__":
    main()
