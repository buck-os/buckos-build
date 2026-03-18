#!/usr/bin/env python3
"""Cargo build helper for Rust packages.

Runs cargo build --release in the source directory, producing binaries
under the target directory.
"""

import argparse
import os
import shutil
import subprocess
import sys

from _env import apply_cache_config, clean_env, filter_path_flags, preferred_linker_flag, setup_ccache_symlinks, sysroot_lib_paths


def _can_unshare_net():
    """Check if unshare --net is available for network isolation."""
    try:
        result = subprocess.run(
            ["unshare", "--net", "true"],
            capture_output=True, timeout=5,
        )
        return result.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


_NETWORK_ISOLATED = _can_unshare_net()


def _resolve_env_paths(value):
    """Resolve relative Buck2 artifact paths in env values to absolute."""
    _FLAG_PREFIXES = ["-specs=", "--sysroot="]

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


def main():
    _host_path = os.environ.get("PATH", "")

    parser = argparse.ArgumentParser(description="Run cargo build --release")
    parser.add_argument("--source-dir", required=True,
                        help="Rust source directory (contains Cargo.toml)")
    parser.add_argument("--output-dir", required=True,
                        help="Output directory for installed binaries")
    parser.add_argument("--target-dir", default=None,
                        help="Cargo target directory (default: source-dir/target)")
    parser.add_argument("--feature", action="append", dest="features", default=[],
                        help="Cargo feature to enable (repeatable)")
    parser.add_argument("--cargo-arg", action="append", dest="cargo_args", default=[],
                        help="Extra argument to pass to cargo (repeatable)")
    parser.add_argument("--env", action="append", dest="extra_env", default=[],
                        help="Extra environment variable KEY=VALUE (repeatable)")
    parser.add_argument("--hermetic-path", action="append", dest="hermetic_path", default=[],
                        help="Set PATH to only these dirs (replaces host PATH, repeatable)")
    parser.add_argument("--allow-host-path", action="store_true",
                        help="Allow host PATH (bootstrap escape hatch)")
    parser.add_argument("--hermetic-empty", action="store_true",
                        help="Start with empty PATH (populated by --path-prepend)")
    parser.add_argument("--ld-linux", default=None,
                        help="Buckos ld-linux path (disables posix_spawn)")
    parser.add_argument("--path-prepend", action="append", dest="path_prepend", default=[],
                        help="Directory to prepend to PATH (repeatable, resolved to absolute)")
    parser.add_argument("--bin", action="append", dest="bins", default=[],
                        help="Specific binary name to install (repeatable; default: all executables)")
    parser.add_argument("--vendor-dir", default=None,
                        help="Vendor directory containing pre-downloaded dependencies")
    parser.add_argument("--pkg-config-file", default=None,
                        help="File with PKG_CONFIG_PATH entries (one per line, from tset projection)")
    parser.add_argument("--lib-dirs-file", default=None,
                        help="File with lib dirs (one per line, from tset projection)")
    args = parser.parse_args()

    if not os.path.isdir(args.source_dir):
        print(f"error: source directory not found: {args.source_dir}", file=sys.stderr)
        sys.exit(1)

    cargo_toml = os.path.join(args.source_dir, "Cargo.toml")
    if not os.path.isfile(cargo_toml):
        print(f"error: Cargo.toml not found in {args.source_dir}", file=sys.stderr)
        sys.exit(1)

    # Copy source to scratch to avoid mutating the previous action's output.
    # cargo_helper writes .cargo/config.toml and may place build artifacts
    # inside the source tree.
    source_dir = os.path.abspath(args.source_dir)
    _scratch = os.path.abspath(os.environ.get("BUCK_SCRATCH_PATH",
                                              os.environ.get("TMPDIR", "/tmp")))
    _scratch_src = os.path.join(_scratch, "source")
    shutil.copytree(source_dir, _scratch_src, symlinks=True)
    source_dir = _scratch_src
    cargo_toml = os.path.join(source_dir, "Cargo.toml")

    target_dir = args.target_dir or os.path.join(source_dir, "target")

    env = clean_env()

    # Read dep flag files (PKG_CONFIG_PATH, lib dirs from tset projections)
    def _read_flag_file(path):
        if not path or not os.path.isfile(path):
            return []
        with open(path) as f:
            return [line.rstrip("\n") for line in f if line.strip()]

    file_pkg_config = [p for p in _read_flag_file(args.pkg_config_file) if os.path.isdir(os.path.abspath(p))]
    file_lib_dirs = _read_flag_file(args.lib_dirs_file)

    # Set PKG_CONFIG_PATH from dep tset so cargo build scripts (e.g.
    # openssl-sys) can find .pc files via pkg-config.
    if file_pkg_config:
        merged = ":".join(os.path.abspath(p) for p in file_pkg_config)
        existing = env.get("PKG_CONFIG_PATH", "")
        env["PKG_CONFIG_PATH"] = (merged + ":" + existing).rstrip(":") if existing else merged

    # Set LIBRARY_PATH and LD_LIBRARY_PATH from dep lib dirs so linker
    # and build scripts find dep shared libraries.
    if file_lib_dirs:
        resolved = [
            os.path.abspath(d) for d in file_lib_dirs
            if os.path.isdir(d) and not os.path.exists(os.path.join(os.path.abspath(d), "libc.so.6"))
        ]
        if resolved:
            merged = ":".join(resolved)
            for var in ("LIBRARY_PATH", "LD_LIBRARY_PATH"):
                existing = env.get(var, "")
                env[var] = (merged + ":" + existing).rstrip(":") if existing else merged

    for entry in args.extra_env:
        key, _, value = entry.partition("=")
        if key:
            env[key] = _resolve_env_paths(value)

    apply_cache_config(env)

    # Isolate cargo from user-level config (~/.cargo/config.toml) which
    # may set linker=clang, rustc-wrapper, or other host-specific options.
    # clean_env() already sets CARGO_HOME; override RUSTC_WRAPPER to
    # prevent ~/.cargo/config from setting it via parent-dir search.
    env["RUSTC_WRAPPER"] = ""
    env["CARGO_BUILD_RUSTC_WRAPPER"] = ""

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
    if args.path_prepend:
        prepend = ":".join(os.path.abspath(p) for p in args.path_prepend)
        env["PATH"] = prepend + (":" + env["PATH"] if env.get("PATH") else "")
        _dep_lib_dirs = []
        for _bp in args.path_prepend:
            _parent = os.path.dirname(os.path.abspath(_bp))
            for _ld in ("lib", "lib64"):
                _d = os.path.join(_parent, _ld)
                if os.path.isdir(_d) and not os.path.exists(os.path.join(_d, "libc.so.6")):
                    _dep_lib_dirs.append(_d)
                    _glibc_d = os.path.join(_d, "glibc")
                    if os.path.isdir(_glibc_d):
                        _dep_lib_dirs.append(_glibc_d)
        if _dep_lib_dirs:
            _existing = env.get("LD_LIBRARY_PATH", "")
            env["LD_LIBRARY_PATH"] = ":".join(_dep_lib_dirs) + (":" + _existing if _existing else "")

    if args.ld_linux:
        sysroot_lib_paths(args.ld_linux, env)

    # Pass the FULL CC (with --sysroot and -specs) through RUSTFLAGS
    # so rustc invokes GCC with the buckos specs file.  The specs
    # inject sysroot ld-linux as the interpreter and sysroot lib dirs
    # as DT_RPATH into every linked binary — build scripts and target
    # alike.  Build scripts then use sysroot ld-linux + sysroot libc
    # (matching pair), avoiding host glibc version mismatches.
    # -fuse-ld=mold uses the mold linker (on PATH via host-tools).
    # rust-lld does not honour --sysroot.
    cc = env.get("CC", "")
    cc_parts = cc.split() if cc else []
    # Skip ccache prefix — the real compiler binary is the next token.
    if cc_parts and os.path.basename(cc_parts[0]) == "ccache":
        cc_parts = cc_parts[1:]
    cc_bin = cc_parts[0] if cc_parts else ""
    if cc_bin:
        link_args = " ".join(f"-C link-arg={flag}" for flag in cc_parts[1:])
        _ld_flag = preferred_linker_flag(env)
        _fuse_ld = f'-C link-arg={_ld_flag}' if _ld_flag else ''
        # Add dep lib dirs as -L flags so the linker finds dep shared
        # libs (e.g. libssl.so from openssl dep).
        _dep_link_dirs = ""
        if file_lib_dirs:
            _dep_link_dirs = " ".join(
                f"-L native={os.path.abspath(d)}" for d in file_lib_dirs
                if os.path.isdir(d) and not os.path.exists(os.path.join(os.path.abspath(d), "libc.so.6"))
            )
        rustflags = f'-C linker={cc_bin} {link_args} {_fuse_ld} {_dep_link_dirs}'.strip()
        env["RUSTFLAGS"] = rustflags

        # Create gcc/cc/clang symlinks so build scripts that invoke
        # a C compiler directly (e.g. cc crate, openssl-sys) find
        # one on the hermetic PATH.
        _cc_abs = os.path.abspath(cc_bin)
        if os.path.isfile(_cc_abs):
            _scratch = os.environ.get("BUCK_SCRATCH_PATH", os.environ.get("TMPDIR", "/tmp"))
            _symlink_dir = os.path.join(os.path.abspath(_scratch), "cc-symlinks")
            os.makedirs(_symlink_dir, exist_ok=True)
            for _name in ("gcc", "cc", "clang"):
                _link = os.path.join(_symlink_dir, _name)
                if not os.path.exists(_link):
                    os.symlink(_cc_abs, _link)
            _cxx_val = env.get("CXX", "")
            if _cxx_val:
                _cxx_abs = os.path.abspath(_cxx_val.split()[0])
                if os.path.isfile(_cxx_abs):
                    for _name in ("g++", "c++", "clang++"):
                        _link = os.path.join(_symlink_dir, _name)
                        if not os.path.exists(_link):
                            os.symlink(_cxx_abs, _link)
            env["PATH"] = _symlink_dir + ":" + env.get("PATH", "")

        # ccache masquerade symlinks — prepended before gcc symlinks.
        setup_ccache_symlinks(env, _scratch)

        # Set CARGO_HOST_LINKER so build scripts use buckos gcc with
        # sysroot specs.  When cargo is invoked with --target, RUSTFLAGS
        # linker only applies to target, not build scripts.
        if args.ld_linux:
            _sysroot = os.path.dirname(os.path.dirname(os.path.abspath(args.ld_linux)))
            _specs = os.path.join(_sysroot, "..", "..", "..", "..", "gcc-link.specs")
            if os.path.isfile(_specs):
                _specs = os.path.abspath(_specs)
                _shell = None
                for _d in env.get("PATH", "").split(":"):
                    for _sh in ("bash", "sh"):
                        _c = os.path.join(_d, _sh) if _d else ""
                        if _c and os.path.isfile(_c) and os.access(_c, os.X_OK):
                            _shell = _c
                            break
                    if _shell:
                        break
                if _shell:
                    _wrapper = os.path.join(os.path.abspath(
                        os.environ.get("BUCK_SCRATCH_PATH",
                                       os.environ.get("TMPDIR", "/tmp"))),
                        "buckos-cargo-host-linker")
                    _fuse = preferred_linker_flag(env)
                    with open(_wrapper, "w") as f:
                        f.write(f"#!{_shell}\n")
                        f.write(f'exec "{_cc_abs}" "--sysroot={_sysroot}" '
                                f'"-specs={_specs}" {_fuse} "$@"\n')
                    os.chmod(_wrapper, 0o755)
                    env["CARGO_HOST_LINKER"] = _wrapper

    # Still write .cargo/config.toml for vendor_dir support; comment out
    # any existing [build] or [target.x86_64-unknown-linux-gnu] sections
    # that might conflict.
    cargo_config_dir = os.path.join(source_dir, ".cargo")
    os.makedirs(cargo_config_dir, exist_ok=True)
    config_path = os.path.join(cargo_config_dir, "config.toml")
    existing_content = ""
    if os.path.isfile(config_path):
        with open(config_path) as f:
            existing_content = f.read()
    # Comment out any existing [build] or [target.*] sections to avoid conflicts.
    if "[build]" in existing_content or "[target." in existing_content:
        lines = existing_content.split("\n")
        new_lines = []
        in_section = False
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("[build]") or stripped.startswith("[target."):
                in_section = True
                new_lines.append("# " + line + "  # overridden by buckos")
            elif stripped.startswith("["):
                in_section = False
                new_lines.append(line)
            elif in_section:
                new_lines.append("# " + line)
            else:
                new_lines.append(line)
        existing_content = "\n".join(new_lines)
    with open(config_path, "w") as f:
        f.write(existing_content)
        f.write("\n# buckos overrides\n")
        if args.vendor_dir:
            vendor_dir = os.path.abspath(args.vendor_dir)
            f.write(f'[source.crates-io]\nreplace-with = "vendored-sources"\n\n')
            f.write(f'[source.vendored-sources]\ndirectory = "{vendor_dir}"\n')

    cmd = [
        "cargo", "build",
        "--release",
        "--target-dir", target_dir,
        "--manifest-path", cargo_toml,
    ]

    if args.features:
        cmd.extend(["--features", ",".join(args.features)])

    cmd.extend(args.cargo_args)

    # Wrap with unshare --net for network isolation (reproducibility)
    if _NETWORK_ISOLATED:
        cmd = ["unshare", "--net"] + cmd
    else:
        print("⚠ Warning: unshare --net unavailable, building without network isolation",
              file=sys.stderr)

    result = subprocess.run(cmd, env=env)
    if result.returncode != 0:
        print(f"error: cargo build failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(1)

    # Install binaries from target/release/ to output-dir/usr/bin/
    release_dir = os.path.join(target_dir, "release")
    if not os.path.isdir(release_dir):
        print(f"error: release directory not found: {release_dir}", file=sys.stderr)
        sys.exit(1)

    bin_dir = os.path.join(args.output_dir, "usr", "bin")
    os.makedirs(bin_dir, exist_ok=True)

    installed = 0
    for entry in os.listdir(release_dir):
        path = os.path.join(release_dir, entry)
        if os.path.isfile(path) and os.access(path, os.X_OK):
            # Skip build artifacts that aren't real binaries
            if entry.startswith(".") or entry.endswith(".d"):
                continue
            # If specific bins were requested, only install those
            if args.bins and entry not in args.bins:
                continue
            dest = os.path.join(bin_dir, entry)
            # Use cp to preserve permissions
            cp = subprocess.run(["cp", "-a", path, dest])
            if cp.returncode != 0:
                print(f"error: failed to install {entry}", file=sys.stderr)
                sys.exit(1)
            installed += 1

    if installed == 0:
        print("warning: no executable binaries found in release directory", file=sys.stderr)


if __name__ == "__main__":
    main()
