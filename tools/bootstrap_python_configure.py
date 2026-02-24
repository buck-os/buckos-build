#!/usr/bin/env python3
"""Bootstrap Python configure phase.

Replaces the inline bash in bootstrap.bzl's _bootstrap_python_impl configure
action.  Merges dependency prefixes into a build sysroot and runs Python's
../configure with cross-compilation cache variables.
"""

import argparse
import os
import shutil
import subprocess
import sys

from _env import clean_env


def main():
    parser = argparse.ArgumentParser(description="Bootstrap Python configure")
    parser.add_argument("--source-dir", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--stage-dir", required=True,
                        help="Stage output directory")
    parser.add_argument("--sysroot", required=True,
                        help="Stage sysroot path")
    parser.add_argument("--cc", required=True, help="Cross CC path")
    parser.add_argument("--cxx", required=True, help="Cross CXX path")
    parser.add_argument("--ar", required=True, help="Cross AR path")
    parser.add_argument("--dep-dir", action="append", dest="dep_dirs", default=[],
                        help="Dependency prefix directory (repeatable)")
    parser.add_argument("--configure-arg", action="append", dest="configure_args",
                        default=[], help="Extra configure argument (repeatable)")
    args = parser.parse_args()

    project_root = os.getcwd()
    source_dir = os.path.abspath(args.source_dir)
    output_dir = os.path.abspath(args.output_dir)

    def resolve(p):
        return p if os.path.isabs(p) else os.path.join(project_root, p)

    stage_dir = resolve(args.stage_dir)
    sysroot = resolve(args.sysroot)
    cc_path = resolve(args.cc)
    cxx_path = resolve(args.cxx)
    ar_path = resolve(args.ar)
    dep_dirs = [resolve(d) for d in args.dep_dirs]

    # Copy prepared source to output dir
    if os.path.exists(output_dir):
        shutil.rmtree(output_dir)
    shutil.copytree(source_dir, output_dir, symlinks=True)

    # Create merged build sysroot from stage sysroot + deps
    build_sysroot = os.path.join(output_dir, "build-sysroot")
    os.makedirs(build_sysroot, exist_ok=True)
    shutil.copytree(sysroot, build_sysroot, symlinks=True, dirs_exist_ok=True)
    for dep_dir in dep_dirs:
        dep_usr = os.path.join(dep_dir, "usr")
        if os.path.isdir(dep_usr):
            dst_usr = os.path.join(build_sysroot, "usr")
            os.makedirs(dst_usr, exist_ok=True)
            shutil.copytree(dep_usr, dst_usr, symlinks=True, dirs_exist_ok=True)

    # Build environment
    env = clean_env()
    env["PROJECT_ROOT"] = project_root
    env["PATH"] = os.path.join(stage_dir, "tools", "bin") + ":" + env.get("PATH", "")
    env["CC"] = cc_path + " --sysroot=" + build_sysroot
    env["CXX"] = cxx_path + " --sysroot=" + build_sysroot
    env["AR"] = ar_path

    # Create build directory
    build_dir = os.path.join(output_dir, "build")
    os.makedirs(build_dir, exist_ok=True)

    # Configure with cross-compilation cache variables
    configure_cmd = [
        "../configure",
    ]

    # Prepend cache variables
    env["ac_cv_file__dev_ptmx"] = "yes"
    env["ac_cv_file__dev_ptc"] = "no"

    configure_cmd.extend(args.configure_args)

    # Add sysroot paths for includes/libs
    configure_cmd.append("CFLAGS=-I" + os.path.join(build_sysroot, "usr", "include"))
    configure_cmd.append(
        "LDFLAGS=-L{lib64} -L{lib} -Wl,-rpath-link,{lib64}".format(
            lib64=os.path.join(build_sysroot, "usr", "lib64"),
            lib=os.path.join(build_sysroot, "usr", "lib"),
        )
    )

    result = subprocess.run(configure_cmd, cwd=build_dir, env=env)
    if result.returncode != 0:
        print(f"error: configure failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
