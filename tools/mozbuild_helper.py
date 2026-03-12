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
import glob as _glob_mod
import os
import re
import shutil
import subprocess
import sys
import json

from _env import clean_env, find_dep_python3, sanitize_filenames, sanitize_global_env, sysroot_lib_paths, write_pkg_config_wrapper


# ── Portable path placeholders (cross-machine cache) ─────────────────
#
# Configure bakes absolute paths into config.status, Makefiles, etc.
# To make cached configure output portable across hosts:
#   phase_configure: project root → @MOZBUILD_PROJECT_ROOT@  (before cache)
#   consuming phases: @MOZBUILD_PROJECT_ROOT@ → os.getcwd()  (after cache)
#
# Fallback: if cached output has raw absolute paths (old cache entries
# without placeholders), detect and rewrite them directly.

_PLACEHOLDER = "@MOZBUILD_PROJECT_ROOT@"

_BUCK_OUT_RE = re.compile(r'(/[^\s"\']+?)/buck-out/')

_BINARY_EXTS = frozenset((
    ".o", ".a", ".so", ".gch", ".pcm", ".pch", ".d",
    ".png", ".jpg", ".gif", ".ico", ".gz", ".xz", ".bz2",
    ".wasm", ".pyc", ".qm",
))


def _rewrite_tree(tree, old, new):
    """Replace old with new in all non-binary text files under tree."""
    for dirpath, _dirnames, filenames in os.walk(tree):
        for fname in filenames:
            if os.path.splitext(fname)[1] in _BINARY_EXTS:
                continue
            fpath = os.path.join(dirpath, fname)
            if os.path.islink(fpath):
                continue
            try:
                stat = os.stat(fpath)
                with open(fpath, "r") as f:
                    content = f.read()
                if old not in content:
                    continue
                with open(fpath, "w") as f:
                    f.write(content.replace(old, new))
                os.utime(fpath, (stat.st_atime, stat.st_mtime))
            except (UnicodeDecodeError, PermissionError, IsADirectoryError,
                    FileNotFoundError):
                pass


def _portabilize_paths(tree):
    """Replace the current project root with a placeholder before caching."""
    _rewrite_tree(tree, os.getcwd(), _PLACEHOLDER)


def _absolutize_paths(tree):
    """Replace placeholder with the current project root after cache retrieval."""
    current_root = os.getcwd()
    _rewrite_tree(tree, _PLACEHOLDER, current_root)

    # Fallback: handle old cache entries that have raw absolute paths
    # instead of placeholders (from before this change).
    for cs in _glob_mod.glob(os.path.join(tree, "**/config.status"), recursive=True):
        try:
            with open(cs, "r") as f:
                content = f.read()
        except (UnicodeDecodeError, PermissionError, OSError):
            continue
        m = _BUCK_OUT_RE.search(content)
        if m and m.group(1) != current_root:
            _rewrite_tree(tree, m.group(1), current_root)
            break


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


def _setup_pkg_config_wrapper(bin_dir, env=None):
    """Create pkg-config wrapper that uses --define-prefix."""
    return write_pkg_config_wrapper(bin_dir, python=find_dep_python3(env) if env else None)


def _build_dep_env(dep_base_dirs, pkg_config_path, base_path=None):
    """Build environment from dep base dirs for mach builds.

    Unlike binary.bzl, we DON'T set CFLAGS/LDFLAGS — mach manages those
    via pkg-config internally.  We set PKG_CONFIG_PATH, PATH, and
    C_INCLUDE_PATH / LIBRARY_PATH as fallbacks for #include_next headers
    that pkg-config flags don't cover (e.g. X11/Xlibint.h).
    """
    env = {}

    pc_paths = []
    lib_paths = []
    include_paths = []

    for dep_dir in dep_base_dirs:
        for subdir in ["usr/lib64/pkgconfig", "usr/lib/pkgconfig", "usr/share/pkgconfig"]:
            p = os.path.join(dep_dir, subdir)
            if os.path.isdir(p):
                pc_paths.append(p)
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

    # Dep bin dirs are NOT added to PATH.  Deps provide libraries and
    # headers; build tools (rustc, cargo, mold, etc.) come from the seed
    # host-tools via the hermetic PATH.  Dep binaries have unrewritten
    # padded ELF interpreters that can cause ENOEXEC.

    # LIBRARY_PATH for the linker
    if lib_paths:
        env["LIBRARY_PATH"] = ":".join(lib_paths)

    # LD_LIBRARY_PATH so dep binaries (rustc, llvm-objdump, mold) can find
    # their shared libraries at runtime.  Exclude dirs containing libc.so.6
    # to avoid poisoning host processes.
    safe_lib_paths = [
        p for p in lib_paths
        if not os.path.exists(os.path.join(p, "libc.so.6"))
    ]
    for _p in list(safe_lib_paths):
        _glibc_d = os.path.join(_p, "glibc")
        if os.path.isdir(_glibc_d):
            safe_lib_paths.append(_glibc_d)
    if safe_lib_paths:
        existing = env.get("LD_LIBRARY_PATH", "")
        merged = ":".join(safe_lib_paths)
        env["LD_LIBRARY_PATH"] = (merged + ":" + existing).rstrip(":") if existing else merged

    # C_INCLUDE_PATH / CPLUS_INCLUDE_PATH as fallback for headers that
    # pkg-config doesn't cover (Firefox system_wrappers use #include_next)
    if include_paths:
        env["C_INCLUDE_PATH"] = ":".join(include_paths)
        env["CPLUS_INCLUDE_PATH"] = ":".join(include_paths)

    env["DEP_BASE_DIRS"] = ":".join(dep_base_dirs)

    return env


