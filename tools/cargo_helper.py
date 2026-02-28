#!/usr/bin/env python3
"""Cargo build helper for Rust packages.

Runs cargo build --release in the source directory, producing binaries
under the target directory.
"""

import argparse
import os
import subprocess
import sys

from _env import clean_env


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
    parts = []
    for token in value.split():
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
    parser.add_argument("--path-prepend", action="append", dest="path_prepend", default=[],
                        help="Directory to prepend to PATH (repeatable, resolved to absolute)")
    parser.add_argument("--bin", action="append", dest="bins", default=[],
                        help="Specific binary name to install (repeatable; default: all executables)")
    parser.add_argument("--vendor-dir", default=None,
                        help="Vendor directory containing pre-downloaded dependencies")
    args = parser.parse_args()

    if not os.path.isdir(args.source_dir):
        print(f"error: source directory not found: {args.source_dir}", file=sys.stderr)
        sys.exit(1)

    cargo_toml = os.path.join(args.source_dir, "Cargo.toml")
    if not os.path.isfile(cargo_toml):
        print(f"error: Cargo.toml not found in {args.source_dir}", file=sys.stderr)
        sys.exit(1)

    target_dir = args.target_dir or os.path.join(args.source_dir, "target")

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
                if os.path.isdir(_d):
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
    if args.path_prepend:
        prepend = ":".join(os.path.abspath(p) for p in args.path_prepend)
        env["PATH"] = prepend + (":" + env["PATH"] if env.get("PATH") else "")
        _dep_lib_dirs = []
        for _bp in args.path_prepend:
            _parent = os.path.dirname(os.path.abspath(_bp))
            for _ld in ("lib", "lib64"):
                _d = os.path.join(_parent, _ld)
                if os.path.isdir(_d):
                    _dep_lib_dirs.append(_d)
        if _dep_lib_dirs:
            _existing = env.get("LD_LIBRARY_PATH", "")
            env["LD_LIBRARY_PATH"] = ":".join(_dep_lib_dirs) + (":" + _existing if _existing else "")

    # Set up vendored dependencies if provided
    if args.vendor_dir:
        vendor_dir = os.path.abspath(args.vendor_dir)
        cargo_config_dir = os.path.join(args.source_dir, ".cargo")
        os.makedirs(cargo_config_dir, exist_ok=True)
        with open(os.path.join(cargo_config_dir, "config.toml"), "a") as f:
            f.write(f'\n[source.crates-io]\nreplace-with = "vendored-sources"\n\n')
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
