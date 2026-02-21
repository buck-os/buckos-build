#!/usr/bin/env python3
"""CMake configure wrapper.

Runs cmake with specified source dir, build dir, and arguments.
"""

import argparse
import os
import subprocess
import sys


def _resolve_env_paths(value):
    """Resolve relative Buck2 artifact paths in env values to absolute.

    Buck2 runs actions from the project root, so artifact paths like
    ``buck-out/v2/.../gcc`` are relative to that root.  When a subprocess
    changes its CWD (e.g. cmake runs in the build dir), the
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
    parser = argparse.ArgumentParser(description="Run CMake configure")
    parser.add_argument("--source-dir", required=True, help="Source directory")
    parser.add_argument("--build-dir", required=True, help="Build directory")
    parser.add_argument("--install-prefix", default="/usr", help="Install prefix (default: /usr)")
    parser.add_argument("--cc", default=None, help="C compiler")
    parser.add_argument("--cxx", default=None, help="C++ compiler")
    parser.add_argument("--source-subdir", default=None,
                        help="Subdirectory within source containing CMakeLists.txt")
    parser.add_argument("--cmake-arg", action="append", dest="cmake_args", default=[],
                        help="Extra argument to pass to cmake (repeatable)")
    parser.add_argument("--cmake-define", action="append", dest="cmake_defines", default=[],
                        help="CMake define as KEY=VALUE (repeatable)")
    parser.add_argument("--env", action="append", dest="extra_env", default=[],
                        help="Extra environment variable KEY=VALUE (repeatable)")
    parser.add_argument("--prefix-path", action="append", dest="prefix_paths", default=[],
                        help="Directory to add to CMAKE_PREFIX_PATH (repeatable)")
    parser.add_argument("--path-prepend", action="append", dest="path_prepend", default=[],
                        help="Directory to prepend to PATH (repeatable, resolved to absolute)")
    args = parser.parse_args()

    if not os.path.isdir(args.source_dir):
        print(f"error: source directory not found: {args.source_dir}", file=sys.stderr)
        sys.exit(1)

    os.makedirs(args.build_dir, exist_ok=True)

    # Create a pkg-config wrapper that always passes --define-prefix so
    # .pc files in Buck2 dep directories resolve paths correctly.
    import tempfile
    wrapper_dir = tempfile.mkdtemp(prefix="pkgconf-wrapper-")
    wrapper = os.path.join(wrapper_dir, "pkg-config")
    with open(wrapper, "w") as f:
        f.write('#!/bin/sh\nexec /usr/bin/pkg-config --define-prefix "$@"\n')
    os.chmod(wrapper, 0o755)

    env = os.environ.copy()
    env["PATH"] = wrapper_dir + ":" + env.get("PATH", "")
    for entry in args.extra_env:
        key, _, value = entry.partition("=")
        if key:
            env[key] = _resolve_env_paths(value)
    if args.path_prepend:
        prepend = ":".join(os.path.abspath(p) for p in args.path_prepend if os.path.isdir(p))
        if prepend:
            env["PATH"] = prepend + ":" + env.get("PATH", "")
    if args.cc:
        env["CC"] = _resolve_env_paths(args.cc)
    if args.cxx:
        env["CXX"] = _resolve_env_paths(args.cxx)

    source_path = os.path.abspath(args.source_dir)
    if args.source_subdir:
        source_path = os.path.join(source_path, args.source_subdir)

    cmd = [
        "cmake",
        "-S", source_path,
        "-B", os.path.abspath(args.build_dir),
        f"-DCMAKE_INSTALL_PREFIX={args.install_prefix}",
        "-G", "Ninja",
    ]

    # Build CMAKE_PREFIX_PATH from dep prefixes so find_package() works
    if args.prefix_paths:
        resolved = [os.path.abspath(p) for p in args.prefix_paths]
        cmd.append("-DCMAKE_PREFIX_PATH=" + ";".join(resolved))

    for define in args.cmake_defines:
        # Resolve relative buck-out paths in define values to absolute
        if "=" in define:
            key, _, value = define.partition("=")
            cmd.append(f"-D{key}={_resolve_env_paths(value)}")
        else:
            cmd.append(f"-D{define}")

    cmd.extend(args.cmake_args)

    result = subprocess.run(cmd, env=env)
    if result.returncode != 0:
        print(f"error: cmake configure failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
