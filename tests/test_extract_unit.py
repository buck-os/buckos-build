#!/usr/bin/env python3
"""Unit tests for archive extraction utilities.

Tests detect_format, _matches_exclude, extract_tar_native, and extract_zip
from tools/extract.py.  Stdlib only -- no pytest.
"""

import io
import os
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path

_REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO / "tools"))

from extract import detect_format, _matches_exclude, extract_tar_native, extract_zip

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


def _make_tar_gz(path, members):
    """Create a tar.gz at *path* with members: list of (name, content) tuples.

    If content is None the entry is a directory.
    """
    with tarfile.open(path, "w:gz") as tf:
        for name, content in members:
            if content is None:
                info = tarfile.TarInfo(name)
                info.type = tarfile.DIRTYPE
                tf.addfile(info)
            else:
                data = content if isinstance(content, bytes) else content.encode()
                info = tarfile.TarInfo(name)
                info.size = len(data)
                tf.addfile(info, io.BytesIO(data))


def _make_tar_gz_raw(path, callback):
    """Create a tar.gz at *path*; *callback(tf)* populates it."""
    with tarfile.open(path, "w:gz") as tf:
        callback(tf)


def _make_zip(path, members):
    """Create a zip at *path* with members: list of (name, content) tuples.

    If content is None the entry is a directory.
    """
    with zipfile.ZipFile(path, "w") as zf:
        for name, content in members:
            if content is None:
                zf.mkdir(name)
            else:
                zf.writestr(name, content)


