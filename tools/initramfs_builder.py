#!/usr/bin/env python3
"""Build an initramfs cpio archive from a rootfs directory.

Replaces the inline bash in initramfs.bzl.  Handles init script injection,
lib64 path fixups, and cpio+compression.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

from _env import add_path_args, clean_env, setup_path


def _fix_lib64(staging):
    """Fix aarch64 library paths — merge lib64 into lib."""
    for prefix in ("", "usr/"):
        lib64 = os.path.join(staging, prefix + "lib64")
        lib = os.path.join(staging, prefix + "lib")
        if os.path.isdir(lib64) and not os.path.islink(lib64):
            os.makedirs(lib, exist_ok=True)
            for item in os.listdir(lib64):
                src = os.path.join(lib64, item)
                dst = os.path.join(lib, item)
                if not os.path.exists(dst):
                    shutil.move(src, dst)
            shutil.rmtree(lib64)
            os.symlink("lib", lib64)


_DEFAULT_INIT = """\
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
[ -x /etc/init.d/rcS ] && /etc/init.d/rcS
exec /bin/sh
"""


def main():
    _host_path = os.environ.get("PATH", "")

    parser = argparse.ArgumentParser(description="Build initramfs cpio archive")
    parser.add_argument("--rootfs-dir", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--init-path", default="/sbin/init")
    parser.add_argument("--init-script", default=None,
                        help="Path to custom init script to install")
    parser.add_argument("--compression", default="gz",
                        choices=["gz", "xz", "lz4", "zstd"])
    add_path_args(parser)
    args = parser.parse_args()

    env = clean_env()
    setup_path(args, env, _host_path)
    output = os.path.abspath(args.output)
    os.makedirs(os.path.dirname(output) or ".", exist_ok=True)

    compress_cmds = {
        "gz": ["gzip", "-9"],
        "xz": ["xz", "-9", "--check=crc32"],
        "lz4": ["lz4", "-l", "-9"],
        "zstd": ["zstd", "-19"],
    }

    with tempfile.TemporaryDirectory() as staging:
        # Copy rootfs
        rootfs_dir = os.path.abspath(args.rootfs_dir)
        if os.path.isdir(rootfs_dir):
            subprocess.check_call(
                ["cp", "-a", rootfs_dir + "/.", staging],
                env=env,
            )

        # Fix lib64 paths
        _fix_lib64(staging)

        # Install custom init script if provided
        init_script = args.init_script
        if init_script and os.path.isfile(init_script):
            init_dest = os.path.join(staging, args.init_path.lstrip("/"))
            os.makedirs(os.path.dirname(init_dest), exist_ok=True)
            shutil.copy2(init_script, init_dest)
            os.chmod(init_dest, 0o755)
        elif not os.path.exists(os.path.join(staging, args.init_path.lstrip("/"))):
            # Generate a default init if none exists
            busybox = os.path.join(staging, "bin", "busybox")
            if os.path.isfile(busybox):
                sbin = os.path.join(staging, "sbin")
                os.makedirs(sbin, exist_ok=True)
                init_path = os.path.join(sbin, "init")
                if not os.path.exists(init_path):
                    os.symlink("/bin/busybox", init_path)
            elif os.path.isfile(os.path.join(staging, "bin", "sh")):
                sbin = os.path.join(staging, "sbin")
                os.makedirs(sbin, exist_ok=True)
                init_path = os.path.join(sbin, "init")
                with open(init_path, "w") as f:
                    f.write(_DEFAULT_INIT)
                os.chmod(init_path, 0o755)

        # Create /init symlink
        init_link = os.path.join(staging, "init")
        if not os.path.exists(init_link):
            init_target = os.path.join(staging, args.init_path.lstrip("/"))
            if os.path.exists(init_target):
                os.symlink(args.init_path, init_link)
            elif os.path.isfile(os.path.join(staging, "sbin", "init")):
                os.symlink("/sbin/init", init_link)
            elif os.path.isfile(os.path.join(staging, "bin", "sh")):
                with open(init_link, "w") as f:
                    f.write(_DEFAULT_INIT)
                os.chmod(init_link, 0o755)

        # Build cpio archive
        find_proc = subprocess.Popen(
            ["find", ".", "-print0"],
            cwd=staging, stdout=subprocess.PIPE, env=env,
        )
        cpio_proc = subprocess.Popen(
            ["cpio", "--null", "-o", "-H", "newc", "--quiet"],
            cwd=staging, stdin=find_proc.stdout,
            stdout=subprocess.PIPE, env=env,
        )
        find_proc.stdout.close()

        compress_proc = subprocess.Popen(
            compress_cmds[args.compression],
            stdin=cpio_proc.stdout,
            stdout=open(output, "wb"), env=env,
        )
        cpio_proc.stdout.close()

        compress_proc.communicate()
        cpio_proc.wait()
        find_proc.wait()

        if find_proc.returncode != 0:
            print(f"error: find exited with code {find_proc.returncode}", file=sys.stderr)
            sys.exit(1)
        if cpio_proc.returncode != 0:
            print(f"error: cpio exited with code {cpio_proc.returncode}", file=sys.stderr)
            sys.exit(1)
        if compress_proc.returncode != 0:
            print(f"error: compression exited with code {compress_proc.returncode}", file=sys.stderr)
            sys.exit(1)

    print(f"Created initramfs: {output}")


if __name__ == "__main__":
    main()
