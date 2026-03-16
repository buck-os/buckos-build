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

from _env import apply_cache_config, clean_env, derive_lib_paths, file_prefix_map_flags, filter_path_flags, find_buckos_shell, find_dep_python3, preferred_linker_flag, register_cleanup, rewrite_shebangs, sanitize_filenames, setup_ccache_symlinks, sysroot_lib_paths, write_pkg_config_wrapper


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

    _FLAG_PREFIXES = ["-I", "-L", "-Wl,-rpath-link,", "-Wl,-rpath,", "-specs=", "--sysroot="]

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
    _host_path = os.environ.get("PATH", "")

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
    parser.add_argument("--allow-host-path", action="store_true",
                        help="Allow host PATH (bootstrap escape hatch)")
    parser.add_argument("--hermetic-empty", action="store_true",
                        help="Start with empty PATH (populated by --path-prepend)")
    parser.add_argument("--ld-linux", default=None,
                        help="Buckos ld-linux path (disables posix_spawn)")
    parser.add_argument("--cflags-file", default=None,
                        help="File with CFLAGS (one per line, from tset projection)")
    parser.add_argument("--ldflags-file", default=None,
                        help="File with LDFLAGS (one per line, from tset projection)")
    parser.add_argument("--pkg-config-file", default=None,
                        help="File with PKG_CONFIG_PATH entries (one per line, from tset projection)")
    parser.add_argument("--path-file", default=None,
                        help="File with PATH dirs to prepend (one per line, from tset projection)")
    parser.add_argument("--lib-dirs-file", default=None,
                        help="File with lib dirs for LD_LIBRARY_PATH (one per line, from tset projection)")
    parser.add_argument("--path-append-file", default=None,
                        help="File with dep bin dirs to append to PATH (one per line, from tset projection)")
    args = parser.parse_args()

    # Read flag files early — tset-propagated values are base defaults.
    def _read_flag_file(path):
        if not path:
            return []
        with open(path) as f:
            return [line.rstrip("\n") for line in f if line.strip()]

    file_cflags = filter_path_flags(_read_flag_file(args.cflags_file))
    file_ldflags = filter_path_flags(_read_flag_file(args.ldflags_file))
    file_pkg_config = [p for p in _read_flag_file(args.pkg_config_file) if os.path.isdir(os.path.abspath(p))]
    file_path_dirs = _read_flag_file(args.path_file)
    file_lib_dirs = _read_flag_file(args.lib_dirs_file)
    file_path_append_dirs = _read_flag_file(args.path_append_file)

    env = clean_env()

    # Expose the project root so pre-cmds can resolve Buck2 artifact
    # paths (which are relative to the project root, not to the build dir).
    env["PROJECT_ROOT"] = os.getcwd()

    build_dir = os.path.abspath(args.build_dir)
    output_dir = os.path.abspath(args.output_dir)
    register_cleanup(output_dir)

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
                r'^build build\.ninja[ :].*?(?=\n(?:build |$))',
                'build build.ninja: phony',
                content, count=1, flags=re.MULTILINE | re.DOTALL,
            )
            if 'build build.ninja: phony' not in content:
                content = 'build build.ninja: phony\n' + content
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
            r'^build build\.ninja[ :].*?(?=\n(?:build |$))',
            'build build.ninja: phony',
            content, count=1, flags=re.MULTILINE | re.DOTALL,
        )
        if 'build build.ninja: phony' not in content:
            content = 'build build.ninja: phony\n' + content
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

    # Suppress meson/cmake regeneration in ALL build.ninja files.
    # Packages like QEMU wrap meson inside autotools, placing build.ninja
    # in a subdirectory (build/build.ninja) that the top-level check
    # above misses.  The configure-phase source tree isn't an input to
    # this action; regeneration would fail looking for files that only
    # existed in the configure action's output directory.
    _regen_re = re.compile(
        r'^build build\.ninja[ :].*?(?=\n(?:build |$))',
        re.MULTILINE | re.DOTALL,
    )
    for _nf in _glob.glob(os.path.join(output_dir, "**/build.ninja"), recursive=True):
        try:
            _nf_stat = os.stat(_nf)
            with open(_nf, "r") as f:
                _nf_content = f.read()
            _nf_new = _regen_re.sub(
                'build build.ninja: phony',
                _nf_content, count=1,
            )
            if 'build build.ninja: phony' not in _nf_new:
                _nf_new = 'build build.ninja: phony\n' + _nf_new
            if _nf_new != _nf_content:
                with open(_nf, "w") as f:
                    f.write(_nf_new)
                os.utime(_nf, (_nf_stat.st_atime, _nf_stat.st_mtime))
        except (UnicodeDecodeError, PermissionError, FileNotFoundError):
            pass

    # Rewrite paths in meson's install.dat (binary pickle).  The text
    # rewrite above skips it due to UnicodeDecodeError.  Unpickle, patch
    # path attributes, and re-pickle so `meson install` finds files at
    # the new location.
    #
    # install.dat contains serialised mesonbuild.* objects.  We must use
    # the REAL mesonbuild classes (not stubs) so the re-pickled file is
    # loadable by meson's safe unpickler.  Find mesonbuild from the
    # hermetic PATH's Python site-packages and add it to sys.path
    # temporarily.
    import pickle as _pickle

    def _patch_pickle_paths(obj, old, new):
        """Recursively replace old prefix with new in string attributes."""
        if isinstance(obj, str):
            return obj.replace(old, new) if old in obj else obj
        if isinstance(obj, list):
            return [_patch_pickle_paths(item, old, new) for item in obj]
        if isinstance(obj, tuple):
            return tuple(_patch_pickle_paths(item, old, new) for item in obj)
        if hasattr(obj, "__dict__"):
            for k, v in obj.__dict__.items():
                patched = _patch_pickle_paths(v, old, new)
                if patched is not v:
                    setattr(obj, k, patched)
        return obj

    # Locate mesonbuild from hermetic path or path-prepend dirs
    _meson_added_paths = []
    for _bp in list(args.hermetic_path) + list(args.path_prepend):
        _parent = os.path.dirname(os.path.abspath(_bp))
        for _pattern in ("lib/python*/site-packages", "lib64/python*/site-packages"):
            for _sp in _glob.glob(os.path.join(_parent, _pattern)):
                if os.path.isdir(os.path.join(_sp, "mesonbuild")):
                    if _sp not in sys.path:
                        sys.path.insert(0, _sp)
                        _meson_added_paths.append(_sp)

    _install_dat = os.path.join(output_dir, "meson-private", "install.dat")
    if os.path.isfile(_install_dat):
        try:
            _dat_stat = os.stat(_install_dat)
            with open(_install_dat, "rb") as f:
                _idata = _pickle.load(f)
            _patch_pickle_paths(_idata, build_dir, output_dir)
            with open(_install_dat, "wb") as f:
                _pickle.dump(_idata, f)
            os.utime(_install_dat, (_dat_stat.st_atime, _dat_stat.st_mtime))
        except Exception as _e:
            print(f"warning: could not rewrite install.dat: {_e}", file=sys.stderr)

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
        # Second pass: build_dir→output_dir.  The first comprehensive
        # rewrite ran before the stale root fix and couldn't match
        # because files contained the stale machine's paths.  Now that
        # stale_root→current_root is done, build_dir will match.
        for dirpath, dirnames, filenames in os.walk(output_dir):
            for entries in (dirnames, filenames):
                for name in entries:
                    p = os.path.join(dirpath, name)
                    if not os.path.islink(p):
                        continue
                    target = os.readlink(p)
                    if build_dir in target:
                        os.unlink(p)
                        os.symlink(target.replace(build_dir, output_dir), p)
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
        # Also fix the meson install.dat pickle which the text rewrite
        # skips (binary).  Apply both stale_root→current_root and
        # build_dir→output_dir so paths resolve to the new location.
        # Uses real mesonbuild classes (added to sys.path earlier) so
        # the re-pickled file is loadable by meson's safe unpickler.
        if os.path.isfile(_install_dat):
            try:
                _dat_stat2 = os.stat(_install_dat)
                with open(_install_dat, "rb") as f:
                    _idata = _pickle.load(f)
                _patch_pickle_paths(_idata, _stale_root, _current_root)
                _patch_pickle_paths(_idata, build_dir, output_dir)
                with open(_install_dat, "wb") as f:
                    _pickle.dump(_idata, f)
                os.utime(_install_dat, (_dat_stat2.st_atime, _dat_stat2.st_mtime))
            except Exception as _e:
                print(f"warning: could not rewrite install.dat (stale root): {_e}",
                      file=sys.stderr)

    # Reset all file timestamps to a single fixed instant so make doesn't
    # try to regenerate autotools/cmake/meson outputs.  The copytree
    # preserves original timestamps but path rewriting modifies some
    # files, making others (version.h, aclocal.m4, Makefiles) appear
    # stale.  A uniform timestamp prevents all spurious rebuilds.
    _epoch = float(env.get("SOURCE_DATE_EPOCH", "315576000"))
    _stamp = (_epoch, _epoch)
    for dirpath, _dirnames, filenames in os.walk(output_dir):
        for fname in filenames:
            try:
                os.utime(os.path.join(dirpath, fname), _stamp)
            except (PermissionError, OSError):
                pass

    # Suppress Makefile-level reconfiguration.  Build systems like QEMU
    # wrap meson inside autotools; their build/Makefile has rules that
    # re-run config.status when config-host.mak appears stale.  cmake-
    # generated Makefiles run cmake --check-build-system which fails
    # when the built cmake has stale paths.  In our split-action model,
    # configuration happened in a previous action — the build phase must
    # never reconfigure.  Append no-op overrides (GNU Make uses the last
    # recipe for a given target) so these rules become harmless.
    _CLEAN_TARGETS = frozenset(("distclean", "clean", "maintainer-clean",
                                "mostlyclean", "realclean"))
    _RECONFIG_TRIGGERS = ('config.status', 'check-build-system')
    _RECONFIG_RECIPE_PATTERNS = ('./config.status', '$(SHELL) config.status',
                                 '--reconfigure', '--check-build-system')
    for _mf in _glob.glob(os.path.join(output_dir, "**/Makefile"), recursive=True):
        try:
            with open(_mf, "r") as f:
                _mf_content = f.read()
        except (UnicodeDecodeError, PermissionError, OSError):
            continue
        if not any(t in _mf_content for t in _RECONFIG_TRIGGERS):
            continue
        _mf_stat = os.stat(_mf)
        # Scan for targets whose recipes invoke config.status (as a
        # command, not in rm/echo), meson --reconfigure, or cmake
        # --check-build-system.  Track whether the target uses ::
        # (double-colon) rules.
        _suppressed = {}  # target -> "::" or ":"
        _current_target = None
        _current_colon = ":"
        for line in _mf_content.splitlines():
            if line.startswith('\t'):
                if (_current_target
                        and _current_target not in _CLEAN_TARGETS
                        and any(p in line for p in _RECONFIG_RECIPE_PATTERNS)):
                    _suppressed[_current_target] = _current_colon
            elif ':' in line and not line.startswith(('#', '\t', '.PHONY')):
                # Detect :: vs : rules
                colon_idx = line.index(':')
                _current_colon = "::" if line[colon_idx:colon_idx+2] == "::" else ":"
                target_part = line[:colon_idx].strip()
                if target_part and not target_part.startswith(('$', '@', '-')):
                    _current_target = target_part
                else:
                    _current_target = None
            else:
                _current_target = None
        if _suppressed:
            _overrides = ["\n# Reconfiguration suppressed by build_helper"]
            # Exclude suppressed targets from $(ninja-targets) to avoid
            # circular deps (e.g. run-ninja → config-host.mak → run-ninja
            # in QEMU's meson+autotools hybrid Makefile).  makefile-targets
            # is the filter-out list; appending is harmless if the variable
            # is unused by this particular Makefile.
            _overrides.append(
                "makefile-targets += " + " ".join(sorted(_suppressed)))
            for _t in sorted(_suppressed):
                _overrides.append(f"{_t}{_suppressed[_t]} ;")
            with open(_mf, "a") as f:
                f.write("\n".join(_overrides) + "\n")
            os.utime(_mf, (_mf_stat.st_atime, _mf_stat.st_mtime))

    # Patch RUNSHARED assignments so LD_LIBRARY_PATH from the environment
    # survives into subprocesses (e.g. Python test-imports during compile).
    _patch_runshared(output_dir)

    # Apply extra environment variables first (toolchain flags like -march).
    for entry in args.extra_env:
        key, _, value = entry.partition("=")
        if key:
            env[key] = _resolve_env_paths(value)

    apply_cache_config(env)

    # Scrub absolute build paths from debug info and __FILE__ expansions.
    pfm = " ".join(file_prefix_map_flags())
    for var in ("CFLAGS", "CXXFLAGS"):
        existing = env.get(var, "")
        env[var] = (pfm + " " + existing).strip() if existing else pfm

    # Prepend flag file values — dep-provided -I/-L flags must appear before
    # toolchain flags so headers/libs from deps are found.  Extract -I flags
    # for CPPFLAGS/CXXFLAGS propagation (autotools: CPPFLAGS→C+C++, CFLAGS→C only).
    if file_cflags:
        existing = env.get("CFLAGS", "")
        merged = _resolve_env_paths(" ".join(file_cflags))
        env["CFLAGS"] = (merged + " " + existing).strip() if existing else merged
        file_include_flags = [f for f in file_cflags if f.startswith("-I")]
        if file_include_flags:
            inc_str = _resolve_env_paths(" ".join(file_include_flags))
            for var in ("CPPFLAGS", "CXXFLAGS"):
                existing = env.get(var, "")
                env[var] = (inc_str + " " + existing).strip() if existing else inc_str
    if file_ldflags:
        existing = env.get("LDFLAGS", "")
        merged = _resolve_env_paths(" ".join(file_ldflags))
        env["LDFLAGS"] = (merged + " " + existing).strip() if existing else merged
    if file_pkg_config:
        existing = env.get("PKG_CONFIG_PATH", "")
        merged = _resolve_env_paths(":".join(file_pkg_config))
        env["PKG_CONFIG_PATH"] = (merged + ":" + existing).rstrip(":") if existing else merged
    if args.hermetic_path:
        env["PATH"] = ":".join(os.path.abspath(p) for p in args.hermetic_path)
        # Derive LD_LIBRARY_PATH from hermetic bin dirs so dynamically
        # linked tools (e.g. cross-ar needing libzstd) find their libs.
        # With sysroot ld-linux and per-package RPATH, buckos binaries
        # find deps via RPATH.  Skip LD_LIBRARY_PATH to avoid
        # contaminating host tools.
        if not args.ld_linux:
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

    # Create gcc/cc/g++ symlinks so scripts that invoke bare `gcc`
    # (e.g. busybox scripts/gcc-version.sh) find the buckos compiler.
    # These are real symlinks, not wrapper scripts — no recursion risk.
    # Use scratch dir (not build_dir which is a buck2 input artifact).
    _cc_val = env.get("CC", "")
    if _cc_val:
        _cc_parts = _cc_val.split()
        if _cc_parts and os.path.basename(_cc_parts[0]) == "ccache":
            _cc_parts = _cc_parts[1:]
        _cc_bin = os.path.abspath(_cc_parts[0]) if _cc_parts else ""
        if _cc_bin and os.path.isfile(_cc_bin):
            _scratch = env.get("BUCK_SCRATCH_PATH", env.get("TMPDIR", "/tmp"))
            _symlink_dir = os.path.join(os.path.abspath(_scratch), "cc-symlinks")
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

    # ccache masquerade symlinks — prepended before gcc symlinks so
    # ccache intercepts gcc invocations.  ccache skips itself by inode
    # and finds the real gcc in the next PATH entry.
    _scratch = env.get("BUCK_SCRATCH_PATH", env.get("TMPDIR", "/tmp"))
    setup_ccache_symlinks(env, _scratch)

    # Append dep bin dirs for *-config discovery scripts (gpg-error-config,
    # curl-config, etc.).  Appended so seed/host tools take priority.
    if file_path_append_dirs:
        append = ":".join(os.path.abspath(p) for p in file_path_append_dirs if os.path.isdir(p))
        if append:
            env["PATH"] = env.get("PATH", "") + ":" + append

    # Merge tset-provided lib dirs into LD_LIBRARY_PATH.  Extension
    # modules (e.g. Python's _sqlite3.so) are test-imported during make;
    # they lack RPATH for dep prefixes, so LD_LIBRARY_PATH is needed
    # even with sysroot ld-linux.  Exclude dirs with libc.so.6 to avoid
    # poisoning host tools with sysroot glibc.
    if file_lib_dirs:
        resolved = [
            os.path.abspath(d) for d in file_lib_dirs
            if os.path.isdir(d) and not os.path.exists(os.path.join(os.path.abspath(d), "libc.so.6"))
        ]
        if resolved:
            existing = env.get("LD_LIBRARY_PATH", "")
            merged = ":".join(resolved)
            env["LD_LIBRARY_PATH"] = (merged + ":" + existing).rstrip(":") if existing else merged

    # Derive GCONV_PATH, BISON_PKGDATADIR, GETTEXTDATADIRS, and
    # LD_LIBRARY_PATH from hermetic and path-prepend dirs.  Host_dep
    # tools (gdk-pixbuf-pixdata, glib-compile-resources, etc.) use
    # the sysroot ld-linux but need LD_LIBRARY_PATH for non-sysroot
    # package libs (e.g. libglib-2.0.so from the glib package).
    # derive_lib_paths excludes dirs containing libc.so.6 to prevent
    # loading buckos glibc via LD_LIBRARY_PATH.
    if args.hermetic_path:
        derive_lib_paths(args.hermetic_path, env)
    derive_lib_paths(all_path_prepend, env)

    # Auto-detect Python site-packages from dep prefixes so build-time
    # Python modules (e.g. mako for mesa) are found by custom generators.
    _path_sources = list(args.hermetic_path) + list(all_path_prepend) + list(file_path_append_dirs)
    if _path_sources or file_lib_dirs:
        python_paths = []
        _seen_sp = set()
        for bin_dir in _path_sources:
            usr_dir = os.path.dirname(os.path.abspath(bin_dir))
            for pattern in ("lib/python*/site-packages", "lib/python*/dist-packages",
                            "lib64/python*/site-packages", "lib64/python*/dist-packages"):
                for sp in _glob.glob(os.path.join(usr_dir, pattern)):
                    if os.path.isdir(sp) and sp not in _seen_sp:
                        python_paths.append(sp)
                        _seen_sp.add(sp)
        # Also scan tset-provided lib dirs — deps without bin dirs (e.g.
        # python packaging) only expose lib dirs via the tset.
        for lib_dir in file_lib_dirs:
            abs_ld = os.path.abspath(lib_dir)
            for pattern in ("python*/site-packages", "python*/dist-packages"):
                for sp in _glob.glob(os.path.join(abs_ld, pattern)):
                    if os.path.isdir(sp) and sp not in _seen_sp:
                        python_paths.append(sp)
                        _seen_sp.add(sp)
        if python_paths:
            existing = env.get("PYTHONPATH", "")
            env["PYTHONPATH"] = ":".join(python_paths) + (":" + existing if existing else "")

    # Replace host python with buckos python in build.ninja files.
    # Dep LD_LIBRARY_PATH includes buckos libs; host python loading them
    # causes ABI mismatches (e.g. pyexpat loading buckos libexpat).
    # Buckos python is ABI-compatible so we redirect all invocations.
    #
    # Two vectors:
    # 1. Explicit host python paths: meson/cmake embed the absolute path
    #    of the python that ran during configure.
    # 2. Embedded pyvenv: packages like QEMU create pyvenv/bin/python
    #    (symlinked to host python) and pyvenv/bin/meson.  build.ninja
    #    references these absolute paths for custom commands.  Replace
    #    them with buckos python and buckos meson from deps.
    _dep_python3 = None
    _dep_meson = None
    for _bp in list(args.hermetic_path) + list(all_path_prepend):
        _abs_bp = os.path.abspath(_bp)
        if not _dep_python3:
            _candidate = os.path.join(_abs_bp, "python3")
            if os.path.isfile(_candidate):
                _dep_python3 = _candidate
        if not _dep_meson:
            _candidate = os.path.join(_abs_bp, "meson")
            if os.path.isfile(_candidate):
                _dep_meson = _candidate
    if _dep_python3:
        env.setdefault("PYTHON", _dep_python3)
        env.setdefault("PYTHON3", _dep_python3)
    _host_python = shutil.which("python3") if _dep_python3 else None
    if _dep_python3 and _host_python:
        _dep_python3_abs = os.path.abspath(_dep_python3)
        # Skip replacement if host python is a substring of dep python —
        # str.replace would corrupt the already-correct dep path by
        # matching "/usr/bin/python3" inside ".../installed/usr/bin/python3".
        _skip_host_replace = (_host_python != _dep_python3_abs and
                              _host_python in _dep_python3_abs)
        _all_ninja_files = _glob.glob(
            os.path.join(output_dir, "**/build.ninja"), recursive=True,
        )
        _top_ninja = os.path.join(output_dir, "build.ninja")
        if os.path.isfile(_top_ninja) and _top_ninja not in _all_ninja_files:
            _all_ninja_files.append(_top_ninja)
        # Collect pyvenv bin dirs that exist in the build tree.
        # Register longest paths first — "python3" before "python" — so
        # str.replace doesn't match a substring and leave a trailing "3"
        # (e.g. replacing "pyvenv/bin/python" inside "pyvenv/bin/python3"
        # would produce ".../python33" instead of ".../python3").
        _pyvenv_replacements = []
        for _pvd in _glob.glob(os.path.join(output_dir, "**/pyvenv/bin"), recursive=True):
            _pv_python3 = os.path.join(_pvd, "python3")
            _pv_python = os.path.join(_pvd, "python")
            if os.path.exists(_pv_python3):
                _pyvenv_replacements.append((_pv_python3, _dep_python3_abs))
            elif os.path.exists(_pv_python):
                _pyvenv_replacements.append((_pv_python, _dep_python3_abs))
            _pv_meson = os.path.join(_pvd, "meson")
            if os.path.exists(_pv_meson) and _dep_meson:
                _pyvenv_replacements.append((_pv_meson, os.path.abspath(_dep_meson)))
        # Sort longest-first to avoid substring collisions
        _pyvenv_replacements.sort(key=lambda x: len(x[0]), reverse=True)
        for _nf in _all_ninja_files:
            try:
                _nf_stat = os.stat(_nf)
                with open(_nf, "r") as f:
                    _nf_content = f.read()
                _nf_orig = _nf_content
                # Replace host python references.  Use regex with
                # lookbehind and lookahead to avoid corrupting longer
                # paths that contain the host python as a substring —
                # e.g. .../installed/usr/bin/python3 contains
                # /usr/bin/python3.  Only match when preceded by
                # whitespace/= (path start) and not followed by path
                # continuation chars.
                if not _skip_host_replace and _host_python in _nf_content:
                    _nf_content = re.sub(
                        r'(?<=[\s=])' + re.escape(_host_python) + r'(?![.\w/])',
                        _dep_python3_abs,
                        _nf_content,
                    )
                # Replace pyvenv python/meson references
                for _old, _new in _pyvenv_replacements:
                    if _old in _nf_content:
                        _nf_content = _nf_content.replace(_old, _new)
                if _nf_content != _nf_orig:
                    with open(_nf, "w") as f:
                        f.write(_nf_content)
                    os.utime(_nf, (_nf_stat.st_atime, _nf_stat.st_mtime))
            except (UnicodeDecodeError, PermissionError, FileNotFoundError):
                pass

    # Create a pkg-config wrapper that always passes --define-prefix so
    # .pc files in Buck2 dep directories resolve paths correctly.
    wrapper_dir = write_pkg_config_wrapper(os.path.join(output_dir, ".pkgconf-wrapper"), python=find_dep_python3(env))

    # Prepend pkg-config wrapper to PATH (after hermetic/prepend logic
    # so the wrapper is always available regardless of PATH mode)
    env["PATH"] = wrapper_dir + ":" + env.get("PATH", "")

    # When buckos ld-linux is available, add sysroot lib dirs to
    # LD_LIBRARY_PATH and disable posix_spawn for padded interpreters.
    if args.ld_linux:
        sysroot_lib_paths(args.ld_linux, env)
        _ld_flag = preferred_linker_flag(env)
        if _ld_flag:
            existing = env.get("LDFLAGS", "")
            env["LDFLAGS"] = (existing + " " + _ld_flag).strip()

    # Find buckos shell for pre-cmds and make SHELL override.
    _buckos_bash = find_buckos_shell(env)
    if _buckos_bash:
        env["SHELL"] = _buckos_bash
        # Rewrite shebangs in the build tree so scripts invoked by
        # make recipes use buckos shell instead of host /bin/sh.
        rewrite_shebangs(output_dir, env)

    # Set HOSTCC from CC so Kconfig (busybox, kernel) builds don't
    # search PATH for bare `gcc`.  HOSTCC ?= gcc in Makefiles.
    if "CC" in env and "HOSTCC" not in env:
        env["HOSTCC"] = env["CC"]

    # Run pre-build commands (e.g. Kconfig setup)
    for cmd_str in args.pre_cmds:
        result = subprocess.run(cmd_str, shell=True, cwd=output_dir, env=env,
                                executable=_buckos_bash)
        if result.returncode != 0:
            print(f"error: pre-cmd failed with exit code {result.returncode}: {cmd_str}",
                  file=sys.stderr)
            sys.exit(1)

    if args.skip_make:
        sanitize_filenames(output_dir)
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

    # Inject CC/CXX/AR as make command-line overrides for Makefile-only
    # packages (skip_configure=True).  Kbuild-style Makefiles (busybox,
    # pciutils) define CC=gcc internally, which overrides env CC.  Make
    # command-line variables have highest precedence.  Skip this for
    # autotools packages that ran configure — configure already captured
    # CC and the Makefile uses the configured value.
    if args.build_system == "make" and not os.path.exists(os.path.join(make_dir, "config.status")):
        for _var in ("CC", "CXX", "AR"):
            _val = env.get(_var, "")
            if _val and not any(a.startswith(f"{_var}=") for a in args.make_args):
                cmd.append(f"{_var}={_val}")

    # Override make's SHELL so recipe lines use buckos bash instead of
    # /bin/sh (which doesn't exist on remote execution workers).
    if args.build_system == "make" and _buckos_bash:
        _has_shell_arg = any(a.startswith("SHELL=") for a in args.make_args)
        if not _has_shell_arg:
            cmd.append(f"SHELL={_buckos_bash}")

    # Wrap with unshare --net for network isolation (reproducibility)
    if _NETWORK_ISOLATED:
        cmd = ["unshare", "--net"] + cmd
    else:
        print("⚠ Warning: unshare --net unavailable, building without network isolation",
              file=sys.stderr)

    result = subprocess.run(cmd, env=env)
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

    sanitize_filenames(output_dir)


if __name__ == "__main__":
    main()
