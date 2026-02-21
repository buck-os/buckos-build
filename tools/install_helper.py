#!/usr/bin/env python3
"""Install wrapper for make install.

Runs make install with DESTDIR (or a custom variable) set to the prefix
directory.  The --destdir-var flag overrides the variable name for
packages that use a non-standard name (e.g. CONFIG_PREFIX for busybox).
"""

import argparse
import os
import subprocess
import sys


def _resolve_env_paths(value):
    """Resolve relative Buck2 artifact paths in env values to absolute.

    Buck2 runs actions from the project root, so artifact paths like
    ``buck-out/v2/.../gcc`` are relative to that root.  When a subprocess
    changes its CWD (e.g. make runs in a copied build tree), the
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
    parser = argparse.ArgumentParser(description="Run make install")
    parser.add_argument("--build-dir", required=True, help="Build directory")
    parser.add_argument("--prefix", required=True, help="DESTDIR prefix for installation")
    parser.add_argument("--make-arg", action="append", dest="make_args", default=[],
                        help="Extra argument to pass to make (repeatable)")
    parser.add_argument("--destdir-var", default="DESTDIR",
                        help="Make variable for install prefix (default: DESTDIR)")
    parser.add_argument("--build-subdir", default=None,
                        help="Subdirectory within build-dir where make runs (for out-of-tree builds)")
    parser.add_argument("--env", action="append", dest="extra_env", default=[],
                        help="Extra environment variable KEY=VALUE (repeatable)")
    parser.add_argument("--path-prepend", action="append", dest="path_prepend", default=[],
                        help="Directory to prepend to PATH (repeatable, resolved to absolute)")
    parser.add_argument("--build-system", choices=["make", "ninja"], default="make",
                        help="Build system to use (default: make)")
    parser.add_argument("--post-cmd", action="append", dest="post_cmds", default=[],
                        help="Shell command to run in prefix dir after install (repeatable)")
    args = parser.parse_args()

    build_dir = os.path.abspath(args.build_dir)
    if args.build_subdir:
        build_dir = os.path.join(build_dir, args.build_subdir)
    if not os.path.isdir(build_dir):
        print(f"error: build directory not found: {build_dir}", file=sys.stderr)
        sys.exit(1)

    # Create a pkg-config wrapper that always passes --define-prefix so
    # .pc files in Buck2 dep directories resolve paths correctly.
    import tempfile
    wrapper_dir = tempfile.mkdtemp(prefix="pkgconf-wrapper-")
    wrapper = os.path.join(wrapper_dir, "pkg-config")
    with open(wrapper, "w") as f:
        f.write('#!/bin/sh\nexec /usr/bin/pkg-config --define-prefix "$@"\n')
    os.chmod(wrapper, 0o755)
    os.environ["PATH"] = wrapper_dir + ":" + os.environ.get("PATH", "")

    # Disable host compiler/build caches — Buck2 caches actions itself,
    # and external caches can poison results across build contexts.
    os.environ["CCACHE_DISABLE"] = "1"
    os.environ["RUSTC_WRAPPER"] = ""

    # Pin timestamps for reproducible builds.
    os.environ.setdefault("SOURCE_DATE_EPOCH", "0")

    # Apply extra environment variables
    for entry in args.extra_env:
        key, _, value = entry.partition("=")
        if key:
            os.environ[key] = _resolve_env_paths(value)
    if args.path_prepend:
        prepend = ":".join(os.path.abspath(p) for p in args.path_prepend if os.path.isdir(p))
        if prepend:
            os.environ["PATH"] = prepend + ":" + os.environ.get("PATH", "")

    prefix = os.path.abspath(args.prefix)
    os.makedirs(prefix, exist_ok=True)

    if args.build_system == "ninja":
        # Ninja uses DESTDIR as an env var, not a command-line arg
        os.environ[args.destdir_var] = prefix
        cmd = [
            "ninja",
            "-C", build_dir,
            "install",
        ]
    else:
        cmd = [
            "make",
            "-C", build_dir,
            f"{args.destdir_var}={prefix}",
            "install",
        ]
    # Resolve paths in make args (e.g. CC=buck-out/.../gcc → absolute)
    for arg in args.make_args:
        if "=" in arg:
            key, _, value = arg.partition("=")
            cmd.append(f"{key}={_resolve_env_paths(value)}")
        else:
            cmd.append(arg)

    result = subprocess.run(cmd)
    if result.returncode != 0:
        print(f"error: make install failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(1)

    # Remove libtool .la files — they embed absolute build-time paths that
    # break when consumed from Buck2 dep directories.  Modern pkg-config and
    # cmake handle transitive deps without them.
    import glob as _glob
    for la in _glob.glob(os.path.join(prefix, "**", "*.la"), recursive=True):
        os.remove(la)

    # Run post-install commands (e.g. ldconfig, cleanup)
    for cmd_str in args.post_cmds:
        result = subprocess.run(cmd_str, shell=True, cwd=prefix)
        if result.returncode != 0:
            print(f"error: post-cmd failed with exit code {result.returncode}: {cmd_str}",
                  file=sys.stderr)
            sys.exit(1)


if __name__ == "__main__":
    main()