def main():
    _real_stdout = sys.stdout
    _buf = io.StringIO()
    sys.stdout = _buf

    # ----------------------------------------------------------------
    # detect_format
    # ----------------------------------------------------------------

    print("=== detect_format: tar.gz ===")
    if detect_format("foo.tar.gz") == "tar.gz":
        ok("foo.tar.gz")
    else:
        fail(f"expected 'tar.gz', got '{detect_format('foo.tar.gz')}'")

    print("=== detect_format: tgz ===")
    if detect_format("foo.tgz") == "tgz":
        ok("foo.tgz")
    else:
        fail(f"expected 'tgz', got '{detect_format('foo.tgz')}'")

    print("=== detect_format: tar.xz ===")
    if detect_format("foo.tar.xz") == "tar.xz":
        ok("foo.tar.xz")
    else:
        fail(f"expected 'tar.xz', got '{detect_format('foo.tar.xz')}'")

    print("=== detect_format: txz ===")
    if detect_format("foo.txz") == "txz":
        ok("foo.txz")
    else:
        fail(f"expected 'txz', got '{detect_format('foo.txz')}'")

    print("=== detect_format: tar.bz2 ===")
    if detect_format("foo.tar.bz2") == "tar.bz2":
        ok("foo.tar.bz2")
    else:
        fail(f"expected 'tar.bz2', got '{detect_format('foo.tar.bz2')}'")

    print("=== detect_format: tbz2 ===")
    if detect_format("foo.tbz2") == "tbz2":
        ok("foo.tbz2")
    else:
        fail(f"expected 'tbz2', got '{detect_format('foo.tbz2')}'")

    print("=== detect_format: tar.zst ===")
    if detect_format("foo.tar.zst") == "tar.zst":
        ok("foo.tar.zst")
    else:
        fail(f"expected 'tar.zst', got '{detect_format('foo.tar.zst')}'")

    print("=== detect_format: tar.lz ===")
    if detect_format("foo.tar.lz") == "tar.lz":
        ok("foo.tar.lz")
    else:
        fail(f"expected 'tar.lz', got '{detect_format('foo.tar.lz')}'")

    print("=== detect_format: tar.lz4 ===")
    if detect_format("foo.tar.lz4") == "tar.lz4":
        ok("foo.tar.lz4")
    else:
        fail(f"expected 'tar.lz4', got '{detect_format('foo.tar.lz4')}'")

    print("=== detect_format: tar ===")
    if detect_format("foo.tar") == "tar":
        ok("foo.tar")
    else:
        fail(f"expected 'tar', got '{detect_format('foo.tar')}'")

    print("=== detect_format: zip ===")
    if detect_format("foo.zip") == "zip":
        ok("foo.zip")
    else:
        fail(f"expected 'zip', got '{detect_format('foo.zip')}'")

    print("=== detect_format: whl ===")
    if detect_format("foo.whl") == "whl":
        ok("foo.whl")
    else:
        fail(f"expected 'whl', got '{detect_format('foo.whl')}'")

    print("=== detect_format: unknown extension ===")
    if detect_format("foo.unknown") is None:
        ok("foo.unknown returns None")
    else:
        fail(f"expected None, got '{detect_format('foo.unknown')}'")

    print("=== detect_format: no extension ===")
    if detect_format("foo") is None:
        ok("foo returns None")
    else:
        fail(f"expected None, got '{detect_format('foo')}'")

    print("=== detect_format: case insensitive ===")
    if detect_format("FOO.TAR.GZ") == "tar.gz":
        ok("FOO.TAR.GZ -> tar.gz")
    else:
        fail(f"expected 'tar.gz', got '{detect_format('FOO.TAR.GZ')}'")

    print("=== detect_format: path with dirs ===")
    if detect_format("/tmp/archives/foo.tar.xz") == "tar.xz":
        ok("/tmp/archives/foo.tar.xz -> tar.xz")
    else:
        fail(f"expected 'tar.xz', got '{detect_format('/tmp/archives/foo.tar.xz')}'")

    # ----------------------------------------------------------------
    # _matches_exclude
    # ----------------------------------------------------------------

    print("=== _matches_exclude: simple match ===")
    if _matches_exclude("foo.pyc", ["*.pyc"]):
        ok("*.pyc matches foo.pyc")
    else:
        fail("*.pyc should match foo.pyc")

    print("=== _matches_exclude: no match ===")
    if not _matches_exclude("foo.py", ["*.pyc"]):
        ok("*.pyc does not match foo.py")
    else:
        fail("*.pyc should not match foo.py")

    print("=== _matches_exclude: multiple patterns ===")
    if _matches_exclude("foo.pyo", ["*.pyc", "*.pyo"]):
        ok("[*.pyc, *.pyo] matches foo.pyo")
    else:
        fail("[*.pyc, *.pyo] should match foo.pyo")

    print("=== _matches_exclude: directory pattern ===")
    if _matches_exclude("test/foo.txt", ["test/*"]):
        ok("test/* matches test/foo.txt")
    else:
        fail("test/* should match test/foo.txt")

    print("=== _matches_exclude: empty patterns ===")
    if not _matches_exclude("foo.py", []):
        ok("empty list returns False")
    else:
        fail("empty list should return False")

    # ----------------------------------------------------------------
    # extract_tar_native
    # ----------------------------------------------------------------

    print("=== extract_tar_native: basic extraction ===")
    with tempfile.TemporaryDirectory() as tmp:
        archive = os.path.join(tmp, "test.tar.gz")
        outdir = os.path.join(tmp, "out")
        os.makedirs(outdir)
        _make_tar_gz(archive, [
            ("file.txt", b"hello"),
            ("subdir/nested.txt", b"world"),
        ])
        extract_tar_native(archive, outdir, 0, "r:gz")
        f1 = os.path.join(outdir, "file.txt")
        f2 = os.path.join(outdir, "subdir", "nested.txt")
        if os.path.isfile(f1) and open(f1, "rb").read() == b"hello":
            ok("file.txt extracted with correct content")
        else:
            fail("file.txt missing or wrong content")
        if os.path.isfile(f2) and open(f2, "rb").read() == b"world":
            ok("subdir/nested.txt extracted with correct content")
        else:
            fail("subdir/nested.txt missing or wrong content")

    print("=== extract_tar_native: strip_components=1 ===")
    with tempfile.TemporaryDirectory() as tmp:
        archive = os.path.join(tmp, "test.tar.gz")
        outdir = os.path.join(tmp, "out")
        os.makedirs(outdir)
        _make_tar_gz(archive, [
            ("top/file.txt", b"stripped"),
            ("top/sub/deep.txt", b"deep"),
        ])
        extract_tar_native(archive, outdir, 1, "r:gz")
        f1 = os.path.join(outdir, "file.txt")
        f2 = os.path.join(outdir, "sub", "deep.txt")
        if os.path.isfile(f1) and open(f1, "rb").read() == b"stripped":
            ok("strip_components=1 removes top-level dir")
        else:
            fail("file.txt not found after strip_components=1")
        if os.path.isfile(f2) and open(f2, "rb").read() == b"deep":
            ok("strip_components=1 preserves deeper structure")
        else:
            fail("sub/deep.txt not found after strip_components=1")
        # top/ directory itself should not appear
        if not os.path.exists(os.path.join(outdir, "top")):
            ok("top-level dir not present in output")
        else:
            fail("top-level dir 'top' should not exist")

    print("=== extract_tar_native: strip_components skips shallow entries ===")
    with tempfile.TemporaryDirectory() as tmp:
        archive = os.path.join(tmp, "test.tar.gz")
        outdir = os.path.join(tmp, "out")
        os.makedirs(outdir)
        _make_tar_gz(archive, [
            ("shallow.txt", b"skip me"),
            ("top/keep.txt", b"kept"),
        ])
        extract_tar_native(archive, outdir, 1, "r:gz")
        if not os.path.exists(os.path.join(outdir, "shallow.txt")):
            ok("shallow entry skipped with strip_components=1")
        else:
            fail("shallow.txt should be skipped")
        if os.path.isfile(os.path.join(outdir, "keep.txt")):
            ok("deep enough entry kept")
        else:
            fail("keep.txt should be extracted")

    print("=== extract_tar_native: exclude patterns ===")
    with tempfile.TemporaryDirectory() as tmp:
        archive = os.path.join(tmp, "test.tar.gz")
        outdir = os.path.join(tmp, "out")
        os.makedirs(outdir)
        _make_tar_gz(archive, [
            ("file.txt", b"keep"),
            ("file.pyc", b"exclude"),
            ("data.log", b"also keep"),
        ])
        extract_tar_native(archive, outdir, 0, "r:gz", exclude_patterns=["*.pyc"])
        if os.path.isfile(os.path.join(outdir, "file.txt")):
            ok("non-excluded file extracted")
        else:
            fail("file.txt should be extracted")
        if not os.path.exists(os.path.join(outdir, "file.pyc")):
            ok("excluded file not extracted")
        else:
            fail("file.pyc should be excluded")
        if os.path.isfile(os.path.join(outdir, "data.log")):
            ok("other non-excluded file extracted")
        else:
            fail("data.log should be extracted")

    print("=== extract_tar_native: path traversal prevented ===")
    with tempfile.TemporaryDirectory() as tmp:
        archive = os.path.join(tmp, "test.tar.gz")
        outdir = os.path.join(tmp, "out")
        os.makedirs(outdir)

        def add_traversal(tf):
            info = tarfile.TarInfo("../../etc/passwd")
            data = b"malicious"
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))

        _make_tar_gz_raw(archive, add_traversal)
        try:
            extract_tar_native(archive, outdir, 0, "r:gz")
            fail("path traversal should trigger sys.exit")
        except SystemExit as e:
            if e.code == 1:
                ok("path traversal triggers sys.exit(1)")
            else:
                fail(f"expected exit code 1, got {e.code}")

    print("=== extract_tar_native: backslash in filename skipped ===")
    with tempfile.TemporaryDirectory() as tmp:
        archive = os.path.join(tmp, "test.tar.gz")
        outdir = os.path.join(tmp, "out")
        os.makedirs(outdir)

        def add_backslash(tf):
            info = tarfile.TarInfo("normal.txt")
            data = b"ok"
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
            info2 = tarfile.TarInfo("system-systemd\\x2dcryptsetup.slice")
            data2 = b"bad"
            info2.size = len(data2)
            tf.addfile(info2, io.BytesIO(data2))

        _make_tar_gz_raw(archive, add_backslash)
        extract_tar_native(archive, outdir, 0, "r:gz")
        if os.path.isfile(os.path.join(outdir, "normal.txt")):
            ok("normal file extracted")
        else:
            fail("normal.txt should be extracted")
        # The backslash file should not appear anywhere in outdir
        all_files = []
        for root, dirs, files in os.walk(outdir):
            all_files.extend(files)
        backslash_found = any("\\" in f for f in all_files)
        if not backslash_found:
            ok("backslash filename skipped")
        else:
            fail("file with backslash should be skipped")

    print("=== extract_tar_native: empty symlink target skipped ===")
    with tempfile.TemporaryDirectory() as tmp:
        archive = os.path.join(tmp, "test.tar.gz")
        outdir = os.path.join(tmp, "out")
        os.makedirs(outdir)

        def add_empty_symlink(tf):
            info = tarfile.TarInfo("real.txt")
            data = b"content"
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
            sym = tarfile.TarInfo("empty_link")
            sym.type = tarfile.SYMTYPE
            sym.linkname = ""
            tf.addfile(sym)
            dot = tarfile.TarInfo("dot_link")
            dot.type = tarfile.SYMTYPE
            dot.linkname = "."
            tf.addfile(dot)

        _make_tar_gz_raw(archive, add_empty_symlink)
        extract_tar_native(archive, outdir, 0, "r:gz")
        if os.path.isfile(os.path.join(outdir, "real.txt")):
            ok("real file extracted")
        else:
            fail("real.txt should be extracted")
        if not os.path.lexists(os.path.join(outdir, "empty_link")):
            ok("empty symlink target skipped")
        else:
            fail("empty_link should be skipped")
        if not os.path.lexists(os.path.join(outdir, "dot_link")):
            ok("dot symlink target skipped")
        else:
            fail("dot_link should be skipped")

    print("=== extract_tar_native: self-referencing symlink skipped ===")
    with tempfile.TemporaryDirectory() as tmp:
        archive = os.path.join(tmp, "test.tar.gz")
        outdir = os.path.join(tmp, "out")
        os.makedirs(outdir)

        def add_self_symlink(tf):
            info = tarfile.TarInfo("real.txt")
            data = b"content"
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
            sym = tarfile.TarInfo("dir/itself")
            sym.type = tarfile.SYMTYPE
            sym.linkname = "itself"
            tf.addfile(sym)

        _make_tar_gz_raw(archive, add_self_symlink)
        extract_tar_native(archive, outdir, 0, "r:gz")
        if os.path.isfile(os.path.join(outdir, "real.txt")):
            ok("real file extracted")
        else:
            fail("real.txt should be extracted")
        if not os.path.lexists(os.path.join(outdir, "dir", "itself")):
            ok("self-referencing symlink skipped")
        else:
            fail("self-referencing symlink should be skipped")

    # ----------------------------------------------------------------
    # extract_zip
    # ----------------------------------------------------------------

    print("=== extract_zip: basic extraction ===")
    with tempfile.TemporaryDirectory() as tmp:
        archive = os.path.join(tmp, "test.zip")
        outdir = os.path.join(tmp, "out")
        os.makedirs(outdir)
        _make_zip(archive, [
            ("file.txt", "hello"),
            ("subdir/nested.txt", "world"),
        ])
        extract_zip(archive, outdir, 0)
        f1 = os.path.join(outdir, "file.txt")
        f2 = os.path.join(outdir, "subdir", "nested.txt")
        if os.path.isfile(f1) and open(f1).read() == "hello":
            ok("zip: file.txt extracted with correct content")
        else:
            fail("zip: file.txt missing or wrong content")
        if os.path.isfile(f2) and open(f2).read() == "world":
            ok("zip: subdir/nested.txt extracted with correct content")
        else:
            fail("zip: subdir/nested.txt missing or wrong content")

    print("=== extract_zip: strip_components=1 ===")
    with tempfile.TemporaryDirectory() as tmp:
        archive = os.path.join(tmp, "test.zip")
        outdir = os.path.join(tmp, "out")
        os.makedirs(outdir)
        _make_zip(archive, [
            ("top/file.txt", "stripped"),
            ("top/sub/deep.txt", "deep"),
        ])
        extract_zip(archive, outdir, 1)
        f1 = os.path.join(outdir, "file.txt")
        f2 = os.path.join(outdir, "sub", "deep.txt")
        if os.path.isfile(f1) and open(f1).read() == "stripped":
            ok("zip: strip_components=1 works")
        else:
            fail("zip: file.txt not found after strip_components=1")
        if os.path.isfile(f2) and open(f2).read() == "deep":
            ok("zip: strip preserves deeper structure")
        else:
            fail("zip: sub/deep.txt not found after strip_components=1")

    print("=== extract_zip: directories not extracted as files ===")
    with tempfile.TemporaryDirectory() as tmp:
        archive = os.path.join(tmp, "test.zip")
        outdir = os.path.join(tmp, "out")
        os.makedirs(outdir)
        _make_zip(archive, [
            ("mydir/", None),
            ("mydir/file.txt", "content"),
        ])
        extract_zip(archive, outdir, 0)
        if os.path.isfile(os.path.join(outdir, "mydir", "file.txt")):
            ok("zip: file inside directory extracted")
        else:
            fail("zip: mydir/file.txt should be extracted")
        # The directory entry itself should not create a stray file
        dir_path = os.path.join(outdir, "mydir")
        if os.path.isdir(dir_path) and not os.path.isfile(dir_path):
            ok("zip: directory entry not extracted as file")
        else:
            fail("zip: mydir should be a directory, not a file")

    print("=== extract_zip: path traversal prevented ===")
    with tempfile.TemporaryDirectory() as tmp:
        archive = os.path.join(tmp, "test.zip")
        outdir = os.path.join(tmp, "out")
        os.makedirs(outdir)
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("../../etc/passwd", "malicious")
        try:
            extract_zip(archive, outdir, 0)
            fail("zip: path traversal should trigger sys.exit")
        except SystemExit as e:
            if e.code == 1:
                ok("zip: path traversal triggers sys.exit(1)")
            else:
                fail(f"zip: expected exit code 1, got {e.code}")

    # ----------------------------------------------------------------
    # Additional edge cases
    # ----------------------------------------------------------------

    print("=== extract_tar_native: hardlink target stripped ===")
    with tempfile.TemporaryDirectory() as tmp:
        archive = os.path.join(tmp, "test.tar.gz")
        outdir = os.path.join(tmp, "out")
        os.makedirs(outdir)

        def add_hardlink(tf):
            info = tarfile.TarInfo("top/real.txt")
            data = b"content"
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
            link = tarfile.TarInfo("top/link.txt")
            link.type = tarfile.LNKTYPE
            link.linkname = "top/real.txt"
            tf.addfile(link)

        _make_tar_gz_raw(archive, add_hardlink)
        extract_tar_native(archive, outdir, 1, "r:gz")
        if os.path.isfile(os.path.join(outdir, "real.txt")):
            ok("hardlink: real file extracted after strip")
        else:
            fail("hardlink: real.txt should be extracted")
        if os.path.exists(os.path.join(outdir, "link.txt")):
            ok("hardlink: link extracted after strip")
        else:
            fail("hardlink: link.txt should be extracted")

    print("=== extract_tar_native: exclude with strip_components ===")
    with tempfile.TemporaryDirectory() as tmp:
        archive = os.path.join(tmp, "test.tar.gz")
        outdir = os.path.join(tmp, "out")
        os.makedirs(outdir)
        _make_tar_gz(archive, [
            ("pkg/keep.txt", b"keep"),
            ("pkg/drop.log", b"drop"),
            ("pkg/also.txt", b"also keep"),
        ])
        extract_tar_native(archive, outdir, 1, "r:gz", exclude_patterns=["*.log"])
        if os.path.isfile(os.path.join(outdir, "keep.txt")):
            ok("exclude+strip: kept file present")
        else:
            fail("exclude+strip: keep.txt missing")
        if not os.path.exists(os.path.join(outdir, "drop.log")):
            ok("exclude+strip: excluded file absent")
        else:
            fail("exclude+strip: drop.log should be excluded")
        if os.path.isfile(os.path.join(outdir, "also.txt")):
            ok("exclude+strip: other kept file present")
        else:
            fail("exclude+strip: also.txt missing")

    print("=== extract_zip: strip_components skips shallow entries ===")
    with tempfile.TemporaryDirectory() as tmp:
        archive = os.path.join(tmp, "test.zip")
        outdir = os.path.join(tmp, "out")
        os.makedirs(outdir)
        _make_zip(archive, [
            ("shallow.txt", "skip"),
            ("top/keep.txt", "kept"),
        ])
        extract_zip(archive, outdir, 1)
        if not os.path.exists(os.path.join(outdir, "shallow.txt")):
            ok("zip: shallow entry skipped with strip_components=1")
        else:
            fail("zip: shallow.txt should be skipped")
        if os.path.isfile(os.path.join(outdir, "keep.txt")):
            ok("zip: deep enough entry kept")
        else:
            fail("zip: keep.txt should be extracted")

    print("=== detect_format: compound name ===")
    if detect_format("linux-6.1.tar.xz") == "tar.xz":
        ok("linux-6.1.tar.xz -> tar.xz")
    else:
        fail(f"expected 'tar.xz', got '{detect_format('linux-6.1.tar.xz')}'")

    print("=== extract_tar_native: valid symlink preserved ===")
    with tempfile.TemporaryDirectory() as tmp:
        archive = os.path.join(tmp, "test.tar.gz")
        outdir = os.path.join(tmp, "out")
        os.makedirs(outdir)

        def add_valid_symlink(tf):
            info = tarfile.TarInfo("real.txt")
            data = b"target"
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
            sym = tarfile.TarInfo("link.txt")
            sym.type = tarfile.SYMTYPE
            sym.linkname = "real.txt"
            tf.addfile(sym)

        _make_tar_gz_raw(archive, add_valid_symlink)
        extract_tar_native(archive, outdir, 0, "r:gz")
        link_path = os.path.join(outdir, "link.txt")
        if os.path.islink(link_path) and os.readlink(link_path) == "real.txt":
            ok("valid symlink preserved")
        else:
            fail("valid symlink should be preserved")

    print("=== extract_tar_native: no exclude_patterns means no filtering ===")
    with tempfile.TemporaryDirectory() as tmp:
        archive = os.path.join(tmp, "test.tar.gz")
        outdir = os.path.join(tmp, "out")
        os.makedirs(outdir)
        _make_tar_gz(archive, [
            ("a.pyc", b"one"),
            ("b.log", b"two"),
            ("c.txt", b"three"),
        ])
        extract_tar_native(archive, outdir, 0, "r:gz")
        count = len(os.listdir(outdir))
        if count == 3:
            ok("all files extracted without exclude patterns")
        else:
            fail(f"expected 3 files, got {count}")

    # -- Summary --
    sys.stdout = _real_stdout
    if failed:
        _real_stdout.write(_buf.getvalue())
        for _line in _output_lines:
            print(_line)
        print(f"\n--- {passed} passed, {failed} failed ---")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
