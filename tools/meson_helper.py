#!/usr/bin/env python3
"""Meson setup wrapper.

Runs meson setup with specified source dir, build dir, and arguments.
"""

import argparse
import glob as _glob
import os
import shutil as _shutil
import subprocess
import sys

from _env import apply_cache_config, clean_env, derive_lib_paths, file_prefix_map_flags, filter_path_flags, find_dep_python3, preferred_linker_flag, register_cleanup, sanitize_filenames, setup_ccache_symlinks, sysroot_lib_paths, write_pkg_config_wrapper


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

    _FLAG_PREFIXES = ["-I", "-L", "-Wl,-rpath-link,", "-Wl,-rpath,", "-specs=", "--sysroot="]

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
    parser.add_argument("--ld-linux", default=None,
                        help="Buckos ld-linux path (disables posix_spawn)")
    parser.add_argument("--cross-triple", default=None,
                        help="Target triple for cross-compilation (generates cross file)")
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
    parser.add_argument("--path-append-file", default=None,
                        help="File with PATH dirs to append (one per line, from tset projection)")
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
    file_path_append_dirs = _read_flag_file(args.path_append_file)
    file_lib_dirs = _read_flag_file(args.lib_dirs_file)

    if not os.path.isdir(args.source_dir):
        print(f"error: source directory not found: {args.source_dir}", file=sys.stderr)
        sys.exit(1)

    _build_dir_abs = os.path.abspath(args.build_dir)
    os.makedirs(_build_dir_abs, exist_ok=True)
    register_cleanup(_build_dir_abs)

    env = clean_env()

    if args.hermetic_path:
        env["PATH"] = ":".join(os.path.abspath(p) for p in args.hermetic_path)
        # Derive LD_LIBRARY_PATH from hermetic bin dirs so dynamically
        # linked tools (e.g. cross-ar needing libzstd) find their libs.
        # With sysroot ld-linux and per-package RPATH, buckos binaries
        # find deps via RPATH.  Skip LD_LIBRARY_PATH to avoid
        # contaminating host tools.
        if not args.ld_linux:
            _lib_dirs = []
            for _bp in args.hermetic_path:
                _parent = os.path.dirname(os.path.abspath(_bp))
                for _ld in ("lib", "lib64"):
                    _d = os.path.join(_parent, _ld)
                    if os.path.isdir(_d) and not os.path.exists(os.path.join(_d, "libc.so.6")):
                        _lib_dirs.append(_d)
                        _glibc_d = os.path.join(_d, "glibc")
                        if os.path.isdir(_glibc_d):
                            _lib_dirs.append(_glibc_d)
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

    # Append dep bin dirs for *-config discovery scripts
    if file_path_append_dirs:
        append = ":".join(os.path.abspath(p) for p in file_path_append_dirs if os.path.isdir(p))
        if append:
            env["PATH"] = env.get("PATH", "") + ":" + append

    # Dep lib dirs in LD_LIBRARY_PATH so dep tools (e.g. buckos python
    # needing libpython3.12.so) can execute during meson setup.  Exclude
    # dirs with libc.so.6 to avoid poisoning host tools.
    if file_lib_dirs:
        resolved = [
            os.path.abspath(d) for d in file_lib_dirs
            if os.path.isdir(d) and not os.path.exists(os.path.join(os.path.abspath(d), "libc.so.6"))
        ]
        if resolved:
            existing = env.get("LD_LIBRARY_PATH", "")
            merged = ":".join(resolved)
            env["LD_LIBRARY_PATH"] = (merged + ":" + existing).rstrip(":") if existing else merged

    derive_lib_paths(all_path_prepend, env)

    # Apply extra environment variables first (toolchain flags like -march).
    for entry in args.extra_env:
        key, _, value = entry.partition("=")
        if key:
            env[key] = _resolve_env_paths(value)

    apply_cache_config(env)

    # Scrub absolute build paths from debug info and __FILE__ expansions.
    pfm = " ".join(file_prefix_map_flags())
    for var in ("CFLAGS", "CXXFLAGS"):
        existing = env.get(var, "")
        env[var] = (pfm + " " + existing).strip() if existing else pfm

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
    # Also scan tset lib dirs — deps without bin dirs (e.g. python
    # packaging) only expose lib dirs via the tset.
    _path_sources = list(args.hermetic_path) + list(all_path_prepend)
    if _path_sources or file_lib_dirs:
        python_paths = []
        _seen_sp = set()
        for bin_dir in _path_sources:
            usr_dir = os.path.dirname(os.path.abspath(bin_dir))
            for pattern in ("lib/python*/site-packages", "lib/python*/dist-packages",
                            "lib64/python*/site-packages", "lib64/python*/dist-packages"):
                for sp in _glob.glob(os.path.join(usr_dir, pattern)):
                    if os.path.isdir(sp) and sp not in _seen_sp:
                        python_paths.append(sp)
                        _seen_sp.add(sp)
        for _ld in file_lib_dirs:
            _abs_ld = os.path.abspath(_ld)
            for pattern in ("python*/site-packages", "python*/dist-packages"):
                for sp in _glob.glob(os.path.join(_abs_ld, pattern)):
                    if os.path.isdir(sp) and sp not in _seen_sp:
                        python_paths.append(sp)
                        _seen_sp.add(sp)
        if python_paths:
            existing = env.get("PYTHONPATH", "")
            env["PYTHONPATH"] = ":".join(python_paths) + (":" + existing if existing else "")

    # Create a pkg-config wrapper that always passes --define-prefix so
    # .pc files in Buck2 dep directories resolve paths correctly.
    # Write into build_dir so the path is stable across meson reconfigures.
    # Use absolute path so meson native file embeds an executable path, not a name.
    wrapper_dir = write_pkg_config_wrapper(os.path.join(_build_dir_abs, ".pkgconf-wrapper"), python=find_dep_python3(env))

    # Prepend pkg-config wrapper to PATH (after hermetic/prepend logic
    # so the wrapper is always available regardless of PATH mode)
    env["PATH"] = wrapper_dir + ":" + env.get("PATH", "")
    if args.cc:
        env["CC"] = _resolve_env_paths(args.cc)
    if args.cxx:
        env["CXX"] = _resolve_env_paths(args.cxx)

    if args.ld_linux:
        sysroot_lib_paths(args.ld_linux, env)
        _ld_flag = preferred_linker_flag(env)
        if _ld_flag:
            existing = env.get("LDFLAGS", "")
            env["LDFLAGS"] = (existing + " " + _ld_flag).strip()

    # Find buckos python3 from dep dirs — prefer it over host python.
    # Buckos python is ABI-matched to buckos libs in LD_LIBRARY_PATH.
    _dep_python3 = None
    for _bp in list(args.hermetic_path) + list(all_path_prepend):
        _candidate = os.path.join(os.path.abspath(_bp), "python3")
        if os.path.isfile(_candidate):
            _dep_python3 = _candidate
            break

    if _dep_python3:
        env["PYTHON"] = _dep_python3
        env["PYTHON3"] = _dep_python3

    # Create gcc/cc symlinks so meson's native compiler detection (and
    # cross-build code generators like fribidi gen.tab) find a build-
    # machine C compiler on PATH.  The hermetic PATH only has the
    # cross-compiler (x86_64-buckos-linux-gnu-gcc), not bare cc/gcc.
    _cc_val = env.get("CC", "")
    if _cc_val:
        _cc_parts = _cc_val.split()
        # Skip ccache prefix to find real compiler binary
        if _cc_parts and os.path.basename(_cc_parts[0]) == "ccache":
            _cc_parts = _cc_parts[1:]
        _cc_bin = os.path.abspath(_cc_parts[0]) if _cc_parts else ""
        if _cc_bin and os.path.isfile(_cc_bin):
            _symlink_dir = os.path.join(_build_dir_abs, ".cc-symlinks")
            os.makedirs(_symlink_dir, exist_ok=True)
            for _name in ("gcc", "cc", "clang"):
                _link = os.path.join(_symlink_dir, _name)
                if not os.path.exists(_link):
                    os.symlink(_cc_bin, _link)
            _cxx_val = env.get("CXX", "")
            if _cxx_val:
                _cxx_parts = _cxx_val.split()
                if _cxx_parts and os.path.basename(_cxx_parts[0]) == "ccache":
                    _cxx_parts = _cxx_parts[1:]
                _cxx_bin = os.path.abspath(_cxx_parts[0]) if _cxx_parts else ""
                if _cxx_bin and os.path.isfile(_cxx_bin):
                    for _name in ("g++", "c++", "clang++"):
                        _link = os.path.join(_symlink_dir, _name)
                        if not os.path.exists(_link):
                            os.symlink(_cxx_bin, _link)
            env["PATH"] = _symlink_dir + ":" + env.get("PATH", "")

    # ccache masquerade symlinks — prepended before gcc symlinks.
    setup_ccache_symlinks(env, _build_dir_abs)

    # Generate a meson native file pinning tool paths so meson embeds
    # the correct absolute paths in build.ninja from the start, rather
    # than relying on PATH lookup or post-hoc build.ninja patching.
    # [binaries] pins apply to the native (build-host) machine tools.
    _native_lines = ["[binaries]"]
    _native_lines.append(f"pkg-config = '{os.path.join(wrapper_dir, 'pkg-config')}'")
    if _dep_python3:
        _native_lines.append(f"python3 = '{_dep_python3}'")
        _native_lines.append(f"python = '{_dep_python3}'")
    # Pin a build-machine C compiler so cross builds can compile native
    # code generators (e.g. fribidi gen.tab).  Look for cc/gcc on PATH.
    _native_cc = _shutil.which("cc", path=env.get("PATH", "")) or _shutil.which("gcc", path=env.get("PATH", ""))
    if _native_cc:
        _native_lines.append(f"c = '{_native_cc}'")
    _native_file = os.path.join(_build_dir_abs, "buckos-native.ini")
    with open(_native_file, "w") as _nf:
        _nf.write("\n".join(_native_lines) + "\n")

    # Run pre-configure commands in the source directory
    source_abs = os.path.abspath(args.source_dir)
    for cmd_str in args.pre_cmds:
        result = subprocess.run(cmd_str, shell=True, cwd=source_abs, env=env)
        if result.returncode != 0:
            print(f"error: pre-cmd failed with exit code {result.returncode}: {cmd_str}",
                  file=sys.stderr)
            sys.exit(1)

    # Resolve meson from the build env PATH.  The buckos-built meson
    # package is a host_dep of all meson-rule packages, so its bin dir
    # is on PATH via --path-prepend.
    _meson_bin = _shutil.which("meson", path=env.get("PATH", ""))
    if not _meson_bin:
        print(f"error: meson not found on PATH: {env.get('PATH', '')}", file=sys.stderr)
        sys.exit(1)
    cmd = [_meson_bin, "setup"]
    cmd.extend([
        _build_dir_abs,
        source_abs,
        f"--prefix={args.prefix}",
        f"--native-file={_native_file}",
    ])

    # Generate and inject cross file for cross-compilation.
    # This tells meson the target system differs from the build host,
    # preventing it from trying to execute compiled test programs
    # (which crash when the padded interpreter is ABI-incompatible
    # with the host ld-linux).
    if args.cross_triple:
        parts = args.cross_triple.split("-")
        cpu = parts[0]
        cpu_family = {"x86_64": "x86_64", "aarch64": "aarch64",
                      "arm": "arm", "i686": "x86"}.get(cpu, cpu)
        # Pin pkg-config in cross file [binaries] so meson finds it for
        # host-machine dependency lookups (e.g. systemd → libcap).
        _cross_pkgconfig = os.path.join(wrapper_dir, "pkg-config")
        # lib_suffix: 64-bit arches use lib64, 32-bit use lib
        _lib_suffix = "lib64" if cpu_family in ("x86_64", "aarch64") else "lib"
        cross_lines = [
            "[binaries]",
            f"pkg-config = '{_cross_pkgconfig}'",
            "",
            "[host_machine]",
            "system = 'linux'",
            f"cpu_family = '{cpu_family}'",
            f"cpu = '{cpu}'",
            "endian = 'little'",
            "",
            "[built-in options]",
            f"libdir = '{_lib_suffix}'",
        ]
        _cross_file = os.path.join(_build_dir_abs, "buckos-cross.ini")
        with open(_cross_file, "w") as _cf:
            _cf.write("\n".join(cross_lines) + "\n")
        cmd.append(f"--cross-file={_cross_file}")

        # In cross mode, meson routes PKG_CONFIG_PATH to the host
        # machine (target).  Native (build-machine) deps like
        # wayland-scanner need PKG_CONFIG_PATH_FOR_BUILD instead.
        _pkg_for_build = env.get("PKG_CONFIG_PATH", "")
        if _pkg_for_build:
            env["PKG_CONFIG_PATH_FOR_BUILD"] = _pkg_for_build

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
