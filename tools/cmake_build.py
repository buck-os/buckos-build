#!/usr/bin/env python3
"""Unified CMake package builder: patch + cmake configure + ninja build + install.

Single-action builder that replaces the four-phase split (patch_helper,
cmake_helper, build_helper, install_helper).  All phases run in the
same scratch directory, eliminating inter-phase path rewriting that the
split model required.

Phases:
1. Copy source to scratch, apply patches, run pre-configure commands
2. Run cmake configure (out-of-tree build dir within scratch)
3. Run ninja build
4. Run cmake --install (or ninja install) to the declared output dir
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
    find_buckos_shell,
    find_dep_python3,
    portabilize_shebangs,
    preferred_linker_flag,
    register_cleanup,
    sanitize_filenames,
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

    parser = argparse.ArgumentParser(description="Unified CMake package builder")
    # Source and output
    parser.add_argument("--source-dir", required=True)
    parser.add_argument("--output-dir", required=True)

    # Patch phase
    parser.add_argument("--patch", action="append", dest="patches", default=[])

    # Configure phase
    parser.add_argument("--cc", default=None)
    parser.add_argument("--cxx", default=None)
    parser.add_argument("--cmake-arg", action="append", dest="cmake_args", default=[])
    parser.add_argument(
        "--cmake-define", action="append", dest="cmake_defines", default=[]
    )
    parser.add_argument(
        "--cmake-dep-define", action="append", dest="cmake_dep_defines", default=[]
    )
    parser.add_argument(
        "--configure-arg",
        action="append",
        dest="configure_args",
        default=[],
        help="Mapped to --cmake-arg for compatibility",
    )
    parser.add_argument("--cflags", action="append", dest="cflags", default=[])
    parser.add_argument("--cxxflags", action="append", dest="cxxflags", default=[])
    parser.add_argument("--ldflags", action="append", dest="ldflags", default=[])
    parser.add_argument(
        "--pkg-config-path", action="append", dest="pkg_config_paths", default=[]
    )
    parser.add_argument(
        "--prefix-path", action="append", dest="prefix_paths", default=[]
    )
    parser.add_argument("--install-prefix", default="/usr")
    parser.add_argument(
        "--source-subdir",
        default=None,
        help="Subdirectory within source containing CMakeLists.txt",
    )
    parser.add_argument(
        "--pre-configure-cmd", action="append", dest="pre_configure_cmds", default=[]
    )

    # Build phase
    parser.add_argument("--ninja-arg", action="append", dest="ninja_args", default=[])
    parser.add_argument(
        "--pre-build-cmd", action="append", dest="pre_build_cmds", default=[]
    )

    # Install phase
    parser.add_argument("--destdir-var", default="DESTDIR")
    parser.add_argument(
        "--install-target", action="append", dest="install_targets", default=None
    )
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
    parser.add_argument("--prefix-path-file", default=None)

    args = parser.parse_args()

    # Merge --configure-arg into --cmake-arg for compatibility
    args.cmake_args.extend(args.configure_args)

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
    file_prefix_paths = _read_flag_file(getattr(args, "prefix_path_file", None))

    source_dir = os.path.abspath(args.source_dir)
    declared_output = os.path.abspath(args.output_dir)

    # Work in scratch -- all phases operate on the same tree
    _scratch_base = os.path.abspath(
        os.environ.get("BUCK_SCRATCH_PATH", os.environ.get("TMPDIR", "/tmp"))
    )
    work_dir = os.path.join(_scratch_base, "build-work")
    register_cleanup(work_dir)

    # ── Phase 1: Copy source, apply patches, pre-configure cmds ──
    if os.path.exists(work_dir):
        shutil.rmtree(work_dir)
    shutil.copytree(source_dir, work_dir, symlinks=True)
    # Make the scratch copy writable (copytree preserves the source's
    # modes; the source is read-only under remote execution).
    from _env import make_tree_writable
    make_tree_writable(work_dir)

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

    # cmake uses CMAKE_COMPILER_LAUNCHER for ccache, not CC prefix.
    # Set this before apply_cache_config so ccache doesn't prepend to CC.
    env["_BUCKOS_CCACHE_NO_CC_PREFIX"] = "1"

    if args.cc:
        env["CC"] = _resolve_env_paths(args.cc)
    if args.cxx:
        env["CXX"] = _resolve_env_paths(args.cxx)

    # Merge --env entries first (toolchain flags like -march)
    _MERGE_FLAGS = {"CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS"}
    for entry in args.extra_env:
        key, _, value = entry.partition("=")
        if key:
            env[key] = _resolve_env_paths(value)

    apply_cache_config(env)
    env.pop("_BUCKOS_CCACHE_NO_CC_PREFIX", None)

    # ── PATH setup ───────────────────────────────────────────────
    if args.hermetic_path:
        env["PATH"] = ":".join(os.path.abspath(p) for p in args.hermetic_path)
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

    if file_path_append_dirs:
        append = ":".join(
            os.path.abspath(p) for p in file_path_append_dirs if os.path.isdir(p)
        )
        if append:
            env["PATH"] = env.get("PATH", "") + ":" + append

    # Add -rpath for dep lib dirs when using ld-linux wrappers.
    if args.ld_linux and file_lib_dirs:
        from _env import _is_sysroot_lib_dir as _is_sysroot

        _rpath_flags = []
        for d in file_lib_dirs:
            d = os.path.abspath(d)
            if os.path.isdir(d) and not _is_sysroot(d):
                _rpath_flags.append(f"-Wl,-rpath,{d}")
        if _rpath_flags:
            _rp = " ".join(_rpath_flags)
            for key in (
                "CMAKE_EXE_LINKER_FLAGS",
                "CMAKE_SHARED_LINKER_FLAGS",
                "CMAKE_MODULE_LINKER_FLAGS",
            ):
                existing = cmake_defines.get(key, "")
                cmake_defines[key] = (existing + " " + _rp).strip()

    # Dep lib dirs in LD_LIBRARY_PATH so build-time tools and test programs
    # can find dep shared libs at runtime.  Exclude dirs with libc.so.6.
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
    for _bp in list(args.hermetic_path) + list(all_path_prepend):
        _candidate = os.path.join(os.path.abspath(_bp), "python3")
        if os.path.isfile(_candidate):
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

    # Auto-detect Perl5 lib dirs from dep prefixes so build-time perl
    # modules are found by cmake's FindPerlModules.
    all_prefix_paths_raw = [os.path.abspath(p) for p in file_prefix_paths] + [
        os.path.abspath(p) for p in args.prefix_paths
    ]
    _perl5_paths = []
    for _pp in all_prefix_paths_raw:
        for _pattern in (
            "lib/perl5",
            "lib/perl5/vendor_perl",
            "lib/perl5/site_perl",
            "share/perl5",
            "share/perl5/vendor_perl",
            "lib/perl5/5.*",
            "lib64/perl5",
            "lib64/perl5/vendor_perl",
            "lib64/perl5/5.*",
        ):
            for _sp in _glob.glob(os.path.join(_pp, _pattern)):
                if os.path.isdir(_sp):
                    _perl5_paths.append(_sp)
    if _perl5_paths:
        _existing = env.get("PERL5LIB", "")
        env["PERL5LIB"] = ":".join(_perl5_paths) + (
            ":" + _existing if _existing else ""
        )

    # Merge pkg-config paths
    all_pkg_config = file_pkg_config + args.pkg_config_paths
    if all_pkg_config:
        env["PKG_CONFIG_PATH"] = _resolve_env_paths(":".join(all_pkg_config))

    # pkg-config wrapper
    wrapper_dir = write_pkg_config_wrapper(
        os.path.join(work_dir, ".pkgconf-wrapper"), python=find_dep_python3(env)
    )
    env["PATH"] = wrapper_dir + ":" + env.get("PATH", os.environ.get("PATH", ""))

    # Sysroot and linker setup
    if args.ld_linux:
        sysroot_lib_paths(args.ld_linux, env)
        _ld_flag = preferred_linker_flag(env)
        if _ld_flag:
            existing = env.get("LDFLAGS", "")
            env["LDFLAGS"] = (existing + " " + _ld_flag).strip()

    # Find buckos shell
    _config_shell = find_buckos_shell(env)
    if _config_shell:
        env["CONFIG_SHELL"] = _config_shell
        env["SHELL"] = _config_shell

    # ── Run pre-configure commands ───────────────────────────────
    for cmd_str in args.pre_configure_cmds:
        result = subprocess.run(
            cmd_str,
            shell=True,
            cwd=work_dir,
            env=env,
            executable=_config_shell,
        )
        if result.returncode != 0:
            print(f"error: pre-configure-cmd failed: {cmd_str}", file=sys.stderr)
            sys.exit(1)

    # ── Phase 2: CMake Configure ─────────────────────────────────
    # Out-of-tree build: cmake runs in a separate build dir within work_dir
    build_dir = os.path.join(work_dir, "_build")
    os.makedirs(build_dir, exist_ok=True)

    # Determine source path (may be a subdirectory)
    source_path = work_dir
    if args.source_subdir:
        source_path = os.path.join(work_dir, args.source_subdir)

    # Extract --sysroot= and -specs= from CC/CXX.  cmake splits multi-word
    # CC into CMAKE_C_COMPILER + COMPILER_ARG1, which breaks -specs= flags.
    # Pass them via CMAKE_SYSROOT and CMAKE_*_FLAGS instead.
    _cmake_sysroot = None
    _specs_flags = []
    for _cc_key in ("CC", "CXX"):
        _cc_val = env.get(_cc_key, "")
        if "--sysroot=" in _cc_val or "-specs=" in _cc_val:
            cc_parts = _cc_val.split()
            clean = []
            for p in cc_parts:
                if p.startswith("--sysroot="):
                    _cmake_sysroot = p[len("--sysroot=") :]
                elif p.startswith("-specs="):
                    if p not in _specs_flags:
                        _specs_flags.append(p)
                else:
                    clean.append(p)
            env[_cc_key] = " ".join(clean)

    # Force cmake to use our --define-prefix wrapper
    wrapper_pkg_config = os.path.join(wrapper_dir, "pkg-config")

    cmd = [
        "cmake",
        "-S",
        source_path,
        "-B",
        build_dir,
        f"-DCMAKE_INSTALL_PREFIX={args.install_prefix}",
        f"-DPKG_CONFIG_EXECUTABLE={wrapper_pkg_config}",
        "-G",
        "Ninja",
    ]
    if _cmake_sysroot:
        cmd.append(f"-DCMAKE_SYSROOT={_cmake_sysroot}")

    # ccache integration via cmake's native compiler launcher mechanism
    if env.get("BUCKOS_CCACHE") == "1":
        _ccache = shutil.which("ccache", path=env.get("PATH", ""))
        if _ccache:
            cmd.append(f"-DCMAKE_C_COMPILER_LAUNCHER={_ccache}")
            cmd.append(f"-DCMAKE_CXX_COMPILER_LAUNCHER={_ccache}")

    # Build CMAKE_PREFIX_PATH from dep prefixes so find_package() works
    all_prefix_paths = [os.path.abspath(p) for p in file_prefix_paths] + [
        os.path.abspath(p) for p in args.prefix_paths
    ]
    if all_prefix_paths:
        cmd.append("-DCMAKE_PREFIX_PATH=" + ";".join(all_prefix_paths))

    # Collect cmake defines in a dict so we can merge flag-file values
    cmake_defines = {}
    for define in args.cmake_defines:
        if "=" in define:
            key, _, value = define.partition("=")
            cmake_defines[key] = _resolve_env_paths(value)
        else:
            cmake_defines[define] = ""

    # Dep prefix paths as cmake defines (--cmake-dep-define KEY=path)
    for dep_define in args.cmake_dep_defines:
        if "=" in dep_define:
            key, _, path = dep_define.partition("=")
            cmake_defines[key] = os.path.abspath(path)

    # Merge tset cflags + per-package cflags into CMAKE_C_FLAGS / CMAKE_CXX_FLAGS
    all_cflags = file_cflags + args.cflags
    all_cxxflags = args.cxxflags
    all_ldflags = file_ldflags + args.ldflags

    # Scrub absolute build paths from debug info and __FILE__ expansions
    pfm = " ".join(file_prefix_map_flags())
    for key in ("CMAKE_C_FLAGS", "CMAKE_CXX_FLAGS"):
        existing = cmake_defines.get(key, "")
        cmake_defines[key] = (pfm + " " + existing).strip() if existing else pfm

    # Merge tset cflags into CMAKE_C_FLAGS and CMAKE_CXX_FLAGS
    if all_cflags:
        _cf = _resolve_env_paths(" ".join(all_cflags))
        for key in ("CMAKE_C_FLAGS", "CMAKE_CXX_FLAGS"):
            existing = cmake_defines.get(key, "")
            cmake_defines[key] = (_cf + " " + existing).strip() if existing else _cf

    # Merge per-package cxxflags into CMAKE_CXX_FLAGS only
    if all_cxxflags:
        _cxxf = _resolve_env_paths(" ".join(all_cxxflags))
        existing = cmake_defines.get("CMAKE_CXX_FLAGS", "")
        cmake_defines["CMAKE_CXX_FLAGS"] = (
            (existing + " " + _cxxf).strip() if existing else _cxxf
        )

    # Merge ldflags into CMAKE_*_LINKER_FLAGS
    if all_ldflags:
        _ld = _resolve_env_paths(" ".join(all_ldflags))
        for key in (
            "CMAKE_EXE_LINKER_FLAGS",
            "CMAKE_SHARED_LINKER_FLAGS",
            "CMAKE_MODULE_LINKER_FLAGS",
        ):
            existing = cmake_defines.get(key, "")
            cmake_defines[key] = (_ld + " " + existing).strip() if existing else _ld

    # Inject -specs= flags stripped from CC/CXX into all flag variables
    if _specs_flags:
        _sf = _resolve_env_paths(" ".join(_specs_flags))
        for key in (
            "CMAKE_C_FLAGS",
            "CMAKE_CXX_FLAGS",
            "CMAKE_EXE_LINKER_FLAGS",
            "CMAKE_SHARED_LINKER_FLAGS",
            "CMAKE_MODULE_LINKER_FLAGS",
        ):
            existing = cmake_defines.get(key, "")
            cmake_defines[key] = (_sf + " " + existing).strip() if existing else _sf

    # Write defines to an initial-cache file to avoid exceeding execve
    # argument limits with packages that have many transitive deps
    _cache_file = os.path.join(build_dir, "_buck_initial_cache.cmake")
    with open(_cache_file, "w") as _cf:
        for key, value in cmake_defines.items():
            escaped = value.replace("\\", "\\\\").replace('"', '\\"')
            _cf.write(f'set({key} "{escaped}" CACHE STRING "")\n')
    cmd.extend(["-C", _cache_file])

    cmd.extend(args.cmake_args)

    # Older CMakeLists.txt files declare cmake_minimum_required < 3.5,
    # which newer CMake rejects.  Set the policy floor globally.
    cmd.append("-DCMAKE_POLICY_VERSION_MINIMUM=3.5")

    result = subprocess.run(cmd, env=env)
    if result.returncode != 0:
        print(
            f"error: cmake configure failed with exit code {result.returncode}",
            file=sys.stderr,
        )
        sys.exit(1)

    # ── Phase 3: Build ───────────────────────────────────────────
    # Run pre-build commands
    for cmd_str in args.pre_build_cmds:
        result = subprocess.run(
            cmd_str, shell=True, cwd=build_dir, env=env, executable=_config_shell
        )
        if result.returncode != 0:
            print(f"error: pre-build-cmd failed: {cmd_str}", file=sys.stderr)
            sys.exit(1)

    jobs = multiprocessing.cpu_count()
    build_cmd = ["ninja", "-C", build_dir, f"-j{jobs}"]

    for arg in args.ninja_args:
        build_cmd.append(arg)

    # Network isolation
    if _NETWORK_ISOLATED:
        build_cmd = ["unshare", "--net"] + build_cmd

    result = subprocess.run(build_cmd, env=env)
    if result.returncode != 0:
        print(
            f"error: ninja build failed with exit code {result.returncode}",
            file=sys.stderr,
        )
        sys.exit(1)

    # ── Phase 4: Install ─────────────────────────────────────────
    prefix = declared_output
    os.makedirs(prefix, exist_ok=True)

    # Prefer cmake --install for CMake builds.  This runs the install
    # scripts directly, bypassing ninja's dependency graph which may
    # reference external libraries not available in the build environment.
    _cmake_bin = shutil.which("cmake", path=env.get("PATH", ""))
    if _cmake_bin:
        env[args.destdir_var] = prefix
        install_cmd = ["cmake", "--install", build_dir]
    else:
        # Fallback to ninja install
        targets = args.install_targets or ["install"]
        env[args.destdir_var] = prefix
        install_cmd = ["ninja", "-C", build_dir, f"-j{jobs}"] + targets

    result = subprocess.run(install_cmd, env=env)
    if result.returncode != 0:
        print(
            f"error: install failed with exit code {result.returncode}", file=sys.stderr
        )
        sys.exit(1)

    # ── Phase 5: Post-install ────────────────────────────────────
    # Remove libtool .la files
    for la in _glob.glob(os.path.join(prefix, "**", "*.la"), recursive=True):
        os.remove(la)

    # Run post-install commands
    env["DESTDIR"] = prefix
    env["OUT"] = prefix
    env["BUILD_DIR"] = build_dir
    for cmd_str in args.post_install_cmds:
        result = subprocess.run(
            cmd_str, shell=True, cwd=prefix, env=env, executable=_config_shell
        )
        if result.returncode != 0:
            print(f"error: post-install-cmd failed: {cmd_str}", file=sys.stderr)
            sys.exit(1)

    sanitize_filenames(prefix, work_dir)
    portabilize_shebangs(prefix)


if __name__ == "__main__":
    main()
