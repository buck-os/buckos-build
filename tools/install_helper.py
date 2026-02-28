#!/usr/bin/env python3
"""Install wrapper for make install.

Runs make install with DESTDIR (or a custom variable) set to the prefix
directory.  The --destdir-var flag overrides the variable name for
packages that use a non-standard name (e.g. CONFIG_PREFIX for busybox).
"""

import argparse
import glob as _glob
import multiprocessing
import os
import re
import shutil
import stat
import subprocess
import sys

from _env import clean_env, sanitize_filenames


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


_BINARY_EXTS = frozenset((
    ".o", ".a", ".so", ".gch", ".pcm", ".pch", ".d",
    ".png", ".jpg", ".gif", ".ico", ".gz", ".xz", ".bz2",
    ".wasm", ".pyc", ".qm",
))

_BUCK_OUT_RE = re.compile(r'(/[^\s"\']+?)/buck-out/')


def _detect_stale_project_root(build_dir):
    """Scan build metadata files for absolute paths containing /buck-out/.

    Checks config.status (autotools), CMakeCache.txt (cmake),
    build.ninja (meson/cmake), and Makefile (OpenSSL-style).  If the
    prefix before /buck-out/ differs from os.getcwd(), return the stale
    root.  Otherwise return None.
    """
    current_root = os.getcwd()
    candidates = list(_glob.glob(os.path.join(build_dir, "**/config.status"), recursive=True))
    for name in ("CMakeCache.txt", "build.ninja"):
        path = os.path.join(build_dir, name)
        if os.path.isfile(path):
            candidates.append(path)
    # Also check top-level Makefile — build systems that don't generate
    # config.status (e.g. OpenSSL's Configure) still embed absolute paths.
    top_makefile = os.path.join(build_dir, "Makefile")
    if os.path.isfile(top_makefile) and not candidates:
        candidates.append(top_makefile)
    for cs in candidates:
        try:
            with open(cs, "r") as f:
                content = f.read()
        except (UnicodeDecodeError, PermissionError, OSError):
            continue
        m = _BUCK_OUT_RE.search(content)
        if m and m.group(1) != current_root:
            return m.group(1)
    return None


def _fix_stale_symlinks(build_dir, old_root, new_root):
    """Rewrite absolute symlink targets that contain old_root."""
    for dirpath, dirnames, filenames in os.walk(build_dir):
        for entries in (dirnames, filenames):
            for name in entries:
                p = os.path.join(dirpath, name)
                if not os.path.islink(p):
                    continue
                target = os.readlink(p)
                if old_root in target:
                    os.unlink(p)
                    os.symlink(target.replace(old_root, new_root), p)


def _rewrite_stale_paths(build_dir, old_root, new_root):
    """Rewrite old_root to new_root in all non-binary text files."""
    for dirpath, _dirnames, filenames in os.walk(build_dir):
        for fname in filenames:
            if os.path.splitext(fname)[1] in _BINARY_EXTS:
                continue
            fpath = os.path.join(dirpath, fname)
            if os.path.islink(fpath):
                continue
            try:
                _rewrite_file(fpath, old_root, new_root)
            except (UnicodeDecodeError, PermissionError, IsADirectoryError,
                    FileNotFoundError):
                pass


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


def _suppress_phony_rebuilds(build_dir):
    """Remove variable-expanded targets from .PHONY declarations.

    Some packages (e.g. xfsprogs) mark compiled binaries/libraries as
    .PHONY via variable expansion (.PHONY: $(LTCOMMAND) $(LTLIBRARY)),
    which forces make to always rebuild them — even during 'make install'.
    In Buck2's split-action model the build tree is a finished input;
    rebuild attempts fail because compiler paths and relative library
    references may not resolve.

    We strip $(VAR)/${VAR} tokens from .PHONY lines so make treats the
    existing files as up-to-date.  Literal .PHONY targets (install,
    clean, all, etc.) are preserved.
    """
    _var_re = re.compile(r'\$[({][^)}]*[)}]')

    for dirpath, _dirnames, filenames in os.walk(build_dir):
        for fname in filenames:
            fpath = os.path.join(dirpath, fname)
            try:
                with open(fpath, "r") as f:
                    content = f.read()
            except (UnicodeDecodeError, PermissionError, OSError):
                continue
            if ".PHONY" not in content:
                continue

            new_lines = []
            changed = False
            in_phony = False
            for line in content.splitlines(True):
                if line.lstrip().startswith(".PHONY"):
                    in_phony = True
                if in_phony and _var_re.search(line):
                    line = _var_re.sub("", line)
                    changed = True
                if in_phony and not line.rstrip().endswith("\\"):
                    in_phony = False
                new_lines.append(line)

            if changed:
                try:
                    stat = os.stat(fpath)
                    with open(fpath, "w") as f:
                        f.writelines(new_lines)
                    os.utime(fpath, (stat.st_atime, stat.st_mtime))
                except (PermissionError, OSError):
                    pass


