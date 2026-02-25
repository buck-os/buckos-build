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
import re
import shutil
import subprocess
import sys

from _env import sanitize_global_env


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


def _rewrite_file(fpath, old, new):
    """Replace old with new in fpath, preserving the original mtime."""
    stat = os.stat(fpath)
    with open(fpath, "r") as f:
        fc = f.read()
    if old not in fc:
        return
    fc = fc.replace(old, new)
    with open(fpath, "w") as f:
        f.write(fc)
    os.utime(fpath, (stat.st_atime, stat.st_mtime))


def _patch_runshared(build_dir):
    """Patch RUNSHARED assignments to preserve LD_LIBRARY_PATH from environment.

    Some packages (notably Python) generate Makefiles with:
        RUNSHARED=	LD_LIBRARY_PATH=/abs/path/to/build
    This replaces LD_LIBRARY_PATH for subprocesses, losing dep lib dirs
    set by the helper.  Appending :$$LD_LIBRARY_PATH (Make syntax for
    literal $) makes the shell expand the current environment value.
    """
    _runshared_re = re.compile(
        r'^(RUNSHARED\s*=\s*LD_LIBRARY_PATH=\S+)$',
        re.MULTILINE,
    )

    def _append_env(m):
        val = m.group(1)
        if '$$LD_LIBRARY_PATH' in val:
            return val
        return val + ':$$LD_LIBRARY_PATH'

    for dirpath, _dirnames, filenames in os.walk(build_dir):
        for fname in filenames:
            fpath = os.path.join(dirpath, fname)
            try:
                with open(fpath, 'r') as f:
                    content = f.read()
            except (UnicodeDecodeError, PermissionError, OSError):
                continue
            if 'RUNSHARED' not in content:
                continue
            new_content = _runshared_re.sub(_append_env, content)
            if new_content != content:
                try:
                    st = os.stat(fpath)
                    with open(fpath, 'w') as f:
                        f.write(new_content)
                    os.utime(fpath, (st.st_atime, st.st_mtime))
                except (PermissionError, OSError):
                    pass


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
    parser.add_argument("--hermetic-path", action="append", dest="hermetic_path", default=[],
                        help="Set PATH to only these dirs (replaces host PATH, repeatable)")
    args = parser.parse_args()

    sanitize_global_env()

    # Expose the project root so pre-cmds can resolve Buck2 artifact
    # paths (which are relative to the project root, not to the build dir).
    os.environ["PROJECT_ROOT"] = os.getcwd()

    build_dir = os.path.abspath(args.build_dir)
    output_dir = os.path.abspath(args.output_dir)

    if not os.path.isdir(build_dir):
        print(f"error: build directory not found: {build_dir}", file=sys.stderr)
        sys.exit(1)

    # Copy build tree to output dir (Buck2 outputs are read-only after creation)
    if os.path.exists(output_dir):
        shutil.rmtree(output_dir)
    shutil.copytree(build_dir, output_dir, symlinks=True)

    # Fix symlinks that break after copytree:
    #
    # 1. Self-referencing symlinks (target ".") — Buck2 records these with
    #    an empty target and fails to materialise them.  Replace with real
    #    directories.  (xfsprogs: include/disk -> .)
    #
    # 2. Absolute symlinks pointing into build_dir — copytree preserves
    #    the old absolute target, making them dangling.  Rewrite to point
    #    into output_dir instead.  (QEMU: build/Makefile -> abs/configured/Makefile)
    for dirpath, dirnames, filenames in os.walk(output_dir):
        for entries in (dirnames, filenames):
            for name in entries:
                p = os.path.join(dirpath, name)
                if not os.path.islink(p):
                    continue
                target = os.readlink(p)
                if target == ".":
                    os.unlink(p)
                    os.makedirs(p, exist_ok=True)
                elif build_dir in target:
                    os.unlink(p)
                    os.symlink(target.replace(build_dir, output_dir), p)

    # Rewrite absolute paths in build system files.
    # Both CMake and Meson embed the build dir in generated files.  After
    # copytree these paths are stale.  Do string replacement in all
    # relevant files and suppress cmake's auto-regeneration (the source
    # dir isn't available as a build action input).
    #
    # IMPORTANT: after rewriting a file we restore its original mtime so
    # make doesn't think the file changed and try to regenerate downstream
    # outputs (man pages, info files, Makefile.in, etc.).
    cmake_cache = os.path.join(output_dir, "CMakeCache.txt")
    ninja_file = os.path.join(output_dir, "build.ninja")
    if os.path.isfile(cmake_cache):
        _rewrite_file(cmake_cache, build_dir, output_dir)
        for pattern in ["cmake_install.cmake", "**/cmake_install.cmake"]:
            for fpath in _glob.glob(os.path.join(output_dir, pattern), recursive=True):
                try:
                    _rewrite_file(fpath, build_dir, output_dir)
                except (UnicodeDecodeError, PermissionError, FileNotFoundError):
                    pass
        # Rewrite build.ninja and suppress cmake regeneration.
        if os.path.isfile(ninja_file):
            stat = os.stat(ninja_file)
            with open(ninja_file, "r") as f:
                content = f.read()
            content = content.replace(build_dir, output_dir)
            content = re.sub(
                r'^build build\.ninja:.*?(?=\n(?:build |$))',
                '# cmake regeneration suppressed by build_helper',
                content, count=1, flags=re.MULTILINE | re.DOTALL,
            )
            with open(ninja_file, "w") as f:
                f.write(content)
            os.utime(ninja_file, (stat.st_atime, stat.st_mtime))
    elif os.path.isfile(ninja_file):
        stat = os.stat(ninja_file)
        with open(ninja_file, "r") as f:
            content = f.read()
        if build_dir in content:
            content = content.replace(build_dir, output_dir)
        content = re.sub(
            r'^build build\.ninja:.*?(?=\n(?:build |$))',
            '# meson regeneration suppressed by build_helper',
            content, count=1, flags=re.MULTILINE | re.DOTALL,
        )
        with open(ninja_file, "w") as f:
            f.write(content)
        os.utime(ninja_file, (stat.st_atime, stat.st_mtime))

    # Rewrite stale absolute paths in autotools Makefiles, libtool, config.status.
    for pattern in ["Makefile", "**/Makefile", "**/Makefile.in",
                     "libtool", "config.status", "**/libtool"]:
        for fpath in _glob.glob(os.path.join(output_dir, pattern), recursive=True):
            try:
                _rewrite_file(fpath, build_dir, output_dir)
            except (UnicodeDecodeError, PermissionError, FileNotFoundError):
                pass

    # Comprehensive rewrite of stale build-dir paths.  Autotools configure
    # generates scripts (tests/*, libtool wrappers) with hardcoded paths
    # that the pattern-based rewrite above misses.  cmake/meson similarly
    # embed paths throughout the tree.  Detect by config.status (autotools),
    # CMakeCache.txt (cmake), or build.ninja (meson/cmake).
    _BINARY_EXTS = frozenset((
        ".o", ".a", ".so", ".gch", ".pcm", ".pch", ".d",
        ".png", ".jpg", ".gif", ".ico", ".gz", ".xz", ".bz2",
        ".wasm", ".pyc", ".qm",
    ))
    config_status = os.path.join(output_dir, "config.status")
    _top_makefile = os.path.join(output_dir, "Makefile")
    _needs_comprehensive = (os.path.isfile(cmake_cache)
                            or os.path.isfile(ninja_file)
                            or os.path.isfile(config_status)
                            or os.path.isfile(_top_makefile))
    if _needs_comprehensive:
        for dirpath, _dirnames, filenames in os.walk(output_dir):
            for fname in filenames:
                if os.path.splitext(fname)[1] in _BINARY_EXTS:
                    continue
                fpath = os.path.join(dirpath, fname)
                if os.path.islink(fpath):
                    continue
                try:
                    _rewrite_file(fpath, build_dir, output_dir)
                except (UnicodeDecodeError, PermissionError, IsADirectoryError,
                        FileNotFoundError):
                    pass

    # Rewrite paths in meson's install.dat (binary pickle).  The text
    # rewrite above skips it due to UnicodeDecodeError.  Unpickle, patch
    # path attributes, and re-pickle so `meson install` finds files at
    # the new location.
    _install_dat = os.path.join(output_dir, "meson-private", "install.dat")
    if os.path.isfile(_install_dat):
        import pickle as _pickle

        class _StubUnpickler(_pickle.Unpickler):
            """Unpickler that stubs missing modules (e.g. mesonbuild).

            install.dat contains serialised mesonbuild.* objects but the
            build_helper pex doesn't ship mesonbuild.  We only need to
            walk __dict__ and rewrite strings, so a generic stub class
            that preserves attributes is sufficient.
            """
            def find_class(self, module, name):
                try:
                    return super().find_class(module, name)
                except (ModuleNotFoundError, AttributeError):
                    # Return a stub that accepts arbitrary pickle state
                    type_key = f"{module}.{name}"
                    if type_key not in _stub_cache:
                        class _Stub:
                            def __reduce__(self):
                                return (_make_stub, (type_key,), self.__dict__)
                            def __setstate__(self, state):
                                if isinstance(state, dict):
                                    self.__dict__.update(state)
                        _Stub.__qualname__ = _Stub.__name__ = name
                        _Stub.__module__ = module
                        _stub_cache[type_key] = _Stub
                    return _stub_cache[type_key]

        _stub_cache = {}

        def _make_stub(type_key):
            return _stub_cache[type_key]()

        stat = os.stat(_install_dat)
        with open(_install_dat, "rb") as f:
            _idata = _StubUnpickler(f).load()
        def _patch_paths(obj, old, new):
            """Recursively replace old prefix with new in string attributes."""
            if isinstance(obj, str):
                return obj.replace(old, new) if old in obj else obj
            if isinstance(obj, list):
                return [_patch_paths(item, old, new) for item in obj]
            if isinstance(obj, tuple):
                return tuple(_patch_paths(item, old, new) for item in obj)
            if hasattr(obj, "__dict__"):
                for k, v in obj.__dict__.items():
                    patched = _patch_paths(v, old, new)
                    if patched is not v:
                        setattr(obj, k, patched)
            return obj
        _patch_paths(_idata, build_dir, output_dir)
        with open(_install_dat, "wb") as f:
            _pickle.dump(_idata, f)
        os.utime(_install_dat, (stat.st_atime, stat.st_mtime))

    # Detect and rewrite stale cross-machine paths.  When Buck2 restores
    # cached configure outputs from a different machine, files contain the
    # original machine's project root (e.g. /home/patso/repos/foo) which
    # doesn't exist here.  Scan config.status for /buck-out/ prefixes that
    # differ from the current project root and rewrite them everywhere.
    _BUCK_OUT_RE = re.compile(r'(/[^\s"\']+?)/buck-out/')
    _stale_root = None
    _current_root = os.getcwd()
    # Check config.status (autotools), CMakeCache.txt (cmake), and
    # build.ninja (meson/cmake) for stale project root prefixes.
    _stale_candidates = list(_glob.glob(os.path.join(output_dir, "**/config.status"), recursive=True))
    if os.path.isfile(cmake_cache):
        _stale_candidates.append(cmake_cache)
    if os.path.isfile(ninja_file):
        _stale_candidates.append(ninja_file)
    # Also check top-level Makefile — build systems that don't generate
    # config.status/CMakeCache.txt/build.ninja (e.g. OpenSSL's Configure)
    # still embed absolute paths in their Makefiles.
    if os.path.isfile(_top_makefile) and not _stale_candidates:
        _stale_candidates.append(_top_makefile)
    for _cs in _stale_candidates:
        try:
            with open(_cs, "r") as f:
                _cs_content = f.read()
        except (UnicodeDecodeError, PermissionError, OSError):
            continue
        _m = _BUCK_OUT_RE.search(_cs_content)
        if _m and _m.group(1) != _current_root:
            _stale_root = _m.group(1)
            break
    if _stale_root:
        # Rewrite symlink targets
        for dirpath, dirnames, filenames in os.walk(output_dir):
            for entries in (dirnames, filenames):
                for name in entries:
                    p = os.path.join(dirpath, name)
                    if not os.path.islink(p):
                        continue
                    target = os.readlink(p)
                    if _stale_root in target:
                        os.unlink(p)
                        os.symlink(target.replace(_stale_root, _current_root), p)
        # Rewrite text files
        for dirpath, _dirnames, filenames in os.walk(output_dir):
            for fname in filenames:
                if os.path.splitext(fname)[1] in _BINARY_EXTS:
                    continue
                fpath = os.path.join(dirpath, fname)
                if os.path.islink(fpath):
                    continue
                try:
                    _rewrite_file(fpath, _stale_root, _current_root)
                except (UnicodeDecodeError, PermissionError, IsADirectoryError,
                        FileNotFoundError):
                    pass

    # Reset all file timestamps to a single fixed instant so make doesn't
    # try to regenerate autotools/cmake/meson outputs.  The copytree
    # preserves original timestamps but path rewriting modifies some
    # files, making others (version.h, aclocal.m4, Makefiles) appear
    # stale.  A uniform timestamp prevents all spurious rebuilds.
    _epoch = float(os.environ.get("SOURCE_DATE_EPOCH", "315576000"))
    _stamp = (_epoch, _epoch)
    for dirpath, _dirnames, filenames in os.walk(output_dir):
        for fname in filenames:
            try:
                os.utime(os.path.join(dirpath, fname), _stamp)
            except (PermissionError, OSError):
                pass

    # Patch RUNSHARED assignments so LD_LIBRARY_PATH from the environment
    # survives into subprocesses (e.g. Python test-imports during compile).
    _patch_runshared(output_dir)

    # Create a pkg-config wrapper that always passes --define-prefix so
    # .pc files in Buck2 dep directories resolve paths correctly.
    wrapper_dir = os.path.join(output_dir, ".pkgconf-wrapper")
    os.makedirs(wrapper_dir, exist_ok=True)
    wrapper = os.path.join(wrapper_dir, "pkg-config")
    with open(wrapper, "w") as f:
        f.write('#!/bin/sh\n'
                'SELF_DIR="$(cd "$(dirname "$0")" && pwd)"\n'
                'PATH="${PATH#"$SELF_DIR:"}" exec pkg-config --define-prefix "$@"\n')
    os.chmod(wrapper, 0o755)

    # Apply extra environment variables
    for entry in args.extra_env:
        key, _, value = entry.partition("=")
        if key:
            os.environ[key] = _resolve_env_paths(value)
    if args.hermetic_path:
        os.environ["PATH"] = ":".join(os.path.abspath(p) for p in args.hermetic_path)
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
            _existing = os.environ.get("LD_LIBRARY_PATH", "")
            os.environ["LD_LIBRARY_PATH"] = ":".join(_lib_dirs) + (":" + _existing if _existing else "")
    if args.path_prepend:
        prepend = ":".join(os.path.abspath(p) for p in args.path_prepend if os.path.isdir(p))
        if prepend:
            os.environ["PATH"] = prepend + ":" + os.environ.get("PATH", "")
        # Derive LD_LIBRARY_PATH from dep bin dirs so dynamically linked
        # libraries (e.g. libbz2.so for Python's _bz2 module) are found
        # at build time when the build process test-imports extensions.
        _dep_lib_dirs = []
        for _bp in args.path_prepend:
            _parent = os.path.dirname(os.path.abspath(_bp))
            for _ld in ("lib", "lib64"):
                _d = os.path.join(_parent, _ld)
                if os.path.isdir(_d):
                    _dep_lib_dirs.append(_d)
        if _dep_lib_dirs:
            _existing = os.environ.get("LD_LIBRARY_PATH", "")
            os.environ["LD_LIBRARY_PATH"] = ":".join(_dep_lib_dirs) + (":" + _existing if _existing else "")

    # Auto-detect Python site-packages from dep prefixes so build-time
    # Python modules (e.g. mako for mesa) are found by custom generators.
    _path_sources = list(args.hermetic_path) + list(args.path_prepend)
    if _path_sources:
        python_paths = []
        for bin_dir in _path_sources:
            usr_dir = os.path.dirname(os.path.abspath(bin_dir))
            for pattern in ("lib/python*/site-packages", "lib/python*/dist-packages",
                            "lib64/python*/site-packages", "lib64/python*/dist-packages"):
                for sp in _glob.glob(os.path.join(usr_dir, pattern)):
                    if os.path.isdir(sp):
                        python_paths.append(sp)
        if python_paths:
            existing = os.environ.get("PYTHONPATH", "")
            os.environ["PYTHONPATH"] = ":".join(python_paths) + (":" + existing if existing else "")

    # Prepend pkg-config wrapper to PATH (after hermetic/prepend logic
    # so the wrapper is always available regardless of PATH mode)
    os.environ["PATH"] = wrapper_dir + ":" + os.environ.get("PATH", "")

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

    # Re-run symlink fix after build — some packages (xfsprogs) recreate
    # self-referencing symlinks during make.
    for dirpath, dirnames, _filenames in os.walk(output_dir):
        for d in dirnames:
            p = os.path.join(dirpath, d)
            if os.path.islink(p) and os.readlink(p) == ".":
                os.unlink(p)
                os.makedirs(p, exist_ok=True)


if __name__ == "__main__":
    main()
