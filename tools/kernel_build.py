#!/usr/bin/env python3
"""Compile the Linux kernel (vmlinux, bzImage, modules).

Copies source to a writable build directory, places the .config,
and runs make with the specified targets.  Captures vmlinux, bzImage,
Module.symvers, and the full build tree as outputs.
"""

import argparse
import multiprocessing
import os
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description="Build Linux kernel")
    parser.add_argument("--source-dir", required=True,
                        help="Kernel source tree (read-only)")
    parser.add_argument("--config", required=True,
                        help="Finalized .config file")
    parser.add_argument("--build-tree-out", required=True,
                        help="Output directory for the full build tree")
    parser.add_argument("--vmlinux-out", required=True,
                        help="Output path for vmlinux")
    parser.add_argument("--bzimage-out", required=True,
                        help="Output path for bzImage (or Image for arm64)")
    parser.add_argument("--modules-dir-out", required=True,
                        help="Output directory for built modules")
    parser.add_argument("--symvers-out", required=True,
                        help="Output path for Module.symvers")
    parser.add_argument("--config-out", required=True,
                        help="Output path for the used .config")
    parser.add_argument("--arch", default="x86",
                        help="ARCH= value for make (default: x86)")
    parser.add_argument("--cross-compile", default="",
                        help="CROSS_COMPILE= prefix")
    parser.add_argument("--image-path", default="arch/x86/boot/bzImage",
                        help="Relative path to kernel image within build tree")
    parser.add_argument("--target", action="append", dest="targets", default=[],
                        help="Make target (repeatable, default: vmlinux bzImage modules)")
    parser.add_argument("--jobs", type=int, default=None,
                        help="Parallel jobs (default: CPU count)")
    parser.add_argument("--install-dir-out", default="",
                        help="Output directory for compatibility install layout")
    parser.add_argument("--version", default="",
                        help="Kernel version string for install layout")
    parser.add_argument("--patch", action="append", dest="patches", default=[],
                        help="Patch file to apply before build (repeatable)")
    parser.add_argument("--kcflags", default="",
                        help="Extra KCFLAGS to pass to make")
    parser.add_argument("--make-flag", action="append", dest="make_flags", default=[],
                        help="Extra make variable (KEY=VALUE, repeatable)")
    args = parser.parse_args()

    source_dir = os.path.abspath(args.source_dir)
    config_file = os.path.abspath(args.config)
    build_tree_out = os.path.abspath(args.build_tree_out)
    vmlinux_out = os.path.abspath(args.vmlinux_out)
    bzimage_out = os.path.abspath(args.bzimage_out)
    modules_dir_out = os.path.abspath(args.modules_dir_out)
    symvers_out = os.path.abspath(args.symvers_out)
    config_out = os.path.abspath(args.config_out)
    targets = args.targets or ["vmlinux", "bzImage", "modules"]
    jobs = args.jobs or multiprocessing.cpu_count()

    if not os.path.isdir(source_dir):
        print(f"error: source directory not found: {source_dir}", file=sys.stderr)
        sys.exit(1)

    # Copy source to writable build directory
    print(f"Copying kernel source to build tree: {build_tree_out}")
    if os.path.exists(build_tree_out):
        shutil.rmtree(build_tree_out)
    shutil.copytree(source_dir, build_tree_out, symlinks=True)

    # Place .config
    shutil.copy2(config_file, os.path.join(build_tree_out, ".config"))

    # Apply patches if any
    patches = [os.path.abspath(p) for p in args.patches]
    for patch_file in patches:
        print(f"Applying patch: {os.path.basename(patch_file)}")
        result = subprocess.run(
            ["patch", "-p1", "-i", patch_file],
            cwd=build_tree_out,
        )
        if result.returncode != 0:
            print(f"error: patch failed: {patch_file}", file=sys.stderr)
            sys.exit(1)

    # Detect GCC 14+ and set up wrapper
    cc_override = _gcc14_workaround(build_tree_out)

    # Build make command
    make_cmd = [
        "make", "-C", build_tree_out,
        f"ARCH={args.arch}",
        f"-j{jobs}",
        "WERROR=0",
    ]
    if args.kcflags:
        make_cmd.append(f"KCFLAGS={args.kcflags}")
    if args.cross_compile:
        make_cmd.append(f"CROSS_COMPILE={args.cross_compile}")
    if cc_override:
        make_cmd.extend(cc_override)
    for flag in args.make_flags:
        make_cmd.append(flag)

    # Run olddefconfig first to ensure config is complete
    print("Running: make olddefconfig")
    _run(make_cmd + ["olddefconfig"])

    # Build targets
    print(f"Building targets: {' '.join(targets)}")
    _run(make_cmd + targets)

    # Copy outputs
    _copy_output(build_tree_out, "vmlinux", vmlinux_out)
    _copy_output(build_tree_out, args.image_path, bzimage_out)
    _copy_output(build_tree_out, "Module.symvers", symvers_out)
    shutil.copy2(os.path.join(build_tree_out, ".config"), config_out)

    # Collect built modules into modules_dir_out
    os.makedirs(modules_dir_out, exist_ok=True)
    _collect_modules(build_tree_out, modules_dir_out)

    # Create compatibility install layout (matches old monolithic kernel_build output)
    if args.install_dir_out:
        install_dir = os.path.abspath(args.install_dir_out)
        _create_install_layout(
            build_tree_out, install_dir, bzimage_out,
            modules_dir_out, args.arch, args.version,
        )

    print("Kernel build complete")


