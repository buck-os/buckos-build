#!/usr/bin/env python3
"""Meson setup wrapper.

Runs meson setup with specified source dir, build dir, and arguments.
"""

import argparse
import glob as _glob
import os
import subprocess
import sys

from _env import clean_env, sanitize_filenames


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
    _host_path = os.environ.get("PATH", "")

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
    parser.add_argument("--allow-host-path", action="store_true",
                        help="Allow host PATH (bootstrap escape hatch)")
    parser.add_argument("--hermetic-empty", action="store_true",
                        help="Start with empty PATH (populated by --path-prepend)")
    parser.add_argument("--pre-cmd", action="append", dest="pre_cmds", default=[],
                        help="Shell command to run in source dir before meson setup (repeatable)")
    parser.add_argument("--cflags-file", default=None,
                        help="File with CFLAGS (one per line, from tset projection)")
    parser.add_argument("--ldflags-file", default=None,
                        help="File with LDFLAGS (one per line, from tset projection)")
    parser.add_argument("--pkg-config-file", default=None,
                        help="File with PKG_CONFIG_PATH entries (one per line, from tset projection)")
    parser.add_argument("--path-file", default=None,
                        help="File with PATH dirs to prepend (one per line, from tset projection)")
    args = parser.parse_args()

    # Read flag files early — tset-propagated values are base defaults.
    def _read_flag_file(path):
        if not path:
            return []
        with open(path) as f:
            return [line.rstrip("\n") for line in f if line.strip()]

    file_cflags = _read_flag_file(args.cflags_file)
    file_ldflags = _read_flag_file(args.ldflags_file)
    file_pkg_config = _read_flag_file(args.pkg_config_file)
    file_path_dirs = _read_flag_file(args.path_file)

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

    env = clean_env()

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
    elif args.hermetic_empty:
        env["PATH"] = ""
    elif args.allow_host_path:
        env["PATH"] = _host_path
    else:
        print("error: build requires --hermetic-path, --hermetic-empty, or --allow-host-path",
              file=sys.stderr)
        sys.exit(1)
    all_path_prepend = file_path_dirs + args.path_prepend
    if all_path_prepend:
        prepend = ":".join(os.path.abspath(p) for p in all_path_prepend if os.path.isdir(p))
        if prepend:
            env["PATH"] = prepend + ":" + env.get("PATH", "")
        # Derive LD_LIBRARY_PATH from dep bin dirs so dynamically linked
        # dep tools (e.g. buckos python needing libpython3.12.so) work
        # during meson setup.  This is scoped to the setup subprocess
        # and doesn't affect the ninja build phase.
        _dep_lib_dirs = []
        for _bp in all_path_prepend:
            _parent = os.path.dirname(os.path.abspath(_bp))
            for _ld in ("lib", "lib64"):
                _d = os.path.join(_parent, _ld)
                if os.path.isdir(_d):
                    _dep_lib_dirs.append(_d)
        if _dep_lib_dirs:
            _existing = env.get("LD_LIBRARY_PATH", "")
            env["LD_LIBRARY_PATH"] = ":".join(_dep_lib_dirs) + (":" + _existing if _existing else "")

    # Apply extra environment variables first (toolchain flags like -march).
    for entry in args.extra_env:
        key, _, value = entry.partition("=")
        if key:
            env[key] = _resolve_env_paths(value)

    # Prepend flag file values — dep-provided -I/-L flags must appear before
    # toolchain flags so headers/libs from deps are found.
    if file_cflags:
        existing = env.get("CFLAGS", "")
        merged = _resolve_env_paths(" ".join(file_cflags))
        env["CFLAGS"] = (merged + " " + existing).strip() if existing else merged
    if file_ldflags:
        existing = env.get("LDFLAGS", "")
        merged = _resolve_env_paths(" ".join(file_ldflags))
        env["LDFLAGS"] = (merged + " " + existing).strip() if existing else merged
    if file_pkg_config:
        existing = env.get("PKG_CONFIG_PATH", "")
        merged = _resolve_env_paths(":".join(file_pkg_config))
        env["PKG_CONFIG_PATH"] = (merged + ":" + existing).rstrip(":") if existing else merged

    # Auto-detect Python site-packages from dep prefixes so build-time
    # Python modules (e.g. mako for mesa) are found without manual
    # PYTHONPATH wiring.  --path-prepend dirs are {prefix}/usr/bin;
    # derive {prefix}/usr/lib/python*/site-packages from them.
    _path_sources = list(args.hermetic_path) + list(all_path_prepend)
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

    cmd = ["meson", "setup"]
    cmd.extend([
        os.path.abspath(args.build_dir),
        source_abs,
        f"--prefix={args.prefix}",
    ])

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

    sanitize_filenames(os.path.abspath(args.build_dir))


if __name__ == "__main__":
    main()
