#!/usr/bin/env python3
"""Run a command with buckos-built dep binaries portabilized first.

Wraps a command so that buckos-built ELF tools (whose PT_INTERP points
at the buckos sysroot ld-linux) are patched to use the host loader before
the command runs.  Used by genrule-style rules that exec dep binaries
directly without going through binary_install_helper.

Usage:
    portabilize_run \\
        --ld-linux PATH --scratch-dir DIR [--patchelf PATH] \\
        --bin-dir DIR [--bin-dir DIR ...] \\
        -- COMMAND [ARGS ...]

The portabilized bin dirs are prepended to PATH; their sibling lib/lib64
dirs (excluding any with libc.so.6 to avoid sysroot-glibc poisoning) are
prepended to LD_LIBRARY_PATH.  Then COMMAND is execvp'd in-place.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from portabilize import portabilize_toolchain


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ld-linux", required=True)
    parser.add_argument("--scratch-dir", default=None,
                        help="Defaults to portabilize._stable_scratch().")
    parser.add_argument("--patchelf", default=None)
    parser.add_argument("--bin-dir", action="append", default=[])
    parser.add_argument("--prefix", action="append", default=[],
                        help="Dep install prefix; bin/sbin/usr/bin/usr/sbin "
                             "subdirs that exist will be portabilized.")
    parser.add_argument("cmd", nargs=argparse.REMAINDER)
    args = parser.parse_args()

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
        port_dirs = portabilize_toolchain(
            [os.path.abspath(d) for d in args.bin_dir],
            args.ld_linux,
            scratch_dir=args.scratch_dir,
            patchelf_path=args.patchelf,
        )
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

    os.execvp(cmd[0], cmd)


if __name__ == "__main__":
    main()
