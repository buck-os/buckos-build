#!/usr/bin/env python3
"""Compile the Linux kernel (vmlinux, bzImage, modules, headers).

Copies source to a writable build directory, places the .config,
and runs make with the specified targets.  Captures vmlinux, bzImage,
Module.symvers, modules, headers, and the full build tree as outputs.
"""

import argparse
import multiprocessing
import os
import re
import shutil
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description="Build Linux kernel")
    parser.add_argument("--source-dir", required=True,
                        help="Kernel source tree (read-only)")
    parser.add_argument("--config", default="",
                        help="Finalized .config file")
    parser.add_argument("--config-base", default="",
                        help="Make config target (tinyconfig, allnoconfig, etc.)")
    parser.add_argument("--build-tree-out", required=True,
                        help="Output directory for the full build tree")
    parser.add_argument("--vmlinux-out", required=True,
                        help="Output path for vmlinux")
    parser.add_argument("--bzimage-out", required=True,
                        help="Output path for bzImage (or Image for arm64)")
    parser.add_argument("--modules-dir-out", required=True,
                        help="Output directory for installed modules")
    parser.add_argument("--symvers-out", required=True,
                        help="Output path for Module.symvers")
    parser.add_argument("--config-out", required=True,
                        help="Output path for the used .config")
    parser.add_argument("--headers-out", default="",
                        help="Output directory for installed headers")
    parser.add_argument("--arch", default="x86",
                        help="ARCH= value for make (default: x86)")
    parser.add_argument("--cross-compile", default="",
                        help="CROSS_COMPILE= prefix")
    parser.add_argument("--cross-toolchain-dir", default="",
                        help="Toolchain directory; bin/ subdirs prepended to PATH")
    parser.add_argument("--image-path", default="arch/x86/boot/bzImage",
                        help="Relative path to kernel image within build tree")
    parser.add_argument("--target", action="append", dest="targets", default=[],
                        help="Make target (repeatable, default: vmlinux bzImage modules)")
    parser.add_argument("--jobs", type=int, default=None,
                        help="Parallel jobs (default: CPU count)")
    parser.add_argument("--version", default="",
                        help="Kernel version string")
    parser.add_argument("--patch", action="append", dest="patches", default=[],
                        help="Patch file to apply before build (repeatable)")
    parser.add_argument("--inject-file", action="append", dest="inject_files",
                        default=[], help="DEST:SRC file injection (repeatable)")
    parser.add_argument("--kcflags", default="",
                        help="Extra KCFLAGS to pass to make")
    parser.add_argument("--make-flag", action="append", dest="make_flags",
                        default=[], help="Extra make variable (KEY=VALUE, repeatable)")
    parser.add_argument("--external-module", action="append",
                        dest="external_modules", default=[],
                        help="External module source dir to build (repeatable)")
    args = parser.parse_args()

    source_dir = os.path.abspath(args.source_dir)
    build_tree_out = os.path.abspath(args.build_tree_out)
    vmlinux_out = os.path.abspath(args.vmlinux_out)
    bzimage_out = os.path.abspath(args.bzimage_out)
    modules_dir_out = os.path.abspath(args.modules_dir_out)
    symvers_out = os.path.abspath(args.symvers_out)
    config_out = os.path.abspath(args.config_out)
    headers_out = os.path.abspath(args.headers_out) if args.headers_out else ""
    targets = args.targets or ["vmlinux", "bzImage", "modules"]
    jobs = args.jobs or multiprocessing.cpu_count()

    if not os.path.isdir(source_dir):
        print(f"error: source directory not found: {source_dir}", file=sys.stderr)
        sys.exit(1)

    # Disable host compiler/build caches — Buck2 caches actions itself.
    os.environ["CCACHE_DISABLE"] = "1"
    os.environ["RUSTC_WRAPPER"] = ""
    os.environ["CARGO_BUILD_RUSTC_WRAPPER"] = ""

    # Pin timestamps for reproducible builds.
    os.environ.setdefault("SOURCE_DATE_EPOCH", "315576000")
    os.environ.setdefault("KBUILD_BUILD_TIMESTAMP", "Thu Jan  1 00:00:00 UTC 1970")
    os.environ.setdefault("KBUILD_BUILD_USER", "buckos")
    os.environ.setdefault("KBUILD_BUILD_HOST", "buckos")

    # Set up cross-toolchain PATH
    if args.cross_toolchain_dir:
        tc_dir = os.path.abspath(args.cross_toolchain_dir)
        if os.path.isdir(tc_dir):
            for root, dirs, _files in os.walk(tc_dir):
                if os.path.basename(root) == "bin":
                    os.environ["PATH"] = root + ":" + os.environ.get("PATH", "")
                for d in list(dirs):
                    if d == "bin":
                        bin_path = os.path.join(root, d)
                        os.environ["PATH"] = bin_path + ":" + os.environ.get("PATH", "")
            print("Cross-toolchain added to PATH")

    # Copy source to writable build directory
    print(f"Copying kernel source to build tree: {build_tree_out}")
    if os.path.exists(build_tree_out):
        shutil.rmtree(build_tree_out)
    shutil.copytree(source_dir, build_tree_out, symlinks=True)

    # Inject files into source tree
    for injection in args.inject_files:
        if ":" not in injection:
            print(f"error: --inject-file must be DEST:SRC, got: {injection}",
                  file=sys.stderr)
            sys.exit(1)
        dest, src = injection.split(":", 1)
        src = os.path.abspath(src)
        dest_path = os.path.join(build_tree_out, dest)
        os.makedirs(os.path.dirname(dest_path), exist_ok=True)
        shutil.copy2(src, dest_path)
        print(f"  Injected {dest}")

    # Apply patches
    for patch_file in args.patches:
        patch_abs = os.path.abspath(patch_file)
        print(f"Applying patch: {os.path.basename(patch_abs)}")
        result = subprocess.run(
            ["patch", "-p1", "-i", patch_abs],
            cwd=build_tree_out,
        )
        if result.returncode != 0:
            print(f"error: patch failed: {patch_abs}", file=sys.stderr)
            sys.exit(1)

    # Detect GCC 14+ and set up wrapper
    cc_override = _gcc14_workaround(build_tree_out)

    # Build base make command
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

    # Configure
    config_file = os.path.abspath(args.config) if args.config else ""
    if args.config_base:
        print(f"Running: make {args.config_base}")
        _run(make_cmd + [args.config_base])
        if config_file:
            # Merge config fragment on top of base
            merge_script = os.path.join(build_tree_out, "scripts/kconfig/merge_config.sh")
            if os.path.isfile(merge_script):
                _run(["bash", merge_script, "-m", ".config", config_file],
                     cwd=build_tree_out)
            else:
                # Fallback: append config fragment
                with open(os.path.join(build_tree_out, ".config"), "a") as f:
                    with open(config_file) as cf:
                        f.write(cf.read())
        _run(make_cmd + ["olddefconfig"])
    elif config_file:
        shutil.copy2(config_file, os.path.join(build_tree_out, ".config"))
        _run(make_cmd + ["olddefconfig"])
    else:
        _run(make_cmd + ["defconfig"])

    # Build
    print(f"Building targets: {' '.join(targets)}")
    _run(make_cmd + targets)

    # Get kernel release string
    krelease = _get_krelease(build_tree_out)
    print(f"Kernel release: {krelease}")

    # Copy individual outputs
    _copy_output(build_tree_out, "vmlinux", vmlinux_out)
    _copy_output(build_tree_out, args.image_path, bzimage_out)
    _copy_output(build_tree_out, "Module.symvers", symvers_out)
    shutil.copy2(os.path.join(build_tree_out, ".config"), config_out)

    # Install modules via make modules_install for proper layout
    _install_modules(make_cmd, build_tree_out, modules_dir_out, krelease,
                     args.external_modules)

    # Install headers
    if headers_out:
        _install_headers(make_cmd, build_tree_out, headers_out)

    print("Kernel build complete")


