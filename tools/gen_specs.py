#!/usr/bin/env python3
"""Generate GCC link specs with padded sysroot dynamic linker path.

Writes a GCC specs file that injects --dynamic-linker and -rpath
unconditionally at link time.  The dynamic linker path is left-padded
with '/' to a fixed length so stale_root rewriting can replace it
in-place across machines without resizing the ELF PT_INTERP section.

Usage:
    gen_specs.py --ld-linux /path/to/sysroot/lib64/ld-linux-x86-64.so.2 \
                 --rpath '$ORIGIN/../lib64:$ORIGIN/../lib' \
                 --output gcc-link.specs
"""

import argparse
import os
import sys

# Total padded interpreter path length.  Must be long enough to
# accommodate any buck-out absolute path across machines.
PADDED_LENGTH = 260


def main():
    parser = argparse.ArgumentParser(description="Generate GCC link specs")
    parser.add_argument("--ld-linux", required=True,
                        help="Absolute path to sysroot ld-linux")
    parser.add_argument("--gcc-lib-dir", default=None,
                        help="GCC runtime lib dir (for libstdc++, libgcc_s)")
    parser.add_argument("--rpath", default=None,
                        help="RPATH value (e.g. $ORIGIN/../lib64)")
    parser.add_argument("--output", required=True,
                        help="Output specs file path")
    args = parser.parse_args()

    ld_linux = os.path.abspath(args.ld_linux)

    if len(ld_linux) >= PADDED_LENGTH:
        print(f"error: ld-linux path too long ({len(ld_linux)} >= {PADDED_LENGTH}): {ld_linux}",
              file=sys.stderr)
        sys.exit(1)

    # Left-pad with '/' so the total path length is fixed.
    # Multiple leading slashes collapse to '/' per POSIX.
    pad_count = PADDED_LENGTH - len(ld_linux)
    padded_ld = "/" * pad_count + ld_linux

    # Derive sysroot lib dirs for RPATH — ensures configure test
    # programs find sysroot libc regardless of their location.
    # $ORIGIN-relative RPATH only works for installed binaries in
    # the FHS layout; test programs in build dirs need absolute paths.
    sysroot_dir = os.path.dirname(os.path.dirname(ld_linux))
    rpath_dirs = [
        os.path.join(sysroot_dir, "usr", "lib64"),
        os.path.join(sysroot_dir, "usr", "lib"),
        os.path.join(sysroot_dir, "lib64"),
        os.path.join(sysroot_dir, "lib"),
    ]
    # Add GCC runtime lib dir (libstdc++.so, libgcc_s.so) if provided
    if args.gcc_lib_dir:
        gcc_lib = os.path.abspath(args.gcc_lib_dir)
        if os.path.isdir(gcc_lib):
            rpath_dirs.insert(0, gcc_lib)
    sysroot_rpath = ":".join(d for d in rpath_dirs if os.path.isdir(d))

    # Build spec parts
    parts = [f"--dynamic-linker {padded_ld}"]
    if args.rpath:
        # Sysroot libs first (for test programs), then $ORIGIN (for installed binaries)
        combined_rpath = sysroot_rpath + ":" + args.rpath if sysroot_rpath else args.rpath
        # Use DT_RPATH (not DT_RUNPATH) so search paths propagate to
        # loaded shared libraries.  DT_RUNPATH only covers the main
        # binary — deps like librustc_driver.so would fall back to
        # /lib64/libstdc++.so.6 (host) without propagation.
        parts.append(f"--disable-new-dtags -rpath {combined_rpath}")

    # GCC specs format:
    # *link:            — override/append the link spec
    # +                 — append to the built-in spec (don't replace)
    #
    # Split into two clauses:
    # 1. --dynamic-linker: only for executables (%{!shared:%{!static:...}})
    # 2. -rpath/--disable-new-dtags: for executables AND shared libs
    #    (%{!static:...}) so .so files like librustc_driver.so also get
    #    sysroot RPATH and find buckos libstdc++ at runtime.
    interp_parts = [p for p in parts if "dynamic-linker" in p]
    rpath_parts = [p for p in parts if "dynamic-linker" not in p]

    clauses = []
    if interp_parts:
        clauses.append(f"%{{!shared:%{{!static:{' '.join(interp_parts)}}}}}")
    if rpath_parts:
        clauses.append(f"%{{!static:{' '.join(rpath_parts)}}}")

    specs = (
        "*link:\n"
        f"+ {' '.join(clauses)}\n"
        "\n"
    )

    with open(args.output, "w") as f:
        f.write(specs)


if __name__ == "__main__":
    main()
