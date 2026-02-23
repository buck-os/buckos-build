#!/usr/bin/env python3
"""Autotools configure wrapper.

Copies source to output dir (for out-of-tree build support), sets
environment variables, and runs ./configure with explicit args.

For packages that don't use autotools (e.g. Kconfig-based builds like
busybox or the kernel), pass --skip-configure to copy the source tree
without running ./configure.
"""

import argparse
import glob as _glob
import os
import shutil
import subprocess
import sys


def _resolve_env_paths(value):
    """Resolve relative Buck2 artifact paths in env values to absolute.

    Buck2 runs actions from the project root, so artifact paths like
    ``buck-out/v2/.../gcc`` are relative to that root.  When a subprocess
    changes its CWD (e.g. configure runs inside a build-subdir), the
    relative paths break.  This function makes them absolute while the
    process is still in the project root.

    Handles: bare paths, -I/path, -L/path, --flag=path, and
    colon-separated paths (PKG_CONFIG_PATH).
    """
    # Handle colon-separated path lists (PKG_CONFIG_PATH)
    if ":" in value and not value.startswith("-"):
        resolved = []
        for p in value.split(":"):
            p = p.strip()
            if p and not os.path.isabs(p) and (p.startswith("buck-out") or os.path.exists(p)):
                resolved.append(os.path.abspath(p))
            else:
                resolved.append(p)
        return ":".join(resolved)

    _FLAG_PREFIXES = ["-I", "-L", "-Wl,-rpath-link,", "-Wl,-rpath,"]

    parts = []
    for token in value.split():
        resolved = False
        # Handle -I/path, -L/path, -Wl,-rpath,/path
        for prefix in _FLAG_PREFIXES:
            if token.startswith(prefix) and len(token) > len(prefix):
                path = token[len(prefix):]
                # Always resolve buck-out relative paths to absolute,
                # even if the path doesn't exist (libtool requires
                # absolute paths and will fail on relative ones).
                if not os.path.isabs(path) and path.startswith("buck-out"):
                    parts.append(prefix + os.path.abspath(path))
                elif not os.path.isabs(path) and os.path.exists(path):
                    parts.append(prefix + os.path.abspath(path))
                else:
                    parts.append(token)
                resolved = True
                break
        if resolved:
            continue
        # Handle --flag=path
        if token.startswith("--") and "=" in token:
            idx = token.index("=")
            flag = token[: idx + 1]
            path = token[idx + 1 :]
            if path and not os.path.isabs(path) and os.path.exists(path):
                parts.append(flag + os.path.abspath(path))
            else:
                parts.append(token)
        elif not os.path.isabs(token) and os.path.exists(token):
            parts.append(os.path.abspath(token))
        else:
            parts.append(token)
    return " ".join(parts)


