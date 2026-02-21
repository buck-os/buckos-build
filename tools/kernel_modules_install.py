#!/usr/bin/env python3
"""Install kernel modules and merge out-of-tree modules.

Runs make modules_install from the kernel build tree, copies extra
out-of-tree .ko files into the module tree, and runs depmod to
regenerate module dependency metadata.
"""

import argparse
import os
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description="Install kernel modules")
    parser.add_argument("--build-tree", required=True,
                        help="Kernel build tree (from kernel_build)")
    parser.add_argument("--output-dir", required=True,
                        help="Output directory for installed modules")
    parser.add_argument("--version", required=True,
                        help="Kernel version string")
    parser.add_argument("--arch", default="x86",
                        help="ARCH= value for make (default: x86)")
    parser.add_argument("--cross-compile", default="",
                        help="CROSS_COMPILE= prefix")
    parser.add_argument("--extra-module", action="append", dest="extra_modules",
                        default=[],
                        help="Path to extra .ko file or directory of .ko files (repeatable)")
    args = parser.parse_args()

    # Disable host compiler/build caches — Buck2 caches actions itself,
    # and external caches can poison results across build contexts.
    os.environ["CCACHE_DISABLE"] = "1"
    os.environ["RUSTC_WRAPPER"] = ""

    # Pin timestamps for reproducible builds.
    os.environ.setdefault("SOURCE_DATE_EPOCH", "0")

    build_tree = os.path.abspath(args.build_tree)
    output_dir = os.path.abspath(args.output_dir)
    version = args.version

    if not os.path.isdir(build_tree):
        print(f"error: build tree not found: {build_tree}", file=sys.stderr)
        sys.exit(1)

    os.makedirs(output_dir, exist_ok=True)

    # Detect GCC 14+ wrapper in build tree
    cc_override = []
    wrapper = os.path.join(build_tree, ".cc-wrapper", "gcc")
    if os.path.isfile(wrapper):
        cc_override = [f"CC={wrapper}", f"HOSTCC={wrapper}"]

    # Run make modules_install
    make_cmd = [
        "make", "-C", build_tree,
        f"ARCH={args.arch}",
        f"INSTALL_MOD_PATH={output_dir}",
        "modules_install",
    ]
    if args.cross_compile:
        make_cmd.append(f"CROSS_COMPILE={args.cross_compile}")
    make_cmd.extend(cc_override)

    print(f"Installing modules to {output_dir}")
    print(f"  + {' '.join(make_cmd)}")
    result = subprocess.run(make_cmd)
    if result.returncode != 0:
        print(f"error: modules_install failed with exit code {result.returncode}",
              file=sys.stderr)
        sys.exit(1)

    # Get actual kernel release from build tree
    krelease = _get_krelease(build_tree, args.arch, args.cross_compile, cc_override)
    if not krelease:
        krelease = version
        print(f"warning: could not determine kernelrelease, using {version}")

    # Merge extra out-of-tree modules
    extra_dir = os.path.join(output_dir, "lib", "modules", krelease, "extra")
    extra_count = 0
    for mod_path in args.extra_modules:
        mod_path = os.path.abspath(mod_path)
        if os.path.isfile(mod_path) and mod_path.endswith(".ko"):
            os.makedirs(extra_dir, exist_ok=True)
            shutil.copy2(mod_path, extra_dir)
            extra_count += 1
        elif os.path.isdir(mod_path):
            for root, _dirs, files in os.walk(mod_path):
                for f in files:
                    if f.endswith(".ko"):
                        os.makedirs(extra_dir, exist_ok=True)
                        shutil.copy2(os.path.join(root, f), extra_dir)
                        extra_count += 1

    if extra_count:
        print(f"  Merged {extra_count} extra module(s)")

    # Run depmod to regenerate module dependency metadata
    depmod = shutil.which("depmod")
    if depmod:
        print(f"Running depmod for {krelease}")
        depmod_result = subprocess.run(
            [depmod, "-a", "-b", output_dir, krelease],
            capture_output=True, text=True,
        )
        if depmod_result.returncode != 0:
            print(f"warning: depmod failed: {depmod_result.stderr}", file=sys.stderr)
    else:
        print("warning: depmod not found, skipping module dependency generation")

    print("Module installation complete")


def _get_krelease(build_tree, arch, cross_compile, cc_override):
    """Get kernel release string from build tree."""
    cmd = ["make", "-C", build_tree, f"ARCH={arch}", "-s", "kernelrelease"]
    if cross_compile:
        cmd.append(f"CROSS_COMPILE={cross_compile}")
    cmd.extend(cc_override)
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode == 0:
            return result.stdout.strip()
    except subprocess.TimeoutExpired:
        pass
    return None


if __name__ == "__main__":
    main()
