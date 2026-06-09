#!/usr/bin/env python3
"""Unified autotools package builder: patch + configure + make + make install.

Single-action builder that replaces the four-phase split (patch_helper,
configure_helper, build_helper, install_helper).  All phases run in the
same scratch directory, eliminating inter-phase path rewriting that the
split model required.

Phases:
1. Copy source to scratch, apply patches, run pre-configure commands
2. Run ./configure (or skip for Kconfig packages)
3. Run make
4. Run make install DESTDIR=<output>
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
    rewrite_shebangs,
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


def _patch_runshared(build_dir):
    """Patch RUNSHARED assignments to preserve LD_LIBRARY_PATH."""
    _runshared_re = re.compile(
        r"^(RUNSHARED\s*=\s*LD_LIBRARY_PATH=\S+)$",
        re.MULTILINE,
    )

    def _append_env(m):
        val = m.group(1)
        if "$$LD_LIBRARY_PATH" in val:
            return val
        return val + ":$$LD_LIBRARY_PATH"

    for dirpath, _dirnames, filenames in os.walk(build_dir):
        for fname in filenames:
            fpath = os.path.join(dirpath, fname)
            try:
                with open(fpath, "r") as f:
                    content = f.read()
            except (UnicodeDecodeError, PermissionError, OSError):
                continue
            if "RUNSHARED" not in content:
                continue
            new_content = _runshared_re.sub(_append_env, content)
            if new_content != content:
                try:
                    st = os.stat(fpath)
                    with open(fpath, "w") as f:
                        f.write(new_content)
                    os.utime(fpath, (st.st_atime, st.st_mtime))
                except (PermissionError, OSError):
                    pass


def main():
    _host_path = os.environ.get("PATH", "")

    parser = argparse.ArgumentParser(description="Unified autotools package builder")
    # Source and output
    parser.add_argument("--source-dir", required=True)
    parser.add_argument("--output-dir", required=True)

    # Patch phase
    parser.add_argument("--patch", action="append", dest="patches", default=[])

    # Configure phase
    parser.add_argument("--cc", default=None)
    parser.add_argument("--cxx", default=None)
    parser.add_argument(
        "--configure-arg", action="append", dest="configure_args", default=[]
    )
    parser.add_argument("--cflags", action="append", dest="cflags", default=[])
    parser.add_argument("--cxxflags", action="append", dest="cxxflags", default=[])
    parser.add_argument("--cppflags", action="append", dest="cppflags", default=[])
    parser.add_argument("--ldflags", action="append", dest="ldflags", default=[])
    parser.add_argument(
        "--pkg-config-path", action="append", dest="pkg_config_paths", default=[]
    )
    parser.add_argument("--skip-configure", action="store_true")
    parser.add_argument("--skip-cc-arg", action="store_true")
    parser.add_argument("--configure-script", default="configure")
    parser.add_argument(
        "--pre-configure-cmd", action="append", dest="pre_configure_cmds", default=[]
    )

    # Build phase
    parser.add_argument("--make-arg", action="append", dest="make_args", default=[])
    parser.add_argument(
        "--pre-build-cmd", action="append", dest="pre_build_cmds", default=[]
    )
    parser.add_argument("--build-subdir", default=None)

    # Install phase
    parser.add_argument("--destdir-var", default="DESTDIR")
    parser.add_argument(
        "--install-target", action="append", dest="install_targets", default=None
    )
    parser.add_argument(
        "--install-arg", action="append", dest="install_args", default=[]
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

    # Work in scratch — all phases operate on the same tree
    _scratch_base = os.path.abspath(
        os.environ.get("BUCK_SCRATCH_PATH", os.environ.get("TMPDIR", "/tmp"))
    )
    work_dir = os.path.join(_scratch_base, "build-work")
    register_cleanup(work_dir)

    # ── Phase 1: Copy source, apply patches, pre-configure cmds ──
    if os.path.exists(work_dir):
        shutil.rmtree(work_dir)
    shutil.copytree(source_dir, work_dir, symlinks=True)

    # Reset timestamps to prevent autotools regeneration
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
        env["CC"] = args.cc
    if args.cxx:
        env["CXX"] = args.cxx

    # Merge tset flags + per-package flags
    all_cflags = file_prefix_map_flags() + file_cflags + args.cflags
    all_ldflags = file_ldflags + args.ldflags
    if file_lib_dirs:
        for d in file_lib_dirs:
            d = os.path.abspath(d)
            if os.path.isdir(d) and not os.path.exists(os.path.join(d, "libc.so.6")):
                all_ldflags.append(f"-Wl,-rpath,{d}")
    all_pkg_config = file_pkg_config + args.pkg_config_paths
    file_include_flags = [f for f in file_cflags if f.startswith("-I")]

    if all_cflags:
        env["CFLAGS"] = _resolve_env_paths(" ".join(all_cflags))
    all_cxxflags = file_include_flags + args.cxxflags
    if all_cxxflags:
        env["CXXFLAGS"] = _resolve_env_paths(" ".join(all_cxxflags))
    all_cppflags = file_include_flags + args.cppflags
    if all_cppflags:
        env["CPPFLAGS"] = _resolve_env_paths(" ".join(all_cppflags))
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

    # Derive CPP from CC
    if "CC" in env and "CPP" not in env:
        env["CPP"] = env["CC"] + " -E"

    apply_cache_config(env)

    # ── PATH setup ───────────────────────────────────────────────
    _cc_has_spaces = False
    _symlink_dir = os.path.join(work_dir, ".cc-symlinks")
    _need_symlink_path = False
    for _var, _names in [("CC", ("cc", "gcc")), ("CXX", ("c++", "g++"))]:
        _val = env.get(_var, "")
        if " " in _val:
            _cc_has_spaces = True
            _cc_parts = _val.split()
            if _cc_parts and os.path.basename(_cc_parts[0]) == "ccache":
                _cc_parts = _cc_parts[1:]
            _cc_bin = os.path.abspath(_cc_parts[0]) if _cc_parts else ""
            if _cc_bin and os.path.isfile(_cc_bin):
                os.makedirs(_symlink_dir, exist_ok=True)
                for _name in _names:
                    _link = os.path.join(_symlink_dir, _name)
                    if not os.path.exists(_link):
                        os.symlink(_cc_bin, _link)
                if _var == "CC":
                    _cpp_link = os.path.join(_symlink_dir, "cpp")
                    if not os.path.exists(_cpp_link):
                        _wrapper_shell = None
                        for _hp in args.hermetic_path or []:
                            _c = os.path.join(os.path.abspath(_hp), "bash")
                            if os.path.isfile(_c):
                                _wrapper_shell = _c
                                break
                        if _wrapper_shell:
                            with open(_cpp_link, "w") as _f:
                                _f.write(
                                    '#!{}\nexec {} -E "$@"\n'.format(
                                        _wrapper_shell,
                                        " ".join(
                                            "'{}'".format(t) if " " in t else t
                                            for t in _val.split()
                                        ),
                                    )
                                )
                            os.chmod(_cpp_link, 0o755)
                _need_symlink_path = True

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
    if _need_symlink_path:
        env["PATH"] = _symlink_dir + ":" + env.get("PATH", "")

    setup_ccache_symlinks(env, work_dir)

    if file_path_append_dirs:
        append = ":".join(
            os.path.abspath(p) for p in file_path_append_dirs if os.path.isdir(p)
        )
        if append:
            env["PATH"] = env.get("PATH", "") + ":" + append

    # Dep lib dirs in LD_LIBRARY_PATH for build/install phases
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

    # Auto-detect automake Perl modules and aclocal dirs
    _path_sources = (
        list(args.hermetic_path) + list(all_path_prepend) + list(file_path_append_dirs)
    )
    if _path_sources:
        perl5lib = []
        aclocal_dirs = []
        for bin_dir in _path_sources:
            share_dir = os.path.join(os.path.dirname(os.path.abspath(bin_dir)), "share")
            for d in _glob.glob(os.path.join(share_dir, "automake-*")):
                if os.path.isdir(d):
                    perl5lib.append(d)
            for d in _glob.glob(os.path.join(share_dir, "aclocal-*")):
                if os.path.isdir(d):
                    aclocal_dirs.append(d)
            plain_aclocal = os.path.join(share_dir, "aclocal")
            if os.path.isdir(plain_aclocal):
                aclocal_dirs.append(plain_aclocal)
        if perl5lib:
            existing = env.get("PERL5LIB", "")
            env["PERL5LIB"] = ":".join(perl5lib) + (":" + existing if existing else "")
            for d in perl5lib:
                if os.path.isdir(os.path.join(d, "am")):
                    env["AUTOMAKE_LIBDIR"] = d
                    break
        if aclocal_dirs:
            for d in aclocal_dirs:
                if "aclocal-" in os.path.basename(d):
                    env["ACLOCAL_AUTOMAKE_DIR"] = d
                    break
            env["ACLOCAL_PATH"] = ":".join(aclocal_dirs)

    # Auto-detect Python site-packages from dep prefixes
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
        rewrite_shebangs(work_dir, env)

    # HOSTCC for Kconfig builds
    if "CC" in env and "HOSTCC" not in env:
        env["HOSTCC"] = env["CC"]

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

    # ── Phase 2: Configure ───────────────────────────────────────
    if args.skip_configure:
        print("configure: skipped (--skip-configure)")
    else:
        configure = os.path.join(work_dir, args.configure_script)
        if not os.path.isfile(configure):
            print(f"error: configure script not found: {configure}", file=sys.stderr)
            sys.exit(1)
        os.chmod(configure, os.stat(configure).st_mode | 0o755)

        configure_cwd = work_dir
        if args.build_subdir:
            configure_cwd = os.path.join(work_dir, args.build_subdir)
            os.makedirs(configure_cwd, exist_ok=True)
            configure = os.path.join(
                os.path.relpath(work_dir, configure_cwd), args.configure_script
            )

        resolved_args = [_resolve_env_paths(a) for a in args.configure_args]

        _use_config_shell = False
        if _config_shell:
            _abs_configure = (
                os.path.join(configure_cwd, configure)
                if not os.path.isabs(configure)
                else configure
            )
            try:
                with open(_abs_configure, "rb") as _f:
                    _shebang = _f.readline(256)
                _use_config_shell = not _shebang.startswith(b"#!") or any(
                    s in _shebang for s in (b"/sh", b"/bash", b"/dash", b"/ash")
                )
            except OSError:
                _use_config_shell = True

        # CC/CXX as configure arguments
        _arg_keys = {a.split("=", 1)[0] for a in resolved_args if "=" in a}
        _cc_args = []
        _is_autotools = False
        _abs_configure = (
            os.path.join(configure_cwd, configure)
            if not os.path.isabs(configure)
            else configure
        )
        try:
            with open(_abs_configure, "rb") as _f:
                _head = _f.read(1024)
                _is_autotools = b"Autoconf" in _head
        except OSError:
            pass
        _inject_cc = args.cc or (
            _cc_has_spaces and _is_autotools and not args.skip_cc_arg
        )
        if _inject_cc and "CC" not in _arg_keys:
            _cc_val = args.cc or env.get("CC", "")
            if _cc_val:
                _cc_args.append(f"CC={_resolve_env_paths(_cc_val)}")
        if _inject_cc and "CXX" not in _arg_keys:
            _cxx_val = args.cxx or env.get("CXX", "")
            if _cxx_val:
                _cc_args.append(f"CXX={_resolve_env_paths(_cxx_val)}")

        if _use_config_shell:
            cmd = [_config_shell, configure] + resolved_args + _cc_args
        else:
            cmd = [configure] + resolved_args + _cc_args
        result = subprocess.run(cmd, cwd=configure_cwd, env=env)
        if result.returncode != 0:
            print(
                f"error: configure failed with exit code {result.returncode}",
                file=sys.stderr,
            )
            sys.exit(1)

    # ── Phase 3: Build ───────────────────────────────────────────
    make_dir = work_dir
    if args.build_subdir:
        make_dir = os.path.join(work_dir, args.build_subdir)

    # Patch RUNSHARED so LD_LIBRARY_PATH survives
    _patch_runshared(make_dir)

    # Run pre-build commands (Kconfig setup)
    for cmd_str in args.pre_build_cmds:
        result = subprocess.run(
            cmd_str, shell=True, cwd=make_dir, env=env, executable=_config_shell
        )
        if result.returncode != 0:
            print(f"error: pre-build-cmd failed: {cmd_str}", file=sys.stderr)
            sys.exit(1)

    jobs = multiprocessing.cpu_count()
    build_cmd = ["make", "-C", make_dir, f"-j{jobs}"]

    # Suppress autotools regeneration
    for var in [
        "ACLOCAL=true",
        "AUTOMAKE=true",
        "AUTOCONF=true",
        "AUTOHEADER=true",
        "MAKEINFO=true",
    ]:
        build_cmd.append(var)

    if args.skip_configure:
        build_cmd.append("PREFIX=/usr")

    for arg in args.make_args:
        if "=" in arg:
            key, _, value = arg.partition("=")
            value = _expand_env_refs(value, env)
            build_cmd.append(f"{key}={_resolve_env_paths(value)}")
        else:
            build_cmd.append(arg)

    # Inject CC/CXX/AR for Makefile-only packages (no config.status)
    if not os.path.exists(os.path.join(make_dir, "config.status")):
        for _var in ("CC", "CXX", "AR"):
            _val = env.get(_var, "")
            if _val and not any(a.startswith(f"{_var}=") for a in args.make_args):
                build_cmd.append(f"{_var}={_val}")

    if _config_shell:
        _has_shell_arg = any(a.startswith("SHELL=") for a in args.make_args)
        if not _has_shell_arg:
            build_cmd.append(f"SHELL={_config_shell}")

    # Network isolation
    if _NETWORK_ISOLATED:
        build_cmd = ["unshare", "--net"] + build_cmd

    result = subprocess.run(build_cmd, env=env)
    if result.returncode != 0:
        print(f"error: make failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(1)

    # ── Phase 4: Install ─────────────────────────────────────────
    prefix = declared_output
    os.makedirs(prefix, exist_ok=True)

    targets = args.install_targets or ["install"]

    install_cmd = [
        "make",
        "-C",
        make_dir,
        f"-j{jobs}",
        f"{args.destdir_var}={prefix}",
    ] + targets

    # Suppress autotools regeneration during install
    for var in [
        "ACLOCAL=true",
        "AUTOMAKE=true",
        "AUTOCONF=true",
        "AUTOHEADER=true",
        "MAKEINFO=true",
    ]:
        install_cmd.append(var)

    if args.skip_configure:
        install_cmd.append("PREFIX=/usr")

    for arg in args.make_args:
        if "=" in arg:
            key, _, value = arg.partition("=")
            value = _expand_env_refs(value, env)
            install_cmd.append(f"{key}={_resolve_env_paths(value)}")
        else:
            install_cmd.append(arg)
    for arg in args.install_args:
        if "=" in arg:
            key, _, value = arg.partition("=")
            value = _expand_env_refs(value, env)
            install_cmd.append(f"{key}={_resolve_env_paths(value)}")
        else:
            install_cmd.append(arg)

    # Inject CC/CXX/AR for Makefile-only packages
    if not os.path.exists(os.path.join(make_dir, "config.status")):
        for _var in ("CC", "CXX", "AR"):
            _val = env.get(_var, "")
            if _val and not any(
                a.startswith(f"{_var}=") for a in (args.make_args + args.install_args)
            ):
                install_cmd.append(f"{_var}={_val}")

    if _config_shell:
        _has_shell_arg = any(
            a.startswith("SHELL=") for a in (args.make_args + args.install_args)
        )
        if not _has_shell_arg:
            install_cmd.append(f"SHELL={_config_shell}")

    result = subprocess.run(install_cmd, env=env)
    if result.returncode != 0:
        print(
            f"error: make install failed with exit code {result.returncode}",
            file=sys.stderr,
        )
        sys.exit(1)

    # ── Phase 5: Post-install ────────────────────────────────────
    # Remove libtool .la files
    for la in _glob.glob(os.path.join(prefix, "**", "*.la"), recursive=True):
        os.remove(la)

    # Run post-install commands
    env["DESTDIR"] = prefix
    env["OUT"] = prefix
    env["BUILD_DIR"] = make_dir
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
