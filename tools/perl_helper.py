#!/usr/bin/env python3
"""Perl module build helper.

Handles both ExtUtils::MakeMaker (Makefile.PL) and Module::Build (Build.PL)
build systems:

  Makefile.PL: perl Makefile.PL PREFIX=/usr && make && make install DESTDIR=$OUT
  Build.PL:    perl Build.PL --prefix=/usr && ./Build && ./Build install --destdir=$OUT
"""

import argparse
import glob
import os
import subprocess
import sys

from _env import add_path_args, clean_env, sanitize_filenames, setup_path


def _resolve_env_paths(value):
    """Resolve relative Buck2 artifact paths in env values to absolute."""
    _FLAG_PREFIXES = ["-specs="]

    parts = []
    for token in value.split():
        flag_resolved = False
        for prefix in _FLAG_PREFIXES:
            if token.startswith(prefix) and len(token) > len(prefix):
                path = token[len(prefix):]
                if not os.path.isabs(path) and os.path.exists(path):
                    parts.append(prefix + os.path.abspath(path))
                else:
                    parts.append(token)
                flag_resolved = True
                break
        if flag_resolved:
            continue
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


def _build_perl5lib(path_prepend, hermetic_path):
    """Build PERL5LIB from dep bin dirs by scanning sibling lib dirs."""
    perl5lib = []
    all_dirs = list(path_prepend) + list(hermetic_path)
    for bin_dir in all_dirs:
        parent = os.path.dirname(os.path.abspath(bin_dir))
        for lib_pattern in (
            "lib/perl5",
            "lib/perl5/vendor_perl",
            "lib/perl5/site_perl",
            "share/perl5",
            "share/perl5/vendor_perl",
            "lib64/perl5",
            "lib64/perl5/vendor_perl",
        ):
            # Check both {parent}/{pattern} and {parent}/usr/{pattern}
            for base in (parent, os.path.join(parent, "usr")):
                lib_dir = os.path.join(base, lib_pattern)
                if os.path.isdir(lib_dir):
                    perl5lib.append(lib_dir)
                    # Also add arch-specific subdirs
                    for arch_dir in glob.glob(os.path.join(lib_dir, "*-linux-*")):
                        if os.path.isdir(arch_dir):
                            perl5lib.append(arch_dir)
    return perl5lib


def main():
    _host_path = os.environ.get("PATH", "")

    parser = argparse.ArgumentParser(description="Build Perl module")
    parser.add_argument("--source-dir", required=True,
                        help="Perl module source directory")
    parser.add_argument("--output-dir", required=True,
                        help="Output directory (DESTDIR)")
    parser.add_argument("--env", action="append", dest="extra_env", default=[],
                        help="Extra environment variable KEY=VALUE (repeatable)")
    parser.add_argument("--configure-arg", action="append",
                        dest="configure_args", default=[],
                        help="Extra arg for Makefile.PL/Build.PL (repeatable)")
    parser.add_argument("--pre-cmd", action="append", dest="pre_cmds", default=[],
                        help="Shell command to run before configure (repeatable)")
    parser.add_argument("--post-install-cmd", action="append",
                        dest="post_install_cmds", default=[],
                        help="Shell command to run after install (repeatable)")
    add_path_args(parser)
    args = parser.parse_args()

    source_dir = os.path.abspath(args.source_dir)
    output_dir = os.path.abspath(args.output_dir)

    if not os.path.isdir(source_dir):
        print(f"error: source directory not found: {source_dir}", file=sys.stderr)
        sys.exit(1)

    os.makedirs(output_dir, exist_ok=True)

    env = clean_env()

    for entry in args.extra_env:
        key, _, value = entry.partition("=")
        if key:
            env[key] = _resolve_env_paths(value)

    setup_path(args, env, _host_path)

    # Build PERL5LIB from dep prefixes so Perl can find dep modules
    perl5lib = _build_perl5lib(args.path_prepend, args.hermetic_path)
    if perl5lib:
        existing = env.get("PERL5LIB", "")
        env["PERL5LIB"] = ":".join(perl5lib) + (":" + existing if existing else "")

    # Derive LD_LIBRARY_PATH from PATH dirs (for XS modules linking against C libs)
    _lib_dirs = []
    for _bp in args.hermetic_path + args.path_prepend:
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

    # Run pre-commands in source dir
    for cmd_str in args.pre_cmds:
        result = subprocess.run(["sh", "-ec", cmd_str], cwd=source_dir, env=env)
        if result.returncode != 0:
            print(f"error: pre-command failed with exit code {result.returncode}",
                  file=sys.stderr)
            sys.exit(1)

    # Detect build system
    has_makefile_pl = os.path.exists(os.path.join(source_dir, "Makefile.PL"))
    has_build_pl = os.path.exists(os.path.join(source_dir, "Build.PL"))

    if has_makefile_pl:
        # ExtUtils::MakeMaker
        configure_cmd = [
            "perl", "Makefile.PL",
            "PREFIX=/usr",
            "INSTALLDIRS=vendor",
        ] + args.configure_args

        result = subprocess.run(configure_cmd, cwd=source_dir, env=env)
        if result.returncode != 0:
            print("error: perl Makefile.PL failed", file=sys.stderr)
            sys.exit(1)

        result = subprocess.run(
            ["make", f"-j{os.cpu_count() or 1}"],
            cwd=source_dir, env=env,
        )
        if result.returncode != 0:
            print("error: make failed", file=sys.stderr)
            sys.exit(1)

        result = subprocess.run(
            ["make", "install", f"DESTDIR={output_dir}"],
            cwd=source_dir, env=env,
        )
        if result.returncode != 0:
            print("error: make install failed", file=sys.stderr)
            sys.exit(1)

    elif has_build_pl:
        # Module::Build
        configure_cmd = [
            "perl", "Build.PL",
            "--prefix=/usr",
            "--installdirs=vendor",
        ] + args.configure_args

        result = subprocess.run(configure_cmd, cwd=source_dir, env=env)
        if result.returncode != 0:
            print("error: perl Build.PL failed", file=sys.stderr)
            sys.exit(1)

        result = subprocess.run(["./Build"], cwd=source_dir, env=env)
        if result.returncode != 0:
            print("error: ./Build failed", file=sys.stderr)
            sys.exit(1)

        result = subprocess.run(
            ["./Build", "install", f"--destdir={output_dir}"],
            cwd=source_dir, env=env,
        )
        if result.returncode != 0:
            print("error: ./Build install failed", file=sys.stderr)
            sys.exit(1)

    else:
        print("error: no Makefile.PL or Build.PL found in source directory",
              file=sys.stderr)
        sys.exit(1)

    # Run post-install commands
    for cmd_str in args.post_install_cmds:
        post_env = dict(env)
        post_env["BUILD_DIR"] = source_dir
        post_env["DESTDIR"] = output_dir
        result = subprocess.run(["sh", "-ec", cmd_str], cwd=output_dir, env=post_env)
        if result.returncode != 0:
            print(f"error: post-install command failed with exit code {result.returncode}",
                  file=sys.stderr)
            sys.exit(1)

    sanitize_filenames(output_dir)


if __name__ == "__main__":
    main()
