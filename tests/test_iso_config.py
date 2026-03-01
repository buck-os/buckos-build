#!/usr/bin/env python3
"""Unit tests for ISO image helper config generation."""
import os
import sys
import tempfile
from pathlib import Path

_REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO / "tools"))

from iso_helper import (
    _write_isolinux_cfg,
    _write_grub_cfg,
    _pin_timestamps,
    _resolve_path,
    _find_syslinux_file,
)

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


def main():
    # ===================================================================
    # _write_isolinux_cfg tests
    # ===================================================================

    # 1. Config file created at correct path
    print("=== _write_isolinux_cfg: config created at correct path ===")
    with tempfile.TemporaryDirectory() as d:
        _write_isolinux_cfg(d, "quiet")
        cfg = os.path.join(d, "isolinux", "isolinux.cfg")
        if os.path.isfile(cfg):
            ok("isolinux.cfg created at isolinux/isolinux.cfg")
        else:
            fail(f"expected {cfg} to exist")

    # 2. Contains KERNEL/LINUX entry
    print("=== _write_isolinux_cfg: contains LINUX entry ===")
    with tempfile.TemporaryDirectory() as d:
        _write_isolinux_cfg(d, "quiet")
        cfg = os.path.join(d, "isolinux", "isolinux.cfg")
        content = open(cfg).read()
        if "LINUX /boot/vmlinuz" in content:
            ok("contains LINUX /boot/vmlinuz")
        else:
            fail("missing LINUX entry")

    # 3. Contains APPEND with kernel_args
    print("=== _write_isolinux_cfg: contains APPEND with kernel_args ===")
    with tempfile.TemporaryDirectory() as d:
        _write_isolinux_cfg(d, "root=/dev/sda1 ro")
        content = open(os.path.join(d, "isolinux", "isolinux.cfg")).read()
        if "APPEND root=/dev/sda1 ro" in content:
            ok("APPEND contains kernel_args")
        else:
            fail(f"APPEND line not found with expected args")

    # 4. Kernel args with spaces rendered correctly
    print("=== _write_isolinux_cfg: kernel args with spaces ===")
    with tempfile.TemporaryDirectory() as d:
        args = "quiet splash console=ttyS0,115200 loglevel=3"
        _write_isolinux_cfg(d, args)
        content = open(os.path.join(d, "isolinux", "isolinux.cfg")).read()
        if f"APPEND {args}" in content:
            ok("multi-word kernel args rendered correctly")
        else:
            fail("multi-word kernel args not rendered correctly")

    # 5. Config contains DEFAULT and TIMEOUT
    print("=== _write_isolinux_cfg: contains DEFAULT and TIMEOUT ===")
    with tempfile.TemporaryDirectory() as d:
        _write_isolinux_cfg(d, "quiet")
        content = open(os.path.join(d, "isolinux", "isolinux.cfg")).read()
        has_default = "DEFAULT buckos" in content
        has_timeout = "TIMEOUT 50" in content
        if has_default and has_timeout:
            ok("DEFAULT and TIMEOUT present")
        else:
            fail(f"DEFAULT={has_default}, TIMEOUT={has_timeout}")

    # 6. Config contains INITRD line
    print("=== _write_isolinux_cfg: contains INITRD ===")
    with tempfile.TemporaryDirectory() as d:
        _write_isolinux_cfg(d, "quiet")
        content = open(os.path.join(d, "isolinux", "isolinux.cfg")).read()
        if "INITRD /boot/initramfs.img" in content:
            ok("INITRD line present")
        else:
            fail("INITRD line missing")

    # 7. Config has multiple LABEL entries (buckos, safe, recovery)
    print("=== _write_isolinux_cfg: has multiple LABEL entries ===")
    with tempfile.TemporaryDirectory() as d:
        _write_isolinux_cfg(d, "quiet")
        content = open(os.path.join(d, "isolinux", "isolinux.cfg")).read()
        labels = sum(1 for line in content.splitlines()
                     if line.startswith("LABEL "))
        if labels == 3:
            ok(f"has {labels} LABEL entries (buckos, safe, recovery)")
        else:
            fail(f"expected 3 LABEL entries, got {labels}")

    # ===================================================================
    # _write_grub_cfg tests
    # ===================================================================

    # 8. Config created for x86_64
    print("=== _write_grub_cfg: config created for x86_64 ===")
    with tempfile.TemporaryDirectory() as d:
        _write_grub_cfg(d, "quiet", "x86_64")
        cfg = os.path.join(d, "boot", "grub", "grub.cfg")
        if os.path.isfile(cfg):
            ok("grub.cfg created for x86_64")
        else:
            fail("grub.cfg not created")

    # 9. Config created for aarch64 with ttyAMA0 console
    print("=== _write_grub_cfg: aarch64 uses ttyAMA0 console ===")
    with tempfile.TemporaryDirectory() as d:
        _write_grub_cfg(d, "quiet", "aarch64")
        content = open(os.path.join(d, "boot", "grub", "grub.cfg")).read()
        if "console=ttyAMA0" in content:
            ok("aarch64 config uses ttyAMA0")
        else:
            fail("aarch64 config missing ttyAMA0")

    # 10. x86_64 config does not contain ttyAMA0
    print("=== _write_grub_cfg: x86_64 does not have ttyAMA0 ===")
    with tempfile.TemporaryDirectory() as d:
        _write_grub_cfg(d, "quiet", "x86_64")
        content = open(os.path.join(d, "boot", "grub", "grub.cfg")).read()
        if "ttyAMA0" not in content:
            ok("x86_64 config does not contain ttyAMA0")
        else:
            fail("x86_64 config unexpectedly contains ttyAMA0")

    # 11. Contains menuentry
    print("=== _write_grub_cfg: contains menuentry ===")
    with tempfile.TemporaryDirectory() as d:
        _write_grub_cfg(d, "quiet", "x86_64")
        content = open(os.path.join(d, "boot", "grub", "grub.cfg")).read()
        if "menuentry" in content:
            ok("contains menuentry")
        else:
            fail("missing menuentry")

    # 12. Contains linux and initrd lines
    print("=== _write_grub_cfg: contains linux and initrd lines ===")
    with tempfile.TemporaryDirectory() as d:
        _write_grub_cfg(d, "quiet", "x86_64")
        content = open(os.path.join(d, "boot", "grub", "grub.cfg")).read()
        has_linux = "linux /boot/vmlinuz" in content
        has_initrd = "initrd /boot/initramfs.img" in content
        if has_linux and has_initrd:
            ok("linux and initrd lines present")
        else:
            fail(f"linux={has_linux}, initrd={has_initrd}")

    # 13. Kernel args rendered in linux line
    print("=== _write_grub_cfg: kernel args in linux line ===")
    with tempfile.TemporaryDirectory() as d:
        _write_grub_cfg(d, "root=/dev/sda1 ro", "x86_64")
        content = open(os.path.join(d, "boot", "grub", "grub.cfg")).read()
        if "linux /boot/vmlinuz root=/dev/sda1 ro" in content:
            ok("kernel args rendered in linux line")
        else:
            fail("kernel args not found in linux line")

    # 14. Contains set timeout
    print("=== _write_grub_cfg: contains set timeout ===")
    with tempfile.TemporaryDirectory() as d:
        _write_grub_cfg(d, "quiet", "x86_64")
        content = open(os.path.join(d, "boot", "grub", "grub.cfg")).read()
        if "set timeout=5" in content:
            ok("set timeout=5 present")
        else:
            fail("set timeout not found")

    # 15. aarch64 config has serial terminal setup
    print("=== _write_grub_cfg: aarch64 has serial terminal config ===")
    with tempfile.TemporaryDirectory() as d:
        _write_grub_cfg(d, "quiet", "aarch64")
        content = open(os.path.join(d, "boot", "grub", "grub.cfg")).read()
        has_serial = "serial --unit=0 --speed=115200" in content
        has_terminal = "terminal_input serial console" in content
        if has_serial and has_terminal:
            ok("aarch64 has serial terminal setup")
        else:
            fail(f"serial={has_serial}, terminal={has_terminal}")

    # ===================================================================
    # _pin_timestamps tests
    # ===================================================================

    # 16. Regular file timestamp set to epoch
    print("=== _pin_timestamps: regular file timestamp set ===")
    with tempfile.TemporaryDirectory() as d:
        f = os.path.join(d, "file.txt")
        open(f, "w").close()
        epoch = 315576000
        _pin_timestamps(d, epoch)
        st = os.stat(f)
        if st.st_mtime == epoch and st.st_atime == epoch:
            ok("file timestamps set to epoch")
        else:
            fail(f"expected mtime={epoch}, got mtime={st.st_mtime}")

    # 17. Directory timestamp set to epoch
    print("=== _pin_timestamps: directory timestamp set ===")
    with tempfile.TemporaryDirectory() as d:
        sub = os.path.join(d, "subdir")
        os.makedirs(sub)
        epoch = 315576000
        _pin_timestamps(d, epoch)
        st = os.stat(sub)
        if st.st_mtime == epoch:
            ok("directory timestamp set to epoch")
        else:
            fail(f"expected mtime={epoch}, got {st.st_mtime}")

    # 18. Nested files all touched
    print("=== _pin_timestamps: nested files all touched ===")
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, "a", "b", "c"))
        for name in ["a/x.txt", "a/b/y.txt", "a/b/c/z.txt"]:
            open(os.path.join(d, name), "w").close()
        epoch = 100000
        _pin_timestamps(d, epoch)
        all_ok = True
        for name in ["a/x.txt", "a/b/y.txt", "a/b/c/z.txt"]:
            st = os.stat(os.path.join(d, name))
            if st.st_mtime != epoch:
                all_ok = False
                break
        if all_ok:
            ok("all nested files have epoch timestamp")
        else:
            fail("some nested files have wrong timestamp")

    # 19. Symlinks handled (not followed for timestamp)
    print("=== _pin_timestamps: symlinks not followed ===")
    with tempfile.TemporaryDirectory() as d:
        target = os.path.join(d, "target.txt")
        link = os.path.join(d, "link.txt")
        open(target, "w").close()
        os.symlink(target, link)
        epoch = 200000
        _pin_timestamps(d, epoch)
        # The function uses follow_symlinks=False, so lstat the symlink
        lst = os.lstat(link)
        if lst.st_mtime == epoch:
            ok("symlink timestamp set without following")
        else:
            fail(f"symlink mtime: expected {epoch}, got {lst.st_mtime}")

    # 20. Root directory itself gets timestamped
    print("=== _pin_timestamps: root dir timestamped ===")
    with tempfile.TemporaryDirectory() as d:
        epoch = 315576000
        _pin_timestamps(d, epoch)
        st = os.stat(d)
        if st.st_mtime == epoch:
            ok("root directory timestamp set")
        else:
            fail(f"root dir mtime: expected {epoch}, got {st.st_mtime}")

    # ===================================================================
    # _resolve_path tests
    # ===================================================================

    # 21. Relative existing path resolved to absolute
    print("=== _resolve_path: relative existing path resolved ===")
    saved_cwd = os.getcwd()
    with tempfile.TemporaryDirectory() as d:
        try:
            os.chdir(d)
            open(os.path.join(d, "exists.txt"), "w").close()
            result = _resolve_path("exists.txt")
            if os.path.isabs(result) and result == os.path.join(d, "exists.txt"):
                ok("relative path resolved to absolute")
            else:
                fail(f"expected absolute path, got '{result}'")
        finally:
            os.chdir(saved_cwd)

    # 22. Absolute path returned unchanged
    print("=== _resolve_path: absolute path unchanged ===")
    result = _resolve_path("/usr/bin/env")
    if result == "/usr/bin/env":
        ok("absolute path returned unchanged")
    else:
        fail(f"expected '/usr/bin/env', got '{result}'")

    # 23. Non-existent relative path returned as-is
    print("=== _resolve_path: non-existent relative path returned as-is ===")
    result = _resolve_path("no_such_file_xyz_123")
    if result == "no_such_file_xyz_123":
        ok("non-existent relative path returned as-is")
    else:
        fail(f"expected 'no_such_file_xyz_123', got '{result}'")

    # 24. None input returns None
    print("=== _resolve_path: None returns None ===")
    result = _resolve_path(None)
    if result is None:
        ok("None input returns None")
    else:
        fail(f"expected None, got '{result}'")

    # 25. Empty string returns empty string
    print("=== _resolve_path: empty string returns empty ===")
    result = _resolve_path("")
    if result == "":
        ok("empty string returns empty string")
    else:
        fail(f"expected '', got '{result}'")

    # ===================================================================
    # _find_syslinux_file tests
    # ===================================================================

    # 26. File found when present in search path (search_dirs param)
    print("=== _find_syslinux_file: finds file via search_dirs ===")
    with tempfile.TemporaryDirectory() as d:
        # Create a fake syslinux file
        open(os.path.join(d, "isolinux.bin"), "w").close()
        result = _find_syslinux_file("isolinux.bin", search_dirs=[d])
        if result and result.endswith("isolinux.bin"):
            ok("finds file in search_dirs")
        else:
            fail(f"expected path to isolinux.bin, got '{result}'")

    # 27. File not found returns None
    print("=== _find_syslinux_file: missing file returns None ===")
    result = _find_syslinux_file("definitely_not_a_real_syslinux_file.xyz")
    if result is None:
        ok("missing file returns None")
    else:
        fail(f"expected None, got '{result}'")

    # -- Summary --
    print(f"\n--- {passed} passed, {failed} failed ---")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
