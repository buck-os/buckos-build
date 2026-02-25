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

from _env import sanitize_global_env


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
    parser.add_argument("--build-system", choices=["make", "ninja"], default="make",
                        help="Build system to use (default: make)")
    parser.add_argument("--make-target", action="append", dest="make_targets", default=None,
                        help="Make target to install (repeatable, default: install)")
    parser.add_argument("--post-cmd", action="append", dest="post_cmds", default=[],
                        help="Shell command to run in prefix dir after install (repeatable)")
    args = parser.parse_args()

    sanitize_global_env()

    # Expose the project root so post-cmds can resolve Buck2 artifact
    # paths (which are relative to the project root, not to the prefix).
    os.environ["PROJECT_ROOT"] = os.getcwd()

    build_dir = os.path.abspath(args.build_dir)
    if args.build_subdir:
        build_dir = os.path.join(build_dir, args.build_subdir)
    if not os.path.isdir(build_dir):
        print(f"error: build directory not found: {build_dir}", file=sys.stderr)
        sys.exit(1)

    # Expose the build directory so post-cmds can reference build
    # artifacts (e.g. copying objects not handled by make install).
    os.environ["BUILD_DIR"] = build_dir

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
        # libraries are found at install time (e.g. Python test-imports
        # extension modules during make install).
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
    # Python modules (e.g. packaging for gdbus-codegen) are found.
    _path_sources = list(args.hermetic_path) + list(args.path_prepend)
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
            _existing = os.environ.get("PYTHONPATH", "")
            os.environ["PYTHONPATH"] = ":".join(_py_paths) + (":" + _existing if _existing else "")

    # Prepend pkg-config wrapper to PATH (after hermetic/prepend logic
    # so the wrapper is always available regardless of PATH mode)
    os.environ["PATH"] = wrapper_dir + ":" + os.environ.get("PATH", "")

    prefix = os.path.abspath(args.prefix)
    os.makedirs(prefix, exist_ok=True)

    # The build tree is a read-only Buck2 output from the compile action.
    # Make it writable so we can patch libtool scripts and reset timestamps.
    # Also break hard links — Buck2 may share inodes across actions, and
    # mmap-based linkers (mold) SIGBUS when writing to shared mappings.
    for dirpath, dirnames, filenames in os.walk(build_dir):
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

    # Detect and rewrite stale absolute paths from cross-machine cache.
    # When build ran on CI and install runs locally, autotools files
    # (config.status, Makefiles) contain CI's project root.
    _stale_root = _detect_stale_project_root(build_dir)
    if _stale_root:
        _new_root = os.getcwd()
        _fix_stale_symlinks(build_dir, _stale_root, _new_root)
        _rewrite_stale_paths(build_dir, _stale_root, _new_root)

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
    for lt_script in _glob.glob(os.path.join(build_dir, "**/libtool"), recursive=True):
        try:
            _rewrite_file(lt_script, "need_relink=yes", "need_relink=no")
        except (UnicodeDecodeError, PermissionError):
            pass
    # Also patch top-level libtool if present
    _top_lt = os.path.join(build_dir, "libtool")
    if os.path.isfile(_top_lt):
        try:
            _rewrite_file(_top_lt, "need_relink=yes", "need_relink=no")
        except (UnicodeDecodeError, PermissionError):
            pass

    # Clear relink_command from .la files so libtool --mode=install doesn't
    # re-link libraries/binaries.  relink_command embeds build-tree paths
    # (often relative) that may not resolve in Buck2's split-action model.
    for la_file in _glob.glob(os.path.join(build_dir, "**", "*.la"), recursive=True):
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
    _suppress_phony_rebuilds(build_dir)

    # Reset all file timestamps in the build tree to a uniform instant.
    # Buck2 normalises artifact timestamps after the build phase, so make
    # install can see stale dependencies and try to regenerate files.
    _epoch = float(os.environ.get("SOURCE_DATE_EPOCH", "315576000"))
    _stamp = (_epoch, _epoch)
    for dirpath, _dirnames, filenames in os.walk(build_dir):
        for fname in filenames:
            try:
                os.utime(os.path.join(dirpath, fname), _stamp)
            except (PermissionError, OSError):
                pass

    # Patch RUNSHARED assignments so LD_LIBRARY_PATH from the environment
    # survives into subprocesses (e.g. Python's compileall test-imports).
    _patch_runshared(build_dir)

    targets = args.make_targets or ["install"]

    jobs = multiprocessing.cpu_count()

    if args.build_system == "ninja":
        # Ninja uses DESTDIR as an env var, not a command-line arg
        os.environ[args.destdir_var] = prefix
        cmd = ["ninja", "-C", build_dir, f"-j{jobs}"] + targets
    else:
        cmd = [
            "make",
            "-C", build_dir,
            f"-j{jobs}",
            f"{args.destdir_var}={prefix}",
        ] + targets
    # Resolve paths in make args (e.g. CC=buck-out/.../gcc → absolute)
    for arg in args.make_args:
        if "=" in arg:
            key, _, value = arg.partition("=")
            cmd.append(f"{key}={_resolve_env_paths(value)}")
        else:
            cmd.append(arg)

    result = subprocess.run(cmd)
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
    os.environ["DESTDIR"] = prefix
    os.environ["OUT"] = prefix
    for cmd_str in args.post_cmds:
        result = subprocess.run(cmd_str, shell=True, cwd=prefix)
        if result.returncode != 0:
            print(f"error: post-cmd failed with exit code {result.returncode}: {cmd_str}",
                  file=sys.stderr)
            sys.exit(1)



if __name__ == "__main__":
    main()
