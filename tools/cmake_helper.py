#!/usr/bin/env python3
"""CMake configure wrapper.

Runs cmake with specified source dir, build dir, and arguments.
"""

import argparse
import glob as _glob
import os
import subprocess
import sys

from _env import clean_env, derive_lib_paths, filter_path_flags, register_cleanup, sanitize_filenames, write_pkg_config_wrapper


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

    _FLAG_PREFIXES = ["-I", "-L", "-Wl,-rpath-link,", "-Wl,-rpath,", "-specs="]

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
    parser.add_argument("--hermetic-path", action="append", dest="hermetic_path", default=[],
                        help="Set PATH to only these dirs (replaces host PATH, repeatable)")
    parser.add_argument("--allow-host-path", action="store_true",
                        help="Allow host PATH (bootstrap escape hatch)")
    parser.add_argument("--hermetic-empty", action="store_true",
                        help="Start with empty PATH (populated by --path-prepend)")
    parser.add_argument("--cflags-file", default=None,
                        help="File with CFLAGS (one per line, from tset projection)")
    parser.add_argument("--ldflags-file", default=None,
                        help="File with LDFLAGS (one per line, from tset projection)")
    parser.add_argument("--pkg-config-file", default=None,
                        help="File with PKG_CONFIG_PATH entries (one per line, from tset projection)")
    parser.add_argument("--path-file", default=None,
                        help="File with PATH dirs to prepend (one per line, from tset projection)")
    parser.add_argument("--prefix-path-file", default=None,
                        help="File with CMAKE_PREFIX_PATH entries (one per line, from tset projection)")
    parser.add_argument("--lib-dirs-file", default=None,
                        help="File with lib dirs for LD_LIBRARY_PATH (one per line, from tset projection)")
    args = parser.parse_args()

    # Read flag files early — tset-propagated values are base defaults.
    def _read_flag_file(path):
        if not path:
            return []
        with open(path) as f:
            return [line.rstrip("\n") for line in f if line.strip()]

    file_cflags = filter_path_flags(_read_flag_file(args.cflags_file))
    file_ldflags = filter_path_flags(_read_flag_file(args.ldflags_file))
    file_pkg_config = [p for p in _read_flag_file(args.pkg_config_file) if os.path.isdir(os.path.abspath(p))]
    file_path_dirs = _read_flag_file(args.path_file)
    file_prefix_paths = _read_flag_file(args.prefix_path_file)
    file_lib_dirs = _read_flag_file(args.lib_dirs_file)

    if not os.path.isdir(args.source_dir):
        print(f"error: source directory not found: {args.source_dir}", file=sys.stderr)
        sys.exit(1)

    os.makedirs(args.build_dir, exist_ok=True)
    register_cleanup(os.path.abspath(args.build_dir))

    # Create a pkg-config wrapper that always passes --define-prefix so
    # .pc files in Buck2 dep directories resolve paths correctly.
    import tempfile
    wrapper_dir = write_pkg_config_wrapper(tempfile.mkdtemp(prefix="pkgconf-wrapper-"))

    env = clean_env()

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
                if os.path.isdir(_d) and not os.path.exists(os.path.join(_d, "libc.so.6")):
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

    # Merge flag file pkg-config paths into env
    if file_pkg_config:
        existing = env.get("PKG_CONFIG_PATH", "")
        merged = _resolve_env_paths(":".join(file_pkg_config))
        env["PKG_CONFIG_PATH"] = (merged + ":" + existing).rstrip(":") if existing else merged

    # Prepend pkg-config wrapper to PATH (after hermetic/prepend logic
    # so the wrapper is always available regardless of PATH mode)
    env["PATH"] = wrapper_dir + ":" + env.get("PATH", "")

    # Extract --sysroot= from CC/CXX and pass as CMAKE_SYSROOT instead.
    # CMake's automoc mishandles sysroot embedded in the compiler command,
    # generating broken ninja rules with escaped-space before --sysroot.
    _cmake_sysroot = None
    for _cc_key in ("CC", "CXX"):
        _cc_val = env.get(_cc_key, "")
        if "--sysroot=" in _cc_val:
            parts = _cc_val.split()
            clean = []
            for p in parts:
                if p.startswith("--sysroot="):
                    _cmake_sysroot = p[len("--sysroot="):]
                else:
                    clean.append(p)
            env[_cc_key] = " ".join(clean)
    if args.cc:
        env["CC"] = _resolve_env_paths(args.cc)
    if args.cxx:
        env["CXX"] = _resolve_env_paths(args.cxx)

    source_path = os.path.abspath(args.source_dir)
    if args.source_subdir:
        source_path = os.path.join(source_path, args.source_subdir)

    # Force cmake to use our --define-prefix wrapper instead of the real
    # pkg-config binary.  cmake's find_program() searches CMAKE_PREFIX_PATH
    # before PATH, so it finds the buckos-built pkg-config binary (which
    # doesn't rewrite prefixes) before our wrapper on PATH.
    wrapper_pkg_config = os.path.join(wrapper_dir, "pkg-config")

    cmd = [
        "cmake",
        "-S", source_path,
        "-B", os.path.abspath(args.build_dir),
        f"-DCMAKE_INSTALL_PREFIX={args.install_prefix}",
        f"-DPKG_CONFIG_EXECUTABLE={wrapper_pkg_config}",
        "-G", "Ninja",
    ]
    if _cmake_sysroot:
        cmd.append(f"-DCMAKE_SYSROOT={_cmake_sysroot}")

    # Build CMAKE_PREFIX_PATH from dep prefixes so find_package() works.
    # Merge flag-file prefix paths with CLI --prefix-path args.
    all_prefix_paths = [os.path.abspath(p) for p in file_prefix_paths] + \
                       [os.path.abspath(p) for p in args.prefix_paths]
    if all_prefix_paths:
        cmd.append("-DCMAKE_PREFIX_PATH=" + ";".join(all_prefix_paths))

    # Merge flag-file lib dirs into LD_LIBRARY_PATH for dep tools
    if file_lib_dirs:
        resolved_lib_dirs = [os.path.abspath(d) for d in file_lib_dirs if os.path.isdir(d)]
        if resolved_lib_dirs:
            existing = env.get("LD_LIBRARY_PATH", "")
            merged = ":".join(resolved_lib_dirs)
            env["LD_LIBRARY_PATH"] = (merged + ":" + existing).rstrip(":") if existing else merged

    # Derive LD_LIBRARY_PATH from path-prepend dirs so host tools with
    # shared libraries (e.g. python → libpython3.so) can execute.
    derive_lib_paths(all_path_prepend, env)

    # Auto-detect Perl5 lib dirs from dep prefixes so build-time perl
    # modules (e.g. URI::Escape for kdoctools) are found by cmake's
    # FindPerlModules.  all_prefix_paths are {dep}/usr directories.
    _perl5_paths = []
    for _pp in all_prefix_paths:
        for _pattern in ("lib/perl5", "lib/perl5/vendor_perl",
                         "lib/perl5/site_perl", "share/perl5",
                         "share/perl5/vendor_perl",
                         "lib/perl5/5.*", "lib64/perl5",
                         "lib64/perl5/vendor_perl",
                         "lib64/perl5/5.*"):
            for _sp in _glob.glob(os.path.join(_pp, _pattern)):
                if os.path.isdir(_sp):
                    _perl5_paths.append(_sp)
    if _perl5_paths:
        _existing = env.get("PERL5LIB", "")
        env["PERL5LIB"] = ":".join(_perl5_paths) + (":" + _existing if _existing else "")

    # Collect cmake defines in a dict so we can merge flag-file values
    # with toolchain/per-package values for CMAKE_*_FLAGS.
    # Last --cmake-define for a given key wins; flag-file values are
    # prepended (dep flags first, per-package flags override).
    cmake_defines = {}
    for define in args.cmake_defines:
        if "=" in define:
            key, _, value = define.partition("=")
            cmake_defines[key] = _resolve_env_paths(value)
        else:
            cmake_defines[define] = ""

    # Merge flag-file cflags into CMAKE_C_FLAGS and CMAKE_CXX_FLAGS.
    # File flags (dep tset) come first; --cmake-define flags (toolchain/
    # per-package) are appended so they can override.
    if file_cflags:
        _cf = _resolve_env_paths(" ".join(file_cflags))
        for key in ("CMAKE_C_FLAGS", "CMAKE_CXX_FLAGS"):
            existing = cmake_defines.get(key, "")
            cmake_defines[key] = (_cf + " " + existing).strip() if existing else _cf

    # Merge flag-file ldflags into CMAKE_*_LINKER_FLAGS.
    if file_ldflags:
        _ld = _resolve_env_paths(" ".join(file_ldflags))
        for key in ("CMAKE_EXE_LINKER_FLAGS", "CMAKE_SHARED_LINKER_FLAGS",
                     "CMAKE_MODULE_LINKER_FLAGS"):
            existing = cmake_defines.get(key, "")
            cmake_defines[key] = (_ld + " " + existing).strip() if existing else _ld

    # Write long defines (CMAKE_*_FLAGS with hundreds of dep flags) to an
    # initial-cache file instead of the command line.  Packages with 100+
    # transitive deps can exceed the execve argument limit otherwise.
    _cache_file = os.path.join(os.path.abspath(args.build_dir), "_buck_initial_cache.cmake")
    with open(_cache_file, "w") as _cf:
        for key, value in cmake_defines.items():
            escaped = value.replace("\\", "\\\\").replace('"', '\\"')
            _cf.write(f'set({key} "{escaped}" CACHE STRING "")\n')
    cmd.extend(["-C", _cache_file])

    cmd.extend(args.cmake_args)

    # Older CMakeLists.txt files declare cmake_minimum_required < 3.5,
    # which newer CMake rejects.  Set the policy floor globally so every
    # package configures without per-package workarounds.
    cmd.append("-DCMAKE_POLICY_VERSION_MINIMUM=3.5")

    result = subprocess.run(cmd, env=env)
    if result.returncode != 0:
        print(f"error: cmake configure failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(1)

    sanitize_filenames(os.path.abspath(args.build_dir))


if __name__ == "__main__":
    main()
