#!/usr/bin/env python3
"""Unit tests for toolchain_unpack.py: detect_compression and sha256_directory."""
import hashlib
import os
import sys
import tempfile
from pathlib import Path

_REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO / "tools"))

from toolchain_unpack import detect_compression, sha256_directory
from toolchain_pack import sha256_directory as pack_sha256_directory

passed = 0
failed = 0


def ok(msg):
    global passed
    print(f"  PASS: {msg}")
    passed += 1


def fail(msg):
    global failed
    print(f"  FAIL: {msg}")
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


def main():
    # ── detect_compression tests ────────────────────────────────────

    print("=== detect_compression: .tar.zst ===")
    check(detect_compression("toolchain.tar.zst") == "zst",
          ".tar.zst -> zst")

    print("=== detect_compression: .tar.zstd ===")
    check(detect_compression("toolchain.tar.zstd") == "zst",
          ".tar.zstd -> zst")

    print("=== detect_compression: .tar.xz ===")
    check(detect_compression("toolchain.tar.xz") == "xz",
          ".tar.xz -> xz")

    print("=== detect_compression: .tar.gz ===")
    check(detect_compression("archive.tar.gz") == "gz",
          ".tar.gz -> gz")

    print("=== detect_compression: .tgz ===")
    check(detect_compression("archive.tgz") == "gz",
          ".tgz -> gz")

    print("=== detect_compression: .tar (plain) ===")
    check(detect_compression("archive.tar") == "auto",
          ".tar -> auto")

    print("=== detect_compression: .zip ===")
    check(detect_compression("archive.zip") == "zip",
          ".zip -> zip")

    print("=== detect_compression: full path preserved ===")
    check(detect_compression("/tmp/builds/seed.tar.zst") == "zst",
          "full path .tar.zst -> zst")
    check(detect_compression("/tmp/builds/seed.tar.xz") == "xz",
          "full path .tar.xz -> xz")
    check(detect_compression("/tmp/builds/seed.tar.gz") == "gz",
          "full path .tar.gz -> gz")

    print("=== detect_compression: no extension ===")
    check(detect_compression("toolchain") == "auto",
          "no extension -> auto")

    # ── sha256_directory tests ──────────────────────────────────────

    # Empty directory
    print("=== sha256_directory: empty directory ===")
    with tempfile.TemporaryDirectory() as tmp:
        h = sha256_directory(tmp)
        check(isinstance(h, str) and len(h) == 64,
              "returns 64-char hex string")
        check(h == hashlib.sha256(b"").hexdigest(),
              "empty dir hash equals sha256(empty)")

    # Single file
    print("=== sha256_directory: single file ===")
    with tempfile.TemporaryDirectory() as tmp:
        _write(os.path.join(tmp, "f.txt"), b"data")
        h = sha256_directory(tmp)
        check(isinstance(h, str) and len(h) == 64,
              "single file returns valid hash")
        # Recompute manually: relative path then content
        expected = hashlib.sha256()
        expected.update(b"f.txt")
        expected.update(b"data")
        check(h == expected.hexdigest(),
              "single file hash matches manual computation")

    # Multiple files sorted deterministically
    print("=== sha256_directory: deterministic ordering ===")
    with tempfile.TemporaryDirectory() as tmp:
        d1 = os.path.join(tmp, "d1")
        d2 = os.path.join(tmp, "d2")
        for name, data in [("z.txt", b"z"), ("a.txt", b"a"), ("m.txt", b"m")]:
            _write(os.path.join(d1, name), data)
        for name, data in [("a.txt", b"a"), ("m.txt", b"m"), ("z.txt", b"z")]:
            _write(os.path.join(d2, name), data)
        check(sha256_directory(d1) == sha256_directory(d2),
              "file creation order does not affect hash")

    # metadata.json excluded at root level
    print("=== sha256_directory: excludes metadata.json at root ===")
    with tempfile.TemporaryDirectory() as tmp:
        _write(os.path.join(tmp, "bin", "gcc"), b"binary")
        h_without = sha256_directory(tmp)
        _write(os.path.join(tmp, "metadata.json"), b'{"key": "value"}')
        h_with = sha256_directory(tmp)
        check(h_without == h_with,
              "metadata.json at root does not change hash")

    # metadata.json included in subdirectories
    print("=== sha256_directory: includes metadata.json in subdirs ===")
    with tempfile.TemporaryDirectory() as tmp:
        _write(os.path.join(tmp, "bin", "gcc"), b"binary")
        h_before = sha256_directory(tmp)
        _write(os.path.join(tmp, "sub", "metadata.json"), b'{"nested": true}')
        h_after = sha256_directory(tmp)
        check(h_before != h_after,
              "metadata.json in subdir is included in hash")

    # Symlinks hashed by target string
    print("=== sha256_directory: symlinks hashed by target ===")
    with tempfile.TemporaryDirectory() as tmp:
        d1 = os.path.join(tmp, "d1")
        d2 = os.path.join(tmp, "d2")
        os.makedirs(d1)
        os.makedirs(d2)
        os.symlink("target-a", os.path.join(d1, "link"))
        os.symlink("target-b", os.path.join(d2, "link"))
        check(sha256_directory(d1) != sha256_directory(d2),
              "different symlink targets produce different hash")
        # Same target -> same hash
        d3 = os.path.join(tmp, "d3")
        os.makedirs(d3)
        os.symlink("target-a", os.path.join(d3, "link"))
        check(sha256_directory(d1) == sha256_directory(d3),
              "same symlink target produces same hash")

    # Different content -> different hash
    print("=== sha256_directory: different content ===")
    with tempfile.TemporaryDirectory() as tmp:
        d1 = os.path.join(tmp, "d1")
        d2 = os.path.join(tmp, "d2")
        _write(os.path.join(d1, "f.txt"), b"aaa")
        _write(os.path.join(d2, "f.txt"), b"bbb")
        check(sha256_directory(d1) != sha256_directory(d2),
              "different content produces different hash")

    # Renaming a file changes the hash (relative path is part of hash)
    print("=== sha256_directory: rename changes hash ===")
    with tempfile.TemporaryDirectory() as tmp:
        d1 = os.path.join(tmp, "d1")
        d2 = os.path.join(tmp, "d2")
        _write(os.path.join(d1, "original.txt"), b"data")
        _write(os.path.join(d2, "renamed.txt"), b"data")
        check(sha256_directory(d1) != sha256_directory(d2),
              "renamed file changes hash")

    # Subdirectories included
    print("=== sha256_directory: subdirectories included ===")
    with tempfile.TemporaryDirectory() as tmp:
        d1 = os.path.join(tmp, "d1")
        d2 = os.path.join(tmp, "d2")
        for d in (d1, d2):
            _write(os.path.join(d, "top.txt"), b"top")
            _write(os.path.join(d, "sub", "deep.txt"), b"deep")
        check(sha256_directory(d1) == sha256_directory(d2),
              "dirs with subdirs produce same hash")

    # Adding a file changes hash
    print("=== sha256_directory: adding file changes hash ===")
    with tempfile.TemporaryDirectory() as tmp:
        _write(os.path.join(tmp, "a.txt"), b"aaa")
        h_before = sha256_directory(tmp)
        _write(os.path.join(tmp, "b.txt"), b"bbb")
        h_after = sha256_directory(tmp)
        check(h_before != h_after,
              "adding file changes hash")

    # ── Cross-implementation consistency ────────────────────────────

    # Without metadata.json both implementations should agree
    print("=== cross-impl: no metadata.json -> identical hashes ===")
    with tempfile.TemporaryDirectory() as tmp:
        _write(os.path.join(tmp, "bin", "gcc"), b"gcc-binary")
        _write(os.path.join(tmp, "lib", "libc.so"), b"libc-data")
        os.symlink("libc.so", os.path.join(tmp, "lib", "libc.so.6"))
        h_unpack = sha256_directory(tmp)
        h_pack = pack_sha256_directory(tmp)
        check(h_unpack == h_pack,
              "without metadata.json, both impls agree")

    # With metadata.json at root, unpack excludes it but pack includes it
    print("=== cross-impl: metadata.json divergence ===")
    with tempfile.TemporaryDirectory() as tmp:
        _write(os.path.join(tmp, "bin", "gcc"), b"gcc-binary")
        _write(os.path.join(tmp, "metadata.json"), b'{"format_version": 1}')
        h_unpack = sha256_directory(tmp)
        h_pack = pack_sha256_directory(tmp)
        check(h_unpack != h_pack,
              "with root metadata.json, impls diverge")

    # Verify the divergence is specifically about metadata.json exclusion:
    # pack's hash of dir-without-metadata == unpack's hash of dir-with-metadata
    print("=== cross-impl: unpack skip matches pack without metadata ===")
    with tempfile.TemporaryDirectory() as tmp:
        d_with = os.path.join(tmp, "with_meta")
        d_without = os.path.join(tmp, "without_meta")
        for d in (d_with, d_without):
            _write(os.path.join(d, "bin", "tool"), b"tool-binary")
            _write(os.path.join(d, "lib", "libfoo.a"), b"archive-data")
        _write(os.path.join(d_with, "metadata.json"), b'{"v": 1}')
        # unpack skips metadata.json, so should match pack on the clean dir
        check(sha256_directory(d_with) == pack_sha256_directory(d_without),
              "unpack(with meta) == pack(without meta)")

    # Both agree on empty directory
    print("=== cross-impl: empty directory ===")
    with tempfile.TemporaryDirectory() as tmp:
        check(sha256_directory(tmp) == pack_sha256_directory(tmp),
              "both impls agree on empty dir")

    # Both agree on symlink-only directory
    print("=== cross-impl: symlink-only directory ===")
    with tempfile.TemporaryDirectory() as tmp:
        os.symlink("target", os.path.join(tmp, "link"))
        check(sha256_directory(tmp) == pack_sha256_directory(tmp),
              "both impls agree on symlink-only dir")

    # Both agree on deeply nested tree
    print("=== cross-impl: deeply nested tree ===")
    with tempfile.TemporaryDirectory() as tmp:
        _write(os.path.join(tmp, "a", "b", "c", "d.txt"), b"deep")
        _write(os.path.join(tmp, "a", "b", "e.txt"), b"mid")
        _write(os.path.join(tmp, "f.txt"), b"top")
        os.symlink("d.txt", os.path.join(tmp, "a", "b", "c", "link"))
        check(sha256_directory(tmp) == pack_sha256_directory(tmp),
              "both impls agree on deep tree without metadata.json")

    # ── Summary ─────────────────────────────────────────────────────

    print(f"\n--- {passed} passed, {failed} failed ---")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
