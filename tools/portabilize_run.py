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
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from portabilize import portabilize_toolchain

# Buck2 invokes us via `env --chdir=<buck root>` so PWD in the inherited env
# is the buck root.  PEX/PAR bootstrap may chdir to its extraction dir before
# main() runs, which makes os.path.abspath() resolve against the wrong base.
# Capture the shell-set PWD up front so we can re-anchor relative buck-out
# paths against the buck project root.
_BUCK_ROOT = os.environ.get("PWD") or os.getcwd()


def _abs(path):
    """Resolve to an absolute path against the original buck root."""
    if not path:
        return path
    if os.path.isabs(path):
        return path
    return os.path.normpath(os.path.join(_BUCK_ROOT, path))


def _bootstrap_patchelf(patchelf, ld_linux):
    """Make buckos-built patchelf runnable on the current host.

    The buckos patchelf binary has PT_INTERP baked in as an absolute
    buck-out path that points at the seed sysroot ld-linux from the
    machine that *built* it.  On a fresh CI host the seed is materialised
    at a different absolute path, so the kernel can't find patchelf's
    interpreter and execve returns ENOENT.

    Use the explicit ld-linux loader to invoke patchelf on a writable
    copy of itself, patching that copy's PT_INTERP and RPATH to point
    at the *current* sysroot.  After that, the patched copy executes
    normally and we return it for use as the real patchelf.
    """
    # Try direct invocation first — if patchelf is on the host already
    # or PT_INTERP happens to resolve, no bootstrap needed.
    try:
        result = subprocess.run(
            [patchelf, "--version"],
            capture_output=True,
        )
        if result.returncode == 0:
            return patchelf
    except (FileNotFoundError, OSError):
        pass

    # Compute sysroot lib paths from the ld-linux location:
    # <sysroot>/lib/ld-linux-aarch64.so.1 → sysroot = <sysroot>
    sysroot = os.path.dirname(os.path.dirname(ld_linux))
    sysroot_libs = []
    for sub in ("lib64", "lib", "usr/lib64", "usr/lib"):
        d = os.path.join(sysroot, sub)
        if os.path.isdir(d):
            sysroot_libs.append(d)
    lib_path = ":".join(sysroot_libs)

    scratch = os.environ.get("BUCK_SCRATCH_PATH") or "/tmp"
    scratch = _abs(scratch)
    bootstrap_dir = os.path.join(scratch, "patchelf-bootstrap")
    os.makedirs(bootstrap_dir, exist_ok=True)
    patched = os.path.join(bootstrap_dir, "patchelf")
    shutil.copy2(patchelf, patched)
    os.chmod(patched, 0o755)

    # ld-linux can launch any ELF directly, ignoring its PT_INTERP.
    # Use that to invoke our copy and rewrite its own PT_INTERP+RPATH
    # so subsequent direct invocations work.
    subprocess.run(
        [
            ld_linux,
            "--library-path", lib_path,
            patched,
            "--set-interpreter", ld_linux,
            "--set-rpath", lib_path,
            patched,
        ],
        check=True,
    )
    return patched


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

    # Absolutize input paths up front so subprocess calls work even after
    # PEX bootstrap or portabilize_toolchain may have changed CWD.
    args.ld_linux = _abs(args.ld_linux)
    if args.patchelf:
        args.patchelf = _abs(args.patchelf)
    if args.scratch_dir:
        args.scratch_dir = _abs(args.scratch_dir)
    args.bin_dir = [_abs(d) for d in args.bin_dir]
    args.prefix = [_abs(p) for p in args.prefix]

    # Make sure patchelf itself can run on this host before handing it to
    # portabilize_toolchain (which will subprocess.run it many times).
    if args.patchelf:
        args.patchelf = _bootstrap_patchelf(args.patchelf, args.ld_linux)

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
        # args.bin_dir is already absolutized via _abs() above.
        orig_dirs = list(args.bin_dir)
        port_dirs = portabilize_toolchain(
            orig_dirs,
            args.ld_linux,
            scratch_dir=args.scratch_dir,
            patchelf_path=args.patchelf,
        )
        # Map original bin dir → portabilized bin dir, used to rewrite cmd[0]
        # if the caller passed an absolute path that landed inside one of the
        # original prefixes (e.g. tests doing subprocess.Popen([qemu_bin, ...])).
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

        # If cmd[0] is a path (absolute or relative-to-buck-root) inside one
        # of the original portabilized bin dirs, rewrite it to the
        # portabilized copy so the patched ELF runs.
        cmd0_abs = _abs(cmd[0])
        cmd0_dir = os.path.dirname(cmd0_abs)
        if cmd0_dir in port_map:
            cmd[0] = os.path.join(port_map[cmd0_dir], os.path.basename(cmd0_abs))

    os.execvp(cmd[0], cmd)


if __name__ == "__main__":
    main()
