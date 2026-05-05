#!/usr/bin/env python3
"""Unit tests for tree merging and content hashing utilities."""
import hashlib
import io
import os
import sys
import tempfile
from pathlib import Path

_REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO / "tools"))

from merge_host_tools import _merge_tree
from toolchain_pack import sha256_directory, sha256_file

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


def main():
    _real_stdout = sys.stdout
    _buf = io.StringIO()
    sys.stdout = _buf

    # ── _merge_tree tests ────────────────────────────────────────────

    # 1. Simple file merge — src has file, dst empty, file copied
    print("=== _merge_tree: simple file merge ===")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        dst = os.path.join(tmp, "dst")
        os.makedirs(src)
        os.makedirs(dst)
        _write(os.path.join(src, "a.txt"), b"alpha")
        _merge_tree(src, dst)
        dst_file = os.path.join(dst, "a.txt")
        check(os.path.isfile(dst_file), "file exists in dst")
        with open(dst_file, "rb") as f:
            check(f.read() == b"alpha", "file content matches")

    # 2. Directory merge — src has subdir with file, merged into dst
    print("=== _merge_tree: directory merge ===")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        dst = os.path.join(tmp, "dst")
        os.makedirs(dst)
        _write(os.path.join(src, "sub", "b.txt"), b"beta")
        _merge_tree(src, dst)
        check(os.path.isfile(os.path.join(dst, "sub", "b.txt")),
              "subdir file merged")

    # 3. File conflict — dst already has file, NOT overwritten
    print("=== _merge_tree: file conflict skipped ===")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        dst = os.path.join(tmp, "dst")
        os.makedirs(src)
        os.makedirs(dst)
        _write(os.path.join(src, "c.txt"), b"from-src")
        _write(os.path.join(dst, "c.txt"), b"from-dst")
        _merge_tree(src, dst)
        with open(os.path.join(dst, "c.txt"), "rb") as f:
            check(f.read() == b"from-dst", "dst file not overwritten")

    # 4. Symlink merge — src has symlink, creates symlink in dst
    print("=== _merge_tree: symlink merge ===")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        dst = os.path.join(tmp, "dst")
        os.makedirs(src)
        os.makedirs(dst)
        os.symlink("target.txt", os.path.join(src, "link"))
        _merge_tree(src, dst)
        dst_link = os.path.join(dst, "link")
        check(os.path.islink(dst_link), "symlink created in dst")
        check(os.readlink(dst_link) == "target.txt", "symlink target correct")

    # 5. Symlink overwrite — dst has regular file, src has symlink, symlink wins
    print("=== _merge_tree: symlink overwrites regular file ===")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        dst = os.path.join(tmp, "dst")
        os.makedirs(src)
        os.makedirs(dst)
        _write(os.path.join(dst, "x"), b"regular")
        os.symlink("other", os.path.join(src, "x"))
        _merge_tree(src, dst)
        dst_x = os.path.join(dst, "x")
        check(os.path.islink(dst_x), "symlink replaced regular file")
        check(os.readlink(dst_x) == "other", "symlink target after overwrite")

    # 6. Deep nesting — multiple nested directories merged correctly
    print("=== _merge_tree: deep nesting ===")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        dst = os.path.join(tmp, "dst")
        os.makedirs(dst)
        _write(os.path.join(src, "a", "b", "c", "d.txt"), b"deep")
        _merge_tree(src, dst)
        check(os.path.isfile(os.path.join(dst, "a", "b", "c", "d.txt")),
              "deeply nested file merged")

    # 7. Empty source directory — no crash
    print("=== _merge_tree: empty source ===")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        dst = os.path.join(tmp, "dst")
        os.makedirs(src)
        os.makedirs(dst)
        _merge_tree(src, dst)
        check(os.listdir(dst) == [], "dst still empty after empty src merge")

    # 8. Mixed content — files, dirs, symlinks all handled
    print("=== _merge_tree: mixed content ===")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        dst = os.path.join(tmp, "dst")
        os.makedirs(dst)
        _write(os.path.join(src, "file.txt"), b"file")
        _write(os.path.join(src, "dir", "inner.txt"), b"inner")
        os.symlink("file.txt", os.path.join(src, "link"))
        _merge_tree(src, dst)
        check(os.path.isfile(os.path.join(dst, "file.txt")), "mixed: file")
        check(os.path.isfile(os.path.join(dst, "dir", "inner.txt")),
              "mixed: dir/inner")
        check(os.path.islink(os.path.join(dst, "link")), "mixed: symlink")

    # 9. Multiple merges — merge A then B into same dst; A's files survive
    print("=== _merge_tree: multiple merges, no overwrite ===")
    with tempfile.TemporaryDirectory() as tmp:
        a = os.path.join(tmp, "a")
        b = os.path.join(tmp, "b")
        dst = os.path.join(tmp, "dst")
        os.makedirs(dst)
        _write(os.path.join(a, "shared.txt"), b"from-a")
        _write(os.path.join(a, "only-a.txt"), b"a-only")
        _write(os.path.join(b, "shared.txt"), b"from-b")
        _write(os.path.join(b, "only-b.txt"), b"b-only")
        _merge_tree(a, dst)
        _merge_tree(b, dst)
        with open(os.path.join(dst, "shared.txt"), "rb") as f:
            check(f.read() == b"from-a", "first merge wins for conflicts")
        check(os.path.isfile(os.path.join(dst, "only-a.txt")),
              "a-only file present")
        check(os.path.isfile(os.path.join(dst, "only-b.txt")),
              "b-only file present")

    # 10. Source file permissions preserved (shutil.copy2)
    print("=== _merge_tree: permissions preserved ===")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        dst = os.path.join(tmp, "dst")
        os.makedirs(src)
        os.makedirs(dst)
        f_path = os.path.join(src, "script.sh")
        _write(f_path, b"#!/bin/sh\nexit 0\n")
        os.chmod(f_path, 0o755)
        _merge_tree(src, dst)
        dst_mode = os.stat(os.path.join(dst, "script.sh")).st_mode & 0o777
        check(dst_mode == 0o755, f"permissions preserved (0o{dst_mode:03o})")

    # ── sha256_file tests ────────────────────────────────────────────

    # 11. Known content produces expected hash
    print("=== sha256_file: known content ===")
    with tempfile.TemporaryDirectory() as tmp:
        p = os.path.join(tmp, "hello.bin")
        _write(p, b"hello")
        expected = hashlib.sha256(b"hello").hexdigest()
        check(sha256_file(p) == expected,
              f"sha256('hello') = {expected[:16]}...")

    # 12. Empty file hash
    print("=== sha256_file: empty file ===")
    with tempfile.TemporaryDirectory() as tmp:
        p = os.path.join(tmp, "empty")
        _write(p, b"")
        expected = hashlib.sha256(b"").hexdigest()
        check(sha256_file(p) == expected, "empty file hash matches")

    # 13. Large file (>64KB) hashes correctly
    print("=== sha256_file: large file ===")
    with tempfile.TemporaryDirectory() as tmp:
        p = os.path.join(tmp, "big")
        data = b"x" * 100_000
        _write(p, data)
        expected = hashlib.sha256(data).hexdigest()
        check(sha256_file(p) == expected, "large file hash correct")

    # 14. Two identical files produce same hash
    print("=== sha256_file: identical files ===")
    with tempfile.TemporaryDirectory() as tmp:
        a = os.path.join(tmp, "a")
        b = os.path.join(tmp, "b")
        _write(a, b"same content")
        _write(b, b"same content")
        check(sha256_file(a) == sha256_file(b), "identical files same hash")

    # 15. Different files produce different hashes
    print("=== sha256_file: different files ===")
    with tempfile.TemporaryDirectory() as tmp:
        a = os.path.join(tmp, "a")
        b = os.path.join(tmp, "b")
        _write(a, b"content-a")
        _write(b, b"content-b")
        check(sha256_file(a) != sha256_file(b), "different files different hash")

    # ── sha256_directory tests ───────────────────────────────────────

    # 16. Single file — deterministic hash
    print("=== sha256_directory: single file ===")
    with tempfile.TemporaryDirectory() as tmp:
        _write(os.path.join(tmp, "f.txt"), b"data")
        h1 = sha256_directory(tmp)
        check(isinstance(h1, str) and len(h1) == 64, "returns 64-char hex string")

    # 17. Same directory contents produces same hash (reproducible)
    print("=== sha256_directory: reproducible ===")
    with tempfile.TemporaryDirectory() as tmp:
        d1 = os.path.join(tmp, "d1")
        d2 = os.path.join(tmp, "d2")
        for d in (d1, d2):
            _write(os.path.join(d, "a.txt"), b"aaa")
            _write(os.path.join(d, "b.txt"), b"bbb")
        check(sha256_directory(d1) == sha256_directory(d2),
              "identical dirs same hash")

    # 18. Different file contents produce different hash
    print("=== sha256_directory: different content ===")
    with tempfile.TemporaryDirectory() as tmp:
        d1 = os.path.join(tmp, "d1")
        d2 = os.path.join(tmp, "d2")
        _write(os.path.join(d1, "f.txt"), b"aaa")
        _write(os.path.join(d2, "f.txt"), b"bbb")
        check(sha256_directory(d1) != sha256_directory(d2),
              "different content different hash")

    # 19. Symlink included in hash (link target string hashed)
    print("=== sha256_directory: symlink hashed ===")
    with tempfile.TemporaryDirectory() as tmp:
        d1 = os.path.join(tmp, "d1")
        d2 = os.path.join(tmp, "d2")
        os.makedirs(d1)
        os.makedirs(d2)
        os.symlink("target-a", os.path.join(d1, "link"))
        os.symlink("target-b", os.path.join(d2, "link"))
        check(sha256_directory(d1) != sha256_directory(d2),
              "different symlink targets different hash")

    # 20. File ordering is deterministic (sorted walk)
    print("=== sha256_directory: deterministic ordering ===")
    with tempfile.TemporaryDirectory() as tmp:
        # Create files in different order; hash should be the same
        d1 = os.path.join(tmp, "d1")
        d2 = os.path.join(tmp, "d2")
        for name, data in [("z.txt", b"z"), ("a.txt", b"a"), ("m.txt", b"m")]:
            _write(os.path.join(d1, name), data)
        for name, data in [("a.txt", b"a"), ("m.txt", b"m"), ("z.txt", b"z")]:
            _write(os.path.join(d2, name), data)
        check(sha256_directory(d1) == sha256_directory(d2),
              "file creation order does not affect hash")

    # 21. Empty directory produces consistent hash
    print("=== sha256_directory: empty directory ===")
    with tempfile.TemporaryDirectory() as tmp:
        d1 = os.path.join(tmp, "d1")
        d2 = os.path.join(tmp, "d2")
        os.makedirs(d1)
        os.makedirs(d2)
        h1 = sha256_directory(d1)
        h2 = sha256_directory(d2)
        check(h1 == h2, "empty dirs produce same hash")
        # Empty dir hash should equal sha256 of nothing
        check(h1 == hashlib.sha256(b"").hexdigest(),
              "empty dir hash equals sha256(empty)")

    # 22. Directory with subdirectories — all files included
    print("=== sha256_directory: subdirectories ===")
    with tempfile.TemporaryDirectory() as tmp:
        d1 = os.path.join(tmp, "d1")
        d2 = os.path.join(tmp, "d2")
        for d in (d1, d2):
            _write(os.path.join(d, "top.txt"), b"top")
            _write(os.path.join(d, "sub", "deep.txt"), b"deep")
        check(sha256_directory(d1) == sha256_directory(d2),
              "dirs with subdirs match")

    # 23. Adding a file changes the hash
    print("=== sha256_directory: adding file changes hash ===")
    with tempfile.TemporaryDirectory() as tmp:
        _write(os.path.join(tmp, "a.txt"), b"aaa")
        h_before = sha256_directory(tmp)
        _write(os.path.join(tmp, "b.txt"), b"bbb")
        h_after = sha256_directory(tmp)
        check(h_before != h_after, "adding file changes hash")

    # 24. Renaming a file changes the hash (relative path is part of hash)
    print("=== sha256_directory: rename changes hash ===")
    with tempfile.TemporaryDirectory() as tmp:
        d1 = os.path.join(tmp, "d1")
        d2 = os.path.join(tmp, "d2")
        _write(os.path.join(d1, "original.txt"), b"data")
        _write(os.path.join(d2, "renamed.txt"), b"data")
        check(sha256_directory(d1) != sha256_directory(d2),
              "renamed file changes hash")

    # 25. Absolute symlinks within source tree are relativized
    print("=== _merge_tree: absolute symlink relativized ===")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        dst = os.path.join(tmp, "dst")
        os.makedirs(os.path.join(src, "bin"))
        os.makedirs(dst)
        _write(os.path.join(src, "bin", "bzmore"), b"#!/bin/sh\n")
        # bzip2-style absolute symlink: bzless -> $PREFIX/bin/bzmore
        os.symlink(os.path.join(src, "bin", "bzmore"),
                   os.path.join(src, "bin", "bzless"))
        _merge_tree(src, dst)
        dst_link = os.path.join(dst, "bin", "bzless")
        check(os.path.islink(dst_link), "abs symlink created in dst")
        target = os.readlink(dst_link)
        check(not os.path.isabs(target),
              f"abs symlink relativized: {target}")
        check(target == "bzmore",
              f"relative target correct: {target}")
        check(os.path.exists(dst_link),
              "relativized symlink resolves")

    # 26. Absolute symlinks outside source tree are preserved as-is
    print("=== _merge_tree: absolute symlink outside tree preserved ===")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        dst = os.path.join(tmp, "dst")
        os.makedirs(src)
        os.makedirs(dst)
        os.symlink("/usr/bin/env", os.path.join(src, "env"))
        _merge_tree(src, dst)
        dst_link = os.path.join(dst, "env")
        check(os.path.islink(dst_link), "external abs symlink created")
        check(os.readlink(dst_link) == "/usr/bin/env",
              "external abs symlink preserved")

    # 27. Cross-subdir absolute symlinks stay absolute (cleanup handles them)
    print("=== _merge_tree: cross-subdir abs symlink preserved ===")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        dst = os.path.join(tmp, "dst")
        os.makedirs(os.path.join(src, "bin"))
        os.makedirs(os.path.join(src, "sbin"))
        os.makedirs(dst)
        _write(os.path.join(src, "bin", "real"), b"binary")
        # sbin/link -> $src/bin/real (cross-subdir absolute)
        os.symlink(os.path.join(src, "bin", "real"),
                   os.path.join(src, "sbin", "link"))
        # _merge_tree is called per-subdir in main(), so simulate that
        os.makedirs(os.path.join(dst, "sbin"), exist_ok=True)
        _merge_tree(os.path.join(src, "sbin"), os.path.join(dst, "sbin"))
        dst_link = os.path.join(dst, "sbin", "link")
        target = os.readlink(dst_link)
        # Target points outside sbin/ tree, so stays absolute
        check(os.path.isabs(target),
              f"cross-subdir abs symlink stays absolute: {target}")

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