def _write_mozconfig(path, options, dep_base_dirs=None):
    """Write mozconfig file.

    Auto-injects --with-libclang-path if libclang.so is found in a dep
    and no explicit --with-libclang-path is already specified.
    """
    has_libclang = any("--with-libclang-path" in o for o in options)
    libclang_dir = ""
    if not has_libclang and dep_base_dirs:
        for d in dep_base_dirs:
            for sub in ("usr/lib64", "usr/lib"):
                candidate = os.path.join(d, sub)
                if os.path.isfile(os.path.join(candidate, "libclang.so")):
                    libclang_dir = candidate
                    break
            if libclang_dir:
                break
    with open(path, "w") as f:
        for opt in options:
            f.write("ac_add_options {}\n".format(opt))
        if libclang_dir:
            f.write("ac_add_options --with-libclang-path={}\n".format(libclang_dir))


def _run(cmd, cwd=None, env=None):
    """Run command, exit on failure."""
    merged_env = clean_env()
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

    # Prevent mach from discovering host rustup/cargo via $HOME/.cargo/bin.
    # mach's rust_search_path explicitly expands $CARGO_HOME (or ~/.cargo)
    # and prepends it to the search path, bypassing our hermetic PATH.
    env["CARGO_HOME"] = os.path.join(args.work_dir, "cargo-home")
    env["RUSTUP_HOME"] = os.path.join(args.work_dir, "rustup-home")

    # Unset flags that interfere with mach's own flag management
    for var in ["CFLAGS", "CXXFLAGS", "LDFLAGS", "CPPFLAGS", "RUSTFLAGS"]:
        env[var] = ""

    # Hermetic PATH: replace host PATH with only specified dirs
    if hasattr(args, 'hermetic_path') and args.hermetic_path:
        base_path = ":".join(os.path.abspath(p) for p in args.hermetic_path)
        # Derive LD_LIBRARY_PATH from hermetic bin dirs so dynamically
        # linked tools (e.g. cross-ar needing libzstd) find their libs.
        _lib_dirs = []
        for _bp in args.hermetic_path:
            _parent = os.path.dirname(os.path.abspath(_bp))
            for _ld in ("lib", "lib64"):
                _d = os.path.join(_parent, _ld)
                if os.path.isdir(_d) and not os.path.exists(os.path.join(_d, "libc.so.6")):
                    _lib_dirs.append(_d)
                    _glibc_d = os.path.join(_d, "glibc")
                    if os.path.isdir(_glibc_d):
                        _lib_dirs.append(_glibc_d)
        if _lib_dirs:
            _existing = env.get("LD_LIBRARY_PATH", "")
            env["LD_LIBRARY_PATH"] = ":".join(_lib_dirs) + (":" + _existing if _existing else "")
        _py_paths = []
        for _bp in args.hermetic_path:
            _parent = os.path.dirname(os.path.abspath(_bp))
            for _pattern in ("lib/python*/site-packages", "lib/python*/dist-packages",
                             "lib64/python*/site-packages", "lib64/python*/dist-packages"):
                for _sp in __import__("glob").glob(os.path.join(_parent, _pattern)):
                    if os.path.isdir(_sp):
                        _py_paths.append(_sp)
        if _py_paths:
            _existing = env.get("PYTHONPATH", "")
            env["PYTHONPATH"] = ":".join(_py_paths) + (":" + _existing if _existing else "")
    elif hasattr(args, 'hermetic_empty') and args.hermetic_empty:
        base_path = ""
    elif hasattr(args, 'allow_host_path') and args.allow_host_path:
        base_path = getattr(args, '_host_path', '')
    else:
        print("error: build requires --hermetic-path, --hermetic-empty, or --allow-host-path",
              file=sys.stderr)
        sys.exit(1)
        base_path = None  # unreachable

    # Dep environment (before PATH so we can prepend pkg-config wrapper)
    # Don't inherit PKG_CONFIG_PATH from os.environ — the Starlark layer sets
    # it with relative buck-out paths that break after cd.  We build everything
    # from resolved dep_base_dirs.
    if args.dep_base_dirs:
        dep_dirs = [_resolve(d) for d in args.dep_base_dirs.split(":") if d]
        dep_env = _build_dep_env(dep_dirs, None, base_path=base_path)
        env.update(dep_env)

    # Set hermetic base PATH even when no deps provided bin paths
    if "PATH" not in env and base_path is not None:
        env["PATH"] = base_path

    # path-prepend dirs
    if hasattr(args, 'path_prepend') and args.path_prepend:
        prepend = ":".join(os.path.abspath(p) for p in args.path_prepend)
        env["PATH"] = prepend + (":" + env["PATH"] if env.get("PATH") else "")
        _dep_lib_dirs = []
        for _bp in args.path_prepend:
            _parent = os.path.dirname(os.path.abspath(_bp))
            for _ld in ("lib", "lib64"):
                _d = os.path.join(_parent, _ld)
                if os.path.isdir(_d) and not os.path.exists(os.path.join(_d, "libc.so.6")):
                    _dep_lib_dirs.append(_d)
                    _glibc_d = os.path.join(_d, "glibc")
                    if os.path.isdir(_glibc_d):
                        _dep_lib_dirs.append(_glibc_d)
        if _dep_lib_dirs:
            _existing = env.get("LD_LIBRARY_PATH", "")
            env["LD_LIBRARY_PATH"] = ":".join(_dep_lib_dirs) + (":" + _existing if _existing else "")

    # pkg-config wrapper with --define-prefix (MUST be first in PATH)
    env["PATH"] = pkg_config_bin_dir + ":" + env.get("PATH", "")

    # User-specified environment variables
    if hasattr(args, 'extra_env') and args.extra_env:
        for entry in args.extra_env:
            key, _, value = entry.partition("=")
            if key:
                env[key] = value

    # Mozconfig
    mozconfig = os.path.join(src_dir, "mozconfig")
    env["MOZCONFIG"] = mozconfig

    # Set up sysroot lib paths and disable posix_spawn in child Python
    # processes (mach) to avoid ENOEXEC with padded ELF interpreters on
    # buckos-native dep binaries.
    if hasattr(args, 'ld_linux') and args.ld_linux:
        sysroot_lib_paths(args.ld_linux, env)

    return env


