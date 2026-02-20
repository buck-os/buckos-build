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
    """Resolve relative Buck2 artifact paths in env values to absolute."""
    parts = []
    for token in value.split():
        if token.startswith("--") and "=" in token:
            idx = token.index("=")
            flag = token[: idx + 1]
            path = token[idx + 1 :]
            if path and os.path.exists(path):
                parts.append(flag + os.path.abspath(path))
            else:
                parts.append(token)
        elif os.path.exists(token):
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
    args = parser.parse_args()

    build_dir = os.path.abspath(args.build_dir)
    if args.build_subdir:
        build_dir = os.path.join(build_dir, args.build_subdir)
    if not os.path.isdir(build_dir):
        print(f"error: build directory not found: {build_dir}", file=sys.stderr)
        sys.exit(1)

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


if __name__ == "__main__":
    main()
