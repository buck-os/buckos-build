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

from _env import derive_lib_paths, sanitize_global_env, sysroot_lib_paths


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
    parser.add_argument("--allow-host-path", action="store_true",
                        help="Allow host PATH (bootstrap escape hatch)")
    parser.add_argument("--hermetic-path", action="append", dest="hermetic_path", default=[],
                        help="Set PATH to only these dirs (replaces host PATH, repeatable)")
    parser.add_argument("--hermetic-empty", action="store_true",
                        help="Start with empty PATH (populated by --path-prepend)")
    parser.add_argument("--ld-linux", default=None,
                        help="Buckos ld-linux path (disables posix_spawn)")
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
        print("error: kernel_config requires --hermetic-path, --hermetic-empty, or --allow-host-path",
              file=sys.stderr)
        sys.exit(1)
    if args.path_prepend:
        prepend = ":".join(os.path.abspath(p) for p in args.path_prepend if os.path.isdir(p))
        if prepend:
            os.environ["PATH"] = prepend + ":" + os.environ.get("PATH", "")

    # Derive LD_LIBRARY_PATH and BISON_PKGDATADIR from bin dirs
    if args.hermetic_path:
        derive_lib_paths(args.hermetic_path, os.environ)
    if args.path_prepend:
        derive_lib_paths(args.path_prepend, os.environ)

    if args.ld_linux:
        sysroot_lib_paths(args.ld_linux, os.environ)

    # Derive LIBRARY_PATH and C_INCLUDE_PATH from hermetic bin dirs so
    # HOSTCC finds headers and libs (kconfig compiles host tools like fixdep).
    _all_bin_dirs = (args.hermetic_path or []) + (args.path_prepend or [])
    _lib_parts, _inc_parts = [], []
    for bin_dir in _all_bin_dirs:
        parent = os.path.dirname(os.path.abspath(bin_dir))
        for ld in ("usr/lib64", "usr/lib", "lib64", "lib"):
            d = os.path.join(parent, ld)
            if os.path.isdir(d) and d not in _lib_parts:
                _lib_parts.append(d)
        for inc in ("usr/include", "include"):
            d = os.path.join(parent, inc)
            if os.path.isdir(d) and d not in _inc_parts:
                _inc_parts.append(d)
    if _lib_parts:
        os.environ["LIBRARY_PATH"] = ":".join(_lib_parts)
    if _inc_parts:
        os.environ["C_INCLUDE_PATH"] = ":".join(_inc_parts)

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

    # Resolve relative buck-out paths in CC/HOSTCC to absolute (make -C
    # changes directory, breaking relative artifact references).
    cc = _resolve_cc_path(args.cc)
    hostcc = _resolve_cc_path(args.hostcc)

    # Build make command base
    make_base = ["make", "-C", source_dir, f"O={build_dir}", f"ARCH={args.arch}"]
    if args.cross_compile:
        make_base.append(f"CROSS_COMPILE={args.cross_compile}")

    # GCC 14+ workaround: detect and create wrapper if needed
    cc_override = _gcc14_workaround(build_dir, cc)
    if cc_override:
        make_base.extend(cc_override)
    elif cc:
        # Kernel doesn't use --sysroot or -specs — bare compiler only.
        # scripts/cc-version.sh quotes "$CC" so multi-word values fail.
        bare_cc = cc.split()[0]
        make_base.append(f"CC={bare_cc}")

    # HOSTCC is independent of CC — always set when provided.
    # Uses the native gcc (not cross-compiler) with --sysroot to avoid
    # picking up incompatible host headers.
    if hostcc:
        make_base.append(f"HOSTCC={hostcc}")

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


def _resolve_cc_path(cc_str):
    """Resolve relative buck-out paths in a CC string to absolute."""
    if not cc_str:
        return cc_str
    parts = cc_str.split()
    resolved = []
    for p in parts:
        for prefix in ("--sysroot=", "-specs=", "-I", "-L"):
            if p.startswith(prefix):
                path = p[len(prefix):]
                if not os.path.isabs(path) and (path.startswith("buck-out") or os.path.exists(path)):
                    p = prefix + os.path.abspath(path)
                break
        else:
            if not os.path.isabs(p) and (p.startswith("buck-out") or os.path.exists(p)):
                p = os.path.abspath(p)
        resolved.append(p)
    return " ".join(resolved)


def _gcc14_workaround(build_dir, cc_bin):
    """Detect GCC 14+ and create a wrapper that appends -std=gnu11.

    GCC 14+ defaults to C23 where bool/true/false are keywords,
    breaking older kernel code.

    Returns list of make CC/HOSTCC args, or empty list.
    """
    # cc_bin may be "gcc" or "/path/to/gcc --sysroot=/path"; extract binary
    cc = (cc_bin or "gcc").split()[0]
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

    print(f"GCC {major} detected, adding -std=gnu11")
    return [f"CC={cc} -std=gnu11"]


def _run(cmd, cwd=None, env=None):
    """Run a command, exit on failure."""
    print(f"  + {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=cwd, env=env)
    if result.returncode != 0:
        print(f"error: command failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
