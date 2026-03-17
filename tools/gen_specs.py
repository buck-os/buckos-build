#!/usr/bin/env python3
"""Generate GCC link specs with padded sysroot dynamic linker path.

Writes a GCC specs file that injects --dynamic-linker and -rpath
unconditionally at link time.  Uses GCC's %R substitution (expands
to --sysroot value at invocation time) so the specs file content is
machine-independent — safely cacheable by remote action caches.

The dynamic linker path is left-padded with '/' to a fixed length so
rewrite_interps.py can replace it in-place across machines without
resizing the ELF PT_INTERP section.

Usage:
    gen_specs.py --ld-linux-subpath lib64/ld-linux-x86-64.so.2 \
                 --rpath '$ORIGIN/../lib64:$ORIGIN/../lib' \
                 --output gcc-link.specs
"""

import argparse
import sys

# Fixed padding length (number of '/' characters prepended).
# The padding is additive: total PT_INTERP = PADDED_LENGTH + len(sysroot)
# + len(subpath).  No upper bound on sysroot path length.
PADDED_LENGTH = 260


def main():
    parser = argparse.ArgumentParser(description="Generate GCC link specs")
    parser.add_argument("--ld-linux-subpath",
                        default="lib64/ld-linux-x86-64.so.2",
                        help="ld-linux path relative to sysroot")
    parser.add_argument("--rpath", default=None,
                        help="RPATH value (e.g. $ORIGIN/../lib64)")
    parser.add_argument("--output", required=True,
                        help="Output specs file path")
    args = parser.parse_args()

    # Build padded interpreter using %R (GCC's sysroot substitution).
    # %R expands to target_system_root at gcc invocation time, set by
    # --sysroot=.  The fixed '/' padding ensures PT_INTERP is large
    # enough for in-place rewriting regardless of sysroot path length.
    padded_ld = "/" * PADDED_LENGTH + "%R/" + args.ld_linux_subpath

    # Sysroot lib dirs for RPATH using %R — ensures configure test
    # programs find sysroot libc regardless of their location.
    # $ORIGIN-relative RPATH only works for installed binaries in
    # the FHS layout; test programs in build dirs need sysroot paths.
    # Non-existent dirs are silently skipped by ld.so.
    # %R/../lib64 reaches the GCC runtime lib dir (libgcc_s, libstdc++)
    # which sits at <sysroot>/../lib64 — outside the sysroot but at a
    # fixed relative position.  Without this, binaries fall back to the
    # host's /lib64/libgcc_s.so.1 which needs GLIBC_ABI_GNU2_TLS that
    # the sysroot glibc doesn't provide.
    sysroot_rpath = "%R/usr/lib64:%R/usr/lib:%R/lib64:%R/lib:%R/../lib64"

    # Build spec parts
    parts = [f"--dynamic-linker {padded_ld}"]
    if args.rpath:
        # Sysroot libs first (for test programs), then $ORIGIN (for installed binaries)
        combined_rpath = sysroot_rpath + ":" + args.rpath
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