def _get_krelease(build_dir):
    """Read kernel release string from the build tree."""
    release_file = os.path.join(build_dir, "include", "config", "kernel.release")
    if os.path.isfile(release_file):
        with open(release_file) as f:
            return f.read().strip()
    return ""


def _install_modules(make_cmd, build_dir, modules_dir_out, krelease,
                     external_modules):
    """Install kernel modules with proper layout and depmod metadata."""
    with tempfile.TemporaryDirectory() as tmpdir:
        _run(make_cmd + [f"INSTALL_MOD_PATH={tmpdir}", "modules_install"])

        # Build and install external modules
        for mod_src in external_modules:
            mod_src = os.path.abspath(mod_src)
            if not os.path.isdir(mod_src):
                continue
            mod_name = os.path.basename(mod_src)
            mod_build = os.path.join(build_dir, ".modules", mod_name)
            os.makedirs(mod_build, exist_ok=True)
            shutil.copytree(mod_src, mod_build, dirs_exist_ok=True)
            _run(make_cmd + [f"M={mod_build}", "modules"])
            if krelease:
                extra_dir = os.path.join(tmpdir, "lib", "modules", krelease, "extra")
                os.makedirs(extra_dir, exist_ok=True)
                for root, _dirs, files in os.walk(mod_build):
                    for f in files:
                        if f.endswith(".ko"):
                            shutil.copy2(os.path.join(root, f),
                                         os.path.join(extra_dir, f))

        # Run depmod
        if krelease and shutil.which("depmod"):
            subprocess.run(["depmod", "-b", tmpdir, krelease],
                           capture_output=True)

        # Copy lib/modules/ to output
        mod_src_dir = os.path.join(tmpdir, "lib", "modules")
        if os.path.isdir(mod_src_dir):
            os.makedirs(modules_dir_out, exist_ok=True)
            shutil.copytree(mod_src_dir, modules_dir_out, dirs_exist_ok=True)
            print(f"  Installed modules to {modules_dir_out}")
        else:
            os.makedirs(modules_dir_out, exist_ok=True)
            print("  No modules installed")


def _install_headers(make_cmd, build_dir, headers_out):
    """Install kernel headers for userspace."""
    os.makedirs(headers_out, exist_ok=True)
    _run(make_cmd + [f"INSTALL_HDR_PATH={headers_out}", "headers_install"])
    print(f"  Installed headers to {headers_out}")


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
        # Create empty file so Buck2 output tracking doesn't fail
        os.makedirs(os.path.dirname(output_path), exist_ok=True)
        with open(output_path, "w") as f:
            pass
        print(f"  Warning: {rel_path} not found, created empty placeholder")


def _run(cmd, cwd=None):
    """Run a command, exit on failure."""
    print(f"  + {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=cwd)
    if result.returncode != 0:
        print(f"error: command failed with exit code {result.returncode}",
              file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
