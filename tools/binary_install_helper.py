#!/usr/bin/env python3
"""binary_package install phase wrapper.

Replaces the ~130-line bash wrapper.sh in binary.bzl _install().
Reads env vars set by Starlark env={} (CC, CXX, AR, CFLAGS, etc.)
from os.environ before sanitizing, then re-injects them into the
clean env for the subprocess call.

Positional args: source_dir output_dir version install_script
"""

import glob as _glob
import os
import shutil
import stat
import subprocess
import sys

from _env import clean_env, derive_lib_paths, file_prefix_map_flags, find_buckos_shell, find_dep_python3, portabilize_shebangs, preferred_linker_flag, register_cleanup, rewrite_shebangs, sanitize_filenames, setup_ccache_symlinks, write_pkg_config_wrapper, write_stub_script


def _resolve_flag_paths(value, project_root):
    """Resolve relative buck-out paths in compiler/linker flag strings."""
    parts = []
    for token in value.split():
        for prefix in ("-I", "-L", "-Wl,-rpath-link,", "-Wl,-rpath,", "-specs="):
            if token.startswith(prefix) and len(token) > len(prefix):
                path = token[len(prefix):]
                if not os.path.isabs(path):
                    parts.append(prefix + os.path.join(project_root, path))
                else:
                    parts.append(token)
                break
        else:
            if token.startswith("--") and "=" in token:
                idx = token.index("=")
                flag = token[:idx + 1]
                path = token[idx + 1:]
                if path.startswith("buck-out") and not os.path.isabs(path):
                    parts.append(flag + os.path.join(project_root, path))
                else:
                    parts.append(token)
            elif not token.startswith("-") and "/" in token and not os.path.isabs(token):
                parts.append(os.path.join(project_root, token))
            else:
                parts.append(token)
    return " ".join(parts)


def _resolve_colon_paths(value, project_root):
    """Resolve relative paths in colon-separated lists."""
    parts = []
    for p in value.split(":"):
        p = p.strip()
        if p and not os.path.isabs(p):
            parts.append(os.path.join(project_root, p))
        else:
            parts.append(p)
    return ":".join(parts)