def _gcc14_workaround(build_dir):
    """Detect GCC 14+ and create a wrapper that appends -std=gnu11."""
    try:
        result = subprocess.run(
            ["gcc", "--version"], capture_output=True, text=True, timeout=5,
        )
        version_line = result.stdout.split("\n")[0] if result.stdout else ""
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return []

    if "gcc" not in version_line.lower():
        return []

    import re
    match = re.search(r"(\d+)\.\d+", version_line)
    if not match:
        return []

    major = int(match.group(1))
    if major < 14:
        return []

    gcc_path = shutil.which("gcc")
    if not gcc_path:
        return []

    print(f"GCC {major} detected, creating -std=gnu11 wrapper")
    wrapper_dir = os.path.join(build_dir, ".cc-wrapper")
    os.makedirs(wrapper_dir, exist_ok=True)
    wrapper_path = os.path.join(wrapper_dir, "gcc")
    with open(wrapper_path, "w") as f:
        f.write(f"#!/bin/bash\nexec {gcc_path} \"$@\" -std=gnu11\n")
    os.chmod(wrapper_path, 0o755)

    return [f"CC={wrapper_path}", f"HOSTCC={wrapper_path}"]


def _copy_output(build_dir, rel_path, output_path):
    """Copy a build artifact to the output location."""
    src = os.path.join(build_dir, rel_path)
    if os.path.isfile(src):
        os.makedirs(os.path.dirname(output_path), exist_ok=True)
        shutil.copy2(src, output_path)
        print(f"  Copied {rel_path} -> {output_path}")
    else:
        print(f"  Warning: {rel_path} not found in build tree")


def _collect_modules(build_dir, output_dir):
    """Find all built .ko files and copy them preserving relative structure."""
    count = 0
    for root, _dirs, files in os.walk(build_dir):
        for f in files:
            if f.endswith(".ko"):
                src = os.path.join(root, f)
                rel = os.path.relpath(src, build_dir)
                dst = os.path.join(output_dir, rel)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copy2(src, dst)
                count += 1
    print(f"  Collected {count} module(s)")


def _create_install_layout(build_dir, install_dir, bzimage_path, modules_src, arch, version):
    """Create traditional install directory layout for backward compatibility.

    Produces:
        $install_dir/boot/vmlinuz-$VERSION
        $install_dir/boot/bzImage  (or Image for arm64)
        $install_dir/lib/modules/$KRELEASE/...
    """
    boot_dir = os.path.join(install_dir, "boot")
    os.makedirs(boot_dir, exist_ok=True)

    # Copy kernel image
    if os.path.isfile(bzimage_path):
        image_name = "Image" if arch == "arm64" else "bzImage"
        shutil.copy2(bzimage_path, os.path.join(boot_dir, image_name))
        if version:
            shutil.copy2(bzimage_path, os.path.join(boot_dir, f"vmlinuz-{version}"))
        else:
            shutil.copy2(bzimage_path, os.path.join(boot_dir, "vmlinuz"))

    # Detect kernel release string from build tree
    krelease = ""
    include_config = os.path.join(build_dir, "include", "config", "kernel.release")
    if os.path.isfile(include_config):
        with open(include_config) as f:
            krelease = f.read().strip()

    # Install modules via make modules_install for proper layout
    if krelease:
        mod_install_dir = os.path.join(install_dir, "lib", "modules", krelease)
        os.makedirs(mod_install_dir, exist_ok=True)

        # Copy collected modules preserving structure
        for root, _dirs, files in os.walk(modules_src):
            for fname in files:
                if fname.endswith(".ko"):
                    src = os.path.join(root, fname)
                    rel = os.path.relpath(src, modules_src)
                    dst = os.path.join(mod_install_dir, "kernel", rel)
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    shutil.copy2(src, dst)

    print(f"  Created install layout: {install_dir}")


def _run(cmd, cwd=None):
    """Run a command, exit on failure."""
    print(f"  + {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=cwd)
    if result.returncode != 0:
        print(f"error: command failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
