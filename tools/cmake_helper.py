#!/usr/bin/env python3
"""CMake configure wrapper.

Runs cmake with specified source dir, build dir, and arguments.
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
    parser = argparse.ArgumentParser(description="Run CMake configure")
    parser.add_argument("--source-dir", required=True, help="Source directory")
    parser.add_argument("--build-dir", required=True, help="Build directory")
    parser.add_argument("--install-prefix", default="/usr", help="Install prefix (default: /usr)")
    parser.add_argument("--cc", default=None, help="C compiler")
    parser.add_argument("--cxx", default=None, help="C++ compiler")
    parser.add_argument("--cmake-arg", action="append", dest="cmake_args", default=[],
                        help="Extra argument to pass to cmake (repeatable)")
    parser.add_argument("--cmake-define", action="append", dest="cmake_defines", default=[],
                        help="CMake define as KEY=VALUE (repeatable)")
    parser.add_argument("--env", action="append", dest="extra_env", default=[],
                        help="Extra environment variable KEY=VALUE (repeatable)")
    args = parser.parse_args()

    if not os.path.isdir(args.source_dir):
        print(f"error: source directory not found: {args.source_dir}", file=sys.stderr)
        sys.exit(1)

    os.makedirs(args.build_dir, exist_ok=True)

    env = os.environ.copy()
    for entry in args.extra_env:
        key, _, value = entry.partition("=")
        if key:
            env[key] = _resolve_env_paths(value)
    if args.cc:
        env["CC"] = _resolve_env_paths(args.cc)
    if args.cxx:
        env["CXX"] = _resolve_env_paths(args.cxx)

    cmd = [
        "cmake",
        "-S", os.path.abspath(args.source_dir),
        "-B", os.path.abspath(args.build_dir),
        f"-DCMAKE_INSTALL_PREFIX={args.install_prefix}",
        "-G", "Ninja",
    ]

    for define in args.cmake_defines:
        cmd.append(f"-D{define}")

    cmd.extend(args.cmake_args)

    result = subprocess.run(cmd, env=env)
    if result.returncode != 0:
        print(f"error: cmake configure failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
