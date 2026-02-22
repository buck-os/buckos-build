#!/usr/bin/env python3
"""Multi-phase build helper for Mozilla Firefox (mach-based builds).

Five discrete phases, each invocable independently:

  configure   — ./mach configure with isolated MOZBUILD_STATE_PATH
  rust-deps   — pre-build vendored Rust crates (the caching win)
  build       — ./mach build with pre-warmed cargo target dir
  install     — DESTDIR=$OUT ./mach install

Each phase copies/symlinks inputs to a writable tree and produces an
output directory that Buck2 can cache independently.
"""

import argparse
import os
import shutil
import subprocess
import sys
import json


def _resolve(path):
    """Resolve a path to absolute."""
    return os.path.abspath(path)


def _setup_writable_source(source_dir, work_dir):
    """Copy source to writable location, return path."""
    writable = os.path.join(work_dir, "src")
    if os.path.exists(writable):
        real_src = os.path.realpath(source_dir)
        real_wr = os.path.realpath(writable)
        if real_src == real_wr:
            return writable
        shutil.rmtree(writable)
    shutil.copytree(source_dir, writable, symlinks=True)
    # Restore write perms
    for root, dirs, files in os.walk(writable):
        for d in dirs:
            os.chmod(os.path.join(root, d), 0o755)
        for f in files:
            fp = os.path.join(root, f)
            os.chmod(fp, os.stat(fp).st_mode | 0o644)
    return writable


def _setup_pkg_config_wrapper(bin_dir):
    """Create pkg-config wrapper that uses --define-prefix."""
    os.makedirs(bin_dir, exist_ok=True)
    wrapper = os.path.join(bin_dir, "pkg-config")
    with open(wrapper, "w") as f:
        f.write("#!/bin/sh\nexec /usr/bin/pkg-config --define-prefix \"$@\"\n")
    os.chmod(wrapper, 0o755)
    return bin_dir


def _build_dep_env(dep_base_dirs, pkg_config_path):
    """Build environment from dep base dirs for mach builds.

    Unlike binary.bzl, we DON'T set CFLAGS/LDFLAGS — mach manages those
    via pkg-config internally.  We set PKG_CONFIG_PATH, PATH, and
    C_INCLUDE_PATH / LIBRARY_PATH as fallbacks for #include_next headers
    that pkg-config flags don't cover (e.g. X11/Xlibint.h).
    """
    env = {}

    pc_paths = []
    bin_paths = []
    lib_paths = []
    include_paths = []

    for dep_dir in dep_base_dirs:
        for subdir in ["usr/lib64/pkgconfig", "usr/lib/pkgconfig", "usr/share/pkgconfig"]:
            p = os.path.join(dep_dir, subdir)
            if os.path.isdir(p):
                pc_paths.append(p)
        for subdir in ["usr/bin", "usr/sbin"]:
            p = os.path.join(dep_dir, subdir)
            if os.path.isdir(p):
                bin_paths.append(p)
        for subdir in ["usr/lib64", "usr/lib"]:
            p = os.path.join(dep_dir, subdir)
            if os.path.isdir(p):
                lib_paths.append(p)
        # Include paths for #include_next fallback (system_wrappers need these)
        inc = os.path.join(dep_dir, "usr/include")
        if os.path.isdir(inc):
            include_paths.append(inc)

    # Prepend dep pkg-config paths
    all_pc = pc_paths
    if pkg_config_path:
        all_pc = pc_paths + pkg_config_path.split(":")
    if all_pc:
        env["PKG_CONFIG_PATH"] = ":".join(all_pc)

    if bin_paths:
        env["PATH"] = ":".join(bin_paths) + ":" + os.environ.get("PATH", "")

    # LIBRARY_PATH for the linker (NOT LD_LIBRARY_PATH — that poisons
    # system Python's shared libs like pyexpat against our older expat)
    if lib_paths:
        env["LIBRARY_PATH"] = ":".join(lib_paths)

    # C_INCLUDE_PATH / CPLUS_INCLUDE_PATH as fallback for headers that
    # pkg-config doesn't cover (Firefox system_wrappers use #include_next)
    if include_paths:
        env["C_INCLUDE_PATH"] = ":".join(include_paths)
        env["CPLUS_INCLUDE_PATH"] = ":".join(include_paths)

    env["DEP_BASE_DIRS"] = ":".join(dep_base_dirs)

    return env


def _write_mozconfig(path, options):
    """Write mozconfig file."""
    with open(path, "w") as f:
        for opt in options:
            f.write("ac_add_options {}\n".format(opt))


def _run(cmd, cwd=None, env=None):
    """Run command, exit on failure."""
    merged_env = dict(os.environ)
    if env:
        merged_env.update(env)

    print("+ {}".format(" ".join(cmd) if isinstance(cmd, list) else cmd),
          flush=True)
    result = subprocess.run(
        cmd, cwd=cwd, env=merged_env,
        shell=isinstance(cmd, str),
    )
    if result.returncode != 0:
        print("error: command failed with exit code {}".format(result.returncode),
              file=sys.stderr)
        sys.exit(result.returncode)


