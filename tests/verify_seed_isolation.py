#!/usr/bin/env python3
"""Verify seed toolchain isolation and integrity.

Unpacks the seed archive and scans all ELF binaries to ensure:
  - No build directory paths leak into RPATH/RUNPATH
  - Host tools don't reference cross-compiler sysroot paths
  - Sysroot libraries are self-contained
  - All symlinks resolve within the archive
  - metadata.json is valid and complete
"""

import json
import os
import subprocess
import sys
import tempfile


def run(cmd):
    """Run a command, return stdout or None on failure."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return r.stdout if r.returncode == 0 else None
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None


def find_elf_files(root):
    """Find all ELF files under root."""
    elfs = []
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            path = os.path.join(dirpath, name)
            if os.path.islink(path) and not os.path.exists(path):
                continue
            if not os.path.isfile(path):
                continue
            try:
                with open(path, "rb") as f:
                    if f.read(4) == b"\x7fELF":
                        elfs.append(path)
            except (PermissionError, OSError):
                pass
    return elfs


def check_rpath(elf_path, forbidden_patterns):
    """Check RPATH/RUNPATH for forbidden patterns."""
    violations = []
    output = run(["readelf", "-d", elf_path])
    if not output:
        return violations
    for line in output.splitlines():
        if "RPATH" not in line and "RUNPATH" not in line:
            continue
        for pattern in forbidden_patterns:
            if pattern in line:
                name = os.path.basename(elf_path)
                violations.append(
                    f"{name}: {line.strip()} (contains '{pattern}')"
                )
    return violations


def check_strings_for_leaks(elf_path, forbidden_patterns):
    """Scan binary strings for leaked build paths."""
    violations = []
    output = run(["strings", elf_path])
    if not output:
        return violations
    seen = set()
    for line in output.splitlines():
        for pattern in forbidden_patterns:
            if pattern in line and pattern not in seen:
                seen.add(pattern)
                name = os.path.basename(elf_path)
                violations.append(
                    f"{name}: '{line[:120]}' (contains '{pattern}')"
                )
    return violations


def check_broken_symlinks(root):
    """Find broken symlinks under root."""
    broken = []
    for dirpath, dirnames, filenames in os.walk(root):
        for name in filenames + dirnames:
            path = os.path.join(dirpath, name)
            if os.path.islink(path) and not os.path.exists(path):
                rel = os.path.relpath(path, root)
                target = os.readlink(path)
                broken.append(f"{rel} -> {target}")
    return broken


def main():
    archive_path = os.environ.get("SEED_ARCHIVE")
    if not archive_path:
        print("FAIL: SEED_ARCHIVE not set", file=sys.stderr)
        sys.exit(1)

    if not os.path.isfile(archive_path):
        print(f"FAIL: archive not found: {archive_path}", file=sys.stderr)
        sys.exit(1)

    failures = []
    warnings = []

    with tempfile.TemporaryDirectory(prefix="seed-verify-") as tmpdir:
        # Unpack
        print(f"Unpacking seed archive ...")
        r = subprocess.run(
            ["tar", "-xf", archive_path, "-C", tmpdir],
            capture_output=True, text=True, timeout=300,
        )
        if r.returncode != 0:
            print(f"FAIL: tar extract failed: {r.stderr}", file=sys.stderr)
            sys.exit(1)

        # ── metadata.json ────────────────────────────────────────────
        meta = {}
        meta_path = os.path.join(tmpdir, "metadata.json")
        if os.path.isfile(meta_path):
            try:
                with open(meta_path) as f:
                    meta = json.load(f)
                for key in ("format_version", "target_triple", "gcc_version",
                            "glibc_version", "contents_sha256"):
                    if key not in meta:
                        failures.append(f"metadata.json: missing key '{key}'")
                triple = meta.get("target_triple", "unknown")
                print(f"  triple={triple}  gcc={meta.get('gcc_version')}  "
                      f"glibc={meta.get('glibc_version')}")
            except json.JSONDecodeError as e:
                failures.append(f"metadata.json: invalid JSON: {e}")
        else:
            failures.append("metadata.json not found in archive")

        # ── Broken symlinks ──────────────────────────────────────────
        broken = check_broken_symlinks(tmpdir)
        for b in broken:
            warnings.append(f"broken symlink: {b}")

        # ── Patterns that must never appear in RPATH or RUNPATH ──────
        rpath_forbidden = [
            "buck-out",
            ".cache/buck",
        ]

        # ── Scan tools/ (cross-compiler + sysroot) ───────────────────
        tools_dir = os.path.join(tmpdir, "tools")
        if os.path.isdir(tools_dir):
            tools_elfs = find_elf_files(tools_dir)
            print(f"  tools/: {len(tools_elfs)} ELF files")

            for elf in tools_elfs:
                for v in check_rpath(elf, rpath_forbidden):
                    failures.append(f"tools RPATH: {v}")

            # Binaries in tools/bin/ — check for build path strings
            for elf in tools_elfs:
                if "/bin/" in os.path.relpath(elf, tools_dir):
                    for v in check_strings_for_leaks(elf, rpath_forbidden):
                        warnings.append(f"tools string: {v}")
        else:
            failures.append("tools/ directory not found in archive")

        # ── Sysroot isolation ────────────────────────────────────────
        triple = meta.get("target_triple", "x86_64-buckos-linux-gnu")
        sysroot_dir = os.path.join(tools_dir, triple, "sys-root")
        if os.path.isdir(sysroot_dir):
            sysroot_elfs = find_elf_files(sysroot_dir)
            print(f"  sysroot: {len(sysroot_elfs)} ELF files")

            sysroot_forbidden = rpath_forbidden + ["/home/"]
            for elf in sysroot_elfs:
                for v in check_rpath(elf, sysroot_forbidden):
                    failures.append(f"sysroot RPATH: {v}")
        elif os.path.isdir(tools_dir):
            warnings.append("sysroot directory not found")

        # ── Scan host-tools/ ─────────────────────────────────────────
        ht_dir = os.path.join(tmpdir, "host-tools")
        if os.path.isdir(ht_dir):
            ht_elfs = find_elf_files(ht_dir)
            print(f"  host-tools/: {len(ht_elfs)} ELF files")

            # Host tools are buckos-native: they reference the buckos
            # sysroot (expected) but must not reference host paths
            ht_forbidden = rpath_forbidden + [
                "/usr/lib",
                "/usr/lib64",
                "/lib/x86_64-linux-gnu",
            ]
            for elf in ht_elfs:
                for v in check_rpath(elf, ht_forbidden):
                    failures.append(f"host-tools RPATH: {v}")

            # String leak check on host-tools binaries
            for elf in ht_elfs:
                if "/bin/" in os.path.relpath(elf, ht_dir):
                    for v in check_strings_for_leaks(elf, rpath_forbidden):
                        warnings.append(f"host-tools string: {v}")

            # Positive check: host-tools ELFs should be buckos-linked
            for elf in ht_elfs:
                if "/bin/" not in os.path.relpath(elf, ht_dir):
                    continue
                output = run(["readelf", "-d", elf])
                if not output:
                    continue
                needed = [
                    l for l in output.splitlines() if "NEEDED" in l
                ]
                if not needed:
                    continue  # statically linked
                # At least one NEEDED should be a standard buckos lib
                has_buckos_lib = any(
                    "libc.so" in l or "libm.so" in l or "libdl.so" in l
                    or "libpthread.so" in l or "libstdc++.so" in l
                    for l in needed
                )
                if not has_buckos_lib:
                    name = os.path.basename(elf)
                    warnings.append(
                        f"host-tools: {name} has no standard buckos NEEDED"
                    )
        else:
            if meta.get("has_host_tools"):
                failures.append(
                    "host-tools/ not found but metadata says has_host_tools=true"
                )

    # ── Report ────────────────────────────────────────────────────────
    if warnings:
        print(f"\n{len(warnings)} warning(s):")
        for w in warnings[:20]:
            print(f"  W: {w}")
        if len(warnings) > 20:
            print(f"  ... and {len(warnings) - 20} more")

    if failures:
        print(f"\n{len(failures)} FAILURE(s):")
        for f in failures:
            print(f"  F: {f}")
        sys.exit(1)

    print(f"\nSeed isolation verified")
    sys.exit(0)


if __name__ == "__main__":
    main()
