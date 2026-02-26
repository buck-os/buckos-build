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

from _env import clean_env


def _resolve_flag_paths(value, project_root):
    """Resolve relative buck-out paths in compiler/linker flag strings."""
    parts = []
    for token in value.split():
        for prefix in ("-I", "-L", "-Wl,-rpath-link,", "-Wl,-rpath,"):
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

    project_root = os.getcwd()

    # Read all Starlark env= vars BEFORE sanitizing.  These survive
    # os.environ.clear() only if captured here first.
    starlark_vars = {}
    for key in ("CC", "CXX", "AR", "_HERMETIC_PATH", "CFLAGS", "LDFLAGS",
                "CPPFLAGS", "PKG_CONFIG_PATH", "_DEP_BIN_PATHS", "DEP_BASE_DIRS",
                "_DEP_LD_LIBRARY_PATH", "MAKE_JOBS"):
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

    # Start with clean env
    env = clean_env()
    env["PROJECT_ROOT"] = project_root

    # Standard build env vars
    env["SRCS"] = source_dir
    env["OUT"] = output_dir
    env["DESTDIR"] = output_dir
    env["S"] = source_dir
    env["PV"] = version
    scratch = os.environ.get("BUCK_SCRATCH_PATH")
    if scratch:
        env["WORKDIR"] = resolve(scratch)
        env["BUCK_SCRATCH_PATH"] = resolve(scratch)
    else:
        import tempfile
        env["WORKDIR"] = tempfile.mkdtemp()

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
                "_DEP_LD_LIBRARY_PATH", "_HERMETIC_PATH"):
        if key in starlark_vars:
            env[key] = _resolve_colon_paths(starlark_vars[key], project_root)

    # Re-inject user env attrs
    for key, val in user_env.items():
        env[key] = val

    # Hermetic PATH handling
    hermetic_path = env.get("_HERMETIC_PATH")
    if hermetic_path:
        env["PATH"] = hermetic_path
        # Derive LD_LIBRARY_PATH from hermetic bin dirs
        ld_lib_parts = []
        for bd in hermetic_path.split(":"):
            parent = os.path.dirname(bd)
            for ld in ("lib", "lib64"):
                d = os.path.join(parent, ld)
                if os.path.isdir(d):
                    ld_lib_parts.append(d)
        if ld_lib_parts:
            existing = env.get("LD_LIBRARY_PATH", "")
            env["LD_LIBRARY_PATH"] = ":".join(ld_lib_parts) + (":" + existing if existing else "")
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

    # Translate _DEP_LD_LIBRARY_PATH → LD_LIBRARY_PATH for the subprocess.
    # The underscore-prefixed name prevents the dynamic linker from seeing
    # target libraries when running the host Python helper process.
    _dep_ld = env.pop("_DEP_LD_LIBRARY_PATH", None)
    if _dep_ld:
        existing = env.get("LD_LIBRARY_PATH", "")
        env["LD_LIBRARY_PATH"] = _dep_ld + (":" + existing if existing else "")

    # Prepend dep bin paths to PATH
    dep_bin = env.get("_DEP_BIN_PATHS")
    if dep_bin:
        env["PATH"] = dep_bin + ":" + env.get("PATH", "")

    # Stub makeinfo if not on PATH
    workdir = env["WORKDIR"]
    path_dirs = env.get("PATH", "").split(":")
    has_makeinfo = any(
        os.path.isfile(os.path.join(d, "makeinfo")) for d in path_dirs if d
    )
    if not has_makeinfo:
        stub_dir = os.path.join(workdir, ".stub-bin")
        os.makedirs(stub_dir, exist_ok=True)
        stub = os.path.join(stub_dir, "makeinfo")
        with open(stub, "w") as f:
            f.write("#!/bin/sh\nexit 0\n")
        os.chmod(stub, 0o755)
        env["PATH"] = stub_dir + ":" + env.get("PATH", "")

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

    # Run install script via bash -e (matching original `source` semantics)
    result = subprocess.run(
        ["bash", "-e", install_script],
        env=env,
        cwd=cwd,
    )

    # Sanitize file names in output and scratch space.  Some build systems
    # (autoconf's filesystem character test) create files with tabs,
    # backslashes, or other control characters that Buck2 cannot relativize.
    # Delete these unconditionally — they are never intentional build output.
    def _has_unsafe_chars(name):
        return any(ord(c) < 32 or ord(c) == 127 or c == '\\' for c in name)

    for _clean_dir in (output_dir, workdir):
        if not os.path.isdir(_clean_dir):
            continue
        for dirpath, dirnames, filenames in os.walk(_clean_dir, topdown=False):
            for fname in filenames:
                if _has_unsafe_chars(fname):
                    try:
                        os.unlink(os.path.join(dirpath, fname))
                    except OSError:
                        pass
            for dname in list(dirnames):
                if _has_unsafe_chars(dname):
                    try:
                        shutil.rmtree(os.path.join(dirpath, dname))
                    except OSError:
                        pass

    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
