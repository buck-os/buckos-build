#!/usr/bin/env python3
"""Merge host tool package prefixes into a single directory.

Creates a merged FHS-like prefix from each package's usr/ tree so that
scripts (Perl, Python, shell) can find their sibling data files (modules,
m4 macros, share/ data) relative to the merged prefix.

Output layout:
    output/bin/          — merged executables
    output/sbin/         — merged system executables
    output/share/        — merged data (automake macros, aclocal, etc.)
    output/lib/          — merged libraries and perl/python modules
    output/libexec/      — merged helper programs
"""

import argparse
import os
import shutil
import sys


def _merge_tree(src_dir, dst_dir):
    """Recursively merge src_dir into dst_dir, skipping conflicts."""
    for entry in os.scandir(src_dir):
        dst = os.path.join(dst_dir, entry.name)
        if entry.is_dir(follow_symlinks=False):
            os.makedirs(dst, exist_ok=True)
            _merge_tree(entry.path, dst)
        elif entry.is_symlink():
            linkto = os.readlink(entry.path)
            if os.path.lexists(dst):
                os.remove(dst)
            os.symlink(linkto, dst)
        elif entry.is_file():
            if not os.path.exists(dst):
                shutil.copy2(entry.path, dst)


def main():
    parser = argparse.ArgumentParser(description="Merge host tool packages")
    parser.add_argument("--output", required=True, help="Output directory")
    parser.add_argument("--prefix", action="append", dest="prefixes", default=[],
                        help="Package prefix directory (repeatable)")
    args = parser.parse_args()

    output = os.path.abspath(args.output)

    for prefix in args.prefixes:
        prefix = os.path.abspath(prefix)
        usr_dir = os.path.join(prefix, "usr")
        if not os.path.isdir(usr_dir):
            continue
        for subdir in ("bin", "sbin", "share", "lib", "lib64", "libexec", "include"):
            src_dir = os.path.join(usr_dir, subdir)
            if not os.path.isdir(src_dir):
                continue
            dst_dir = os.path.join(output, subdir)
            os.makedirs(dst_dir, exist_ok=True)
            _merge_tree(src_dir, dst_dir)

    # Remove broken symlinks left by cross-directory references that
    # don't resolve within the merged tree (e.g. sbin/foo -> ../bin/bar
    # where bar wasn't merged, or lib64/foo.so -> ../../lib64/foo.so.1).
    broken = 0
    for dirpath, dirnames, filenames in os.walk(output):
        for name in filenames + list(dirnames):
            path = os.path.join(dirpath, name)
            if os.path.islink(path) and not os.path.exists(path):
                os.remove(path)
                broken += 1
    if broken:
        print(f"Removed {broken} broken symlinks", file=sys.stderr)

    bin_dir = os.path.join(output, "bin")
    count = len(os.listdir(bin_dir)) if os.path.isdir(bin_dir) else 0
    print(f"Merged {count} tools into {output}", file=sys.stderr)


if __name__ == "__main__":
    main()
