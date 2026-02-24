#!/usr/bin/env python3
"""Env-sanitized wrapper for dracut create_script.

Replaces the direct create_script invocation in initramfs.bzl with an
env-sanitized subprocess call.
"""

import os
import subprocess
import sys

from _env import clean_env


def main():
    # Arguments are passed through positionally, matching the original
    # cmd_args layout in _dracut_initramfs_impl:
    #   create_script kernel_image dracut_dir rootfs_dir output kver compress [modules_dir]
    if len(sys.argv) < 7:
        print("usage: dracut_initramfs_helper create_script kernel dracut rootfs output kver compress [modules]",
              file=sys.stderr)
        sys.exit(1)

    create_script = os.path.abspath(sys.argv[1])
    rest = sys.argv[2:]

    if not os.path.isfile(create_script):
        print(f"error: create_script not found: {create_script}", file=sys.stderr)
        sys.exit(1)

    env = clean_env()
    result = subprocess.run([create_script] + rest, env=env)
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