def phase_configure(args):
    """Phase 2: ./mach configure."""
    src_dir = _setup_writable_source(args.source_dir, args.work_dir)

    pkg_config_bin = _setup_pkg_config_wrapper(
        os.path.join(args.work_dir, "bin"))

    env = _common_env(args, src_dir, pkg_config_bin)
    # Re-create wrapper with buckos python now that env is available
    _setup_pkg_config_wrapper(os.path.join(args.work_dir, "bin"), env=env)

    # Write mozconfig
    _dep_dirs = [_resolve(d) for d in args.dep_base_dirs.split(":") if d] if args.dep_base_dirs else []
    _write_mozconfig(os.path.join(src_dir, "mozconfig"), args.mozconfig_options, _dep_dirs)

    # Run configure
    # Always use "python3" (resolved via hermetic PATH in the subprocess
    # env).  Never fall back to sys.executable — that's the host Python
    # running the helper, which bypasses the hermetic PATH.
    _run(["python3", "./mach", "configure"], cwd=src_dir, env=env)

    # Replace absolute project root with portable placeholder before
    # caching — makes the output identical regardless of host.
    _portabilize_paths(src_dir)

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

    _absolutize_paths(src_dir)

    pkg_config_bin = _setup_pkg_config_wrapper(
        os.path.join(args.work_dir, "bin"))
    env = _common_env(args, src_dir, pkg_config_bin)
    # Re-create wrapper with buckos python now that env is available
    _setup_pkg_config_wrapper(os.path.join(args.work_dir, "bin"), env=env)
    _dep_dirs = [_resolve(d) for d in args.dep_base_dirs.split(":") if d] if args.dep_base_dirs else []
    _write_mozconfig(os.path.join(src_dir, "mozconfig"), args.mozconfig_options, _dep_dirs)

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

    # Rewrite stale absolute paths from cross-machine cache (e.g. CI
    # runner path baked into config.status by ./mach configure).
    _absolutize_paths(src_dir)

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
    # Re-create wrapper with buckos python now that env is available
    _setup_pkg_config_wrapper(os.path.join(args.work_dir, "bin"), env=env)
    _dep_dirs = [_resolve(d) for d in args.dep_base_dirs.split(":") if d] if args.dep_base_dirs else []
    _write_mozconfig(os.path.join(src_dir, "mozconfig"), args.mozconfig_options, _dep_dirs)

    # Full build
    _run(["python3", "./mach", "build"], cwd=src_dir, env=env)

    # Portabilize before caching
    _portabilize_paths(src_dir)

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

    _absolutize_paths(src_dir)

    pkg_config_bin = _setup_pkg_config_wrapper(
        os.path.join(args.work_dir, "bin"))
    env = _common_env(args, src_dir, pkg_config_bin)
    # Re-create wrapper with buckos python now that env is available
    _setup_pkg_config_wrapper(os.path.join(args.work_dir, "bin"), env=env)
    _dep_dirs = [_resolve(d) for d in args.dep_base_dirs.split(":") if d] if args.dep_base_dirs else []
    _write_mozconfig(os.path.join(src_dir, "mozconfig"), args.mozconfig_options, _dep_dirs)

    output = _resolve(args.output_dir)
    os.makedirs(output, exist_ok=True)
    env["DESTDIR"] = output

    _run(["python3", "./mach", "install"], cwd=src_dir, env=env)


