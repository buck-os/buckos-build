#!/usr/bin/env python3
"""Bootstrap GCC configure phase.

Replaces the inline bash in bootstrap.bzl's _bootstrap_gcc_impl configure
action.  Assembles a build sysroot from headers/libc/binutils deps, creates
a stub sdt.h, and runs GCC's ../configure from an out-of-tree build dir.
"""

import argparse
import os
import shutil
import subprocess
import sys

from _env import clean_env


def main():
    parser = argparse.ArgumentParser(description="Bootstrap GCC configure")
    parser.add_argument("--source-dir", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--target-triple", default="x86_64-buckos-linux-gnu")
    parser.add_argument("--headers-dir", default=None,
                        help="Linux headers install dir (libc_headers dep)")
    parser.add_argument("--libc-dir", default=None,
                        help="glibc install dir (libc_dep)")
    parser.add_argument("--binutils-dir", default=None,
                        help="Cross-binutils install dir")
    parser.add_argument("--configure-arg", action="append", dest="configure_args",
                        default=[], help="Argument to pass to configure (repeatable)")
    parser.add_argument("--env", action="append", dest="extra_env", default=[],
                        help="Environment variable KEY=VALUE (repeatable)")
    parser.add_argument("--languages", default="c")
    parser.add_argument("--with-headers", action="store_true",
                        help="Pass2 mode (has libc headers)")
    args = parser.parse_args()

    project_root = os.getcwd()
    source_dir = os.path.abspath(args.source_dir)
    output_dir = os.path.abspath(args.output_dir)

    # Copy prepared source to output dir
    if os.path.exists(output_dir):
        shutil.rmtree(output_dir)
    shutil.copytree(source_dir, output_dir, symlinks=True)

    # Resolve dep paths
    headers_abs = os.path.join(project_root, args.headers_dir) if args.headers_dir else None
    libc_abs = os.path.join(project_root, args.libc_dir) if args.libc_dir else None
    binutils_abs = os.path.join(project_root, args.binutils_dir) if args.binutils_dir else None

    # Assemble build sysroot from dependencies
    build_sysroot = os.path.join(output_dir, "build-sysroot")
    if headers_abs:
        src_inc = os.path.join(headers_abs, "usr", "include")
        dst_inc = os.path.join(build_sysroot, "usr", "include")
        os.makedirs(dst_inc, exist_ok=True)
        if os.path.isdir(src_inc):
            shutil.copytree(src_inc, dst_inc, symlinks=True, dirs_exist_ok=True)
    if libc_abs:
        os.makedirs(build_sysroot, exist_ok=True)
        shutil.copytree(libc_abs, build_sysroot, symlinks=True, dirs_exist_ok=True)
        if headers_abs:
            shutil.copytree(headers_abs, build_sysroot, symlinks=True, dirs_exist_ok=True)
        # Create stub sdt.h
        sdt_dir = os.path.join(build_sysroot, "usr", "include", "sys")
        os.makedirs(sdt_dir, exist_ok=True)
        with open(os.path.join(sdt_dir, "sdt.h"), "w") as f:
            f.write("#ifndef _SYS_SDT_H\n#define _SYS_SDT_H\n"
                    "#define STAP_PROBE(p,n)\n#endif\n")

    # Create build directory
    build_dir = os.path.join(output_dir, "build")
    os.makedirs(build_dir, exist_ok=True)

    # Build environment
    env = clean_env()
    env["PROJECT_ROOT"] = project_root
    for entry in args.extra_env:
        key, _, value = entry.partition("=")
        if key:
            # Resolve relative paths to absolute
            if value and not os.path.isabs(value) and os.path.exists(os.path.join(project_root, value)):
                value = os.path.join(project_root, value)
            env[key] = value

    # Build configure command
    configure_cmd = ["../configure"]

    # Sysroot args
    has_sysroot = headers_abs or libc_abs
    if has_sysroot:
        configure_cmd.append("--with-build-sysroot=" + build_sysroot)

    if headers_abs and not libc_abs and binutils_abs:
        # Pass1 with binutils: specify cross-assembler and linker
        configure_cmd.append("--with-as=" + os.path.join(binutils_abs, "tools", "bin",
                                                          args.target_triple + "-as"))
        configure_cmd.append("--with-ld=" + os.path.join(binutils_abs, "tools", "bin",
                                                          args.target_triple + "-ld"))
    elif not has_sysroot and binutils_abs:
        # No sysroot, but have binutils
        configure_cmd.append("--with-as=" + os.path.join(binutils_abs, "tools", "bin",
                                                          args.target_triple + "-as"))
        configure_cmd.append("--with-ld=" + os.path.join(binutils_abs, "tools", "bin",
                                                          args.target_triple + "-ld"))

    configure_cmd.extend(args.configure_args)

    result = subprocess.run(configure_cmd, cwd=build_dir, env=env)
    if result.returncode != 0:
        print(f"error: configure failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
