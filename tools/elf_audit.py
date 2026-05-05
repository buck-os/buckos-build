#!/usr/bin/env python3
"""ELF dependency audit tool.

Scans a package prefix for ELF binaries, extracts DT_NEEDED entries via
readelf, and verifies they can be resolved against declared deps or the
sysroot.

Exit codes:
  0 — all NEEDED entries resolve to declared deps or known sysroot libs
  1 — unresolved NEEDED entries found (missing deps)
  2 — usage error
"""

import argparse
import os
import re
import subprocess
import sys

# Libraries provided by the base sysroot (glibc, gcc runtime, ld-linux).
# These never need an explicit dep declaration.
SYSROOT_SONAMES = {
    "libc.so.6",
    "libm.so.6",
    "libdl.so.2",
    "libpthread.so.0",
    "librt.so.1",
    "libutil.so.1",
    "libresolv.so.2",
    "libnss_dns.so.2",
    "libnss_files.so.2",
    "libcrypt.so.1",
    "libcrypt.so.2",
    "libmvec.so.1",
    "libnsl.so.1",
    "ld-linux-x86-64.so.2",
    "libstdc++.so.6",
    "libgcc_s.so.1",
    "libatomic.so.1",
    "libgomp.so.1",
    "libquadmath.so.0",
    "libasan.so",
    "libtsan.so",
    "libubsan.so",
    "linux-vdso.so.1",
}

# Regex for readelf NEEDED output: 0x... (NEEDED) Shared library: [libfoo.so.1]
_NEEDED_RE = re.compile(r"\(NEEDED\)\s+Shared library:\s+\[(.+?)\]")


def _find_elf_files(prefix):
    """Find all ELF files under a prefix directory."""
    elf_files = []
    for dirpath, _, filenames in os.walk(prefix):
        for fname in filenames:
            fpath = os.path.join(dirpath, fname)
            if os.path.islink(fpath):
                continue
            if not os.path.isfile(fpath):
                continue
            try:
                with open(fpath, "rb") as f:
                    magic = f.read(4)
                if magic == b"\x7fELF":
                    elf_files.append(fpath)
            except (OSError, IOError):
                continue
    return elf_files


def _extract_needed(elf_path):
    """Extract DT_NEEDED entries from an ELF file."""
    try:
        result = subprocess.run(
            ["readelf", "-d", elf_path],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode != 0:
            return []
        needed = []
        for line in result.stdout.splitlines():
            m = _NEEDED_RE.search(line)
            if m:
                needed.append(m.group(1))
        return needed
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return []


def _collect_provided_sonames(dep_prefixes):
    """Collect all .so files provided by dep prefixes."""
    provided = set()
    for prefix in dep_prefixes:
        for lib_dir in ("usr/lib64", "usr/lib", "lib64", "lib"):
            d = os.path.join(prefix, lib_dir)
            if not os.path.isdir(d):
                continue
            for fname in os.listdir(d):
                if ".so" in fname:
                    provided.add(fname)
                    # Also add the soname base (libfoo.so.1 matches libfoo.so.1.2.3)
                    # and the symlink names
                    if os.path.islink(os.path.join(d, fname)):
                        target = os.path.basename(os.readlink(os.path.join(d, fname)))
                        provided.add(target)
    return provided


def main():
    parser = argparse.ArgumentParser(description="Audit ELF dependencies")
    parser.add_argument("--prefix", required=True,
                        help="Package prefix to scan for ELF binaries")
    parser.add_argument("--dep-prefix", action="append", dest="dep_prefixes",
                        default=[], help="Dep prefix to check against (repeatable)")
    parser.add_argument("--dep-prefix-list", default=None,
                        help="File with dep prefix paths (one per line)")
    parser.add_argument("--allow-unresolved", action="append",
                        dest="allow_unresolved", default=[],
                        help="Soname to allow even if unresolved (repeatable)")
    parser.add_argument("--verbose", action="store_true",
                        help="Print all NEEDED entries, not just unresolved")
    args = parser.parse_args()

    prefix = os.path.abspath(args.prefix)
    if not os.path.isdir(prefix):
        print(f"error: prefix not found: {prefix}", file=sys.stderr)
        sys.exit(2)

    # Collect dep prefixes
    dep_prefixes = [os.path.abspath(p) for p in args.dep_prefixes]
    if args.dep_prefix_list:
        with open(args.dep_prefix_list) as f:
            for line in f:
                line = line.strip()
                if line:
                    dep_prefixes.append(os.path.abspath(line))

    # Include the package's own prefix as a provider
    dep_prefixes.insert(0, prefix)

    # Collect all sonames provided by deps
    provided = _collect_provided_sonames(dep_prefixes)
    allowed = set(args.allow_unresolved)

    # Scan for ELF files
    elf_files = _find_elf_files(prefix)
    if not elf_files:
        print(f"No ELF files found in {prefix}")
        sys.exit(0)

    # Check each ELF file
    unresolved_map = {}  # soname -> list of elf paths
    total_needed = 0

    for elf_path in elf_files:
        needed = _extract_needed(elf_path)
        for soname in needed:
            total_needed += 1
            if args.verbose:
                rel = os.path.relpath(elf_path, prefix)
                print(f"  {rel}: NEEDED {soname}")

            if soname in SYSROOT_SONAMES:
                continue
            if soname in provided:
                continue
            if soname in allowed:
                continue
            # Wildcard match for versioned sonames (libasan.so matches libasan.so.8)
            base = soname.split(".so")[0] + ".so"
            if base in SYSROOT_SONAMES:
                continue

            rel = os.path.relpath(elf_path, prefix)
            if soname not in unresolved_map:
                unresolved_map[soname] = []
            unresolved_map[soname].append(rel)

    if unresolved_map:
        print(f"FAIL: {len(unresolved_map)} unresolved soname(s) in {prefix}:")
        for soname, paths in sorted(unresolved_map.items()):
            print(f"  {soname}")
            for p in paths[:5]:
                print(f"    needed by: {p}")
            if len(paths) > 5:
                print(f"    ... and {len(paths) - 5} more")
        sys.exit(1)
    else:
        print(f"OK: {len(elf_files)} ELF files, {total_needed} NEEDED entries, all resolved")
        sys.exit(0)


if __name__ == "__main__":
    main()