def main():
    if len(sys.argv) < 5:
        print("usage: binary_install_helper source_dir output_dir version install_script",
              file=sys.stderr)
        sys.exit(1)

    _host_path = os.environ.get("PATH", "")
    project_root = os.getcwd()

    # Read all Starlark env= vars BEFORE sanitizing.  These survive
    # os.environ.clear() only if captured here first.
    starlark_vars = {}
    for key in ("CC", "CXX", "AR", "_HERMETIC_PATH", "_ALLOW_HOST_PATH",
                "_HERMETIC_EMPTY", "_PATH_PREPEND",
                "CFLAGS", "LDFLAGS",
                "CPPFLAGS", "PKG_CONFIG_PATH", "_DEP_BIN_PATHS", "DEP_BASE_DIRS",
                "_DEP_LD_LIBRARY_PATH", "_HOST_LIB_DIRS_FILE", "MAKE_JOBS",
                "TARGET_TRIPLE"):
        val = os.environ.get(key)
        if val is not None:
            starlark_vars[key] = val
    # Also capture user env attrs (any remaining env vars not in passthrough)
    user_env = {}
    for key, val in os.environ.items():
        if key not in starlark_vars and key not in (
            "HOME", "USER", "LOGNAME", "TMPDIR", "TEMP", "TMP",
            "TERM", "PATH", "BUCK_SCRATCH_PATH", "LC_ALL", "LANG",
            "SOURCE_DATE_EPOCH", "CCACHE_DISABLE", "RUSTC_WRAPPER",
            "CARGO_BUILD_RUSTC_WRAPPER",
        ):
            user_env[key] = val

    def resolve(p):
        return p if os.path.isabs(p) else os.path.join(project_root, p)

    source_dir = resolve(sys.argv[1])
    output_dir = resolve(sys.argv[2])
    version = sys.argv[3]
    install_script = resolve(sys.argv[4])

    # Register cleanup early so unsafe filenames are removed on any exit
    scratch = os.environ.get("BUCK_SCRATCH_PATH")
    workdir = resolve(scratch) if scratch else None
    register_cleanup(output_dir, workdir)

    # Start with clean env
    env = clean_env()
    env["PROJECT_ROOT"] = project_root

    # Standard build env vars
    env["SRCS"] = source_dir
    env["OUT"] = output_dir
    env["DESTDIR"] = output_dir
    env["S"] = source_dir
    env["PV"] = version
    if workdir:
        env["WORKDIR"] = workdir
        env["BUCK_SCRATCH_PATH"] = workdir
    else:
        import tempfile
        workdir = tempfile.mkdtemp()
        env["WORKDIR"] = workdir
        register_cleanup(workdir)

    make_jobs = starlark_vars.get("MAKE_JOBS", str(os.cpu_count() or 1))
    env["MAKE_JOBS"] = make_jobs
    env["MAKEOPTS"] = make_jobs

    # Re-inject Starlark env vars with path resolution
    for key in ("CC", "CXX", "AR"):
        if key in starlark_vars:
            env[key] = _resolve_flag_paths(starlark_vars[key], project_root)
    for key in ("CFLAGS", "LDFLAGS", "CPPFLAGS"):
        if key in starlark_vars:
            env[key] = _resolve_flag_paths(starlark_vars[key], project_root)

    for key in ("PKG_CONFIG_PATH", "_DEP_BIN_PATHS", "DEP_BASE_DIRS",
                "_DEP_LD_LIBRARY_PATH", "_HERMETIC_PATH", "_PATH_PREPEND"):
        if key in starlark_vars:
            env[key] = _resolve_colon_paths(starlark_vars[key], project_root)
    # Pass through flags that don't need path resolution
    for key in ("_ALLOW_HOST_PATH", "_HERMETIC_EMPTY", "TARGET_TRIPLE"):
        if key in starlark_vars:
            env[key] = starlark_vars[key]

    # Propagate -I flags from CFLAGS to CXXFLAGS/CPPFLAGS so C++ builds
    # find dep headers (autotools/cmake do this via build_helper.py).
    # Packages that use -nostdinc (e.g. glibc) must explicitly clear
    # CPPFLAGS in their install script to avoid include path conflicts.
    _cflags_val = env.get("CFLAGS", "")
    if _cflags_val:
        _include_flags = " ".join(f for f in _cflags_val.split() if f.startswith("-I"))
        if _include_flags:
            for var in ("CPPFLAGS", "CXXFLAGS"):
                existing = env.get(var, "")
                env[var] = (_include_flags + " " + existing).strip() if existing else _include_flags

    # Scrub absolute build paths from debug info and __FILE__ expansions.
    pfm = " ".join(file_prefix_map_flags())
    for var in ("CFLAGS", "CXXFLAGS"):
        existing = env.get(var, "")
        env[var] = (pfm + " " + existing).strip() if existing else pfm

    # Set CHOST = TARGET_TRIPLE (matches autotools behavior)
    _target_triple = starlark_vars.get("TARGET_TRIPLE")
    if _target_triple:
        env.setdefault("CHOST", _target_triple)
        env.setdefault("CBUILD", _target_triple)

    # Re-inject user env attrs
    for key, val in user_env.items():
        env[key] = val

    # Auto-set RUSTFLAGS so cargo build scripts link against sysroot glibc
    # (matching the sysroot ld-linux), avoiding host glibc version mismatches.
    # Only set if CC is present and RUSTFLAGS is not already set by the user.
    if "RUSTFLAGS" not in env and env.get("CC"):
        _cc = env["CC"]
        _cc_parts = _cc.split()
        # Skip ccache prefix
        if _cc_parts and os.path.basename(_cc_parts[0]) == "ccache":
            _cc_parts = _cc_parts[1:]
        if _cc_parts:
            _cc_bin = _cc_parts[0]
            _link_args = " ".join(f"-C link-arg={flag}" for flag in _cc_parts[1:])
            env["RUSTFLAGS"] = f"-C linker={_cc_bin} {_link_args}".strip()
            env["CARGO_HOST_LINKER"] = _cc_bin

    # Hermetic PATH handling
    hermetic_path = env.pop("_HERMETIC_PATH", None)
    hermetic_empty = env.pop("_HERMETIC_EMPTY", None)
    allow_host_path = env.pop("_ALLOW_HOST_PATH", None)
    path_prepend = env.pop("_PATH_PREPEND", None)
    if hermetic_path:
        env["PATH"] = hermetic_path
        # Derive LD_LIBRARY_PATH from hermetic bin dirs
        ld_lib_parts = []
        for bd in hermetic_path.split(":"):
            parent = os.path.dirname(bd)
            for ld in ("lib", "lib64"):
                d = os.path.join(parent, ld)
                if os.path.isdir(d) and not os.path.exists(os.path.join(d, "libc.so.6")):
                    ld_lib_parts.append(d)
        if ld_lib_parts:
            existing = env.get("LD_LIBRARY_PATH", "")
            env["LD_LIBRARY_PATH"] = ":".join(ld_lib_parts) + (":" + existing if existing else "")
        # Auto-detect BISON_PKGDATADIR
        if "BISON_PKGDATADIR" not in env:
            for bd in hermetic_path.split(":"):
                bison_data = os.path.join(os.path.dirname(bd), "share", "bison")
                if os.path.isdir(bison_data):
                    env["BISON_PKGDATADIR"] = bison_data
                    break
        # Auto-detect PYTHONPATH
        py_paths = []
        for bd in hermetic_path.split(":"):
            parent = os.path.dirname(bd)
            for pattern in ("lib/python*/site-packages", "lib/python*/dist-packages",
                            "lib64/python*/site-packages", "lib64/python*/dist-packages"):
                for sp in _glob.glob(os.path.join(parent, pattern)):
                    if os.path.isdir(sp):
                        py_paths.append(sp)
        if py_paths:
            existing = env.get("PYTHONPATH", "")
            env["PYTHONPATH"] = ":".join(py_paths) + (":" + existing if existing else "")
    elif hermetic_empty:
        env["PATH"] = ""
    elif allow_host_path:
        env["PATH"] = _host_path
    else:
        print("error: build requires _HERMETIC_PATH, _HERMETIC_EMPTY, or _ALLOW_HOST_PATH env",
              file=sys.stderr)
        sys.exit(1)

    # Prepend host tool deps to PATH
    if path_prepend:
        env["PATH"] = path_prepend + (":" + env["PATH"] if env.get("PATH") else "")
        # Derive LD_LIBRARY_PATH from prepend dirs
        _pp_lib_dirs = []
        for bd in path_prepend.split(":"):
            parent = os.path.dirname(bd)
            for ld in ("lib", "lib64"):
                d = os.path.join(parent, ld)
                if os.path.isdir(d) and not os.path.exists(os.path.join(d, "libc.so.6")):
                    _pp_lib_dirs.append(d)
        if _pp_lib_dirs:
            existing = env.get("LD_LIBRARY_PATH", "")
            env["LD_LIBRARY_PATH"] = ":".join(_pp_lib_dirs) + (":" + existing if existing else "")
        # Auto-detect BISON_PKGDATADIR from prepend dirs
        if "BISON_PKGDATADIR" not in env:
            for bd in path_prepend.split(":"):
                bison_data = os.path.join(os.path.dirname(bd), "share", "bison")
                if os.path.isdir(bison_data):
                    env["BISON_PKGDATADIR"] = bison_data
                    break

    # Translate _DEP_LD_LIBRARY_PATH → LD_LIBRARY_PATH for the subprocess.
    # The underscore-prefixed name prevents the dynamic linker from seeing
    # target libraries when running the host Python helper process.
    _dep_ld = env.pop("_DEP_LD_LIBRARY_PATH", None)
    if _dep_ld:
        existing = env.get("LD_LIBRARY_PATH", "")
        env["LD_LIBRARY_PATH"] = _dep_ld + (":" + existing if existing else "")

    # Merge host tool transitive dep lib dirs into LD_LIBRARY_PATH.
    # Host tool binaries cached in NativeLink CAS may have RUNPATH with
    # absolute paths from the original build machine.  On a different
    # machine those paths don't exist — LD_LIBRARY_PATH bridges the gap.
    _host_lib_file = env.pop("_HOST_LIB_DIRS_FILE", None)
    if _host_lib_file:
        _host_lib_file = resolve(_host_lib_file)
        if os.path.isfile(_host_lib_file):
            _host_dirs = []
            with open(_host_lib_file) as f:
                for line in f:
                    d = line.strip()
                    if d:
                        d = resolve(d) if not os.path.isabs(d) else d
                        if os.path.isdir(d):
                            _host_dirs.append(d)
            if _host_dirs:
                existing = env.get("LD_LIBRARY_PATH", "")
                merged = ":".join(_host_dirs)
                env["LD_LIBRARY_PATH"] = (merged + ":" + existing).rstrip(":") if existing else merged

    # Prepend dep bin paths to PATH and derive tool data dirs
    dep_bin = env.get("_DEP_BIN_PATHS")
    if dep_bin:
        env["PATH"] = dep_bin + ":" + env.get("PATH", "")
        # Derive BISON_PKGDATADIR so relocated bison finds its data files.
        for _bp in dep_bin.split(":"):
            _parent = os.path.dirname(_bp)
            bison_data = os.path.join(_parent, "share", "bison")
            if os.path.isdir(bison_data) and "BISON_PKGDATADIR" not in env:
                env["BISON_PKGDATADIR"] = bison_data

    # Stub makeinfo if not on PATH
    workdir = env["WORKDIR"]
    path_dirs = env.get("PATH", "").split(":")
    has_makeinfo = any(
        os.path.isfile(os.path.join(d, "makeinfo")) for d in path_dirs if d
    )
    if not has_makeinfo:
        stub_dir = os.path.join(workdir, ".stub-bin")
        write_stub_script(os.path.join(stub_dir, "makeinfo"))
        env["PATH"] = stub_dir + ":" + env.get("PATH", "")

    # Create gcc/cc/g++/c++ symlinks so install scripts that invoke bare
    # `gcc` (e.g. libcap _makenames, busybox gcc-version.sh) find the
    # buckos compiler.  Mirrors build_helper.py:666-689.
    _cc_val = env.get("CC", "")
    if _cc_val:
        _cc_bin = os.path.abspath(_cc_val.split()[0])
        if os.path.isfile(_cc_bin):
            _symlink_dir = os.path.join(workdir, "cc-symlinks")
            os.makedirs(_symlink_dir, exist_ok=True)
            for _name in ("gcc", "cc", "clang"):
                _link = os.path.join(_symlink_dir, _name)
                if not os.path.exists(_link):
                    os.symlink(_cc_bin, _link)
            _cxx_val = env.get("CXX", "")
            if _cxx_val:
                _cxx_bin = os.path.abspath(_cxx_val.split()[0])
                if os.path.isfile(_cxx_bin):
                    for _name in ("g++", "c++", "clang++"):
                        _link = os.path.join(_symlink_dir, _name)
                        if not os.path.exists(_link):
                            os.symlink(_cxx_bin, _link)
            env["PATH"] = _symlink_dir + ":" + env.get("PATH", "")

    # ccache masquerade symlinks (matches build_helper.py behavior)
    _scratch = env.get("BUCK_SCRATCH_PATH", env.get("TMPDIR", "/tmp"))
    setup_ccache_symlinks(env, _scratch)

    # Derive GCONV_PATH, GETTEXTDATADIRS, and additional LD_LIBRARY_PATH
    # from hermetic and path-prepend dirs (matches build_helper.py).
    hermetic_dirs = env.get("PATH", "").split(":")
    derive_lib_paths(hermetic_dirs, env)

    # Auto-detect PYTHON/PYTHON3 from hermetic PATH
    _dep_python3 = find_dep_python3(env)
    if _dep_python3:
        env.setdefault("PYTHON", _dep_python3)
        env.setdefault("PYTHON3", _dep_python3)

    # Create pkg-config wrapper with --define-prefix (matches build_helper.py)
    _wrapper_dir = write_pkg_config_wrapper(
        os.path.join(workdir, ".pkgconf-wrapper"),
        python=_dep_python3,
    )
    env["PATH"] = _wrapper_dir + ":" + env.get("PATH", "")

    # Inject preferred linker flag into LDFLAGS (mold if available)
    _ld_flag = preferred_linker_flag(env)
    if _ld_flag:
        existing = env.get("LDFLAGS", "")
        env["LDFLAGS"] = (existing + " " + _ld_flag).strip()

    # Copy source to writable directory
    if os.path.isdir(source_dir):
        os.makedirs(workdir, exist_ok=True)
        writable_src = os.path.join(workdir, "src")
        src_real = os.path.realpath(source_dir)
        writable_real = os.path.realpath(writable_src) if os.path.exists(writable_src) else writable_src
        if src_real != writable_real:
            shutil.copytree(source_dir, writable_src, symlinks=True, dirs_exist_ok=True)
            # Resolve top-level directory symlinks to actual copies so
            # os.walk/chmod/touch reach their contents (e.g. GCC in-tree
            # gmp/, mpfr/, mpc/ symlinked from read-only dep artifacts).
            for item in os.listdir(writable_src):
                path = os.path.join(writable_src, item)
                if os.path.islink(path) and os.path.isdir(path):
                    target = os.path.realpath(path)
                    os.unlink(path)
                    shutil.copytree(target, path, symlinks=True)
            # Make writable
            for dirpath, dirnames, filenames in os.walk(writable_src):
                for d in dirnames:
                    dp = os.path.join(dirpath, d)
                    if not os.path.islink(dp):
                        os.chmod(dp, os.stat(dp).st_mode | stat.S_IWUSR)
                for f in filenames:
                    fp = os.path.join(dirpath, f)
                    if not os.path.islink(fp):
                        os.chmod(fp, os.stat(fp).st_mode | stat.S_IWUSR)
            # Restore execute bits on autotools scripts
            autotools_scripts = (
                "configure", "config.guess", "config.sub", "install-sh",
                "depcomp", "missing", "compile", "ltmain.sh", "mkinstalldirs",
                "config.status",
            )
            for dirpath, _, filenames in os.walk(writable_src):
                for f in filenames:
                    if f in autotools_scripts:
                        fp = os.path.join(dirpath, f)
                        if not os.path.islink(fp):
                            os.chmod(fp, os.stat(fp).st_mode | stat.S_IXUSR)
            # Touch autotools-generated files
            touch_names = (
                "configure", "configure.sh", "aclocal.m4", "config.h.in",
                "Makefile.in",
            )
            for dirpath, _, filenames in os.walk(writable_src):
                for f in filenames:
                    if f in touch_names or f.endswith(".info") or f.endswith(".1"):
                        fp = os.path.join(dirpath, f)
                        if not os.path.islink(fp):
                            os.utime(fp, None)

        env["SRCS"] = writable_src
        env["S"] = writable_src
        cwd = writable_src
    elif os.path.isfile(source_dir):
        cwd = os.path.dirname(source_dir)
    else:
        cwd = project_root

    # Find buckos shell and use it for install script execution, make
    # SHELL override, and shebang rewriting in the writable source copy.
    _buckos_bash = find_buckos_shell(env)
    if _buckos_bash:
        env["SHELL"] = _buckos_bash
        existing_flags = env.get("MAKEFLAGS", "")
        if "SHELL=" not in existing_flags:
            env["MAKEFLAGS"] = (existing_flags + " " if existing_flags else "") + f"SHELL={_buckos_bash}"
        if os.path.isdir(source_dir):
            rewrite_shebangs(writable_src, env)

    # Run install script via bash -e (matching original `source` semantics)
    _bash_cmd = _buckos_bash or "bash"
    result = subprocess.run(
        [_bash_cmd, "-e", install_script],
        env=env,
        cwd=cwd,
    )

    sanitize_filenames(output_dir, workdir)
    portabilize_shebangs(output_dir)

    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
