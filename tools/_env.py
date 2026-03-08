"""Shared environment sanitization for build helpers.

Buck2's local executor inherits the daemon's full host environment into
action subprocesses, but action cache keys only include explicitly declared
env={}.  Two hosts sharing a NativeLink CAS compute identical digests but
may produce different outputs when host env differs — cache poisoning.

This module provides a whitelist-based approach: start from a clean env
with only functional vars, pin determinism vars, and let each helper add
what it needs on top.
"""

import atexit
import os
import signal
import shutil
import sys

# Vars passed through from the host environment when present.
_PASSTHROUGH = frozenset({
    "HOME", "USER", "LOGNAME",
    "TMPDIR", "TEMP", "TMP",
    "TERM",
    "BUCK_SCRATCH_PATH",
})

# Vars pinned to fixed values for determinism.
_DETERMINISM_PINS = {
    "LC_ALL": "C",
    "LANG": "C",
    "SOURCE_DATE_EPOCH": "315576000",
    "CCACHE_DISABLE": "1",
    "RUSTC_WRAPPER": "",
    "CARGO_BUILD_RUSTC_WRAPPER": "",
    # Prevent rustup from intercepting rustc/cargo via host toolchains.
    # cargo discovers rustc from PATH; rustup interposes by installing
    # proxies in ~/.cargo/bin that redirect to ~/.rustup/toolchains/.
    # Pinning RUSTUP_HOME to nonexistent prevents this.
    "RUSTUP_HOME": "/nonexistent-buckos-rustup",
    # Prevent pkg-config from falling through to host system .pc files.
    # The compiled-in default search path (/usr/lib64/pkgconfig, etc.) is
    # replaced with a nonexistent dir — helpers set PKG_CONFIG_PATH to
    # buckos deps.  Empty string doesn't work: pkgconf treats "" as unset.
    "PKG_CONFIG_LIBDIR": "/nonexistent-buckos-pkgconfig",
}


def clean_env():
    """Return a clean env dict for subprocess env= parameter.

    Copies only whitelisted vars from the host, then applies
    determinism pins.  Callers layer helper-specific vars on top.
    """
    env = {}
    for key in _PASSTHROUGH:
        val = os.environ.get(key)
        if val is not None:
            env[key] = val
    env.update(_DETERMINISM_PINS)
    # Isolate cargo from host ~/.cargo — cargo checks $CARGO_HOME/bin
    # for tools and $CARGO_HOME/config.toml for settings.  Use a scratch
    # dir so cargo can write registry/cache if needed.
    scratch = env.get("BUCK_SCRATCH_PATH") or env.get("TMPDIR") or "/tmp"
    env["CARGO_HOME"] = os.path.join(scratch, "buckos-cargo-home")
    return env


def _has_unsafe_chars(name):
    """True if *name* contains characters Buck2 cannot relativize."""
    return any(ord(c) < 32 or ord(c) == 127 or c == '\\' for c in name)


def sanitize_filenames(*roots):
    """Delete files/dirs whose names contain control chars or backslashes.

    Some build systems (autoconf's filesystem character test, conftest.t<TAB>)
    create files that Buck2's path handling cannot relativize.  Walk each
    root bottom-up and remove offending entries before Buck2 sees them.
    """
    for root in roots:
        if not root or not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root, topdown=False):
            for fname in filenames:
                if _has_unsafe_chars(fname):
                    try:
                        os.unlink(os.path.join(dirpath, fname))
                    except OSError:
                        pass
            for dname in list(dirnames):
                if _has_unsafe_chars(dname):
                    try:
                        shutil.rmtree(os.path.join(dirpath, dname))
                    except OSError:
                        pass


# ── Guaranteed cleanup ────────────────────────────────────────────────
# Helpers register directories here so sanitize_filenames runs on ANY
# exit path — normal return, exception, or SIGTERM.  Only SIGKILL
# bypasses this (unavoidable).

_cleanup_dirs = []
_cleanup_ran = False


def register_cleanup(*dirs):
    """Register directories for filename sanitization on exit.

    Call early (before builds start) so cleanup runs even if the
    build is interrupted.
    """
    _cleanup_dirs.extend(d for d in dirs if d)


