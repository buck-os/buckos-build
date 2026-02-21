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

    Buck2 runs actions from the project root, so artifact paths like
    ``buck-out/v2/.../gcc`` are relative to that root.  When a subprocess
    changes its CWD (e.g. make runs in a copied build tree), the
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

    _FLAG_PREFIXES = ["-I", "-L", "-Wl,-rpath-link,", "-Wl,-rpath,"]

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

    # Rewrite absolute paths in build system files.
    # Both CMake and Meson embed the build dir in generated files.  After
    # copytree these paths are stale.  Do string replacement in all
    # relevant files and suppress cmake's auto-regeneration (the source
    # dir isn't available as a build action input).
    cmake_cache = os.path.join(output_dir, "CMakeCache.txt")
    ninja_file = os.path.join(output_dir, "build.ninja")
    if os.path.isfile(cmake_cache):
        # Rewrite paths in CMakeCache.txt
        with open(cmake_cache, "r") as f:
            content = f.read()
        content = content.replace(build_dir, output_dir)
        with open(cmake_cache, "w") as f:
            f.write(content)
        # Rewrite cmake_install.cmake files at any depth
        for pattern in ["cmake_install.cmake", "**/cmake_install.cmake"]:
            for fpath in _glob.glob(os.path.join(output_dir, pattern), recursive=True):
                try:
                    with open(fpath, "r") as f:
                        fc = f.read()
                    if build_dir in fc:
                        fc = fc.replace(build_dir, output_dir)
                        with open(fpath, "w") as f:
                            f.write(fc)
                except (UnicodeDecodeError, PermissionError):
                    pass
        # Rewrite build.ninja and suppress cmake regeneration.
        # Ninja's RERUN_CMAKE rule would try to access the source dir
        # which isn't available in the build action.
        if os.path.isfile(ninja_file):
            with open(ninja_file, "r") as f:
                content = f.read()
            content = content.replace(build_dir, output_dir)
            # Remove cmake regeneration rules so ninja doesn't try to
            # re-run cmake (which would fail without the source dir).
            import re
            content = re.sub(
                r'^build build\.ninja:.*?(?=\n(?:build |$))',
                '# cmake regeneration suppressed by build_helper',
                content, count=1, flags=re.MULTILINE | re.DOTALL,
            )
            with open(ninja_file, "w") as f:
                f.write(content)
    elif os.path.isfile(ninja_file):
        # Meson / plain ninja — string replacement + suppress regeneration
        with open(ninja_file, "r") as f:
            content = f.read()
        if build_dir in content:
            content = content.replace(build_dir, output_dir)
        # Suppress meson regeneration (source dir not available in build action)
        import re
        content = re.sub(
            r'^build build\.ninja:.*?(?=\n(?:build |$))',
            '# meson regeneration suppressed by build_helper',
            content, count=1, flags=re.MULTILINE | re.DOTALL,
        )
        with open(ninja_file, "w") as f:
            f.write(content)

    # Rewrite stale absolute paths in autotools Makefiles.  configure
    # embeds the build directory in generated Makefiles (e.g. references
    # to man page sources, libtool scripts).  After copytree these point
    # at the old "configured" directory which won't exist in later phases.
    for pattern in ["Makefile", "**/Makefile", "**/Makefile.in"]:
        for fpath in _glob.glob(os.path.join(output_dir, pattern), recursive=True):
            try:
                with open(fpath, "r") as f:
                    fc = f.read()
                if build_dir in fc:
                    fc = fc.replace(build_dir, output_dir)
                    with open(fpath, "w") as f:
                        f.write(fc)
            except (UnicodeDecodeError, PermissionError):
                pass

    # Also rewrite libtool and config.status which embed build dir paths
    for pattern in ["libtool", "config.status", "**/libtool"]:
        for fpath in _glob.glob(os.path.join(output_dir, pattern), recursive=True):
            try:
                with open(fpath, "r") as f:
                    fc = f.read()
                if build_dir in fc:
                    fc = fc.replace(build_dir, output_dir)
                    with open(fpath, "w") as f:
                        f.write(fc)
            except (UnicodeDecodeError, PermissionError):
                pass

    # Comprehensive rewrite of stale build-dir paths in cmake artefacts.
    # CMake embeds the build directory in many generated files: syncqt
    # args, AutogenInfo.json, precompiled-header wrappers, response
    # files, etc.  Rather than maintaining an ever-growing allowlist,
    # walk the tree and fix every text file that references the old path.
    # Skip known binary extensions to avoid corrupting object files.
    _BINARY_EXTS = frozenset((
        ".o", ".a", ".so", ".gch", ".pcm", ".pch", ".d",
        ".png", ".jpg", ".gif", ".ico", ".gz", ".xz", ".bz2",
        ".wasm", ".pyc", ".qm",
    ))
    if os.path.isfile(cmake_cache) or os.path.isfile(ninja_file):
        for dirpath, _dirnames, filenames in os.walk(output_dir):
            for fname in filenames:
                if os.path.splitext(fname)[1] in _BINARY_EXTS:
                    continue
                fpath = os.path.join(dirpath, fname)
                if os.path.islink(fpath):
                    continue  # skip symlinks (may be dangling)
                try:
                    with open(fpath, "r") as f:
                        fc = f.read()
                    if build_dir in fc:
                        fc = fc.replace(build_dir, output_dir)
                        with open(fpath, "w") as f:
                            f.write(fc)
                except (UnicodeDecodeError, PermissionError, IsADirectoryError,
                        FileNotFoundError):
                    pass

    # Reset all file timestamps to a single instant so make doesn't try
    # to regenerate autotools/cmake/meson outputs.  The copytree preserves
    # original timestamps but path rewriting modifies some files, making
    # others (version.h, aclocal.m4, Makefiles) appear stale.  A uniform
    # timestamp prevents all spurious rebuilds.
    import time
    _now = time.time()
    _stamp = (_now, _now)
    for dirpath, _dirnames, filenames in os.walk(output_dir):
        for fname in filenames:
            try:
                os.utime(os.path.join(dirpath, fname), _stamp)
            except (PermissionError, OSError):
                pass

    # Create a pkg-config wrapper that always passes --define-prefix so
    # .pc files in Buck2 dep directories resolve paths correctly.
    wrapper_dir = os.path.join(output_dir, ".pkgconf-wrapper")
    os.makedirs(wrapper_dir, exist_ok=True)
    wrapper = os.path.join(wrapper_dir, "pkg-config")
    with open(wrapper, "w") as f:
        f.write('#!/bin/sh\nexec /usr/bin/pkg-config --define-prefix "$@"\n')
    os.chmod(wrapper, 0o755)
    os.environ["PATH"] = wrapper_dir + ":" + os.environ.get("PATH", "")

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

        # Auto-detect Python site-packages from dep prefixes so build-time
        # Python modules (e.g. mako for mesa) are found by custom generators.
        python_paths = []
        for bin_dir in args.path_prepend:
            usr_dir = os.path.dirname(os.path.abspath(bin_dir))
            for sp in _glob.glob(os.path.join(usr_dir, "lib", "python*", "site-packages")):
                if os.path.isdir(sp):
                    python_paths.append(sp)
        if python_paths:
            existing = os.environ.get("PYTHONPATH", "")
            os.environ["PYTHONPATH"] = ":".join(python_paths) + (":" + existing if existing else "")

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
