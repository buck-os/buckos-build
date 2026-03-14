#!/usr/bin/env python3
"""Autotools configure wrapper.

Copies source to output dir (for out-of-tree build support), sets
environment variables, and runs ./configure with explicit args.

For packages that don't use autotools (e.g. Kconfig-based builds like
busybox or the kernel), pass --skip-configure to copy the source tree
without running ./configure.
"""

import argparse
import glob as _glob
import os
import shutil
import subprocess
import sys

from _env import clean_env, derive_lib_paths, file_prefix_map_flags, filter_path_flags, find_buckos_shell, find_dep_python3, register_cleanup, rewrite_shebangs, sanitize_filenames, sysroot_lib_paths, write_pkg_config_wrapper


def _resolve_env_paths(value):
    """Resolve relative Buck2 artifact paths in env values to absolute.

    Buck2 runs actions from the project root, so artifact paths like
    ``buck-out/v2/.../gcc`` are relative to that root.  When a subprocess
    changes its CWD (e.g. configure runs inside a build-subdir), the
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
                # Always resolve buck-out relative paths to absolute,
                # even if the path doesn't exist (libtool requires
                # absolute paths and will fail on relative ones).
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
            if path and not os.path.isabs(path) and (path.startswith("buck-out") or os.path.exists(path)):
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

    parser = argparse.ArgumentParser(description="Run autotools configure")
    parser.add_argument("--source-dir", required=True, help="Source directory containing configure script")
    parser.add_argument("--output-dir", required=True, help="Build/output directory")
    parser.add_argument("--cc", default=None, help="C compiler")
    parser.add_argument("--cxx", default=None, help="C++ compiler")
    parser.add_argument("--configure-arg", action="append", dest="configure_args", default=[],
                        help="Argument to pass to ./configure (repeatable)")
    parser.add_argument("--cflags", action="append", dest="cflags", default=[],
                        help="CFLAGS value (repeatable, joined with spaces)")
    parser.add_argument("--cxxflags", action="append", dest="cxxflags", default=[],
                        help="CXXFLAGS value (repeatable, joined with spaces)")
    parser.add_argument("--cppflags", action="append", dest="cppflags", default=[],
                        help="CPPFLAGS value (repeatable, joined with spaces)")
    parser.add_argument("--ldflags", action="append", dest="ldflags", default=[],
                        help="LDFLAGS value (repeatable, joined with spaces)")
    parser.add_argument("--pkg-config-path", action="append", dest="pkg_config_paths", default=[],
                        help="PKG_CONFIG_PATH entries (repeatable)")
    parser.add_argument("--skip-configure", action="store_true",
                        help="Copy source but skip running ./configure (for Kconfig packages)")
    parser.add_argument("--skip-cc-arg", action="store_true",
                        help="Don't auto-inject CC as a configure argument")
    parser.add_argument("--configure-script", default="configure",
                        help="Name of the configure script (default: configure, e.g. Configure for OpenSSL)")
    parser.add_argument("--env", action="append", dest="extra_env", default=[],
                        help="Extra environment variable KEY=VALUE (repeatable)")
    parser.add_argument("--build-subdir", default=None,
                        help="Subdirectory to create and run configure from (for out-of-tree builds)")
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
    parser.add_argument("--pre-cmd", action="append", dest="pre_cmds", default=[],
                        help="Shell command to run in source dir before configure (repeatable)")
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

    # Read flag files early — tset-propagated flags are base; per-package
    # flags from --cflags/--ldflags can override them.
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

    source_dir = os.path.abspath(args.source_dir)
    output_dir = os.path.abspath(args.output_dir)

    # Register cleanup early so unsafe filenames are removed on any exit
    register_cleanup(output_dir)

    if not os.path.isdir(source_dir):
        print(f"error: source directory not found: {source_dir}", file=sys.stderr)
        sys.exit(1)

    # Copy source to output dir for building
    if os.path.exists(output_dir):
        shutil.rmtree(output_dir)
    shutil.copytree(source_dir, output_dir, symlinks=True)

    env = clean_env()

    # Expose the project root so pre-cmds can resolve Buck2 artifact
    # paths (which are relative to the project root, not to output_dir).
    env["PROJECT_ROOT"] = os.getcwd()

    if args.cc:
        env["CC"] = args.cc
    if args.cxx:
        env["CXX"] = args.cxx
    all_cflags = file_prefix_map_flags() + file_cflags + args.cflags
    all_ldflags = file_ldflags + args.ldflags
    all_pkg_config = file_pkg_config + args.pkg_config_paths

    # Extract -I flags from tset cflags file for CPPFLAGS/CXXFLAGS propagation.
    # Autotools passes CPPFLAGS to both C and C++ compilers, CFLAGS to C only,
    # CXXFLAGS to C++ only — include dirs need to be in all three.
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
    # Merge --env entries.  For compiler/linker flag variables, prepend to
    # existing tset-derived values so user flags (e.g. -std=gnu11) combine
    # with dep flags (e.g. -I.../include) instead of clobbering them.
    _MERGE_FLAGS = {"CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS"}
    for entry in args.extra_env:
        key, _, value = entry.partition("=")
        if key:
            resolved = _resolve_env_paths(value)
            if key in _MERGE_FLAGS and key in env:
                env[key] = resolved + " " + env[key]
            else:
                env[key] = resolved

    # Create gcc/cc symlinks on PATH so libtool sub-configures
    # (which search PATH for gcc/cc independently of the parent's CC)
    # find the buckos compiler.  CC stays multi-token — don't split it.
    # Every invocation of $CC includes --sysroot and -specs, ensuring
    # compiled programs get the right interpreter and RPATH.
    _symlink_dir = os.path.join(output_dir, ".cc-symlinks")
    _need_symlink_path = False
    _cc_has_spaces = False
    for _var, _names in [("CC", ("cc", "gcc")), ("CXX", ("c++", "g++"))]:
        _val = env.get(_var, "")
        if " " in _val:
            _cc_has_spaces = True
            _cc_bin = os.path.abspath(_val.split()[0])
            if os.path.isfile(_cc_bin):
                os.makedirs(_symlink_dir, exist_ok=True)
                for _name in _names:
                    _link = os.path.join(_symlink_dir, _name)
                    if not os.path.exists(_link):
                        os.symlink(_cc_bin, _link)
                _need_symlink_path = True
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
                    _glibc_d = os.path.join(_d, "glibc")
                    if os.path.isdir(_glibc_d):
                        _lib_dirs.append(_glibc_d)
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
    # Add CC symlink dir to PATH so libtool sub-configures find gcc/cc.
    if _need_symlink_path:
        env["PATH"] = _symlink_dir + ":" + env.get("PATH", "")

    # Append dep bin dirs AFTER hermetic PATH for *-config discovery scripts
    # (gpg-error-config, curl-config, xml2-config, etc.).  Appended so seed
    # host-tools always take priority — prevents ENOEXEC from dep binaries
    # with unrewritten padded ELF interpreters shadowing seed tools.
    if file_path_append_dirs:
        append = ":".join(os.path.abspath(p) for p in file_path_append_dirs if os.path.isdir(p))
        if append:
            env["PATH"] = env.get("PATH", "") + ":" + append

    # Tset-provided lib dirs for dep libraries.  With sysroot ld-linux
    # and per-package RPATH from specs, buckos binaries find deps via
    # RPATH.  Skip adding to LD_LIBRARY_PATH — it contaminates host
    # tools (e.g. /usr/bin/awk) that load buckos .so files and crash
    # on glibc version mismatches.
    #
    # Only add when no sysroot is available (bootstrap/host mode).
    if file_lib_dirs and not args.ld_linux:
        resolved = [os.path.abspath(d) for d in file_lib_dirs if os.path.isdir(d)]
        if resolved:
            existing = env.get("LD_LIBRARY_PATH", "")
            merged = ":".join(resolved)
            env["LD_LIBRARY_PATH"] = (merged + ":" + existing).rstrip(":") if existing else merged

    # Derive LD_LIBRARY_PATH, GCONV_PATH, BISON_PKGDATADIR from hermetic
    # and path-prepend dirs so host tools find shared libraries and data.
    if args.hermetic_path:
        derive_lib_paths(args.hermetic_path, env)
    derive_lib_paths(all_path_prepend, env)

    # Pin PYTHON/PYTHON3 to buckos python so autotools build scripts
    # (e.g. AC_PATH_PROG([PYTHON3]), Makefile rules invoking $(PYTHON))
    # use the ABI-matched buckos python rather than host python.
    for _bp in list(args.hermetic_path) + list(all_path_prepend):
        _candidate = os.path.join(os.path.abspath(_bp), "python3")
        if os.path.isfile(_candidate):
            env.setdefault("PYTHON", _candidate)
            env.setdefault("PYTHON3", _candidate)
            break

    # Auto-detect automake Perl modules and aclocal dirs from dep
    # prefixes.  The Buck2-installed automake hardcodes /usr/share/...
    # paths which don't resolve to the artifact directory.
    _path_sources = list(args.hermetic_path) + list(all_path_prepend) + list(file_path_append_dirs)
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
            # Also include the plain aclocal dir (for libtool m4 macros etc.)
            plain_aclocal = os.path.join(share_dir, "aclocal")
            if os.path.isdir(plain_aclocal):
                aclocal_dirs.append(plain_aclocal)
        if perl5lib:
            existing = env.get("PERL5LIB", "")
            env["PERL5LIB"] = ":".join(perl5lib) + (":" + existing if existing else "")
            # AUTOMAKE_LIBDIR overrides automake's hardcoded pkgvdatadir
            # (where am/*.am files and support scripts like install-sh live)
            for d in perl5lib:
                if os.path.isdir(os.path.join(d, "am")):
                    env["AUTOMAKE_LIBDIR"] = d
                    break
        if aclocal_dirs:
            # ACLOCAL_AUTOMAKE_DIR overrides the hardcoded automake acdir
            for d in aclocal_dirs:
                if "aclocal-" in os.path.basename(d):
                    env["ACLOCAL_AUTOMAKE_DIR"] = d
                    break
            # ACLOCAL_PATH adds extra search directories
            env["ACLOCAL_PATH"] = ":".join(aclocal_dirs)

    # Create a pkg-config wrapper that always passes --define-prefix so
    # .pc files in Buck2 dep directories resolve paths correctly.
    wrapper_dir = write_pkg_config_wrapper(os.path.join(output_dir, ".pkgconf-wrapper"), python=find_dep_python3(env))

    # Prepend pkg-config wrapper to PATH
    env["PATH"] = wrapper_dir + ":" + env.get("PATH", os.environ.get("PATH", ""))

    # Set up sysroot lib paths and disable posix_spawn to avoid
    # ENOEXEC with padded ELF interpreters on buckos-native dep binaries.
    if args.ld_linux:
        sysroot_lib_paths(args.ld_linux, env)

    # Find buckos shell on PATH for running configure, pre-cmds, and
    # shebang rewriting.  CONFIG_SHELL tells autotools to re-exec
    # sub-configures under this shell.  SHELL is inherited by make.
    _config_shell = find_buckos_shell(env)
    if _config_shell:
        env["CONFIG_SHELL"] = _config_shell
        env["SHELL"] = _config_shell
        # Rewrite #!/bin/sh, #!/usr/bin/bash, etc. in the copied source
        # tree so the kernel uses buckos shell instead of host shell.
        rewrite_shebangs(output_dir, env)

    # Run pre-configure commands (e.g. autoreconf, libtoolize, or
    # bootstrap src_prepare steps like symlinking in-tree libraries).
    # These run before the skip-configure check so they're available
    # for prepare-only actions (--skip-configure --pre-cmd "...").
    for cmd_str in args.pre_cmds:
        result = subprocess.run(
            cmd_str, shell=True, cwd=output_dir, env=env,
            executable=_config_shell,
        )
        if result.returncode != 0:
            print(f"error: pre-cmd failed with exit code {result.returncode}: {cmd_str}",
                  file=sys.stderr)
            sys.exit(1)

    if args.skip_configure:
        sanitize_filenames(output_dir)
        return

    configure = os.path.join(output_dir, args.configure_script)
    if not os.path.isfile(configure):
        print(f"error: configure script not found in {output_dir}", file=sys.stderr)
        sys.exit(1)

    # Ensure configure is executable
    os.chmod(configure, os.stat(configure).st_mode | 0o755)

    # Determine configure working directory
    configure_cwd = output_dir
    if args.build_subdir:
        configure_cwd = os.path.join(output_dir, args.build_subdir)
        os.makedirs(configure_cwd, exist_ok=True)
        # For out-of-tree builds, configure path is relative to the subdir
        configure = os.path.join(os.path.relpath(output_dir, configure_cwd), args.configure_script)

    # Resolve buck-out relative paths in configure args to absolute.
    # Buck2 renders artifact paths relative to the project root, but
    # configure runs in output_dir — the relative paths would break.
    resolved_args = [_resolve_env_paths(a) for a in args.configure_args]

    # Only wrap with CONFIG_SHELL for shell scripts.  Perl-based configure
    # scripts (e.g. OpenSSL's Configure) must run via their own shebang.
    _use_config_shell = False
    if _config_shell:
        _abs_configure = os.path.join(configure_cwd, configure) if not os.path.isabs(configure) else configure
        try:
            with open(_abs_configure, "rb") as _f:
                _shebang = _f.readline(256)
            # Shell script or no shebang → wrap with CONFIG_SHELL
            _use_config_shell = not _shebang.startswith(b"#!") or \
                any(s in _shebang for s in (b"/sh", b"/bash", b"/dash", b"/ash"))
        except OSError:
            _use_config_shell = True

    # Pass CC/CXX as configure arguments.  Required for:
    # 1. Hand-written scripts (GNU ed, lzip) that ignore env vars
    # 2. Autotools with multi-token CC — `test -f "$CC"` fails when CC
    #    has spaces, but CC=... as a configure argument bypasses this
    #    via eval.  Only autotools scripts handle CC= arguments; non-
    #    autotools scripts (zlib) reject them as unknown options.
    _arg_keys = {a.split("=", 1)[0] for a in resolved_args if "=" in a}
    _cc_args = []
    # Detect autotools by checking for "GNU Autoconf" marker
    _is_autotools = False
    _abs_configure = os.path.join(configure_cwd, configure) if not os.path.isabs(configure) else configure
    try:
        with open(_abs_configure, "rb") as _f:
            _head = _f.read(1024)
            _is_autotools = b"Autoconf" in _head
    except OSError:
        pass
    _inject_cc = args.cc or (_cc_has_spaces and _is_autotools and not args.skip_cc_arg)
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
        print(f"error: configure failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(1)

    sanitize_filenames(output_dir)


if __name__ == "__main__":
    main()
