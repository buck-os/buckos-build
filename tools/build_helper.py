#!/usr/bin/env python3
"""Build wrapper for make and ninja.

Runs the specified build system in the build directory.  Supports
--pre-cmd for running setup commands before the main build (e.g. Kconfig
initialisation for busybox/kernel builds).
"""

import argparse
import glob as _glob
import multiprocessing
import os
import shutil
import subprocess
import sys


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
    """Resolve relative Buck2 artifact paths in env values to absolute.

    Handles: bare paths, -I/path, -L/path, --flag=path, and
    colon-separated paths (PKG_CONFIG_PATH).
    """
    # Handle colon-separated path lists (PKG_CONFIG_PATH)
    if ":" in value and not value.startswith("-"):
        resolved = []
        for p in value.split(":"):
            if p and os.path.exists(p):
                resolved.append(os.path.abspath(p))
            elif p:
                resolved.append(p)
        return ":".join(resolved)

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
    parser = argparse.ArgumentParser(description="Run make or ninja build")
    parser.add_argument("--build-dir", required=True, help="Build directory")
    parser.add_argument("--output-dir", required=True,
                        help="Output directory (build tree is copied here before building)")
    parser.add_argument("--jobs", type=int, default=None,
                        help="Number of parallel jobs (default: CPU count)")
    parser.add_argument("--make-arg", action="append", dest="make_args", default=[],
                        help="Extra argument to pass to make/ninja (repeatable)")
    parser.add_argument("--build-system", choices=["make", "ninja"], default="make",
                        help="Build system to use (default: make)")
    parser.add_argument("--pre-cmd", action="append", dest="pre_cmds", default=[],
                        help="Shell command to run in build dir before make (repeatable)")
    parser.add_argument("--build-subdir", default=None,
                        help="Subdirectory within build-dir where make runs (for out-of-tree builds)")
    parser.add_argument("--skip-make", action="store_true",
                        help="Skip the make/ninja step (only run pre-cmds and copy)")
    parser.add_argument("--env", action="append", dest="extra_env", default=[],
                        help="Extra environment variable KEY=VALUE (repeatable)")
    parser.add_argument("--path-prepend", action="append", dest="path_prepend", default=[],
                        help="Directory to prepend to PATH (repeatable, resolved to absolute)")
    args = parser.parse_args()

    build_dir = os.path.abspath(args.build_dir)
    output_dir = os.path.abspath(args.output_dir)

    if not os.path.isdir(build_dir):
        print(f"error: build directory not found: {build_dir}", file=sys.stderr)
        sys.exit(1)

    # Copy build tree to output dir (Buck2 outputs are read-only after creation)
    if os.path.exists(output_dir):
        shutil.rmtree(output_dir)
    shutil.copytree(build_dir, output_dir, symlinks=True)

    # Rewrite absolute paths in build.ninja — meson embeds the configured
    # directory's absolute path into build rules.  After copying to output_dir
    # those paths are stale.
    ninja_file = os.path.join(output_dir, "build.ninja")
    if os.path.isfile(ninja_file):
        with open(ninja_file, "r") as f:
            content = f.read()
        if build_dir in content:
            content = content.replace(build_dir, output_dir)
            with open(ninja_file, "w") as f:
                f.write(content)

    # Touch autotools-generated files so make doesn't try to regenerate
    # them.  The copytree preserves timestamps but configure may have
    # touched dependency files (configure.ac, m4/*) making the generated
    # outputs appear stale.
    for pattern in [
        "aclocal.m4", "configure", "config.h.in", "config.h.in~",
        "config.status", "config.h", "stamp-h1",
        "Makefile.in", "*/Makefile.in", "*/*/Makefile.in",
        "Makefile", "*/Makefile", "*/*/Makefile",
    ]:
        for f in _glob.glob(os.path.join(output_dir, pattern)):
            os.utime(f, None)

    # Disable host compiler/build caches — Buck2 caches actions itself,
    # and external caches can poison results across build contexts.
    os.environ["CCACHE_DISABLE"] = "1"
    os.environ["RUSTC_WRAPPER"] = ""

    # Apply extra environment variables
    for entry in args.extra_env:
        key, _, value = entry.partition("=")
        if key:
            os.environ[key] = _resolve_env_paths(value)
    if args.path_prepend:
        prepend = ":".join(os.path.abspath(p) for p in args.path_prepend if os.path.isdir(p))
        if prepend:
            os.environ["PATH"] = prepend + ":" + os.environ.get("PATH", "")

    # Run pre-build commands (e.g. Kconfig setup)
    for cmd_str in args.pre_cmds:
        result = subprocess.run(cmd_str, shell=True, cwd=output_dir)
        if result.returncode != 0:
            print(f"error: pre-cmd failed with exit code {result.returncode}: {cmd_str}",
                  file=sys.stderr)
            sys.exit(1)

    if args.skip_make:
        return

    jobs = args.jobs or multiprocessing.cpu_count()

    # Determine actual build directory (may be a subdir for out-of-tree builds)
    make_dir = output_dir
    if args.build_subdir:
        make_dir = os.path.join(output_dir, args.build_subdir)

    if args.build_system == "ninja":
        cmd = ["ninja", "-C", make_dir, f"-j{jobs}"]
    else:
        cmd = ["make", "-C", make_dir, f"-j{jobs}"]

    # Resolve paths in make args (e.g. CC=buck-out/.../gcc → absolute)
    for arg in args.make_args:
        if "=" in arg:
            key, _, value = arg.partition("=")
            cmd.append(f"{key}={_resolve_env_paths(value)}")
        else:
            cmd.append(arg)

    # Wrap with unshare --net for network isolation (reproducibility)
    if _NETWORK_ISOLATED:
        cmd = ["unshare", "--net"] + cmd
    else:
        print("⚠ Warning: unshare --net unavailable, building without network isolation",
              file=sys.stderr)

    result = subprocess.run(cmd)
    if result.returncode != 0:
        print(f"error: {args.build_system} failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
