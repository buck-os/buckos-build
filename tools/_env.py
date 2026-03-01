"""Shared environment sanitization for build helpers.

Buck2's local executor inherits the daemon's full host environment into
action subprocesses, but action cache keys only include explicitly declared
env={}.  Two hosts sharing a NativeLink CAS compute identical digests but
may produce different outputs when host env differs — cache poisoning.

This module provides a whitelist-based approach: start from a clean env
with only functional vars, pin determinism vars, and let each helper add
what it needs on top.
"""

import os
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


def setup_path(args, env, host_path=""):
    """Set env["PATH"] from the standard three-way PATH arguments.

    Requires args parsed by add_path_args().  host_path is the original
    host PATH captured before sanitization (used with --allow-host-path).
    """
    if args.hermetic_path:
        env["PATH"] = ":".join(os.path.abspath(p) for p in args.hermetic_path)
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
