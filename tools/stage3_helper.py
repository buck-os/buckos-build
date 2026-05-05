#!/usr/bin/env python3
"""Create a stage3 tarball from a rootfs with metadata.

Replaces the inline bash in image.bzl _stage3_tarball_impl.
"""

import argparse
import gzip
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

from _env import add_path_args, clean_env, setup_path


def _apply_ima(workdir, env):
    """Apply IMA .sig sidecars as security.ima xattrs."""
    if not shutil.which("evmctl"):
        return
    applied = 0
    for dirpath, _, filenames in os.walk(workdir):
        for fname in filenames:
            if not fname.endswith(".sig"):
                continue
            sig_path = os.path.join(dirpath, fname)
            target = sig_path[:-4]
            if not os.path.isfile(target):
                continue
            result = subprocess.run(
                ["evmctl", "ima_setxattr", "--sigfile", sig_path, target],
                env=env, capture_output=True,
            )
            if result.returncode == 0:
                os.remove(sig_path)
                applied += 1
    if applied:
        print(f"Applied security.ima to {applied} files")


def main():
    _host_path = os.environ.get("PATH", "")

    parser = argparse.ArgumentParser(description="Create stage3 tarball")
    parser.add_argument("--rootfs", required=True)
    parser.add_argument("--tarball-output", required=True)
    parser.add_argument("--sha256-output", required=True)
    parser.add_argument("--contents-output", required=True)
    parser.add_argument("--arch", default="amd64")
    parser.add_argument("--variant", default="base")
    parser.add_argument("--libc", default="glibc")
    parser.add_argument("--version", default="0.1")
    parser.add_argument("--compression", default="xz", choices=["xz", "gz", "zstd"])
    add_path_args(parser)
    args = parser.parse_args()

    env = clean_env()
    setup_path(args, env, _host_path)
    rootfs = os.path.abspath(args.rootfs)
    tarball = os.path.abspath(args.tarball_output)
    sha256_file = os.path.abspath(args.sha256_output)
    contents_file = os.path.abspath(args.contents_output)

    compress_flags = {
        "xz": ["-J"],
        "gz": ["-z"],
        "zstd": ["--zstd"],
    }

    build_date = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    date_stamp = datetime.now(timezone.utc).strftime("%Y%m%d")

    print("Creating stage3 tarball...")
    print(f"  Architecture: {args.arch}")
    print(f"  Variant: {args.variant}")
    print(f"  Libc: {args.libc}")
    print(f"  Version: {args.version}")

    with tempfile.TemporaryDirectory() as workdir:
        # Copy rootfs
        shutil.copytree(rootfs, workdir, symlinks=True, dirs_exist_ok=True)

        # Apply IMA xattrs
        _apply_ima(workdir, env)

        # Create metadata directory
        buckos_dir = os.path.join(workdir, "etc", "buckos")
        os.makedirs(buckos_dir, exist_ok=True)
        with open(os.path.join(buckos_dir, "stage3-info"), "w") as f:
            f.write(f"# BuckOS Stage3 Information\n")
            f.write(f"# Generated: {build_date}\n\n")
            f.write(f"[stage3]\nvariant={args.variant}\narch={args.arch}\n")
            f.write(f"libc={args.libc}\ndate={date_stamp}\nversion={args.version}\n\n")
            f.write(f"[build]\nbuild_date={build_date}\n\n")
            f.write(f"[packages]\n# Package count will be updated after build\n")

        # Generate CONTENTS file
        print("Generating CONTENTS file...")
        contents_lines = []
        for dirpath, dirnames, filenames in sorted(os.walk(workdir)):
            dirnames.sort()
            for name in sorted(dirnames + filenames):
                path = os.path.join(dirpath, name)
                relpath = os.path.relpath(path, workdir)
                if os.path.islink(path):
                    target = os.readlink(path)
                    contents_lines.append(f"sym /{relpath} -> {target}\n")
                elif os.path.isdir(path):
                    contents_lines.append(f"dir /{relpath}\n")
                elif os.path.isfile(path):
                    h = hashlib.sha256()
                    try:
                        with open(path, "rb") as fh:
                            for chunk in iter(lambda: fh.read(65536), b""):
                                h.update(chunk)
                        contents_lines.append(f"obj /{relpath} {h.hexdigest()}\n")
                    except (OSError, IOError):
                        contents_lines.append(f"obj /{relpath} 0\n")

        with gzip.open(contents_file, "wt") as f:
            f.writelines(contents_lines)

        # Create tarball
        print(f"Creating tarball with {args.compression} compression...")
        tar_cmd = [
            "tar", "--numeric-owner", "--owner=0", "--group=0",
            "--xattrs", "--sort=name",
        ] + compress_flags[args.compression] + ["-cf", tarball, "-C", workdir, "."]
        result = subprocess.run(tar_cmd, env=env)
        if result.returncode != 0:
            print(f"error: tar failed with exit code {result.returncode}", file=sys.stderr)
            sys.exit(1)

    # Generate SHA256 checksum
    print("Generating SHA256 checksum...")
    h = hashlib.sha256()
    with open(tarball, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    tarball_basename = os.path.basename(tarball)
    with open(sha256_file, "w") as f:
        f.write(f"{h.hexdigest()}  {tarball_basename}\n")

    print("Stage3 tarball created successfully!")
    print(f"  Tarball: {tarball}")
    print(f"  Checksum: {sha256_file}")
    print(f"  Contents: {contents_file}")


if __name__ == "__main__":
    main()