def _run_cleanup():
    global _cleanup_ran
    if _cleanup_ran:
        return
    _cleanup_ran = True
    sanitize_filenames(*_cleanup_dirs)


atexit.register(_run_cleanup)


def _sigterm_cleanup(signum, frame):
    _run_cleanup()
    sys.exit(128 + signum)


signal.signal(signal.SIGTERM, _sigterm_cleanup)


def add_path_args(parser):
    """Register the standard three-way PATH arguments on an argparse parser."""
    parser.add_argument("--hermetic-path", action="append",
                        dest="hermetic_path", default=[],
                        help="Set PATH to only these dirs (repeatable)")
    parser.add_argument("--allow-host-path", action="store_true",
                        help="Allow host PATH (bootstrap escape hatch)")
    parser.add_argument("--hermetic-empty", action="store_true",
                        help="Start with empty PATH")
    parser.add_argument("--path-prepend", action="append",
                        dest="path_prepend", default=[],
                        help="Dir to prepend to PATH (repeatable)")
    parser.add_argument("--ld-linux", default=None,
                        help="Buckos ld-linux path (disables posix_spawn)")


def setup_path(args, env, host_path=""):
    """Set env["PATH"] from the standard three-way PATH arguments.

    Requires args parsed by add_path_args().  host_path is the original
    host PATH captured before sanitization (used with --allow-host-path).
    If --ld-linux was provided, disables posix_spawn in child Python
    processes to avoid ENOEXEC with padded ELF interpreters.
    """
    if args.hermetic_path:
        env["PATH"] = ":".join(os.path.abspath(p) for p in args.hermetic_path)
        derive_lib_paths(args.hermetic_path, env)
    elif args.hermetic_empty:
        env["PATH"] = ""
    elif args.allow_host_path:
        env["PATH"] = host_path
    else:
        print("error: requires --hermetic-path, --hermetic-empty, or --allow-host-path",
              file=sys.stderr)
        sys.exit(1)
    if hasattr(args, 'path_prepend') and args.path_prepend:
        prepend = ":".join(os.path.abspath(p) for p in args.path_prepend)
        env["PATH"] = prepend + (":" + env["PATH"] if env.get("PATH") else "")
        derive_lib_paths(args.path_prepend, env)
    if getattr(args, 'ld_linux', None):
        disable_posix_spawn(env)


def disable_posix_spawn(env, scratch_dir=None):
    """Install a sitecustomize.py that disables posix_spawn in subprocess.

    Python 3.14+ defaults to posix_spawn for subprocess.Popen, which
    fails with ENOEXEC on some kernels/configurations when the ELF
    interpreter is padded (///...///lib64/ld-linux-x86-64.so.2).
    Fork+exec handles padded interpreters correctly everywhere.

    Creates a sitecustomize.py in a scratch directory and prepends it
    to PYTHONPATH so all child Python processes inherit the fix.
    """
    if scratch_dir is None:
        scratch_dir = os.environ.get("BUCK_SCRATCH_PATH",
                                     os.environ.get("TMPDIR", "/tmp"))
    pysite = os.path.join(scratch_dir, "buckos-pysite")
    sitecust = os.path.join(pysite, "sitecustomize.py")
    if not os.path.exists(sitecust):
        os.makedirs(pysite, exist_ok=True)
        with open(sitecust, "w") as f:
            f.write("import subprocess as _sp\n")
            f.write("_sp._USE_POSIX_SPAWN = False\n")
    existing = env.get("PYTHONPATH", "")
    env["PYTHONPATH"] = pysite + (":" + existing if existing else "")


