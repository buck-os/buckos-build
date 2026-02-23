#!/usr/bin/env python3
"""Meson setup wrapper.

Runs meson setup with specified source dir, build dir, and arguments.
"""

import argparse
import glob as _glob
import os
import subprocess
import sys


def _resolve_env_paths(value):
    """Resolve relative Buck2 artifact paths in env values to absolute.

    Buck2 runs actions from the project root, so artifact paths like
    ``buck-out/v2/.../gcc`` are relative to that root.  When a subprocess
    changes its CWD (e.g. meson runs compiler checks in a temp dir), the
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
    parser = argparse.ArgumentParser(description="Run meson setup")
    parser.add_argument("--source-dir", required=True, help="Source directory")
    parser.add_argument("--build-dir", required=True, help="Build directory")
    parser.add_argument("--prefix", default="/usr", help="Install prefix (default: /usr)")
    parser.add_argument("--cc", default=None, help="C compiler")
    parser.add_argument("--cxx", default=None, help="C++ compiler")
    parser.add_argument("--meson-arg", action="append", dest="meson_args", default=[],
                        help="Extra argument to pass to meson (repeatable)")
    parser.add_argument("--meson-define", action="append", dest="meson_defines", default=[],
                        help="Meson option as KEY=VALUE (repeatable)")
    parser.add_argument("--env", action="append", dest="extra_env", default=[],
                        help="Extra environment variable KEY=VALUE (repeatable)")
    parser.add_argument("--path-prepend", action="append", dest="path_prepend", default=[],
                        help="Directory to prepend to PATH (repeatable, resolved to absolute)")
    parser.add_argument("--hermetic-path", action="append", dest="hermetic_path", default=[],
                        help="Set PATH to only these dirs (replaces host PATH, repeatable)")
    parser.add_argument("--pre-cmd", action="append", dest="pre_cmds", default=[],
                        help="Shell command to run in source dir before meson setup (repeatable)")
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
        f.write('#!/bin/sh\n'
                'SELF_DIR="$(cd "$(dirname "$0")" && pwd)"\n'
                'PATH="${PATH#"$SELF_DIR:"}" exec pkg-config --define-prefix "$@"\n')
    os.chmod(wrapper, 0o755)

    env = os.environ.copy()

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

    # Pin timestamps for reproducible builds.
    env.setdefault("SOURCE_DATE_EPOCH", "315576000")

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
    if args.path_prepend:
        prepend = ":".join(os.path.abspath(p) for p in args.path_prepend if os.path.isdir(p))
        if prepend:
            env["PATH"] = prepend + ":" + env.get("PATH", "")

    # Auto-detect Python site-packages from dep prefixes so build-time
    # Python modules (e.g. mako for mesa) are found without manual
    # PYTHONPATH wiring.  --path-prepend dirs are {prefix}/usr/bin;
    # derive {prefix}/usr/lib/python*/site-packages from them.
    _path_sources = list(args.hermetic_path) + list(args.path_prepend)
    if _path_sources:
        python_paths = []
        for bin_dir in _path_sources:
            usr_dir = os.path.dirname(os.path.abspath(bin_dir))
            for pattern in ("lib/python*/site-packages", "lib/python*/dist-packages",
                            "lib64/python*/site-packages", "lib64/python*/dist-packages"):
                for sp in _glob.glob(os.path.join(usr_dir, pattern)):
                    if os.path.isdir(sp):
                        python_paths.append(sp)
        if python_paths:
            existing = env.get("PYTHONPATH", "")
            env["PYTHONPATH"] = ":".join(python_paths) + (":" + existing if existing else "")

    # Prepend pkg-config wrapper to PATH (after hermetic/prepend logic
    # so the wrapper is always available regardless of PATH mode)
    env["PATH"] = wrapper_dir + ":" + env.get("PATH", "")

    for entry in args.extra_env:
        key, _, value = entry.partition("=")
        if key:
            env[key] = _resolve_env_paths(value)
    if args.cc:
        env["CC"] = _resolve_env_paths(args.cc)
    if args.cxx:
        env["CXX"] = _resolve_env_paths(args.cxx)

    # Run pre-configure commands in the source directory
    source_abs = os.path.abspath(args.source_dir)
    for cmd_str in args.pre_cmds:
        result = subprocess.run(cmd_str, shell=True, cwd=source_abs, env=env)
        if result.returncode != 0:
            print(f"error: pre-cmd failed with exit code {result.returncode}: {cmd_str}",
                  file=sys.stderr)
            sys.exit(1)

    cmd = [
        "meson",
        "setup",
        os.path.abspath(args.build_dir),
        source_abs,
        f"--prefix={args.prefix}",
    ]

    for define in args.meson_defines:
        # Resolve relative Buck2 paths in define values (e.g.
        # c_args=-Ibuck-out/... or c_link_args=-Lbuck-out/...)
        key, _, value = define.partition("=")
        if value and ("buck-out" in value or value.startswith("-")):
            parts = []
            for token in value.split(","):
                token = token.strip()
                for prefix in ("-I", "-L"):
                    if token.startswith(prefix):
                        path = token[len(prefix):]
                        if not os.path.isabs(path) and os.path.exists(path):
                            token = prefix + os.path.abspath(path)
                        elif not os.path.isabs(path) and path.startswith("buck-out"):
                            token = prefix + os.path.abspath(path)
                        break
                parts.append(token)
            define = key + "=" + ",".join(parts)
        cmd.extend(["-D", define])

    cmd.extend(args.meson_args)

    result = subprocess.run(cmd, env=env)
    if result.returncode != 0:
        print(f"error: meson setup failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