def main():
    _host_path = os.environ.get("PATH", "")

    parser = argparse.ArgumentParser(description="Run make install")
    parser.add_argument("--build-dir", required=True, help="Build directory")
    parser.add_argument("--prefix", required=True, help="DESTDIR prefix for installation")
    parser.add_argument("--make-arg", action="append", dest="make_args", default=[],
                        help="Extra argument to pass to make (repeatable)")
    parser.add_argument("--destdir-var", default="DESTDIR",
                        help="Make variable for install prefix (default: DESTDIR)")
    parser.add_argument("--build-subdir", default=None,
                        help="Subdirectory within build-dir where make runs (for out-of-tree builds)")
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
    parser.add_argument("--build-system", choices=["make", "ninja"], default="make",
                        help="Build system to use (default: make)")
    parser.add_argument("--make-target", action="append", dest="make_targets", default=None,
                        help="Make target to install (repeatable, default: install)")
    parser.add_argument("--post-cmd", action="append", dest="post_cmds", default=[],
                        help="Shell command to run in prefix dir after install (repeatable)")
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
    args = parser.parse_args()

    # Read flag files early — tset-propagated values are base defaults.
    def _read_flag_file(path):
        if not path:
            return []
        with open(path) as f:
            return [line.rstrip("\n") for line in f if line.strip()]

    file_cflags = _read_flag_file(args.cflags_file)
    file_ldflags = _read_flag_file(args.ldflags_file)
    file_pkg_config = _read_flag_file(args.pkg_config_file)
    file_path_dirs = _read_flag_file(args.path_file)
    file_lib_dirs = _read_flag_file(args.lib_dirs_file)

    env = clean_env()

    # Expose the project root so post-cmds can resolve Buck2 artifact
    # paths (which are relative to the project root, not to the prefix).
    env["PROJECT_ROOT"] = os.getcwd()

    build_dir = os.path.abspath(args.build_dir)
    make_dir = build_dir
    if args.build_subdir:
        make_dir = os.path.join(build_dir, args.build_subdir)
    if not os.path.isdir(make_dir):
        print(f"error: build directory not found: {make_dir}", file=sys.stderr)
        sys.exit(1)

    # Expose the build directory so post-cmds can reference build
    # artifacts (e.g. copying objects not handled by make install).
    env["BUILD_DIR"] = make_dir

    # Create a pkg-config wrapper that always passes --define-prefix so
    # .pc files in Buck2 dep directories resolve paths correctly.
    import tempfile
    wrapper_dir = tempfile.mkdtemp(prefix="pkgconf-wrapper-")
    wrapper = os.path.join(wrapper_dir, "pkg-config")
    with open(wrapper, "w") as f:
        f.write('#!/bin/sh\n'
                'SELF_DIR="$(cd "$(dirname "$0")" && pwd)"\n'
                'PATH="${PATH#"$SELF_DIR:"}" exec pkg-config --define-prefix "$@"\n')
    os.chmod(wrapper, 0o755)

    # Apply extra environment variables first (toolchain flags like -march).
    for entry in args.extra_env:
        key, _, value = entry.partition("=")
        if key:
            env[key] = _resolve_env_paths(value)

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

    # Merge tset-provided lib dirs into LD_LIBRARY_PATH so dynamically
    # linked dep libraries are found at install time (e.g. Python
    # test-imports extension modules during make install).  Scoped to the
    # subprocess env dict — never poisons the host Python process.
    if file_lib_dirs:
        resolved = [os.path.abspath(d) for d in file_lib_dirs if os.path.isdir(d)]
        if resolved:
            existing = env.get("LD_LIBRARY_PATH", "")
            merged = ":".join(resolved)
            env["LD_LIBRARY_PATH"] = (merged + ":" + existing).rstrip(":") if existing else merged

    # Auto-detect Python site-packages from dep prefixes so build-time
    # Python modules (e.g. packaging for gdbus-codegen) are found.
    _path_sources = list(args.hermetic_path) + list(all_path_prepend)
    if _path_sources:
        _py_paths = []
        for _bp in _path_sources:
            _parent = os.path.dirname(os.path.abspath(_bp))
            for _pattern in ("lib/python*/site-packages", "lib/python*/dist-packages",
                             "lib64/python*/site-packages", "lib64/python*/dist-packages"):
                for _sp in _glob.glob(os.path.join(_parent, _pattern)):
                    if os.path.isdir(_sp):
                        _py_paths.append(_sp)
        if _py_paths:
            _existing = env.get("PYTHONPATH", "")
            env["PYTHONPATH"] = ":".join(_py_paths) + (":" + _existing if _existing else "")

    # Prepend pkg-config wrapper to PATH (after hermetic/prepend logic
    # so the wrapper is always available regardless of PATH mode)
    env["PATH"] = wrapper_dir + ":" + env.get("PATH", "")

    prefix = os.path.abspath(args.prefix)
    os.makedirs(prefix, exist_ok=True)

    # The build tree is a read-only Buck2 output from the compile action.
    # Make it writable so we can patch libtool scripts and reset timestamps.
    # Also break hard links — Buck2 may share inodes across actions, and
    # mmap-based linkers (mold) SIGBUS when writing to shared mappings.
    for dirpath, dirnames, filenames in os.walk(make_dir):
        for d in dirnames:
            dp = os.path.join(dirpath, d)
            if not os.path.islink(dp):
                try:
                    os.chmod(dp, os.stat(dp).st_mode | stat.S_IWUSR)
                except OSError:
                    pass
        for f in filenames:
            fp = os.path.join(dirpath, f)
            if os.path.islink(fp):
                continue
            try:
                st = os.stat(fp)
                os.chmod(fp, st.st_mode | stat.S_IWUSR)
                if st.st_nlink > 1:
                    tmp = fp + ".hlbreak"
                    shutil.copy2(fp, tmp)
                    os.rename(tmp, fp)
            except OSError:
                pass

    # Reconstruct shared library symlinks lost by RE/cache transport.
    # Buck2's remote execution cache doesn't preserve symlinks — directory
    # artifacts get the real files but not the symlinks.  Shared library
    # builds typically create:
    #   libfoo.so.2.4  (real file)
    #   libfoo.so.2 -> libfoo.so.2.4
    #   libfoo.so   -> libfoo.so.2
    # Some packages (e.g. e2fsprogs) also create parent-directory symlinks:
    #   lib/ext2fs/libext2fs.so.2.4  (real file, built here)
    #   lib/libext2fs.so.2.4 -> ext2fs/libext2fs.so.2.4
    #   lib/libext2fs.so     -> libext2fs.so.2.4
    # Without these, Makefile DEPLIBS references like ../lib/libext2fs.so
    # fail with "No rule to make target".  Reconstruct by scanning for
    # versioned .so files and creating missing symlinks.
    _soname_re = re.compile(r'^(.+\.so)\.(\d+(?:\.\d+)*)$')
    for dirpath, _dirnames, filenames in os.walk(make_dir):
        # Collect versioned .so files: {base: {version_string: filename}}
        _so_versions = {}  # "libfoo.so" -> ["1.2.3", "1.2", "1"]
        for fname in filenames:
            m = _soname_re.match(fname)
            if m:
                base = m.group(1)       # libfoo.so
                ver = m.group(2)        # "2.4" or "2"
                _so_versions.setdefault(base, []).append((ver, fname))
        for base, versions in _so_versions.items():
            # Find the most-versioned real file to anchor the chain
            # (e.g. libfoo.so.2.4 is the real file, .so.2 and .so are symlinks)
            _anchor = max(versions, key=lambda v: v[0].count('.'))[1]
            # Create base symlink (libfoo.so -> libfoo.so.2.4) if missing
            base_path = os.path.join(dirpath, base)
            if not os.path.lexists(base_path):
                os.symlink(_anchor, base_path)
            # Create intermediate version symlinks if missing
            # e.g. libfoo.so.2 -> libfoo.so.2.4
            for ver, fname in versions:
                parts = ver.split('.')
                for i in range(1, len(parts)):
                    short_ver = '.'.join(parts[:i])
                    short_name = base + '.' + short_ver
                    short_path = os.path.join(dirpath, short_name)
                    if not os.path.lexists(short_path):
                        os.symlink(fname, short_path)

            # Reconstruct parent-directory symlinks.  Some build systems
            # (e.g. e2fsprogs Makefile.elf-lib) create symlinks in the
            # parent dir pointing into the subdirectory:
            #   lib/libext2fs.so.2.4 -> ext2fs/libext2fs.so.2.4
            #   lib/libext2fs.so     -> libext2fs.so.2.4
            # These let DEPLIBS like $(LIB)/libext2fs.so (where LIB=../lib)
            # resolve without encoding the subdirectory name.
            parent = os.path.dirname(dirpath)
            if parent and parent != make_dir and os.path.isdir(parent):
                subdir = os.path.basename(dirpath)
                # anchor symlink: lib/libfoo.so.2.4 -> ext2fs/libfoo.so.2.4
                parent_anchor = os.path.join(parent, _anchor)
                if not os.path.lexists(parent_anchor):
                    os.symlink(os.path.join(subdir, _anchor), parent_anchor)
                # base symlink: lib/libfoo.so -> libfoo.so.2.4
                parent_base = os.path.join(parent, base)
                if not os.path.lexists(parent_base):
                    os.symlink(_anchor, parent_base)
                # soname symlink: lib/libfoo.so.2 -> libfoo.so.2.4
                for ver, fname in versions:
                    parts = ver.split('.')
                    for i in range(1, len(parts)):
                        short_name = base + '.' + '.'.join(parts[:i])
                        parent_short = os.path.join(parent, short_name)
                        if not os.path.lexists(parent_short):
                            os.symlink(_anchor, parent_short)

    # Detect and rewrite stale absolute paths from cross-machine cache.
    # When build ran on CI and install runs locally, autotools files
    # (config.status, Makefiles) contain CI's project root.
    _stale_root = _detect_stale_project_root(make_dir)
    if _stale_root:
        _new_root = os.getcwd()
        _fix_stale_symlinks(make_dir, _stale_root, _new_root)
        _rewrite_stale_paths(make_dir, _stale_root, _new_root)

        # Rewrite meson's install.dat pickle which the text rewrite
        # skips (binary).  install.dat stores absolute source paths
        # used by `meson install` to locate headers and other files.
        _install_dat = os.path.join(make_dir, "meson-private", "install.dat")
        if os.path.isfile(_install_dat):
            import pickle as _pickle

            class _StubUnpickler(_pickle.Unpickler):
                """Unpickler that stubs missing mesonbuild modules."""
                def find_class(self, module, name):
                    try:
                        return super().find_class(module, name)
                    except (ModuleNotFoundError, AttributeError):
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

            try:
                _dat_stat = os.stat(_install_dat)
                with open(_install_dat, "rb") as f:
                    _idata = _StubUnpickler(f).load()
                _patch_paths(_idata, _stale_root, _new_root)
                with open(_install_dat, "wb") as f:
                    _pickle.dump(_idata, f)
                os.utime(_install_dat, (_dat_stat.st_atime, _dat_stat.st_mtime))
            except Exception:
                pass  # Best-effort — don't block install on pickle errors

    # Suppress libtool re-linking during install.
    #
    # Libtool's --mode=install re-links binaries when it sees .la files
    # with installed=no.  Re-linking invokes the linker with build-tree
    # paths (relative or absolute) that may not resolve in Buck2's
    # split-action model where build and install are separate cached
    # actions.  The binaries are already correctly linked from the build
    # phase; re-linking during install into DESTDIR is unnecessary.
    #
    # This is the same technique distros like Gentoo and Arch use to
    # avoid libtool re-link failures in staged installs.
    for lt_script in _glob.glob(os.path.join(make_dir, "**/libtool"), recursive=True):
        try:
            _rewrite_file(lt_script, "need_relink=yes", "need_relink=no")
        except (UnicodeDecodeError, PermissionError):
            pass
    # Also patch top-level libtool if present
    _top_lt = os.path.join(make_dir, "libtool")
    if os.path.isfile(_top_lt):
        try:
            _rewrite_file(_top_lt, "need_relink=yes", "need_relink=no")
        except (UnicodeDecodeError, PermissionError):
            pass

    # Clear relink_command from .la files so libtool --mode=install doesn't
    # re-link libraries/binaries.  relink_command embeds build-tree paths
    # (often relative) that may not resolve in Buck2's split-action model.
    for la_file in _glob.glob(os.path.join(make_dir, "**", "*.la"), recursive=True):
        try:
            with open(la_file, "r") as f:
                la_content = f.read()
            if "relink_command=" not in la_content:
                continue
            la_new = re.sub(r"relink_command=.*", 'relink_command=""', la_content)
            if la_new != la_content:
                la_stat = os.stat(la_file)
                with open(la_file, "w") as f:
                    f.write(la_new)
                os.utime(la_file, (la_stat.st_atime, la_stat.st_mtime))
        except (UnicodeDecodeError, PermissionError, OSError):
            pass

    # Neutralise .PHONY declarations that reference build artifacts via
    # variable expansion so make doesn't force-rebuild them during install.
    _suppress_phony_rebuilds(make_dir)

    # Suppress meson/cmake regeneration in all build.ninja files.
    # In Buck2's split-action model the configure output isn't available
    # during install; if ninja tries to regenerate, meson/cmake would
    # fail looking for source files or cross-compilation configs from
    # the configure action's output directory.
    _regen_re = re.compile(
        r'^build build\.ninja[ :].*?(?=\n(?:build |$))',
        re.MULTILINE | re.DOTALL,
    )
    for _nf in _glob.glob(os.path.join(make_dir, "**/build.ninja"), recursive=True):
        try:
            _nf_stat = os.stat(_nf)
            with open(_nf, "r") as f:
                _nf_content = f.read()
            _nf_new = _regen_re.sub(
                'build build.ninja: phony',
                _nf_content, count=1,
            )
            # Ensure phony rule exists even if the regex didn't match
            # (e.g. cached build output with old comment-based suppression).
            if 'build build.ninja: phony' not in _nf_new:
                _nf_new = 'build build.ninja: phony\n' + _nf_new
            if _nf_new != _nf_content:
                with open(_nf, "w") as f:
                    f.write(_nf_new)
                os.utime(_nf, (_nf_stat.st_atime, _nf_stat.st_mtime))
        except (UnicodeDecodeError, PermissionError, FileNotFoundError):
            pass

    # Remove standalone dependency tracking files (*.o.d, *.lo.d).
    # These record header paths from the build phase and are not needed
    # during install.  Cross-machine caches may contain paths that cause
    # make parse errors (e.g. nettle's ecc-gostdsa-sign.o.d).
    for dirpath, _dirnames, filenames in os.walk(make_dir):
        for fname in filenames:
            if fname.endswith((".o.d", ".lo.d")):
                try:
                    os.unlink(os.path.join(dirpath, fname))
                except OSError:
                    pass

    # Reset all file timestamps in the build tree to a uniform instant.
    # Buck2 normalises artifact timestamps after the build phase, so make
    # install can see stale dependencies and try to regenerate files.
    _epoch = float(env.get("SOURCE_DATE_EPOCH", "315576000"))
    _stamp = (_epoch, _epoch)
    for dirpath, _dirnames, filenames in os.walk(make_dir):
        for fname in filenames:
            try:
                os.utime(os.path.join(dirpath, fname), _stamp)
            except (PermissionError, OSError):
                pass

    # Suppress Makefile-level reconfiguration.  Build systems like QEMU
    # wrap meson inside autotools; their Makefile re-runs config.status
    # when included Makefiles (Makefile.mtest, Makefile.ninja) are created
    # for the first time.  cmake-generated Makefiles run cmake
    # --check-build-system which fails when the built cmake has stale
    # paths from a different machine.  Append no-op overrides for
    # targets whose recipes invoke these reconfiguration commands.
    _CLEAN_TARGETS = frozenset(("distclean", "clean", "maintainer-clean",
                                "mostlyclean", "realclean"))
    _RECONFIG_TRIGGERS = ('config.status', 'check-build-system')
    _RECONFIG_RECIPE_PATTERNS = ('./config.status', '$(SHELL) config.status',
                                 '--reconfigure', '--check-build-system')
    for _mf in _glob.glob(os.path.join(make_dir, "**/Makefile"), recursive=True):
        try:
            with open(_mf, "r") as f:
                _mf_content = f.read()
        except (UnicodeDecodeError, PermissionError, OSError):
            continue
        if not any(t in _mf_content for t in _RECONFIG_TRIGGERS):
            continue
        _mf_stat = os.stat(_mf)
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
            _overrides = ["\n# Reconfiguration suppressed by install_helper"]
            for _t in sorted(_suppressed):
                _overrides.append(f"{_t}{_suppressed[_t]} ;")
            with open(_mf, "a") as f:
                f.write("\n".join(_overrides) + "\n")
            os.utime(_mf, (_mf_stat.st_atime, _mf_stat.st_mtime))

    # Suppress rebuild-during-install.  In Buck2's split-action model the
    # build tree is a finished input from the compile phase.  Install
    # targets (install-am) depend on all/all-am which checks whether
    # binaries need rebuilding.  Race conditions in parallel make or
    # missing transitive deps can trigger relinking that fails because
    # the full dependency tree isn't available during install.
    #
    # Dynamically discover all "all" variant targets (all, all-am,
    # all-recursive, all-libs-recursive, etc.) rather than maintaining
    # a static list.  Packages like e2fsprogs define additional variants.
    #
    # Single-colon (:) rules: append no-op override at end of file.
    # GNU Make uses the last single-colon definition, so this reliably
    # replaces both prerequisites and recipe.
    #
    # Double-colon (::) rules: rewrite in-place.  Each :: definition is
    # independent, so appending a new :: no-op does NOT suppress the
    # original recipe.
    _ALL_NAME_RE = re.compile(r'^all(?:-[\w-]*)?$')
    for _mf in _glob.glob(os.path.join(make_dir, "**/Makefile"), recursive=True):
        try:
            with open(_mf, "r") as f:
                _mf_content = f.read()
        except (UnicodeDecodeError, PermissionError, OSError):
            continue
        _mf_stat = os.stat(_mf)
        _single = []
        _double = []
        # Parse target definition lines to find all "all" variant targets.
        # Handles multi-target lines like "all-libs-recursive all-progs-recursive:"
        # and backslash-continuation lines like:
        #   all-libs-recursive install-libs-recursive \
        #     install-shlibs-libs-recursive::
        # Join continuation lines before parsing so targets on continued
        # lines are not missed.
        _joined_lines = []
        _accum = ""
        for _raw in _mf_content.splitlines():
            if _raw.endswith('\\'):
                _accum += _raw[:-1] + " "
            else:
                _accum += _raw
                _joined_lines.append(_accum)
                _accum = ""
        if _accum:
            _joined_lines.append(_accum)
        for _line in _joined_lines:
            if _line.startswith(('\t', '#')) or ':' not in _line:
                continue
            _ci = _line.index(':')
            _tpart = _line[:_ci]
            # Skip variable assignments (VAR = ...) that happen to contain ':'
            if '=' in _tpart:
                continue
            _is_dc = _line[_ci:_ci + 2] == '::'
            for _bt in _tpart.split():
                if _bt.startswith(('$', '%', '.')) or _bt in _single or _bt in _double:
                    continue
                if _ALL_NAME_RE.match(_bt):
                    (_double if _is_dc else _single).append(_bt)
        if not _single and not _double:
            continue
        # Single-colon: append override (proven reliable)
        if _single:
            with open(_mf, "a") as f:
                f.write("\n# Build suppressed by install_helper — "
                        "compile phase already completed\n")
                f.write("\n".join(f"{_bt}: ;" for _bt in _single) + "\n")
        # Double-colon: rewrite in-place
        if _double:
            _dc_re = re.compile(
                r'^(' + '|'.join(re.escape(t) for t in _double) + r')\s*::',
            )
            with open(_mf, "r") as f:
                _mf_lines = f.readlines()
            _changed = False
            _new_lines = []
            _in_recipe = False
            _in_continuation = False
            for _line in _mf_lines:
                _stripped = _line.rstrip('\n')
                # Skip continuation lines from a matched target
                if _in_continuation:
                    _changed = True
                    if not _stripped.endswith('\\'):
                        _in_continuation = False
                    continue
                if not _line.startswith('\t') and _dc_re.match(_stripped):
                    _m = _dc_re.match(_stripped)
                    _new_lines.append(f"{_m.group(1)}::\n")
                    _new_lines.append("\t@:\n")
                    _in_recipe = True
                    _changed = True
                    if _stripped.endswith('\\'):
                        _in_continuation = True
                    continue
                if _in_recipe:
                    if _line.startswith('\t'):
                        _changed = True
                        continue
                    _in_recipe = False
                _new_lines.append(_line)
            if _changed:
                with open(_mf, "w") as f:
                    f.writelines(_new_lines)
        os.utime(_mf, (_mf_stat.st_atime, _mf_stat.st_mtime))

    # Prevent autotools reconfigure during install.  In out-of-tree builds
    # the build subdir's config.status depends on ../configure (in the
    # source root).  Buck2 normalises artifact timestamps, so configure
    # can appear newer than config.status, causing make to re-run configure.
    # The configure action's inputs (headers, cross-tools) aren't available
    # here, so reconfigure would fail.  Touch configure scripts to match
    # their config.status mtime.
    for _cs in _glob.glob(os.path.join(make_dir, "**/config.status"), recursive=True):
        _cs_mtime = os.stat(_cs).st_mtime
        _cs_dir = os.path.dirname(_cs)
        for _parent in [os.path.dirname(_cs_dir),
                        os.path.dirname(os.path.dirname(_cs_dir))]:
            _configure = os.path.join(_parent, "configure")
            if os.path.isfile(_configure):
                try:
                    os.chmod(_configure,
                             os.stat(_configure).st_mode | stat.S_IWUSR)
                    os.utime(_configure, (_cs_mtime, _cs_mtime))
                except OSError:
                    pass
                break

    # Patch RUNSHARED assignments so LD_LIBRARY_PATH from the environment
    # survives into subprocesses (e.g. Python's compileall test-imports).
    _patch_runshared(make_dir)

    targets = args.make_targets or ["install"]

    jobs = multiprocessing.cpu_count()

    _use_cmake_install = False
    if args.build_system == "ninja":
        # Ninja uses DESTDIR as an env var, not a command-line arg
        env[args.destdir_var] = prefix
        # Prefer cmake --install for CMake builds.  ninja install checks
        # the full dependency graph including external libraries that may
        # not exist in Buck2's split-action model (only the build output
        # is an input to the install action, not the dep tree).  cmake
        # --install runs the install scripts directly, bypassing ninja.
        _cmake_cache = os.path.join(make_dir, "CMakeCache.txt")
        if os.path.isfile(_cmake_cache) and shutil.which("cmake"):
            cmd = ["cmake", "--install", make_dir]
            _use_cmake_install = True
        else:
            cmd = ["ninja", "-C", make_dir, f"-j{jobs}"] + targets
    else:
        cmd = [
            "make",
            "-C", make_dir,
            f"-j{jobs}",
            f"{args.destdir_var}={prefix}",
        ] + targets
    # Resolve paths in make args (e.g. CC=buck-out/.../gcc → absolute).
    # Skipped for cmake --install which doesn't accept make arguments.
    if not _use_cmake_install:
        for arg in args.make_args:
            if "=" in arg:
                key, _, value = arg.partition("=")
                cmd.append(f"{key}={_resolve_env_paths(value)}")
            else:
                cmd.append(arg)

    result = subprocess.run(cmd, env=env)
    if result.returncode != 0:
        print(f"error: make install failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(1)

    # Remove libtool .la files — they embed absolute build-time paths that
    # break when consumed from Buck2 dep directories.  Modern pkg-config and
    # cmake handle transitive deps without them.
    for la in _glob.glob(os.path.join(prefix, "**", "*.la"), recursive=True):
        os.remove(la)

    # Run post-install commands (e.g. ldconfig, cleanup)
    # Set DESTDIR so legacy scripts that reference $DESTDIR work correctly.
    env["DESTDIR"] = prefix
    env["OUT"] = prefix
    for cmd_str in args.post_cmds:
        result = subprocess.run(cmd_str, shell=True, cwd=prefix, env=env)
        if result.returncode != 0:
            print(f"error: post-cmd failed with exit code {result.returncode}: {cmd_str}",
                  file=sys.stderr)
            sys.exit(1)

    sanitize_filenames(prefix, make_dir)


if __name__ == "__main__":
    main()
