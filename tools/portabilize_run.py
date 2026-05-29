#!/usr/bin/env python3
"""Run a command with buckos-built dep binaries portabilized first.

Wraps a command so that buckos-built ELF tools (whose PT_INTERP points
at the buckos sysroot ld-linux) are invoked through ld-linux wrapper
scripts before the command runs.

Usage:
    portabilize_run \\
        --ld-linux PATH --scratch-dir DIR \\
        --bin-dir DIR [--bin-dir DIR ...] \\
        -- COMMAND [ARGS ...]

The wrapper bin dirs are prepended to PATH; their sibling lib/lib64
dirs (excluding any with libc.so.6 to avoid sysroot-glibc poisoning) are
prepended to LD_LIBRARY_PATH.  Then COMMAND is execvp'd in-place.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from portabilize import portabilize_toolchain

_BUCK_ROOT = os.environ.get("PWD") or os.getcwd()


def _abs(path):
    """Resolve to an absolute path against the original buck root."""
    if not path:
        return path
    if os.path.isabs(path):
        return path
    return os.path.normpath(os.path.join(_BUCK_ROOT, path))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ld-linux", required=True)
    parser.add_argument("--scratch-dir", default=None)
    parser.add_argument("--patchelf", default=None,
                        help="Unused (kept for compatibility).")
    parser.add_argument("--bin-dir", action="append", default=[])
    parser.add_argument("--prefix", action="append", default=[],
                        help="Dep install prefix; bin/sbin/usr/bin/usr/sbin "
                             "subdirs that exist will be portabilized.")
    parser.add_argument("cmd", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    args.ld_linux = _abs(args.ld_linux)
    if args.scratch_dir:
        args.scratch_dir = _abs(args.scratch_dir)
    args.bin_dir = [_abs(d) for d in args.bin_dir]
    args.prefix = [_abs(p) for p in args.prefix]

    for prefix in args.prefix:
        for sub in ("bin", "sbin", "usr/bin", "usr/sbin"):
            d = os.path.join(prefix, sub)
            if os.path.isdir(d):
                args.bin_dir.append(d)

    if not args.cmd or args.cmd[0] != "--":
        sys.exit("error: missing '--' before command")
    cmd = args.cmd[1:]
    if not cmd:
        sys.exit("error: empty command after '--'")

    if args.bin_dir:
        orig_dirs = list(args.bin_dir)
        port_dirs = portabilize_toolchain(
            orig_dirs,
            args.ld_linux,
            scratch_dir=args.scratch_dir,
        )
        port_map = dict(zip(orig_dirs, port_dirs))
        lib_dirs = []
        for bd in port_dirs:
            parent = os.path.dirname(bd)
            for ld in ("lib", "lib64"):
                d = os.path.join(parent, ld)
                if os.path.isdir(d) and not os.path.exists(
                    os.path.join(d, "libc.so.6")
                ):
                    lib_dirs.append(d)
        existing_path = os.environ.get("PATH", "")
        os.environ["PATH"] = ":".join(port_dirs) + (
            ":" + existing_path if existing_path else ""
        )
        if lib_dirs:
            existing_ll = os.environ.get("LD_LIBRARY_PATH", "")
            os.environ["LD_LIBRARY_PATH"] = ":".join(lib_dirs) + (
                ":" + existing_ll if existing_ll else ""
            )

        cmd0_abs = _abs(cmd[0])
        cmd0_dir = os.path.dirname(cmd0_abs)
        if cmd0_dir in port_map:
            cmd[0] = os.path.join(port_map[cmd0_dir], os.path.basename(cmd0_abs))

    _run_env_ll = os.environ.pop("_RUN_ENV_LD_LIBRARY_PATH", "")
    if _run_env_ll:
        existing_ll = os.environ.get("LD_LIBRARY_PATH", "")
        os.environ["LD_LIBRARY_PATH"] = _run_env_ll + (
            ":" + existing_ll if existing_ll else ""
        )

    os.execvp(cmd[0], cmd)


if __name__ == "__main__":
    main()
