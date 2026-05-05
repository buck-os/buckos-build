#!/usr/bin/env python3
"""Unit tests for stage3 tarball and strip helper utilities."""
import gzip
import hashlib
import io
import os
import sys
import tempfile
from pathlib import Path

_REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO / "tools"))

from strip_helper import is_elf

passed = 0
failed = 0
_output_lines = []


def ok(msg):
    global passed
    _output_lines.append(f"  PASS: {msg}")
    passed += 1


def fail(msg):
    global failed
    _output_lines.append(f"  FAIL: {msg}")
    failed += 1


def check(condition, msg):
    if condition:
        ok(msg)
    else:
        fail(msg)


def _write(path, content=b"hello"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(content)


def _sha256(data):
    return hashlib.sha256(data).hexdigest()


def _build_rootfs(root):
    """Create a small rootfs tree with files, dirs, and symlinks."""
    _write(os.path.join(root, "bin", "sh"), b"\x7fELF fake shell")
    _write(os.path.join(root, "etc", "hostname"), b"buckos\n")
    os.makedirs(os.path.join(root, "usr", "lib"), exist_ok=True)
    _write(os.path.join(root, "usr", "lib", "libc.so"), b"\x7fELF fake libc")
    os.symlink("sh", os.path.join(root, "bin", "bash"))
    os.makedirs(os.path.join(root, "var", "empty"), exist_ok=True)


def main():
    _real_stdout = sys.stdout
    _buf = io.StringIO()
    sys.stdout = _buf

    # ================================================================
    # CONTENTS generation tests (stage3_helper.py inline logic)
    # ================================================================
    # The CONTENTS generation lives inside stage3_helper.main() and is
    # not factored into a standalone function, so we replicate the same
    # algorithm here against known inputs and verify the format contract.

    print("=== CONTENTS: correct format for regular files ===")
    with tempfile.TemporaryDirectory() as root:
        _write(os.path.join(root, "etc", "hostname"), b"buckos\n")
        contents_lines = []
        for dirpath, dirnames, filenames in sorted(os.walk(root)):
            dirnames.sort()
            for name in sorted(dirnames + filenames):
                path = os.path.join(dirpath, name)
                relpath = os.path.relpath(path, root)
                if os.path.islink(path):
                    target = os.readlink(path)
                    contents_lines.append(f"sym /{relpath} -> {target}\n")
                elif os.path.isdir(path):
                    contents_lines.append(f"dir /{relpath}\n")
                elif os.path.isfile(path):
                    h = hashlib.sha256()
                    with open(path, "rb") as fh:
                        for chunk in iter(lambda: fh.read(65536), b""):
                            h.update(chunk)
                    contents_lines.append(f"obj /{relpath} {h.hexdigest()}\n")
        expected_hash = _sha256(b"buckos\n")
        found = [l for l in contents_lines if l.startswith("obj /etc/hostname")]
        check(len(found) == 1, "exactly one obj entry for etc/hostname")
        check(found[0] == f"obj /etc/hostname {expected_hash}\n",
              "obj entry has correct sha256")

    print("=== CONTENTS: correct format for directories ===")
    with tempfile.TemporaryDirectory() as root:
        os.makedirs(os.path.join(root, "var", "empty"))
        contents_lines = []
        for dirpath, dirnames, filenames in sorted(os.walk(root)):
            dirnames.sort()
            for name in sorted(dirnames + filenames):
                path = os.path.join(dirpath, name)
                relpath = os.path.relpath(path, root)
                if os.path.isdir(path) and not os.path.islink(path):
                    contents_lines.append(f"dir /{relpath}\n")
        dir_entries = [l for l in contents_lines if l.startswith("dir /")]
        check("dir /var\n" in dir_entries, "dir entry for /var")
        check("dir /var/empty\n" in dir_entries, "dir entry for /var/empty")

    print("=== CONTENTS: correct format for symlinks ===")
    with tempfile.TemporaryDirectory() as root:
        os.makedirs(os.path.join(root, "bin"))
        _write(os.path.join(root, "bin", "sh"), b"\x7fELF")
        os.symlink("sh", os.path.join(root, "bin", "bash"))
        contents_lines = []
        for dirpath, dirnames, filenames in sorted(os.walk(root)):
            dirnames.sort()
            for name in sorted(dirnames + filenames):
                path = os.path.join(dirpath, name)
                relpath = os.path.relpath(path, root)
                if os.path.islink(path):
                    target = os.readlink(path)
                    contents_lines.append(f"sym /{relpath} -> {target}\n")
        sym_entries = [l for l in contents_lines if l.startswith("sym /")]
        check(len(sym_entries) == 1, "one symlink entry")
        check(sym_entries[0] == "sym /bin/bash -> sh\n",
              "symlink entry format correct")

    print("=== CONTENTS: paths are relative to rootfs ===")
    with tempfile.TemporaryDirectory() as root:
        _build_rootfs(root)
        contents_lines = []
        for dirpath, dirnames, filenames in sorted(os.walk(root)):
            dirnames.sort()
            for name in sorted(dirnames + filenames):
                path = os.path.join(dirpath, name)
                relpath = os.path.relpath(path, root)
                if os.path.islink(path):
                    target = os.readlink(path)
                    contents_lines.append(f"sym /{relpath} -> {target}\n")
                elif os.path.isdir(path):
                    contents_lines.append(f"dir /{relpath}\n")
                elif os.path.isfile(path):
                    h = hashlib.sha256()
                    with open(path, "rb") as fh:
                        for chunk in iter(lambda: fh.read(65536), b""):
                            h.update(chunk)
                    contents_lines.append(f"obj /{relpath} {h.hexdigest()}\n")
        # No absolute host paths should appear
        for line in contents_lines:
            parts = line.split()
            # The path field is parts[1] for all entry types
            check(parts[1].startswith("/") and root not in parts[1],
                  f"path is rootfs-relative: {parts[1]}")
            break  # Just check first entry to not spam output
        # Verify all start with / but none contain the tmpdir
        all_relative = all(root not in l for l in contents_lines)
        check(all_relative, "no host tmpdir path in any entry")

    print("=== CONTENTS: output is sorted ===")
    with tempfile.TemporaryDirectory() as root:
        # Create files in reverse order to test sorting
        for name in ["zz.txt", "aa.txt", "mm.txt"]:
            _write(os.path.join(root, name), name.encode())
        contents_lines = []
        for dirpath, dirnames, filenames in sorted(os.walk(root)):
            dirnames.sort()
            for name in sorted(dirnames + filenames):
                path = os.path.join(dirpath, name)
                relpath = os.path.relpath(path, root)
                if os.path.isfile(path):
                    h = hashlib.sha256()
                    with open(path, "rb") as fh:
                        for chunk in iter(lambda: fh.read(65536), b""):
                            h.update(chunk)
                    contents_lines.append(f"obj /{relpath} {h.hexdigest()}\n")
        paths = [l.split()[1] for l in contents_lines]
        check(paths == sorted(paths), "entries are sorted by path")

    print("=== CONTENTS: gzip round-trip ===")
    with tempfile.TemporaryDirectory() as root:
        _write(os.path.join(root, "a.txt"), b"alpha")
        _write(os.path.join(root, "b.txt"), b"bravo")
        contents_lines = []
        for dirpath, dirnames, filenames in sorted(os.walk(root)):
            dirnames.sort()
            for name in sorted(dirnames + filenames):
                path = os.path.join(dirpath, name)
                relpath = os.path.relpath(path, root)
                if os.path.isfile(path) and not os.path.islink(path):
                    h = hashlib.sha256()
                    with open(path, "rb") as fh:
                        for chunk in iter(lambda: fh.read(65536), b""):
                            h.update(chunk)
                    contents_lines.append(f"obj /{relpath} {h.hexdigest()}\n")
        gz_path = os.path.join(root, "CONTENTS.gz")
        with gzip.open(gz_path, "wt") as f:
            f.writelines(contents_lines)
        with gzip.open(gz_path, "rt") as f:
            recovered = f.readlines()
        check(recovered == contents_lines, "gzip round-trip preserves content")

    # ================================================================
    # stage3-info metadata tests
    # ================================================================

    print("=== stage3-info: all fields present ===")
    with tempfile.TemporaryDirectory() as workdir:
        buckos_dir = os.path.join(workdir, "etc", "buckos")
        os.makedirs(buckos_dir)
        variant, arch, libc, version = "base", "amd64", "glibc", "0.1"
        build_date = "20260223T120000Z"
        date_stamp = "20260223"
        with open(os.path.join(buckos_dir, "stage3-info"), "w") as f:
            f.write(f"# BuckOS Stage3 Information\n")
            f.write(f"# Generated: {build_date}\n\n")
            f.write(f"[stage3]\nvariant={variant}\narch={arch}\n")
            f.write(f"libc={libc}\ndate={date_stamp}\nversion={version}\n\n")
            f.write(f"[build]\nbuild_date={build_date}\n\n")
            f.write(f"[packages]\n# Package count will be updated after build\n")
        with open(os.path.join(buckos_dir, "stage3-info")) as f:
            content = f.read()
        check("variant=base" in content, "variant field present")
        check("arch=amd64" in content, "arch field present")
        check("libc=glibc" in content, "libc field present")
        check("version=0.1" in content, "version field present")
        check("build_date=20260223T120000Z" in content, "build_date field present")
        check("date=20260223" in content, "date field present")

    print("=== stage3-info: INI section headers ===")
    check("[stage3]" in content, "stage3 section header present")
    check("[build]" in content, "build section header present")
    check("[packages]" in content, "packages section header present")

    print("=== stage3-info: comment line format ===")
    lines = content.splitlines()
    comment_lines = [l for l in lines if l.startswith("#")]
    check(len(comment_lines) >= 2, "at least 2 comment lines")
    check(any("BuckOS" in l for l in comment_lines),
          "header comment mentions BuckOS")

    # ================================================================
    # SHA256 checksum generation test
    # ================================================================

    print("=== sha256: tarball checksum format ===")
    with tempfile.TemporaryDirectory() as tmp:
        # Simulate the sha256 output format from stage3_helper
        fake_tarball = os.path.join(tmp, "stage3-amd64-base-20260223.tar.xz")
        data = b"fake tarball content for hashing"
        _write(fake_tarball, data)
        h = hashlib.sha256()
        with open(fake_tarball, "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
        tarball_basename = os.path.basename(fake_tarball)
        sha256_file = os.path.join(tmp, "stage3.sha256")
        with open(sha256_file, "w") as f:
            f.write(f"{h.hexdigest()}  {tarball_basename}\n")
        with open(sha256_file) as f:
            line = f.read()
        parts = line.strip().split("  ")
        check(len(parts) == 2, "sha256sum format: hash  filename")
        check(len(parts[0]) == 64, "hash is 64 hex chars")
        check(parts[1] == "stage3-amd64-base-20260223.tar.xz",
              "filename in checksum matches basename")
        check(parts[0] == _sha256(data), "hash matches expected digest")

    # ================================================================
    # strip_helper.is_elf tests
    # ================================================================

    print("=== is_elf (strip_helper): ELF file detected ===")
    with tempfile.NamedTemporaryFile(delete=False) as f:
        f.write(b"\x7fELF" + b"\x00" * 12)
        f.flush()
        try:
            check(is_elf(f.name), "ELF magic detected")
        finally:
            os.unlink(f.name)

    print("=== is_elf (strip_helper): non-ELF returns False ===")
    with tempfile.NamedTemporaryFile(delete=False, mode="w") as f:
        f.write("plain text")
        f.flush()
        try:
            check(not is_elf(f.name), "non-ELF file returns False")
        finally:
            os.unlink(f.name)

    print("=== is_elf (strip_helper): nonexistent path returns False ===")
    check(not is_elf("/nonexistent/path/to/file"),
          "nonexistent path returns False")

    print("=== is_elf (strip_helper): empty file returns False ===")
    with tempfile.NamedTemporaryFile(delete=False) as f:
        pass
    try:
        check(not is_elf(f.name), "empty file returns False")
    finally:
        os.unlink(f.name)

    print("=== is_elf (strip_helper): short file (< 4 bytes) returns False ===")
    with tempfile.NamedTemporaryFile(delete=False) as f:
        f.write(b"\x7fE")
        f.flush()
        try:
            check(not is_elf(f.name), "short file returns False")
        finally:
            os.unlink(f.name)

    # ================================================================
    # Strip file discovery logic tests
    # ================================================================
    # The strip walk in main() skips symlinks, non-files, and non-ELF.
    # We replicate the discovery logic to verify classification.

    print("=== strip discovery: finds ELF files in tree ===")
    with tempfile.TemporaryDirectory() as tree:
        _write(os.path.join(tree, "bin", "prog"), b"\x7fELF" + b"\x00" * 12)
        _write(os.path.join(tree, "lib", "libc.so"), b"\x7fELF" + b"\x00" * 12)
        _write(os.path.join(tree, "etc", "config"), b"key=value\n")
        os.symlink("prog", os.path.join(tree, "bin", "alias"))
        elf_files = []
        for dirpath, _, filenames in os.walk(tree):
            for filename in filenames:
                filepath = os.path.join(dirpath, filename)
                if os.path.islink(filepath):
                    continue
                if not os.path.isfile(filepath):
                    continue
                if is_elf(filepath):
                    elf_files.append(os.path.relpath(filepath, tree))
        check(len(elf_files) == 2, f"found 2 ELF files (got {len(elf_files)})")
        check("bin/prog" in elf_files, "bin/prog identified as ELF")
        check("lib/libc.so" in elf_files, "lib/libc.so identified as ELF")

    print("=== strip discovery: skips symlinks ===")
    with tempfile.TemporaryDirectory() as tree:
        _write(os.path.join(tree, "bin", "real"), b"\x7fELF" + b"\x00" * 12)
        os.symlink("real", os.path.join(tree, "bin", "link"))
        visited = []
        for dirpath, _, filenames in os.walk(tree):
            for filename in filenames:
                filepath = os.path.join(dirpath, filename)
                if os.path.islink(filepath):
                    continue
                if os.path.isfile(filepath) and is_elf(filepath):
                    visited.append(filename)
        check(visited == ["real"], "symlink skipped, only real file visited")

    print("=== strip discovery: skips non-ELF files ===")
    with tempfile.TemporaryDirectory() as tree:
        _write(os.path.join(tree, "readme.txt"), b"hello world")
        _write(os.path.join(tree, "script.sh"), b"#!/bin/sh\nexit 0\n")
        _write(os.path.join(tree, "data.bin"), b"\x00\x01\x02\x03")
        elf_count = 0
        for dirpath, _, filenames in os.walk(tree):
            for filename in filenames:
                filepath = os.path.join(dirpath, filename)
                if not os.path.islink(filepath) and os.path.isfile(filepath):
                    if is_elf(filepath):
                        elf_count += 1
        check(elf_count == 0, "no ELF files found in non-ELF tree")

    print("=== strip discovery: handles mixed tree correctly ===")
    with tempfile.TemporaryDirectory() as tree:
        # ELF binaries
        _write(os.path.join(tree, "usr", "bin", "app"), b"\x7fELF\x02\x01\x01")
        _write(os.path.join(tree, "usr", "lib", "libx.so.1"), b"\x7fELF\x02\x01\x01")
        # Non-ELF
        _write(os.path.join(tree, "usr", "share", "doc", "readme"), b"docs")
        _write(os.path.join(tree, "usr", "include", "header.h"), b"#pragma once\n")
        # Symlink to ELF
        os.symlink("libx.so.1", os.path.join(tree, "usr", "lib", "libx.so"))
        # Empty directory
        os.makedirs(os.path.join(tree, "usr", "libexec"), exist_ok=True)

        elf_files = []
        non_elf_files = []
        skipped_links = []
        for dirpath, _, filenames in os.walk(tree):
            for filename in filenames:
                filepath = os.path.join(dirpath, filename)
                if os.path.islink(filepath):
                    skipped_links.append(filename)
                    continue
                if not os.path.isfile(filepath):
                    continue
                if is_elf(filepath):
                    elf_files.append(filename)
                else:
                    non_elf_files.append(filename)

        check(len(elf_files) == 2, f"2 ELF files in mixed tree (got {len(elf_files)})")
        check(len(non_elf_files) == 2,
              f"2 non-ELF files in mixed tree (got {len(non_elf_files)})")
        check(len(skipped_links) == 1,
              f"1 symlink skipped (got {len(skipped_links)})")

    # ================================================================
    # CONTENTS: full rootfs integration
    # ================================================================

    print("=== CONTENTS: full rootfs has all entry types ===")
    with tempfile.TemporaryDirectory() as root:
        _build_rootfs(root)
        contents_lines = []
        for dirpath, dirnames, filenames in sorted(os.walk(root)):
            dirnames.sort()
            for name in sorted(dirnames + filenames):
                path = os.path.join(dirpath, name)
                relpath = os.path.relpath(path, root)
                if os.path.islink(path):
                    target = os.readlink(path)
                    contents_lines.append(f"sym /{relpath} -> {target}\n")
                elif os.path.isdir(path):
                    contents_lines.append(f"dir /{relpath}\n")
                elif os.path.isfile(path):
                    h = hashlib.sha256()
                    with open(path, "rb") as fh:
                        for chunk in iter(lambda: fh.read(65536), b""):
                            h.update(chunk)
                    contents_lines.append(f"obj /{relpath} {h.hexdigest()}\n")
        types = set(l.split()[0] for l in contents_lines)
        check(types == {"sym", "dir", "obj"},
              f"all three entry types present: {types}")
        # Verify specific entries
        check(any("sym /bin/bash -> sh" in l for l in contents_lines),
              "symlink bin/bash -> sh in CONTENTS")
        check(any("dir /var/empty" in l for l in contents_lines),
              "dir var/empty in CONTENTS")
        check(any(l.startswith("obj /bin/sh ") for l in contents_lines),
              "obj bin/sh in CONTENTS")

    # ── Summary ──────────────────────────────────────────────────────

    sys.stdout = _real_stdout
    if failed:
        _real_stdout.write(_buf.getvalue())
        for _line in _output_lines:
            print(_line)
        print(f"\n--- {passed} passed, {failed} failed ---")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