def derive_lib_paths(bin_dirs, env):
    """Derive LD_LIBRARY_PATH and tool data dirs from bin dirs.

    Given {prefix}/bin, adds {prefix}/lib and {prefix}/lib64 to
    LD_LIBRARY_PATH so dynamically linked host tools can find their
    shared libraries, and sets BISON_PKGDATADIR so relocated bison
    finds its m4sugar data files.

    Directories containing libc.so.6 are EXCLUDED from LD_LIBRARY_PATH
    to avoid poisoning host processes with buckos glibc.  The isolated
    glibc directory (lib64/glibc/) is also excluded — freshly compiled
    buckos binaries find glibc via RPATH set in the GCC specs at unpack
    time.  Including glibc in LD_LIBRARY_PATH would poison the cross-
    compiler (a host binary) causing segfaults on hosts with older glibc.
    """
    lib_parts = []
    for bin_dir in bin_dirs:
        parent = os.path.dirname(os.path.abspath(bin_dir))
        for ld in ("lib", "lib64"):
            d = os.path.join(parent, ld)
            if os.path.isdir(d) and not os.path.exists(os.path.join(d, "libc.so.6")):
                lib_parts.append(d)
        # Bison looks for data at compiled-in /usr/share/bison; set
        # BISON_PKGDATADIR so it finds data in the relocated prefix.
        bison_data = os.path.join(parent, "share", "bison")
        if os.path.isdir(bison_data) and "BISON_PKGDATADIR" not in env:
            env["BISON_PKGDATADIR"] = bison_data
    if lib_parts:
        existing = env.get("LD_LIBRARY_PATH", "")
        merged = ":".join(lib_parts)
        env["LD_LIBRARY_PATH"] = (merged + ":" + existing).rstrip(":") if existing else merged


def filter_path_flags(flags):
    """Filter out -I/-L/-Wl,-rpath-link flags for non-existent directories.

    Tset projections emit flags for every possible lib layout
    ({prefix}/usr/lib64, usr/lib, lib64, lib) but most only exist
    for one or two.  Filtering avoids blowing the execve arg limit
    on packages with 100+ transitive deps.
    """
    result = []
    for flag in flags:
        if flag.startswith("-I"):
            if os.path.isdir(os.path.abspath(flag[2:])):
                result.append(flag)
        elif flag.startswith("-L"):
            if os.path.isdir(os.path.abspath(flag[2:])):
                result.append(flag)
        elif flag.startswith("-Wl,-rpath-link,"):
            if os.path.isdir(os.path.abspath(flag[16:])):
                result.append(flag)
        else:
            result.append(flag)
    return result


def write_pkg_config_wrapper(wrapper_dir):
    """Write a pkg-config wrapper that passes --define-prefix.

    Uses a Python script (not shell) so it works in environments
    without /bin/sh (e.g. remote execution).  The wrapper removes
    its own directory from PATH to avoid infinite recursion, then
    execs the real pkg-config with --define-prefix prepended.
    """
    os.makedirs(wrapper_dir, exist_ok=True)
    wrapper = os.path.join(wrapper_dir, "pkg-config")
    with open(wrapper, "w") as f:
        f.write(
            '#!/usr/bin/env python3\n'
            'import os, sys\n'
            'sd = os.path.dirname(os.path.abspath(__file__))\n'
            'p = os.environ.get("PATH", "").split(":")\n'
            'os.environ["PATH"] = ":".join(d for d in p if os.path.abspath(d) != sd)\n'
            'os.execvp("pkg-config", ["pkg-config", "--define-prefix"] + sys.argv[1:])\n'
        )
    os.chmod(wrapper, 0o755)
    return wrapper_dir


def write_stub_script(path, exit_code=0):
    """Write a no-op stub script (e.g. for makeinfo, autotools regen).

    Uses Python instead of shell so it works without /bin/sh.
    """
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(
            '#!/usr/bin/env python3\n'
            'import sys; sys.exit({})\n'.format(exit_code)
        )
    os.chmod(path, 0o755)


def file_prefix_map_flags():
    """Return compiler flags that strip absolute build paths from output.

    Maps the project root (Buck2 cwd) to empty so paths like
    /home/user/repos/buckos-build/buck-out/v2/.../foo.c become
    buck-out/v2/.../foo.c in debug info and __FILE__ expansions.
    """
    cwd = os.getcwd()
    return [f"-ffile-prefix-map={cwd}/="]


def sanitize_global_env():
    """Replace os.environ in-place with a clean environment.

    For helpers that mutate os.environ directly (Pattern B) rather
    than passing env= to subprocess.  Preserves whitelisted vars,
    applies determinism pins, drops everything else.
    """
    keep = {}
    for key in _PASSTHROUGH:
        val = os.environ.get(key)
        if val is not None:
            keep[key] = val
    os.environ.clear()
    os.environ.update(keep)
    os.environ.update(_DETERMINISM_PINS)
