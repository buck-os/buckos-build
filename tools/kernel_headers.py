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

from _env import sanitize_global_env


def main():
    parser = argparse.ArgumentParser(description="Install kernel headers")
    parser.add_argument("--source-dir", required=True,
                        help="Kernel source tree (read-only)")
    parser.add_argument("--config", default=None,
                        help="Finalized .config file (optional)")
    parser.add_argument("--output-dir", required=True,
                        help="Output directory for installed headers")
    parser.add_argument("--arch", default="x86",
                        help="ARCH= value for make (default: x86)")
    parser.add_argument("--cross-compile", default="",
                        help="CROSS_COMPILE= prefix")
    parser.add_argument("--allow-host-path", action="store_true",
                        help="Allow host PATH (bootstrap escape hatch)")
    parser.add_argument("--hermetic-path", action="append", dest="hermetic_path", default=[],
                        help="Set PATH to only these dirs (replaces host PATH, repeatable)")
    parser.add_argument("--hermetic-empty", action="store_true",
                        help="Start with empty PATH (populated by --path-prepend)")
    parser.add_argument("--path-prepend", action="append", dest="path_prepend", default=[],
                        help="Directory to prepend to PATH (repeatable, resolved to absolute)")
    args = parser.parse_args()

    _host_path = os.environ.get("PATH", "")
    sanitize_global_env()

    # Apply PATH from toolchain flags
    if args.hermetic_path:
        os.environ["PATH"] = ":".join(os.path.abspath(p) for p in args.hermetic_path)
    elif args.hermetic_empty:
        os.environ["PATH"] = ""
    elif args.allow_host_path:
        os.environ["PATH"] = _host_path
    else:
        print("error: kernel_headers requires --hermetic-path, --hermetic-empty, or --allow-host-path",
              file=sys.stderr)
        sys.exit(1)
    if args.path_prepend:
        prepend = ":".join(os.path.abspath(p) for p in args.path_prepend if os.path.isdir(p))
        if prepend:
            os.environ["PATH"] = prepend + ":" + os.environ.get("PATH", "")

    source_dir = os.path.abspath(args.source_dir)
    config_file = os.path.abspath(args.config) if args.config else None
    output_dir = os.path.abspath(args.output_dir)

    if not os.path.isdir(source_dir):
        print(f"error: source directory not found: {source_dir}", file=sys.stderr)
        sys.exit(1)

    if config_file and not os.path.isfile(config_file):
        print(f"error: config file not found: {config_file}", file=sys.stderr)
        sys.exit(1)

    # Create a temporary build directory for O= builds
    build_dir = output_dir + ".kbuild"
    if os.path.exists(build_dir):
        shutil.rmtree(build_dir)
    os.makedirs(build_dir)

    # Copy .config into the O= build directory (if provided)
    if config_file:
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
