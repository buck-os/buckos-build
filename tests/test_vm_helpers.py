#!/usr/bin/env python3
"""Unit tests for vm_test_runner and disk_image_helper pure functions."""
import argparse
import io
import os
import sys
import tempfile
from pathlib import Path

_REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO / "tools"))

from vm_test_runner import parse_inject, build_init_script, kvm_available
from disk_image_helper import _parse_size, _parse_sgdisk_output, _build_debugfs_ima_commands

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


def main():
    _real_stdout = sys.stdout
    _buf = io.StringIO()
    sys.stdout = _buf

    # ----------------------------------------------------------------
    # parse_inject tests
    # ----------------------------------------------------------------

    print("=== parse_inject: simple SRC:DEST ===")
    result = parse_inject("foo:/bar")
    if result == ("foo", "/bar"):
        ok("foo:/bar -> ('foo', '/bar')")
    else:
        fail(f"expected ('foo', '/bar'), got {result!r}")

    print("=== parse_inject: full paths ===")
    result = parse_inject("/path/to/file:/dest/path")
    if result == ("/path/to/file", "/dest/path"):
        ok("/path/to/file:/dest/path -> correct tuple")
    else:
        fail(f"expected ('/path/to/file', '/dest/path'), got {result!r}")

    print("=== parse_inject: multiple colons splits on first only ===")
    result = parse_inject("src:dest:extra")
    if result == ("src", "dest:extra"):
        ok("src:dest:extra -> ('src', 'dest:extra')")
    else:
        fail(f"expected ('src', 'dest:extra'), got {result!r}")

    print("=== parse_inject: no colon raises ArgumentTypeError ===")
    try:
        parse_inject("no-colon")
        fail("no exception raised for missing colon")
    except argparse.ArgumentTypeError:
        ok("ArgumentTypeError raised for 'no-colon'")
    except Exception as e:
        fail(f"wrong exception type: {type(e).__name__}: {e}")

    print("=== parse_inject: empty string raises ArgumentTypeError ===")
    try:
        parse_inject("")
        fail("no exception raised for empty string")
    except argparse.ArgumentTypeError:
        ok("ArgumentTypeError raised for empty string")
    except Exception as e:
        fail(f"wrong exception type: {type(e).__name__}: {e}")

    print("=== parse_inject: colon at start gives empty src ===")
    result = parse_inject(":/dest")
    if result == ("", "/dest"):
        ok(":/dest -> ('', '/dest')")
    else:
        fail(f"expected ('', '/dest'), got {result!r}")

    print("=== parse_inject: colon at end gives empty dest ===")
    result = parse_inject("src:")
    if result == ("src", ""):
        ok("src: -> ('src', '')")
    else:
        fail(f"expected ('src', ''), got {result!r}")

    print("=== parse_inject: paths with spaces ===")
    result = parse_inject("/my file:/dest dir/file")
    if result == ("/my file", "/dest dir/file"):
        ok("paths with spaces parsed correctly")
    else:
        fail(f"expected ('/my file', '/dest dir/file'), got {result!r}")

    # ----------------------------------------------------------------
    # build_init_script tests
    # ----------------------------------------------------------------

    script = build_init_script()

    print("=== build_init_script: starts with shebang ===")
    if script.startswith("#!/bin/sh\n"):
        ok("starts with #!/bin/sh")
    else:
        fail(f"unexpected start: {script[:20]!r}")

    print("=== build_init_script: contains mount -t proc ===")
    if "mount -t proc" in script:
        ok("contains mount -t proc")
    else:
        fail("mount -t proc not found")

    print("=== build_init_script: contains mount -t sysfs ===")
    if "mount -t sysfs" in script:
        ok("contains mount -t sysfs")
    else:
        fail("mount -t sysfs not found")

    print("=== build_init_script: contains mount -t devtmpfs ===")
    if "mount -t devtmpfs" in script:
        ok("contains mount -t devtmpfs")
    else:
        fail("mount -t devtmpfs not found")

    print("=== build_init_script: devtmpfs failure tolerated ===")
    if "2>/dev/null || true" in script:
        ok("devtmpfs mount failure tolerated")
    else:
        fail("devtmpfs error suppression not found")

    print("=== build_init_script: contains exec /bin/sh /test.sh ===")
    if "exec /bin/sh /test.sh" in script:
        ok("contains exec /bin/sh /test.sh")
    else:
        fail("exec /bin/sh /test.sh not found")

    print("=== build_init_script: contains poweroff -f ===")
    if "poweroff -f" in script:
        ok("contains poweroff -f")
    else:
        fail("poweroff -f not found")

    print("=== build_init_script: ends with newline ===")
    if script.endswith("\n"):
        ok("ends with newline")
    else:
        fail("does not end with newline")

    print("=== build_init_script: deterministic ===")
    if build_init_script() == build_init_script():
        ok("two calls produce identical output")
    else:
        fail("non-deterministic output")

    # ----------------------------------------------------------------
    # kvm_available tests
    # ----------------------------------------------------------------

    print("=== kvm_available: returns a boolean ===")
    result = kvm_available()
    if isinstance(result, bool):
        ok(f"returns bool (value={result})")
    else:
        fail(f"expected bool, got {type(result).__name__}")

    print("=== kvm_available: consistent with /dev/kvm access ===")
    expected = os.access("/dev/kvm", os.R_OK | os.W_OK)
    if kvm_available() == expected:
        ok("matches os.access check")
    else:
        fail("disagrees with os.access")

    # ----------------------------------------------------------------
    # IMA file-matching logic tests (disk_image_helper._apply_ima)
    # ----------------------------------------------------------------
    # We test the file-walking pattern used by _apply_ima without
    # requiring evmctl.  The logic under test:
    #   1. Walk directory tree
    #   2. Find files ending in .sig
    #   3. Strip .sig suffix to get target path
    #   4. Check if target file exists

    print("=== IMA: .sig suffix detection ===")
    sig_names = ["foo.bin.sig", "bar.sig", "lib.so.1.sig"]
    non_sig = ["foo.bin", "bar.signature", "sig", ".sig.bak", "readme"]
    detected = [f for f in sig_names + non_sig if f.endswith(".sig")]
    if detected == sig_names:
        ok(".sig suffix correctly filters filenames")
    else:
        fail(f"expected {sig_names!r}, got {detected!r}")

    print("=== IMA: target path stripping ===")
    cases = [
        ("/mnt/foo.bin.sig", "/mnt/foo.bin"),
        ("/mnt/lib.so.1.sig", "/mnt/lib.so.1"),
        ("/a/b/c.sig", "/a/b/c"),
        ("relative.sig", "relative"),
    ]
    all_ok = True
    for sig_path, expected_target in cases:
        target = sig_path[:-4]
        if target != expected_target:
            fail(f"strip .sig: {sig_path!r} -> {target!r}, expected {expected_target!r}")
            all_ok = False
    if all_ok:
        ok("sig_path[:-4] strips .sig correctly for all cases")

    print("=== IMA: target existence check with real files ===")
    tmpdir = tempfile.mkdtemp(prefix="test_ima_")
    try:
        # Create target + sidecar pair
        target_path = os.path.join(tmpdir, "hello.bin")
        sig_path = os.path.join(tmpdir, "hello.bin.sig")
        with open(target_path, "w") as f:
            f.write("binary content")
        with open(sig_path, "w") as f:
            f.write("signature data")

        # Orphan sidecar (no matching target)
        orphan_sig = os.path.join(tmpdir, "orphan.bin.sig")
        with open(orphan_sig, "w") as f:
            f.write("orphan sig")

        # Walk and apply the matching logic
        matched = []
        unmatched = []
        for dirpath, _, filenames in os.walk(tmpdir):
            for fname in filenames:
                if not fname.endswith(".sig"):
                    continue
                sp = os.path.join(dirpath, fname)
                t = sp[:-4]
                if os.path.isfile(t):
                    matched.append(fname)
                else:
                    unmatched.append(fname)

        if matched == ["hello.bin.sig"]:
            ok("matched target+sidecar pair")
        else:
            fail(f"expected ['hello.bin.sig'], got {matched!r}")

        if unmatched == ["orphan.bin.sig"]:
            ok("orphan sidecar correctly unmatched")
        else:
            fail(f"expected ['orphan.bin.sig'], got {unmatched!r}")
    finally:
        import shutil
        shutil.rmtree(tmpdir, ignore_errors=True)

    print("=== IMA: nested directory walking ===")
    tmpdir = tempfile.mkdtemp(prefix="test_ima_nested_")
    try:
        # Create nested structure:
        #   tmpdir/usr/bin/tool         (target)
        #   tmpdir/usr/bin/tool.sig     (sidecar)
        #   tmpdir/usr/lib/libfoo.so    (target)
        #   tmpdir/usr/lib/libfoo.so.sig (sidecar)
        #   tmpdir/etc/config.sig       (orphan, no target)
        for d in ("usr/bin", "usr/lib", "etc"):
            os.makedirs(os.path.join(tmpdir, d))

        for f in ("usr/bin/tool", "usr/bin/tool.sig",
                   "usr/lib/libfoo.so", "usr/lib/libfoo.so.sig",
                   "etc/config.sig"):
            with open(os.path.join(tmpdir, f), "w") as fh:
                fh.write("data")

        matched = []
        unmatched = []
        for dirpath, _, filenames in os.walk(tmpdir):
            for fname in sorted(filenames):
                if not fname.endswith(".sig"):
                    continue
                sp = os.path.join(dirpath, fname)
                t = sp[:-4]
                if os.path.isfile(t):
                    matched.append(os.path.relpath(sp, tmpdir))
                else:
                    unmatched.append(os.path.relpath(sp, tmpdir))

        matched.sort()
        unmatched.sort()
        if matched == ["usr/bin/tool.sig", "usr/lib/libfoo.so.sig"]:
            ok("nested sidecar pairs found across directories")
        else:
            fail(f"expected nested matches, got {matched!r}")

        if unmatched == ["etc/config.sig"]:
            ok("nested orphan sidecar correctly unmatched")
        else:
            fail(f"expected ['etc/config.sig'], got {unmatched!r}")
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    print("=== IMA: empty directory produces no matches ===")
    tmpdir = tempfile.mkdtemp(prefix="test_ima_empty_")
    try:
        matched = []
        for dirpath, _, filenames in os.walk(tmpdir):
            for fname in filenames:
                if fname.endswith(".sig"):
                    matched.append(fname)
        if matched == []:
            ok("empty directory yields no matches")
        else:
            fail(f"expected [], got {matched!r}")
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    print("=== IMA: file named exactly '.sig' has empty target name ===")
    sig_path = "/some/dir/.sig"
    target = sig_path[:-4]
    if target == "/some/dir/":
        ok(".sig file strips to directory path (correctly rejected by isfile)")
    else:
        fail(f"expected '/some/dir/', got {target!r}")

    # ----------------------------------------------------------------
    # _parse_size tests
    # ----------------------------------------------------------------

    print("=== _parse_size: bytes (no suffix) ===")
    if _parse_size("1024") == 1024:
        ok("1024 -> 1024")
    else:
        fail(f"expected 1024, got {_parse_size('1024')}")

    print("=== _parse_size: kilobytes ===")
    if _parse_size("4K") == 4096:
        ok("4K -> 4096")
    else:
        fail(f"expected 4096, got {_parse_size('4K')}")

    print("=== _parse_size: megabytes ===")
    if _parse_size("512M") == 512 * 1024 * 1024:
        ok("512M -> 536870912")
    else:
        fail(f"expected 536870912, got {_parse_size('512M')}")

    print("=== _parse_size: gigabytes ===")
    if _parse_size("2G") == 2 * 1024 * 1024 * 1024:
        ok("2G -> 2147483648")
    else:
        fail(f"expected 2147483648, got {_parse_size('2G')}")

    print("=== _parse_size: terabytes ===")
    if _parse_size("1T") == 1024 * 1024 * 1024 * 1024:
        ok("1T -> 1099511627776")
    else:
        fail(f"expected 1099511627776, got {_parse_size('1T')}")

    print("=== _parse_size: lowercase suffix ===")
    if _parse_size("2g") == 2 * 1024 * 1024 * 1024:
        ok("2g -> same as 2G")
    else:
        fail(f"expected 2147483648, got {_parse_size('2g')}")

    # ----------------------------------------------------------------
    # _parse_sgdisk_output tests
    # ----------------------------------------------------------------

    print("=== _parse_sgdisk_output: typical two-partition GPT ===")
    sgdisk_text = """\
Disk /tmp/disk.img: 4194304 sectors, 2.0 GiB
Sector size (logical/physical): 512/512 bytes
Disk identifier (GUID): 12345678-ABCD-EFGH-IJKL-123456789012
Partition table holds up to 128 entries
Main partition table begins at sector 2 and ends at sector 33
First usable sector is 34, last usable sector is 4194270
Partitions will be aligned on 2048-sector boundaries
Total free space is 2014 sectors (1007.0 KiB)

Number  Start (sector)    End (sector)  Size       Code  Name
   1            2048          206847   100.0 MiB   EF00  EFI
   2          206848         4194270   1.9 GiB     8300  buckos
"""
    parts = _parse_sgdisk_output(sgdisk_text)
    if len(parts) == 2:
        ok("parsed 2 partitions")
    else:
        fail(f"expected 2 partitions, got {len(parts)}")

    if parts[0]['number'] == 1 and parts[0]['start'] == 2048 and parts[0]['end'] == 206847:
        ok("partition 1 start/end correct")
    else:
        fail(f"partition 1 wrong: {parts[0]!r}")

    if parts[0]['code'] == 'EF00' and parts[0]['name'] == 'EFI':
        ok("partition 1 code/name correct")
    else:
        fail(f"partition 1 code/name wrong: {parts[0]!r}")

    if parts[1]['number'] == 2 and parts[1]['start'] == 206848 and parts[1]['end'] == 4194270:
        ok("partition 2 start/end correct")
    else:
        fail(f"partition 2 wrong: {parts[1]!r}")

    if parts[1]['code'] == '8300' and parts[1]['name'] == 'buckos':
        ok("partition 2 code/name correct")
    else:
        fail(f"partition 2 code/name wrong: {parts[1]!r}")

    print("=== _parse_sgdisk_output: empty input ===")
    parts = _parse_sgdisk_output("")
    if parts == []:
        ok("empty input returns empty list")
    else:
        fail(f"expected [], got {parts!r}")

    print("=== _parse_sgdisk_output: no partitions ===")
    no_parts_text = """\
Disk /tmp/disk.img: 4194304 sectors, 2.0 GiB
Sector size (logical/physical): 512/512 bytes

Number  Start (sector)    End (sector)  Size       Code  Name
"""
    parts = _parse_sgdisk_output(no_parts_text)
    if parts == []:
        ok("header-only returns empty list")
    else:
        fail(f"expected [], got {parts!r}")

    # ----------------------------------------------------------------
    # _build_debugfs_ima_commands tests
    # ----------------------------------------------------------------

    print("=== _build_debugfs_ima_commands: paired sidecars ===")
    tmpdir = tempfile.mkdtemp(prefix="test_debugfs_")
    try:
        os.makedirs(os.path.join(tmpdir, "usr", "bin"))
        for f in ("usr/bin/app", "usr/bin/app.sig"):
            with open(os.path.join(tmpdir, f), "w") as fh:
                fh.write("data")

        cmds, count = _build_debugfs_ima_commands(tmpdir)
        if count == 1:
            ok("count=1 for one paired sidecar")
        else:
            fail(f"expected count=1, got {count}")

        if len(cmds) == 2:
            ok("two commands (ea_set + rm)")
        else:
            fail(f"expected 2 commands, got {len(cmds)}")

        if cmds[0] == f"ea_set /usr/bin/app security.ima -f {os.path.join(tmpdir, 'usr/bin/app.sig')}":
            ok("ea_set command correct")
        else:
            fail(f"unexpected ea_set: {cmds[0]!r}")

        if cmds[1] == "rm /usr/bin/app.sig":
            ok("rm command correct")
        else:
            fail(f"unexpected rm: {cmds[1]!r}")
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    print("=== _build_debugfs_ima_commands: orphan sidecar ignored ===")
    tmpdir = tempfile.mkdtemp(prefix="test_debugfs_orphan_")
    try:
        with open(os.path.join(tmpdir, "orphan.sig"), "w") as fh:
            fh.write("sig")

        cmds, count = _build_debugfs_ima_commands(tmpdir)
        if count == 0 and cmds == []:
            ok("orphan sidecar produces no commands")
        else:
            fail(f"expected empty, got count={count} cmds={cmds!r}")
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    print("=== _build_debugfs_ima_commands: empty directory ===")
    tmpdir = tempfile.mkdtemp(prefix="test_debugfs_empty_")
    try:
        cmds, count = _build_debugfs_ima_commands(tmpdir)
        if count == 0 and cmds == []:
            ok("empty directory produces no commands")
        else:
            fail(f"expected empty, got count={count} cmds={cmds!r}")
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    print("=== _build_debugfs_ima_commands: multiple sidecars sorted ===")
    tmpdir = tempfile.mkdtemp(prefix="test_debugfs_multi_")
    try:
        os.makedirs(os.path.join(tmpdir, "usr", "bin"))
        os.makedirs(os.path.join(tmpdir, "usr", "lib"))
        for f in ("usr/bin/z-tool", "usr/bin/z-tool.sig",
                   "usr/bin/a-tool", "usr/bin/a-tool.sig",
                   "usr/lib/libfoo.so", "usr/lib/libfoo.so.sig"):
            with open(os.path.join(tmpdir, f), "w") as fh:
                fh.write("data")

        cmds, count = _build_debugfs_ima_commands(tmpdir)
        if count == 3:
            ok("count=3 for three paired sidecars")
        else:
            fail(f"expected count=3, got {count}")

        # Verify commands reference sorted filenames within each directory
        ea_cmds = [c for c in cmds if c.startswith("ea_set")]
        paths = [c.split()[1] for c in ea_cmds]
        # Within usr/bin, a-tool should come before z-tool (sorted)
        bin_paths = [p for p in paths if "/bin/" in p]
        if bin_paths == ["/usr/bin/a-tool", "/usr/bin/z-tool"]:
            ok("filenames sorted within directory")
        else:
            fail(f"expected sorted bin paths, got {bin_paths!r}")
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    print("=== _build_debugfs_ima_commands: with image_rel_prefix ===")
    tmpdir = tempfile.mkdtemp(prefix="test_debugfs_prefix_")
    try:
        with open(os.path.join(tmpdir, "file"), "w") as fh:
            fh.write("data")
        with open(os.path.join(tmpdir, "file.sig"), "w") as fh:
            fh.write("sig")

        cmds, count = _build_debugfs_ima_commands(tmpdir, image_rel_prefix="/root")
        if count == 1:
            ok("count=1 with prefix")
        else:
            fail(f"expected count=1, got {count}")

        if cmds[0].startswith("ea_set /root/file security.ima"):
            ok("prefix applied to ea_set path")
        else:
            fail(f"unexpected ea_set: {cmds[0]!r}")

        if cmds[1] == "rm /root/file.sig":
            ok("prefix applied to rm path")
        else:
            fail(f"unexpected rm: {cmds[1]!r}")
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

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
