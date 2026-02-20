#!/usr/bin/env python3
"""Sysroot merge helper.

Copies a base sysroot directory and overlays additional content on top.
Used to incrementally build sysroots across bootstrap steps (e.g.
linux-headers -> glibc -> merged sysroot for GCC pass2).
"""

import argparse
import os
import shutil
import sys


def main():
    parser = argparse.ArgumentParser(description="Merge sysroot directories")
    parser.add_argument("--base", default=None,
                        help="Base sysroot directory to copy first (optional)")
    parser.add_argument("--overlay", action="append", dest="overlays", default=[],
                        help="Directory to overlay on top (repeatable, applied in order)")
    parser.add_argument("--output-dir", required=True,
                        help="Output sysroot directory")
    args = parser.parse_args()

    if not args.base and not args.overlays:
        print("error: at least --base or --overlay must be specified", file=sys.stderr)
        sys.exit(1)

    output = args.output_dir
    if os.path.exists(output):
        shutil.rmtree(output)

    if args.base:
        if not os.path.isdir(args.base):
            print(f"error: base directory not found: {args.base}", file=sys.stderr)
            sys.exit(1)
        shutil.copytree(args.base, output, symlinks=True)
    else:
        os.makedirs(output)

    for overlay in args.overlays:
        if not os.path.isdir(overlay):
            print(f"error: overlay directory not found: {overlay}", file=sys.stderr)
            sys.exit(1)
        # Walk overlay and copy files, merging directories
        for dirpath, dirnames, filenames in os.walk(overlay):
            rel = os.path.relpath(dirpath, overlay)
            dest_dir = os.path.join(output, rel)
            os.makedirs(dest_dir, exist_ok=True)
            for f in filenames:
                src = os.path.join(dirpath, f)
                dst = os.path.join(dest_dir, f)
                if os.path.islink(src):
                    link_target = os.readlink(src)
                    if os.path.exists(dst) or os.path.islink(dst):
                        os.remove(dst)
                    os.symlink(link_target, dst)
                else:
                    shutil.copy2(src, dst)


if __name__ == "__main__":
    main()
