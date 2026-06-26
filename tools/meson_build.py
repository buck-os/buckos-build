#!/usr/bin/env python3
"""Unified meson package builder: patch + meson setup + ninja + meson install.

Single-action builder that replaces the three-phase split (meson_helper,
build_helper, install_helper) for meson packages.  All phases run in the
same scratch directory, eliminating inter-phase path rewriting and pickle
fixup that the split model required.

Phases:
1. Copy source to scratch, apply patches, run pre-configure commands
2. Run meson setup (out-of-tree build)
3. Run ninja build
4. Run meson install --no-rebuild DESTDIR=<output>
5. Post-install commands, .la removal, sanitization
"""

import argparse
import glob as _glob
import multiprocessing
import os
import re
import shutil
import subprocess
import sys

from _env import (
    apply_cache_config,
    clean_env,
    derive_lib_paths,
    file_prefix_map_flags,
    filter_path_flags,
    find_dep_python3,
    portabilize_shebangs,
    preferred_linker_flag,
    register_cleanup,
    sanitize_filenames,
    setup_ccache_symlinks,
    sysroot_lib_paths,
    write_pkg_config_wrapper,
)


def _can_unshare_net():
    """Check if unshare --net is available for network isolation."""
    try:
        result = subprocess.run(
            ["unshare", "--net", "true"],
            capture_output=True,
            timeout=5,
        )
        return result.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


_NETWORK_ISOLATED = _can_unshare_net()


def _resolve_env_paths(value):
    """Resolve relative Buck2 artifact paths in env values to absolute."""
    if ":" in value and not value.startswith("-"):
        resolved = []
        for p in value.split(":"):
            p = p.strip()
            if (
                p
                and not os.path.isabs(p)
                and (p.startswith("buck-out") or os.path.exists(p))
            ):
                resolved.append(os.path.abspath(p))
            else:
                resolved.append(p)
        return ":".join(resolved)

    _FLAG_PREFIXES = [
        "-I",
        "-L",
        "-Wl,-rpath-link,",
        "-Wl,-rpath,",
        "-specs=",
        "--sysroot=",
    ]

    parts = []
    for token in value.split():
        resolved = False
        for prefix in _FLAG_PREFIXES:
            if token.startswith(prefix) and len(token) > len(prefix):
                path = token[len(prefix) :]
                if not os.path.isabs(path) and (
                    path.startswith("buck-out") or os.path.exists(path)
                ):
                    parts.append(prefix + os.path.abspath(path))
                else:
                    parts.append(token)
                resolved = True
                break
        if resolved:
            continue
        if token.startswith("--") and "=" in token:
            idx = token.index("=")
            flag = token[: idx + 1]
            path = token[idx + 1 :]
            if (
                path
                and not os.path.isabs(path)
                and (path.startswith("buck-out") or os.path.exists(path))
            ):
                parts.append(flag + os.path.abspath(path))
            else:
                parts.append(token)
        elif not os.path.isabs(token) and os.path.exists(token):
            parts.append(os.path.abspath(token))
        else:
            parts.append(token)
    return " ".join(parts)


def _expand_env_refs(value, env):
    """Expand $VAR, ${VAR}, and ${VAR:-default} references."""
    if "$" not in value:
        return value

    def _repl(m):
        var = m.group(1) or m.group(3)
        default = m.group(2) or ""
        val = env.get(var, "")
        return val if val else default

    return re.sub(r"\$\{(\w+)(?::-([^}]*))?\}|\$(\w+)", _repl, value)


def _read_flag_file(path):
    if not path:
        return []
    with open(path) as f:
        return [line.rstrip("\n") for line in f if line.strip()]


