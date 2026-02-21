#!/usr/bin/env python3
"""Autotools configure wrapper.

Copies source to output dir (for out-of-tree build support), sets
environment variables, and runs ./configure with explicit args.

For packages that don't use autotools (e.g. Kconfig-based builds like
busybox or the kernel), pass --skip-configure to copy the source tree
without running ./configure.
"""

import argparse
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

    _FLAG_PREFIXES = ["-I", "-L", "-Wl,-rpath,"]

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

    # For Kconfig-based packages, just copying is enough -- the actual
    # configuration happens via make targets in the build phase.
    if args.skip_configure:
        return

    configure = os.path.join(output_dir, args.configure_script)

    env = os.environ.copy()

    # Disable host compiler/build caches — Buck2 caches actions itself,
    # and external caches can poison results across build contexts.
    env["CCACHE_DISABLE"] = "1"
    env["RUSTC_WRAPPER"] = ""

    if args.cc:
        env["CC"] = args.cc
    if args.cxx:
        env["CXX"] = args.cxx
    if args.cflags:
        env["CFLAGS"] = _resolve_env_paths(" ".join(args.cflags))
    if args.ldflags:
        env["LDFLAGS"] = _resolve_env_paths(" ".join(args.ldflags))
    if args.pkg_config_paths:
        env["PKG_CONFIG_PATH"] = _resolve_env_paths(":".join(args.pkg_config_paths))
    for entry in args.extra_env:
        key, _, value = entry.partition("=")
        if key:
            env[key] = _resolve_env_paths(value)
    if args.path_prepend:
        prepend = ":".join(os.path.abspath(p) for p in args.path_prepend if os.path.isdir(p))
        if prepend:
            env["PATH"] = prepend + ":" + env.get("PATH", os.environ.get("PATH", ""))

    # Run pre-configure commands (e.g. autoreconf, libtoolize)
    for cmd_str in args.pre_cmds:
        result = subprocess.run(cmd_str, shell=True, cwd=output_dir, env=env)
        if result.returncode != 0:
            print(f"error: pre-cmd failed with exit code {result.returncode}: {cmd_str}",
                  file=sys.stderr)
            sys.exit(1)

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