def main():
    parser = argparse.ArgumentParser(description="Run autotools configure")
    parser.add_argument("--source-dir", required=True, help="Source directory containing configure script")
    parser.add_argument("--output-dir", required=True, help="Build/output directory")
    parser.add_argument("--cc", default=None, help="C compiler")
    parser.add_argument("--cxx", default=None, help="C++ compiler")
    parser.add_argument("--configure-arg", action="append", dest="configure_args", default=[],
                        help="Argument to pass to ./configure (repeatable)")
    parser.add_argument("--cflags", action="append", dest="cflags", default=[],
                        help="CFLAGS value (repeatable, joined with spaces)")
    parser.add_argument("--cppflags", action="append", dest="cppflags", default=[],
                        help="CPPFLAGS value (repeatable, joined with spaces)")
    parser.add_argument("--ldflags", action="append", dest="ldflags", default=[],
                        help="LDFLAGS value (repeatable, joined with spaces)")
    parser.add_argument("--pkg-config-path", action="append", dest="pkg_config_paths", default=[],
                        help="PKG_CONFIG_PATH entries (repeatable)")
    parser.add_argument("--skip-configure", action="store_true",
                        help="Copy source but skip running ./configure (for Kconfig packages)")
    parser.add_argument("--configure-script", default="configure",
                        help="Name of the configure script (default: configure, e.g. Configure for OpenSSL)")
    parser.add_argument("--env", action="append", dest="extra_env", default=[],
                        help="Extra environment variable KEY=VALUE (repeatable)")
    parser.add_argument("--build-subdir", default=None,
                        help="Subdirectory to create and run configure from (for out-of-tree builds)")
    parser.add_argument("--path-prepend", action="append", dest="path_prepend", default=[],
                        help="Directory to prepend to PATH (repeatable, resolved to absolute)")
    parser.add_argument("--hermetic-path", action="append", dest="hermetic_path", default=[],
                        help="Set PATH to only these dirs (replaces host PATH, repeatable)")
    parser.add_argument("--pre-cmd", action="append", dest="pre_cmds", default=[],
                        help="Shell command to run in source dir before configure (repeatable)")
    args = parser.parse_args()

    source_dir = os.path.abspath(args.source_dir)
    output_dir = os.path.abspath(args.output_dir)

    if not os.path.isdir(source_dir):
        print(f"error: source directory not found: {source_dir}", file=sys.stderr)
        sys.exit(1)

    # Copy source to output dir for building
    if os.path.exists(output_dir):
        shutil.rmtree(output_dir)
    shutil.copytree(source_dir, output_dir, symlinks=True)

    # Create a pkg-config wrapper that always passes --define-prefix so
    # .pc files in Buck2 dep directories resolve paths correctly.
    wrapper_dir = os.path.join(output_dir, ".pkgconf-wrapper")
    os.makedirs(wrapper_dir, exist_ok=True)
    wrapper = os.path.join(wrapper_dir, "pkg-config")
    with open(wrapper, "w") as f:
        f.write('#!/bin/sh\n'
                'SELF_DIR="$(cd "$(dirname "$0")" && pwd)"\n'
                'PATH="${PATH#"$SELF_DIR:"}" exec pkg-config --define-prefix "$@"\n')
    os.chmod(wrapper, 0o755)

    env = os.environ.copy()

    # Expose the project root so pre-cmds can resolve Buck2 artifact
    # paths (which are relative to the project root, not to output_dir).
    env["PROJECT_ROOT"] = os.getcwd()

    # Clear host build env vars that could poison the build.
    # Deps inject these explicitly via --env args.
    for var in ["LD_LIBRARY_PATH", "PKG_CONFIG_PATH", "PYTHONPATH",
                "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "LIBRARY_PATH",
                "ACLOCAL_PATH"]:
        env.pop(var, None)

    # Disable host compiler/build caches — Buck2 caches actions itself,
    # and external caches can poison results across build contexts.
    env["CCACHE_DISABLE"] = "1"
    env["RUSTC_WRAPPER"] = ""
    env["CARGO_BUILD_RUSTC_WRAPPER"] = ""

    # Pin timestamps for reproducible builds.  Many build systems (autotools,
    # cmake, meson, kernel) embed __DATE__/__TIME__ or query the system clock.
    # SOURCE_DATE_EPOCH is the standard mechanism to override this.
    env.setdefault("SOURCE_DATE_EPOCH", "315576000")

    if args.cc:
        env["CC"] = args.cc
    if args.cxx:
        env["CXX"] = args.cxx
    if args.cflags:
        env["CFLAGS"] = _resolve_env_paths(" ".join(args.cflags))
    if args.cppflags:
        env["CPPFLAGS"] = _resolve_env_paths(" ".join(args.cppflags))
    if args.ldflags:
        env["LDFLAGS"] = _resolve_env_paths(" ".join(args.ldflags))
    if args.pkg_config_paths:
        env["PKG_CONFIG_PATH"] = _resolve_env_paths(":".join(args.pkg_config_paths))
    for entry in args.extra_env:
        key, _, value = entry.partition("=")
        if key:
            env[key] = _resolve_env_paths(value)
    if args.hermetic_path:
        env["PATH"] = ":".join(os.path.abspath(p) for p in args.hermetic_path)
        # Derive LD_LIBRARY_PATH from hermetic bin dirs so dynamically
        # linked tools (e.g. cross-ar needing libzstd) find their libs.
        _lib_dirs = []
        for _bp in args.hermetic_path:
            _parent = os.path.dirname(os.path.abspath(_bp))
            for _ld in ("lib", "lib64"):
                _d = os.path.join(_parent, _ld)
                if os.path.isdir(_d):
                    _lib_dirs.append(_d)
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
    if args.path_prepend:
        prepend = ":".join(os.path.abspath(p) for p in args.path_prepend if os.path.isdir(p))
        if prepend:
            env["PATH"] = prepend + ":" + env.get("PATH", os.environ.get("PATH", ""))

    # Auto-detect automake Perl modules and aclocal dirs from dep
    # prefixes.  The Buck2-installed automake hardcodes /usr/share/...
    # paths which don't resolve to the artifact directory.
    _path_sources = list(args.hermetic_path) + list(args.path_prepend)
    if _path_sources:
        perl5lib = []
        aclocal_dirs = []
        for bin_dir in _path_sources:
            share_dir = os.path.join(os.path.dirname(os.path.abspath(bin_dir)), "share")
            for d in _glob.glob(os.path.join(share_dir, "automake-*")):
                if os.path.isdir(d):
                    perl5lib.append(d)
            for d in _glob.glob(os.path.join(share_dir, "aclocal-*")):
                if os.path.isdir(d):
                    aclocal_dirs.append(d)
            # Also include the plain aclocal dir (for libtool m4 macros etc.)
            plain_aclocal = os.path.join(share_dir, "aclocal")
            if os.path.isdir(plain_aclocal):
                aclocal_dirs.append(plain_aclocal)
        if perl5lib:
            existing = env.get("PERL5LIB", "")
            env["PERL5LIB"] = ":".join(perl5lib) + (":" + existing if existing else "")
            # AUTOMAKE_LIBDIR overrides automake's hardcoded pkgvdatadir
            # (where am/*.am files and support scripts like install-sh live)
            for d in perl5lib:
                if os.path.isdir(os.path.join(d, "am")):
                    env["AUTOMAKE_LIBDIR"] = d
                    break
        if aclocal_dirs:
            # ACLOCAL_AUTOMAKE_DIR overrides the hardcoded automake acdir
            for d in aclocal_dirs:
                if "aclocal-" in os.path.basename(d):
                    env["ACLOCAL_AUTOMAKE_DIR"] = d
                    break
            # Include host system aclocal dir for m4 macros from
            # host-installed packages (e.g. pkg.m4 from pkg-config)
            host_aclocal = "/usr/share/aclocal"
            if os.path.isdir(host_aclocal) and host_aclocal not in aclocal_dirs:
                aclocal_dirs.append(host_aclocal)
            # ACLOCAL_PATH adds extra search directories
            env["ACLOCAL_PATH"] = ":".join(aclocal_dirs)

    # Prepend pkg-config wrapper to PATH
    env["PATH"] = wrapper_dir + ":" + env.get("PATH", os.environ.get("PATH", ""))

    # Run pre-configure commands (e.g. autoreconf, libtoolize, or
    # bootstrap src_prepare steps like symlinking in-tree libraries).
    # These run before the skip-configure check so they're available
    # for prepare-only actions (--skip-configure --pre-cmd "...").
    for cmd_str in args.pre_cmds:
        result = subprocess.run(cmd_str, shell=True, cwd=output_dir, env=env)
        if result.returncode != 0:
            print(f"error: pre-cmd failed with exit code {result.returncode}: {cmd_str}",
                  file=sys.stderr)
            sys.exit(1)

    if args.skip_configure:
        return

    configure = os.path.join(output_dir, args.configure_script)
    if not os.path.isfile(configure):
        print(f"error: configure script not found in {output_dir}", file=sys.stderr)
        sys.exit(1)

    # Ensure configure is executable
    os.chmod(configure, os.stat(configure).st_mode | 0o755)

    # Determine configure working directory
    configure_cwd = output_dir
    if args.build_subdir:
        configure_cwd = os.path.join(output_dir, args.build_subdir)
        os.makedirs(configure_cwd, exist_ok=True)
        # For out-of-tree builds, configure path is relative to the subdir
        configure = os.path.join(os.path.relpath(output_dir, configure_cwd), args.configure_script)

    cmd = [configure] + args.configure_args
    result = subprocess.run(cmd, cwd=configure_cwd, env=env)
    if result.returncode != 0:
        print(f"error: configure failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
