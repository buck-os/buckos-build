#!/usr/bin/env python3
"""Generate a finalized kernel .config from defconfig + composable fragments.

Runs make <defconfig>, applies fragments via scripts/kconfig/merge_config.sh,
then runs make olddefconfig to resolve dependencies.

Uses O=<build-dir> to keep the source tree clean (Buck2 source artifacts
are read-only).
"""

import argparse
import os
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description="Generate kernel .config")
    parser.add_argument("--source-dir", required=True,
                        help="Kernel source tree (read-only)")
    parser.add_argument("--output", required=True,
                        help="Output .config file path")
    parser.add_argument("--defconfig", default="",
                        help="Defconfig target (e.g. x86_64_defconfig), or empty for allnoconfig")
    parser.add_argument("--fragment", action="append", dest="fragments", default=[],
                        help="Kconfig fragment file to merge (repeatable, order matters)")
    parser.add_argument("--arch", default="x86",
                        help="ARCH= value for make (default: x86)")
    parser.add_argument("--cross-compile", default="",
                        help="CROSS_COMPILE= prefix")
    parser.add_argument("--localversion", default="",
                        help="CONFIG_LOCALVERSION value")
    parser.add_argument("--cc", default="", help="CC override")
    parser.add_argument("--hostcc", default="", help="HOSTCC override")
    args = parser.parse_args()

    # Disable host compiler/build caches — Buck2 caches actions itself,
    # and external caches can poison results across build contexts.
    os.environ["CCACHE_DISABLE"] = "1"
    os.environ["RUSTC_WRAPPER"] = ""

    # Pin timestamps for reproducible builds.
    os.environ.setdefault("SOURCE_DATE_EPOCH", "0")

    source_dir = os.path.abspath(args.source_dir)
    output_config = os.path.abspath(args.output)

    if not os.path.isdir(source_dir):
        print(f"error: source directory not found: {source_dir}", file=sys.stderr)
        sys.exit(1)

    # Create a temporary build directory for kconfig operations.
    # We copy the source tree because kconfig needs a writable tree
    # even with O= for some operations.
    build_dir = output_config + ".build"
    if os.path.exists(build_dir):
        shutil.rmtree(build_dir)
    os.makedirs(build_dir)

    # Resolve fragment paths to absolute before any chdir
    fragments = [os.path.abspath(f) for f in args.fragments]

    # Build make command base
    make_base = ["make", "-C", source_dir, f"O={build_dir}", f"ARCH={args.arch}"]
    if args.cross_compile:
        make_base.append(f"CROSS_COMPILE={args.cross_compile}")

    # GCC 14+ workaround: detect and create wrapper if needed
    cc_override = _gcc14_workaround(build_dir, args.cc)
    if cc_override:
        make_base.extend(cc_override)
    elif args.cc:
        make_base.append(f"CC={args.cc}")
        if args.hostcc:
            make_base.append(f"HOSTCC={args.hostcc}")

    # Step 1: Generate base config
    if args.defconfig:
        defconfig_target = args.defconfig
    else:
        defconfig_target = "allnoconfig"

    print(f"Running: make {defconfig_target}")
    _run(make_base + [defconfig_target])

    # Step 2: Merge fragments via merge_config.sh
    if fragments:
        merge_script = os.path.join(source_dir, "scripts", "kconfig", "merge_config.sh")
        if os.path.isfile(merge_script):
            print(f"Merging {len(fragments)} fragment(s) via merge_config.sh")
            env = os.environ.copy()
            env["ARCH"] = args.arch
            env["SRCARCH"] = args.arch
            # merge_config.sh expects to run in the build dir with .config present
            cmd = ["bash", merge_script, "-m", ".config"] + fragments
            _run(cmd, cwd=build_dir, env=env)
        else:
            # Fallback: concatenate fragments manually
            print(f"merge_config.sh not found, concatenating fragments manually")
            config_path = os.path.join(build_dir, ".config")
            with open(config_path, "a") as f:
                for frag in fragments:
                    with open(frag) as frag_f:
                        f.write(frag_f.read())
                        f.write("\n")

        # Step 3: Resolve dependencies with olddefconfig
        print("Running: make olddefconfig")
        _run(make_base + ["olddefconfig"])

    # Copy the finalized .config to the output path
    built_config = os.path.join(build_dir, ".config")
    if not os.path.isfile(built_config):
        print(f"error: .config not generated at {built_config}", file=sys.stderr)
        sys.exit(1)

    shutil.copy2(built_config, output_config)

    # Clean up build dir
    shutil.rmtree(build_dir, ignore_errors=True)

    print(f"Kernel config generated: {output_config}")


def _gcc14_workaround(build_dir, cc_bin):
    """Detect GCC 14+ and create a wrapper that appends -std=gnu11.

    GCC 14+ defaults to C23 where bool/true/false are keywords,
    breaking older kernel code.

    Returns list of make CC/HOSTCC args, or empty list.
    """
    cc = cc_bin or "gcc"
    try:
        result = subprocess.run(
            [cc, "--version"], capture_output=True, text=True, timeout=5,
        )
        version_line = result.stdout.split("\n")[0] if result.stdout else ""
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return []

    if "gcc" not in version_line.lower():
        return []

    # Extract major version
    import re
    match = re.search(r"(\d+)\.\d+", version_line)
    if not match:
        return []

    major = int(match.group(1))
    if major < 14:
        return []

    # Find actual gcc path
    cc_path = shutil.which(cc)
    if not cc_path:
        return []

    print(f"GCC {major} detected, creating -std=gnu11 wrapper")
    wrapper_dir = os.path.join(build_dir, ".cc-wrapper")
    os.makedirs(wrapper_dir, exist_ok=True)
    wrapper_path = os.path.join(wrapper_dir, "gcc")
    with open(wrapper_path, "w") as f:
        f.write(f"#!/bin/bash\nexec {cc_path} \"$@\" -std=gnu11\n")
    os.chmod(wrapper_path, 0o755)

    return [f"CC={wrapper_path}", f"HOSTCC={wrapper_path}"]


def _run(cmd, cwd=None, env=None):
    """Run a command, exit on failure."""
    print(f"  + {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=cwd, env=env)
    if result.returncode != 0:
        print(f"error: command failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
