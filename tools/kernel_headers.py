#!/usr/bin/env python3
"""Install kernel headers via make headers_install.

Produces a clean headers tree suitable for glibc/musl/BPF compilation.
Uses O=<build-dir> to keep the kernel source tree read-only.
"""

import argparse
import os
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description="Install kernel headers")
    parser.add_argument("--source-dir", required=True,
                        help="Kernel source tree (read-only)")
    parser.add_argument("--config", required=True,
                        help="Finalized .config file")
    parser.add_argument("--output-dir", required=True,
                        help="Output directory for installed headers")
    parser.add_argument("--arch", default="x86",
                        help="ARCH= value for make (default: x86)")
    parser.add_argument("--cross-compile", default="",
                        help="CROSS_COMPILE= prefix")
    args = parser.parse_args()

    # Disable host compiler/build caches — Buck2 caches actions itself,
    # and external caches can poison results across build contexts.
    os.environ["CCACHE_DISABLE"] = "1"
    os.environ["RUSTC_WRAPPER"] = ""

    # Pin timestamps for reproducible builds.
    os.environ.setdefault("SOURCE_DATE_EPOCH", "0")

    source_dir = os.path.abspath(args.source_dir)
    config_file = os.path.abspath(args.config)
    output_dir = os.path.abspath(args.output_dir)

    if not os.path.isdir(source_dir):
        print(f"error: source directory not found: {source_dir}", file=sys.stderr)
        sys.exit(1)

    if not os.path.isfile(config_file):
        print(f"error: config file not found: {config_file}", file=sys.stderr)
        sys.exit(1)

    # Create a temporary build directory for O= builds
    build_dir = output_dir + ".kbuild"
    if os.path.exists(build_dir):
        shutil.rmtree(build_dir)
    os.makedirs(build_dir)

    # Copy .config into the O= build directory
    shutil.copy2(config_file, os.path.join(build_dir, ".config"))

    # Ensure output dir exists
    os.makedirs(output_dir, exist_ok=True)

    # Build make command
    make_cmd = [
        "make", "-C", source_dir,
        f"O={build_dir}",
        f"ARCH={args.arch}",
        f"INSTALL_HDR_PATH={output_dir}",
        "headers_install",
    ]
    if args.cross_compile:
        make_cmd.append(f"CROSS_COMPILE={args.cross_compile}")

    print(f"Installing kernel headers to {output_dir}")
    print(f"  + {' '.join(make_cmd)}")
    result = subprocess.run(make_cmd)
    if result.returncode != 0:
        print(f"error: headers_install failed with exit code {result.returncode}",
              file=sys.stderr)
        sys.exit(1)

    # Clean up temporary build dir
    shutil.rmtree(build_dir, ignore_errors=True)

    print("Kernel headers installed successfully")


if __name__ == "__main__":
    main()