def main():
    _host_path = os.environ.get("PATH", "")

    parser = argparse.ArgumentParser(description="Unified meson package builder")
    # Source and output
    parser.add_argument("--source-dir", required=True)
    parser.add_argument("--output-dir", required=True)

    # Patch phase
    parser.add_argument("--patch", action="append", dest="patches", default=[])

    # Configure phase (meson setup)
    parser.add_argument("--cc", default=None)
    parser.add_argument("--cxx", default=None)
    parser.add_argument(
        "--prefix", default="/usr", help="Install prefix (default: /usr)"
    )
    parser.add_argument("--meson-arg", action="append", dest="meson_args", default=[])
    parser.add_argument(
        "--meson-define", action="append", dest="meson_defines", default=[]
    )
    parser.add_argument(
        "--cross-triple",
        default=None,
        help="Target triple for cross-compilation (generates cross file)",
    )
    parser.add_argument(
        "--source-subdir", default=None, help="Subdirectory containing meson.build"
    )
    parser.add_argument("--cflags", action="append", dest="cflags", default=[])
    parser.add_argument("--cxxflags", action="append", dest="cxxflags", default=[])
    parser.add_argument("--ldflags", action="append", dest="ldflags", default=[])
    parser.add_argument(
        "--pkg-config-path", action="append", dest="pkg_config_paths", default=[]
    )
    parser.add_argument(
        "--pre-configure-cmd", action="append", dest="pre_configure_cmds", default=[]
    )

    # Build phase
    parser.add_argument("--make-arg", action="append", dest="make_args", default=[])

    # Install phase
    parser.add_argument(
        "--post-install-cmd", action="append", dest="post_install_cmds", default=[]
    )

    # Environment
    parser.add_argument("--env", action="append", dest="extra_env", default=[])
    parser.add_argument(
        "--path-prepend", action="append", dest="path_prepend", default=[]
    )
    parser.add_argument(
        "--hermetic-path", action="append", dest="hermetic_path", default=[]
    )
    parser.add_argument("--allow-host-path", action="store_true")
    parser.add_argument("--hermetic-empty", action="store_true")
    parser.add_argument("--ld-linux", default=None)

    # Tset flag files
    parser.add_argument("--cflags-file", default=None)
    parser.add_argument("--ldflags-file", default=None)
    parser.add_argument("--pkg-config-file", default=None)
    parser.add_argument("--path-file", default=None)
    parser.add_argument("--path-append-file", default=None)
    parser.add_argument("--lib-dirs-file", default=None)

    args = parser.parse_args()

    # ── Read flag files ──────────────────────────────────────────────
    file_cflags = filter_path_flags(_read_flag_file(args.cflags_file))
    file_ldflags = filter_path_flags(_read_flag_file(args.ldflags_file))
    file_pkg_config = [
        p
        for p in _read_flag_file(args.pkg_config_file)
        if os.path.isdir(os.path.abspath(p))
    ]
    file_path_dirs = _read_flag_file(args.path_file)
    file_path_append_dirs = _read_flag_file(args.path_append_file)
    file_lib_dirs = _read_flag_file(args.lib_dirs_file)

    source_dir = os.path.abspath(args.source_dir)
    declared_output = os.path.abspath(args.output_dir)

    # Work in scratch -- all phases operate on the same tree
    _scratch_base = os.path.abspath(
        os.environ.get("BUCK_SCRATCH_PATH", os.environ.get("TMPDIR", "/tmp"))
    )
    work_dir = os.path.join(_scratch_base, "meson-work")
    register_cleanup(work_dir)

    # ── Phase 1: Copy source, apply patches, pre-configure cmds ──
    if os.path.exists(work_dir):
        shutil.rmtree(work_dir)
    shutil.copytree(source_dir, work_dir, symlinks=True)

    # Reset timestamps to prevent build system regeneration
    epoch = os.environ.get("SOURCE_DATE_EPOCH", "315576000")
    subprocess.run(
        ["find", ".", "-exec", "touch", "-h", "-d", f"@{epoch}", "{}", "+"],
        cwd=work_dir,
        capture_output=True,
    )

    # Apply patches
    for patch_file in args.patches:
        if not os.path.isfile(patch_file):
            print(f"error: patch file not found: {patch_file}", file=sys.stderr)
            sys.exit(1)
        patch_abs = os.path.abspath(patch_file)
        result = subprocess.run(
            ["patch", "-p1", "-i", patch_abs],
            cwd=work_dir,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print(f"error: patch failed: {patch_file}", file=sys.stderr)
            if result.stdout:
                print(result.stdout, file=sys.stderr)
            if result.stderr:
                print(result.stderr, file=sys.stderr)
            sys.exit(1)
        print(f"applied: {os.path.basename(patch_file)}")

    # ── Environment setup (once for all phases) ──────────────────
    env = clean_env()
    env["PROJECT_ROOT"] = os.getcwd()

    if args.cc:
        env["CC"] = _resolve_env_paths(args.cc)
    if args.cxx:
        env["CXX"] = _resolve_env_paths(args.cxx)

    # Merge tset flags + per-package flags.  Meson reads CFLAGS/LDFLAGS
    # from the environment (not as configure arguments).
    all_cflags = file_prefix_map_flags() + file_cflags + args.cflags
    all_ldflags = file_ldflags + args.ldflags
    if file_lib_dirs:
        from _env import _is_sysroot_lib_dir as _is_sysroot

        for d in file_lib_dirs:
            d = os.path.abspath(d)
            if os.path.isdir(d) and not _is_sysroot(d):
                all_ldflags.append(f"-Wl,-rpath,{d}")
    all_pkg_config = file_pkg_config + args.pkg_config_paths

    if all_cflags:
        env["CFLAGS"] = _resolve_env_paths(" ".join(all_cflags))
    all_cxxflags = [f for f in file_cflags if f.startswith("-I")] + args.cxxflags
    if all_cxxflags:
        env["CXXFLAGS"] = _resolve_env_paths(" ".join(all_cxxflags))
    if all_ldflags:
        env["LDFLAGS"] = _resolve_env_paths(" ".join(all_ldflags))
    if all_pkg_config:
        env["PKG_CONFIG_PATH"] = _resolve_env_paths(":".join(all_pkg_config))

    # Merge --env entries (user flags prepend to tset-derived values)
    _MERGE_FLAGS = {"CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS"}
    for entry in args.extra_env:
        key, _, value = entry.partition("=")
        if key:
            resolved = _resolve_env_paths(value)
            if key in _MERGE_FLAGS and key in env:
                env[key] = resolved + " " + env[key]
            else:
                env[key] = resolved

    apply_cache_config(env)

    # ── PATH setup ───────────────────────────────────────────────
    if args.hermetic_path:
        # Portabilize the hermetic host tools (ld-linux wrappers + toolchain
        # relocation) so they run on remote-execution workers, where inputs
        # are materialized read-only and the host's ld-linux/glibc differ.
        # The configure/build/install helpers already do this; meson packages
        # built on RE need it too.
        _hp_dirs = [os.path.abspath(p) for p in args.hermetic_path]
        if args.ld_linux:
            from portabilize import portabilize_toolchain

            _hp_dirs = portabilize_toolchain(_hp_dirs, args.ld_linux)
        env["PATH"] = ":".join(_hp_dirs)
        _lib_dirs = []
        for _bp in args.hermetic_path:
            _parent = os.path.dirname(os.path.abspath(_bp))
            for _ld in ("lib", "lib64"):
                _d = os.path.join(_parent, _ld)
                if os.path.isdir(_d) and not os.path.exists(
                    os.path.join(_d, "libc.so.6")
                ):
                    _lib_dirs.append(_d)
                    _glibc_d = os.path.join(_d, "glibc")
                    if os.path.isdir(_glibc_d):
                        _lib_dirs.append(_glibc_d)
        if _lib_dirs:
            _existing = env.get("LD_LIBRARY_PATH", "")
            env["LD_LIBRARY_PATH"] = ":".join(_lib_dirs) + (
                ":" + _existing if _existing else ""
            )
        _py_paths = []
        for _bp in args.hermetic_path:
            _parent = os.path.dirname(os.path.abspath(_bp))
            for _pattern in (
                "lib/python*/site-packages",
                "lib/python*/dist-packages",
                "lib64/python*/site-packages",
                "lib64/python*/dist-packages",
            ):
                for _sp in _glob.glob(os.path.join(_parent, _pattern)):
                    if os.path.isdir(_sp):
                        _py_paths.append(_sp)
        if _py_paths:
            _existing = env.get("PYTHONPATH", "")
            env["PYTHONPATH"] = ":".join(_py_paths) + (
                ":" + _existing if _existing else ""
            )
    elif args.hermetic_empty:
        env["PATH"] = ""
    elif args.allow_host_path:
        env["PATH"] = _host_path
    else:
        print(
            "error: build requires --hermetic-path, --hermetic-empty, or --allow-host-path",
            file=sys.stderr,
        )
        sys.exit(1)

    all_path_prepend = file_path_dirs + args.path_prepend
    if all_path_prepend:
        _pp_dirs = [os.path.abspath(p) for p in all_path_prepend if os.path.isdir(p)]
        if args.ld_linux and _pp_dirs:
            from portabilize import portabilize_toolchain

            _pp_dirs = portabilize_toolchain(_pp_dirs, args.ld_linux)
        if _pp_dirs:
            env["PATH"] = ":".join(_pp_dirs) + ":" + env.get("PATH", "")

    # Create gcc/cc symlinks so meson's native compiler detection finds
    # a build-machine C compiler on PATH.
    _cc_val = env.get("CC", "")
    if _cc_val:
        _cc_parts = _cc_val.split()
        if _cc_parts and os.path.basename(_cc_parts[0]) == "ccache":
            _cc_parts = _cc_parts[1:]
        _cc_bin = os.path.abspath(_cc_parts[0]) if _cc_parts else ""
        if _cc_bin and os.path.isfile(_cc_bin):
            _symlink_dir = os.path.join(work_dir, ".cc-symlinks")
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

    setup_ccache_symlinks(env, work_dir)

    if file_path_append_dirs:
        append = ":".join(
            os.path.abspath(p) for p in file_path_append_dirs if os.path.isdir(p)
        )
        if append:
            env["PATH"] = env.get("PATH", "") + ":" + append

    # Dep lib dirs in LD_LIBRARY_PATH
    if file_lib_dirs:
        resolved = [
            os.path.abspath(d)
            for d in file_lib_dirs
            if os.path.isdir(d)
            and not os.path.exists(os.path.join(os.path.abspath(d), "libc.so.6"))
        ]
        if resolved:
            existing = env.get("LD_LIBRARY_PATH", "")
            merged = ":".join(resolved)
            env["LD_LIBRARY_PATH"] = (
                (merged + ":" + existing).rstrip(":") if existing else merged
            )

    if args.hermetic_path:
        derive_lib_paths(args.hermetic_path, env)
    derive_lib_paths(all_path_prepend, env)

    # Pin PYTHON/PYTHON3 to buckos python
    _dep_python3 = None
    for _bp in list(args.hermetic_path) + list(all_path_prepend):
        _candidate = os.path.join(os.path.abspath(_bp), "python3")
        if os.path.isfile(_candidate):
            _dep_python3 = _candidate
            env.setdefault("PYTHON", _candidate)
            env.setdefault("PYTHON3", _candidate)
            break

    # Auto-detect Python site-packages from dep prefixes
    _path_sources = (
        list(args.hermetic_path) + list(all_path_prepend) + list(file_path_append_dirs)
    )
    if _path_sources or file_lib_dirs:
        python_paths = []
        _seen_sp = set()
        for bin_dir in _path_sources:
            usr_dir = os.path.dirname(os.path.abspath(bin_dir))
            for pattern in (
                "lib/python*/site-packages",
                "lib/python*/dist-packages",
                "lib64/python*/site-packages",
                "lib64/python*/dist-packages",
            ):
                for sp in _glob.glob(os.path.join(usr_dir, pattern)):
                    if os.path.isdir(sp) and sp not in _seen_sp:
                        python_paths.append(sp)
                        _seen_sp.add(sp)
        for lib_dir in file_lib_dirs:
            abs_ld = os.path.abspath(lib_dir)
            for pattern in ("python*/site-packages", "python*/dist-packages"):
                for sp in _glob.glob(os.path.join(abs_ld, pattern)):
                    if os.path.isdir(sp) and sp not in _seen_sp:
                        python_paths.append(sp)
                        _seen_sp.add(sp)
        if python_paths:
            existing = env.get("PYTHONPATH", "")
            env["PYTHONPATH"] = ":".join(python_paths) + (
                ":" + existing if existing else ""
            )

    # pkg-config wrapper
    wrapper_dir = write_pkg_config_wrapper(
        os.path.join(work_dir, ".pkgconf-wrapper"), python=find_dep_python3(env)
    )
    env["PATH"] = wrapper_dir + ":" + env.get("PATH", "")

    # Sysroot and linker setup
    if args.ld_linux:
        sysroot_lib_paths(args.ld_linux, env)
        _ld_flag = preferred_linker_flag(env)
        if _ld_flag:
            existing = env.get("LDFLAGS", "")
            env["LDFLAGS"] = (existing + " " + _ld_flag).strip()

    # ── Run pre-configure commands ───────────────────────────────
    for cmd_str in args.pre_configure_cmds:
        result = subprocess.run(cmd_str, shell=True, cwd=work_dir, env=env)
        if result.returncode != 0:
            print(f"error: pre-configure-cmd failed: {cmd_str}", file=sys.stderr)
            sys.exit(1)

    # ── Phase 2: Meson Setup ─────────────────────────────────────
    # Meson does out-of-tree builds: source_dir and build_dir are separate.
    source_path = work_dir
    if args.source_subdir:
        source_path = os.path.join(work_dir, args.source_subdir)

    build_dir = os.path.join(work_dir, "_build")
    os.makedirs(build_dir, exist_ok=True)

    # Resolve meson from the build env PATH
    _meson_bin = shutil.which("meson", path=env.get("PATH", ""))
    if not _meson_bin:
        print(f"error: meson not found on PATH: {env.get('PATH', '')}", file=sys.stderr)
        sys.exit(1)

    # Generate native file pinning tool paths
    _native_lines = ["[binaries]"]
    _native_lines.append(f"pkg-config = '{os.path.join(wrapper_dir, 'pkg-config')}'")
    if _dep_python3:
        _native_lines.append(f"python3 = '{_dep_python3}'")
        _native_lines.append(f"python = '{_dep_python3}'")
    _native_cc = shutil.which("cc", path=env.get("PATH", "")) or shutil.which(
        "gcc", path=env.get("PATH", "")
    )
    if _native_cc:
        _native_lines.append(f"c = '{_native_cc}'")
    _native_file = os.path.join(build_dir, "buckos-native.ini")
    with open(_native_file, "w") as _nf:
        _nf.write("\n".join(_native_lines) + "\n")

    cmd = [_meson_bin, "setup"]
    cmd.extend(
        [
            build_dir,
            source_path,
            f"--prefix={args.prefix}",
            f"--native-file={_native_file}",
        ]
    )

    # Cross-compilation support
    if args.cross_triple:
        parts = args.cross_triple.split("-")
        cpu = parts[0]
        cpu_family = {
            "x86_64": "x86_64",
            "aarch64": "aarch64",
            "arm": "arm",
            "i686": "x86",
        }.get(cpu, cpu)
        _cross_pkgconfig = os.path.join(wrapper_dir, "pkg-config")
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
        _cross_file = os.path.join(build_dir, "buckos-cross.ini")
        with open(_cross_file, "w") as _cf:
            _cf.write("\n".join(cross_lines) + "\n")
        cmd.append(f"--cross-file={_cross_file}")

        # In cross mode, meson routes PKG_CONFIG_PATH to the host machine
        # (target).  Native (build-machine) deps need PKG_CONFIG_PATH_FOR_BUILD.
        _pkg_for_build = env.get("PKG_CONFIG_PATH", "")
        if _pkg_for_build:
            env["PKG_CONFIG_PATH_FOR_BUILD"] = _pkg_for_build

    # Meson defines: -DKEY=VALUE
    for define in args.meson_defines:
        key, _, value = define.partition("=")
        if value and ("buck-out" in value or value.startswith("-")):
            parts = []
            for token in value.split(","):
                token = token.strip()
                for prefix in ("-I", "-L"):
                    if token.startswith(prefix):
                        path = token[len(prefix) :]
                        if not os.path.isabs(path) and (
                            os.path.exists(path) or path.startswith("buck-out")
                        ):
                            token = prefix + os.path.abspath(path)
                        break
                parts.append(token)
            define = key + "=" + ",".join(parts)
        cmd.extend(["-D", define])

    cmd.extend(args.meson_args)

    print(f"configure: meson setup {source_path} -> {build_dir}")
    result = subprocess.run(cmd, env=env)
    if result.returncode != 0:
        print(
            f"error: meson setup failed with exit code {result.returncode}",
            file=sys.stderr,
        )
        sys.exit(1)

    # ── Phase 3: Build (ninja) ───────────────────────────────────
    jobs = multiprocessing.cpu_count()
    build_cmd = ["ninja", "-C", build_dir, f"-j{jobs}"]

    for arg in args.make_args:
        if "=" in arg:
            key, _, value = arg.partition("=")
            value = _expand_env_refs(value, env)
            build_cmd.append(f"{key}={_resolve_env_paths(value)}")
        else:
            build_cmd.append(arg)

    # Network isolation
    if _NETWORK_ISOLATED:
        build_cmd = ["unshare", "--net"] + build_cmd

    print(f"build: ninja -C {build_dir}")
    result = subprocess.run(build_cmd, env=env)
    if result.returncode != 0:
        print(
            f"error: ninja failed with exit code {result.returncode}", file=sys.stderr
        )
        sys.exit(1)

    # ── Phase 4: Install ─────────────────────────────────────────
    prefix = declared_output
    os.makedirs(prefix, exist_ok=True)

    # Meson install reads DESTDIR from the environment
    env["DESTDIR"] = prefix

    install_cmd = [_meson_bin, "install", "--no-rebuild", "-C", build_dir]

    print(f"install: meson install --no-rebuild -C {build_dir}")
    result = subprocess.run(install_cmd, env=env)
    if result.returncode != 0:
        print(
            f"error: meson install failed with exit code {result.returncode}",
            file=sys.stderr,
        )
        sys.exit(1)

    # ── Phase 5: Post-install ────────────────────────────────────
    # Remove libtool .la files
    for la in _glob.glob(os.path.join(prefix, "**", "*.la"), recursive=True):
        os.remove(la)

    # Run post-install commands
    env["OUT"] = prefix
    env["BUILD_DIR"] = build_dir
    for cmd_str in args.post_install_cmds:
        result = subprocess.run(cmd_str, shell=True, cwd=prefix, env=env)
        if result.returncode != 0:
            print(f"error: post-install-cmd failed: {cmd_str}", file=sys.stderr)
            sys.exit(1)

    sanitize_filenames(prefix, work_dir)
    portabilize_shebangs(prefix)


if __name__ == "__main__":
    main()