def _common_env(args, src_dir, pkg_config_bin_dir):
    """Build the common environment for all mach phases."""
    env = {}

    # Isolate mach state
    mozbuild_state = os.path.join(args.work_dir, "mozbuild")
    os.makedirs(mozbuild_state, exist_ok=True)
    env["MOZBUILD_STATE_PATH"] = mozbuild_state
    env["NO_MERCURIAL_SETUP_CHECK"] = "1"

    # Don't let mach use system Python packages
    env["MACH_BUILD_PYTHON_NATIVE_PACKAGE_SOURCE"] = "pip"

    # Disable compiler caches
    env["CCACHE_DISABLE"] = "1"
    env["CARGO_BUILD_RUSTC_WRAPPER"] = ""

    # Unset flags that interfere with mach's own flag management
    for var in ["CFLAGS", "CXXFLAGS", "LDFLAGS", "CPPFLAGS", "RUSTFLAGS"]:
        env[var] = ""

    # Dep environment (before PATH so we can prepend pkg-config wrapper)
    # Don't inherit PKG_CONFIG_PATH from os.environ — the Starlark layer sets
    # it with relative buck-out paths that break after cd.  We build everything
    # from resolved dep_base_dirs.
    if args.dep_base_dirs:
        dep_dirs = [_resolve(d) for d in args.dep_base_dirs.split(":") if d]
        dep_env = _build_dep_env(dep_dirs, None)
        env.update(dep_env)

    # pkg-config wrapper with --define-prefix (MUST be first in PATH)
    env["PATH"] = pkg_config_bin_dir + ":" + env.get("PATH", os.environ.get("PATH", ""))

    # Mozconfig
    mozconfig = os.path.join(src_dir, "mozconfig")
    env["MOZCONFIG"] = mozconfig

    return env


def phase_configure(args):
    """Phase 2: ./mach configure."""
    src_dir = _setup_writable_source(args.source_dir, args.work_dir)

    pkg_config_bin = _setup_pkg_config_wrapper(
        os.path.join(args.work_dir, "bin"))

    env = _common_env(args, src_dir, pkg_config_bin)

    # Write mozconfig
    _write_mozconfig(os.path.join(src_dir, "mozconfig"), args.mozconfig_options)

    # Run configure
    _run([sys.executable if shutil.which("python3") is None else "python3",
          "./mach", "configure"], cwd=src_dir, env=env)

    # Copy the configured source (with objdir) to output
    output = _resolve(args.output_dir)
    shutil.copytree(src_dir, output, symlinks=True)


def phase_rust_deps(args):
    """Phase 3: pre-build vendored Rust crates."""
    # Copy source to writable location
    src_dir = _setup_writable_source(args.source_dir, args.work_dir)

    # If we have a configured dir, overlay objdir from it
    if args.configured_dir:
        configured = _resolve(args.configured_dir)
        # Find the objdir
        for entry in os.listdir(configured):
            if entry.startswith("obj-"):
                obj_src = os.path.join(configured, entry)
                obj_dst = os.path.join(src_dir, entry)
                if not os.path.exists(obj_dst):
                    shutil.copytree(obj_src, obj_dst, symlinks=True)
                break

    pkg_config_bin = _setup_pkg_config_wrapper(
        os.path.join(args.work_dir, "bin"))
    env = _common_env(args, src_dir, pkg_config_bin)
    _write_mozconfig(os.path.join(src_dir, "mozconfig"), args.mozconfig_options)

    # Find objdir
    objdir = None
    for entry in os.listdir(src_dir):
        if entry.startswith("obj-"):
            objdir = os.path.join(src_dir, entry)
            break

    if not objdir:
        print("error: no objdir found — configure phase must run first",
              file=sys.stderr)
        sys.exit(1)

    cargo_target = os.path.join(objdir, "toolkit", "library", "rust",
                                "target")

    # Build Rust deps by building gkrust with cargo (mach handles this).
    # We use `./mach cargo build` or directly invoke cargo with the right env.
    # The key insight: building the full `./mach build` Rust portion compiles
    # all 574 crates.  We capture the cargo target dir as output.
    #
    # Use mach's cargo sub-command to get the right RUSTFLAGS and env:
    _run(["python3", "./mach", "build", "toolkit/library/rust"],
         cwd=src_dir, env=env)

    # Copy cargo target dir to output
    output = _resolve(args.output_dir)
    if os.path.isdir(cargo_target):
        shutil.copytree(cargo_target, output, symlinks=True)
    else:
        # Fallback: copy entire objdir rust artifacts
        os.makedirs(output, exist_ok=True)
        # Look for libgkrust.a as marker
        for root, dirs, files in os.walk(objdir):
            for f in files:
                if f == "libgkrust.a":
                    shutil.copy2(os.path.join(root, f), output)