def phase_full(args):
    """Full build: configure + build + install in a single action.

    Running all phases together eliminates cross-action path mismatches.
    Each Buck2 action gets its own scratch directory, so mach's
    per-source-path virtualenv hashing produces different srcdirs/src-HASH
    entries in each action.  config.status records the virtualenv path
    from configure, and when build runs in a different action the old
    path doesn't exist — triggering FileNotFoundError on backend regen.
    """
    src_dir = _setup_writable_source(args.source_dir, args.work_dir)

    pkg_config_bin = _setup_pkg_config_wrapper(
        os.path.join(args.work_dir, "bin"))

    env = _common_env(args, src_dir, pkg_config_bin)
    # Re-create wrapper with buckos python now that env is available
    _setup_pkg_config_wrapper(os.path.join(args.work_dir, "bin"), env=env)

    _dep_dirs = [_resolve(d) for d in args.dep_base_dirs.split(":") if d] if args.dep_base_dirs else []
    _write_mozconfig(os.path.join(src_dir, "mozconfig"), args.mozconfig_options, _dep_dirs)

    _run(["python3", "./mach", "configure"], cwd=src_dir, env=env)
    _run(["python3", "./mach", "build"], cwd=src_dir, env=env)

    output = _resolve(args.output_dir)
    os.makedirs(output, exist_ok=True)
    env["DESTDIR"] = output
    _run(["python3", "./mach", "install"], cwd=src_dir, env=env)


def main():
    _host_path = os.environ.get("PATH", "")

    parser = argparse.ArgumentParser(description="Mozilla/mach build helper")
    parser.add_argument("--phase", required=True,
                        choices=["configure", "rust-deps", "build", "install", "full"],
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
    parser.add_argument("--dep-base-dirs-file", default=None,
                        help="File with dep base directories (one per line)")
    parser.add_argument("--hermetic-path", action="append", dest="hermetic_path", default=[],
                        help="Set PATH to only these dirs (replaces host PATH, repeatable)")
    parser.add_argument("--allow-host-path", action="store_true",
                        help="Allow host PATH (bootstrap escape hatch)")
    parser.add_argument("--hermetic-empty", action="store_true",
                        help="Start with empty PATH (populated by --path-prepend)")
    parser.add_argument("--path-prepend", action="append", dest="path_prepend", default=[],
                        help="Directory to prepend to PATH (repeatable, resolved to absolute)")
    parser.add_argument("--ld-linux", default=None,
                        help="Buckos ld-linux path (disables posix_spawn)")
    parser.add_argument("--env", action="append", dest="extra_env", default=[],
                        help="Extra environment variable KEY=VALUE (repeatable)")

    args = parser.parse_args()
    args._host_path = _host_path

    sanitize_global_env()

    # Merge --dep-base-dirs-file into --dep-base-dirs (flag file takes precedence)
    if args.dep_base_dirs_file:
        with open(os.path.abspath(args.dep_base_dirs_file)) as f:
            dirs = [line.strip() for line in f if line.strip()]
        args.dep_base_dirs = ":".join(dirs)

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
        "full": phase_full,
    }

    phases[args.phase](args)
    sanitize_filenames(args.output_dir, args.work_dir)


if __name__ == "__main__":
    main()
