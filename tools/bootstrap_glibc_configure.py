#!/usr/bin/env python3
"""Bootstrap glibc configure phase.

Replaces the inline bash in bootstrap.bzl's _bootstrap_glibc_impl configure
action.  Discovers cross-tools from compiler/binutils dirs and runs glibc's
../configure from an out-of-tree build dir.
"""

import argparse
import os
import shutil
import subprocess
import sys

from _env import clean_env


def _find_tool(name, extra_paths):
    """Find a tool on a modified PATH."""
    for d in extra_paths:
        candidate = os.path.join(d, name)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    # Fall back to system PATH
    for d in os.environ.get("PATH", "").split(":"):
        candidate = os.path.join(d, name)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def main():
    parser = argparse.ArgumentParser(description="Bootstrap glibc configure")
    parser.add_argument("--source-dir", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--target-triple", default="x86_64-buckos-linux-gnu")
    parser.add_argument("--compiler-dir", required=True,
                        help="GCC install dir")
    parser.add_argument("--headers-dir", required=True,
                        help="Linux headers install dir")
    parser.add_argument("--binutils-dir", default=None,
                        help="Cross-binutils install dir")
    parser.add_argument("--lib-dir", default="lib64",
                        help="Library directory name (e.g. lib64, lib)")
    parser.add_argument("--dynamic-linker", default="ld-linux-x86-64.so.2",
                        help="Dynamic linker filename")
    parser.add_argument("--configure-arg", action="append", dest="configure_args",
                        default=[], help="Extra configure argument (repeatable)")
    args = parser.parse_args()

    project_root = os.getcwd()
    source_dir = os.path.abspath(args.source_dir)
    output_dir = os.path.abspath(args.output_dir)
    compiler_abs = os.path.join(project_root, args.compiler_dir) if not os.path.isabs(args.compiler_dir) else args.compiler_dir
    headers_abs = os.path.join(project_root, args.headers_dir) if not os.path.isabs(args.headers_dir) else args.headers_dir
    binutils_abs = (os.path.join(project_root, args.binutils_dir)
                    if args.binutils_dir and not os.path.isabs(args.binutils_dir)
                    else args.binutils_dir)

    # Copy prepared source to output dir
    if os.path.exists(output_dir):
        shutil.rmtree(output_dir)
    shutil.copytree(source_dir, output_dir, symlinks=True)

    # Create build directory and configparms
    build_dir = os.path.join(output_dir, "build")
    os.makedirs(build_dir, exist_ok=True)
    with open(os.path.join(build_dir, "configparms"), "w") as f:
        f.write("rootsbindir=/usr/sbin\n")

    # Build search paths for cross-tool discovery
    tool_prefix = args.target_triple + "-"
    search_paths = [os.path.join(compiler_abs, "tools", "bin")]
    if binutils_abs:
        search_paths.append(os.path.join(binutils_abs, "tools", "bin"))

    # Discover cross-tools
    cross_cc = _find_tool(tool_prefix + "gcc", search_paths)
    if not cross_cc:
        print(f"error: {tool_prefix}gcc not found in {search_paths}", file=sys.stderr)
        sys.exit(1)

    # Build environment
    env = clean_env()
    env["PROJECT_ROOT"] = project_root
    env["CC"] = cross_cc
    env["CPP"] = cross_cc + " -E"
    env["CXX"] = ""

    if binutils_abs:
        binutils_bin = os.path.join(binutils_abs, "tools", "bin")
        for tool_name in ["LD", "AR", "AS", "NM", "RANLIB", "OBJCOPY", "OBJDUMP", "STRIP"]:
            tool_path = _find_tool(tool_prefix + tool_name.lower(), [binutils_bin])
            if tool_path:
                env[tool_name] = tool_path

    headers_path = os.path.join(headers_abs, "usr", "include")

    # Determine build triple
    config_guess = os.path.join(output_dir, "scripts", "config.guess")
    if os.path.isfile(config_guess):
        os.chmod(config_guess, os.stat(config_guess).st_mode | 0o755)
        result = subprocess.run([config_guess], capture_output=True, text=True, env=env)
        build_triple = result.stdout.strip()
    else:
        build_triple = "x86_64-pc-linux-gnu"

    # Build configure command
    configure_cmd = [
        "../configure",
        "--prefix=/usr",
        "--host=" + args.target_triple,
        "--build=" + build_triple,
        "--enable-kernel=4.19",
        "--with-headers=" + headers_path,
        "--disable-nscd",
        "--disable-werror",
        "libc_cv_slibdir=/usr/" + args.lib_dir,
        "libc_cv_forced_unwind=yes",
        "libc_cv_c_cleanup=yes",
        "libc_cv_pde=yes",
        "libc_cv_cxx_link_ok=no",
    ]
    configure_cmd.extend(args.configure_args)

    result = subprocess.run(configure_cmd, cwd=build_dir, env=env)
    if result.returncode != 0:
        print(f"error: configure failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