def phase_build(args):
    """Phase 4: ./mach build with pre-warmed cargo target dir."""
    src_dir = _setup_writable_source(args.source_dir, args.work_dir)

    # Overlay configured objdir
    if args.configured_dir:
        configured = _resolve(args.configured_dir)
        for entry in os.listdir(configured):
            if entry.startswith("obj-"):
                obj_src = os.path.join(configured, entry)
                obj_dst = os.path.join(src_dir, entry)
                if not os.path.exists(obj_dst):
                    shutil.copytree(obj_src, obj_dst, symlinks=True)
                # Make writable
                for root, dirs, files in os.walk(obj_dst):
                    for d in dirs:
                        os.chmod(os.path.join(root, d), 0o755)
                    for f in files:
                        fp = os.path.join(root, f)
                        os.chmod(fp, os.stat(fp).st_mode | 0o644)
                break

    # Pre-warm cargo target dir from rust-deps phase
    if args.rust_deps_dir:
        rust_deps = _resolve(args.rust_deps_dir)
        # Find objdir and inject cached rust build artifacts
        for entry in os.listdir(src_dir):
            if entry.startswith("obj-"):
                cargo_target = os.path.join(src_dir, entry,
                                            "toolkit", "library", "rust",
                                            "target")
                if os.path.isdir(rust_deps) and not os.path.exists(cargo_target):
                    os.makedirs(os.path.dirname(cargo_target), exist_ok=True)
                    shutil.copytree(rust_deps, cargo_target, symlinks=True)
                    # Make writable
                    for root, dirs, files in os.walk(cargo_target):
                        for d in dirs:
                            os.chmod(os.path.join(root, d), 0o755)
                        for f in files:
                            fp = os.path.join(root, f)
                            os.chmod(fp, os.stat(fp).st_mode | 0o644)
                break

    pkg_config_bin = _setup_pkg_config_wrapper(
        os.path.join(args.work_dir, "bin"))
    env = _common_env(args, src_dir, pkg_config_bin)
    _write_mozconfig(os.path.join(src_dir, "mozconfig"), args.mozconfig_options)

    # Full build
    _run(["python3", "./mach", "build"], cwd=src_dir, env=env)

    # Copy built tree to output
    output = _resolve(args.output_dir)
    shutil.copytree(src_dir, output, symlinks=True)


def phase_install(args):
    """Phase 5: DESTDIR=$OUT ./mach install."""
    src_dir = _setup_writable_source(args.source_dir, args.work_dir)

    # Overlay built objdir
    if args.built_dir:
        built = _resolve(args.built_dir)
        for entry in os.listdir(built):
            if entry.startswith("obj-"):
                obj_src = os.path.join(built, entry)
                obj_dst = os.path.join(src_dir, entry)
                if not os.path.exists(obj_dst):
                    shutil.copytree(obj_src, obj_dst, symlinks=True)
                break

    pkg_config_bin = _setup_pkg_config_wrapper(
        os.path.join(args.work_dir, "bin"))
    env = _common_env(args, src_dir, pkg_config_bin)
    _write_mozconfig(os.path.join(src_dir, "mozconfig"), args.mozconfig_options)

    output = _resolve(args.output_dir)
    os.makedirs(output, exist_ok=True)
    env["DESTDIR"] = output

    _run(["python3", "./mach", "install"], cwd=src_dir, env=env)


def main():
    parser = argparse.ArgumentParser(description="Mozilla/mach build helper")
    parser.add_argument("--phase", required=True,
                        choices=["configure", "rust-deps", "build", "install"],
                        help="Build phase to execute")
    parser.add_argument("--source-dir", required=True,
                        help="Source directory")
    parser.add_argument("--output-dir", required=True,
                        help="Output directory")
    parser.add_argument("--work-dir", default=None,
                        help="Scratch directory (default: output-dir/../scratch)")
    parser.add_argument("--configured-dir", default=None,
                        help="Configured objdir from configure phase")
    parser.add_argument("--rust-deps-dir", default=None,
                        help="Pre-built Rust deps from rust-deps phase")
    parser.add_argument("--built-dir", default=None,
                        help="Built tree from build phase")
    parser.add_argument("--mozconfig-option", action="append",
                        dest="mozconfig_options", default=[],
                        help="Mozconfig ac_add_options value (repeatable)")
    parser.add_argument("--dep-base-dirs", default=None,
                        help="Colon-separated dep base directories")

    args = parser.parse_args()

    args.source_dir = _resolve(args.source_dir)
    args.output_dir = _resolve(args.output_dir)
    if args.work_dir is None:
        args.work_dir = os.path.join(os.path.dirname(args.output_dir), "scratch")
    args.work_dir = _resolve(args.work_dir)
    os.makedirs(args.work_dir, exist_ok=True)

    phases = {
        "configure": phase_configure,
        "rust-deps": phase_rust_deps,
        "build": phase_build,
        "install": phase_install,
    }

    phases[args.phase](args)


if __name__ == "__main__":
    main()
