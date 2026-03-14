#!/usr/bin/env python3
"""Unit tests for small helper utilities."""
import io
import os
import shutil
import stat
import sys
import tempfile
from pathlib import Path

_REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO / "tools"))

from stamp_helper import is_elf
from stage2_wrapper_helper import _is_elf, _WRAPPER_TEMPLATE
from boot_script_helper import _SCRIPT_TEMPLATE
from initramfs_builder import _fix_lib64

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
    # is_elf / _is_elf tests
    # ----------------------------------------------------------------

    print("=== is_elf: real ELF file detected ===")
    with tempfile.NamedTemporaryFile(delete=False) as f:
        f.write(b"\x7fELF" + b"\x00" * 12)
        f.flush()
        try:
            if is_elf(f.name):
                ok("real ELF magic detected")
            else:
                fail("is_elf returned False for ELF file")
        finally:
            os.unlink(f.name)

    print("=== is_elf: non-ELF file returns False ===")
    with tempfile.NamedTemporaryFile(delete=False, mode="w") as f:
        f.write("hello world")
        f.flush()
        try:
            if not is_elf(f.name):
                ok("non-ELF file returns False")
            else:
                fail("is_elf returned True for text file")
        finally:
            os.unlink(f.name)

    print("=== is_elf: empty file returns False ===")
    with tempfile.NamedTemporaryFile(delete=False) as f:
        pass  # empty
    try:
        if not is_elf(f.name):
            ok("empty file returns False")
        else:
            fail("is_elf returned True for empty file")
    finally:
        os.unlink(f.name)

    print("=== is_elf: nonexistent path returns False ===")
    if not is_elf("/nonexistent/path/to/file"):
        ok("nonexistent path returns False")
    else:
        fail("is_elf returned True for nonexistent path")

    print("=== is_elf: directory path returns False ===")
    with tempfile.TemporaryDirectory() as d:
        if not is_elf(d):
            ok("directory path returns False")
        else:
            fail("is_elf returned True for directory")

    print("=== is_elf: short file (< 4 bytes) returns False ===")
    with tempfile.NamedTemporaryFile(delete=False) as f:
        f.write(b"\x7fE")
        f.flush()
        try:
            if not is_elf(f.name):
                ok("short file returns False")
            else:
                fail("is_elf returned True for short file")
        finally:
            os.unlink(f.name)

    print("=== is_elf: ELF magic + garbage still returns True ===")
    with tempfile.NamedTemporaryFile(delete=False) as f:
        f.write(b"\x7fELF" + b"\xde\xad\xbe\xef" * 4)
        f.flush()
        try:
            if is_elf(f.name):
                ok("ELF magic + garbage returns True")
            else:
                fail("is_elf returned False for ELF magic + garbage")
        finally:
            os.unlink(f.name)

    print("=== _is_elf: matches is_elf behavior ===")
    with tempfile.NamedTemporaryFile(delete=False) as f:
        f.write(b"\x7fELF" + b"\x00" * 8)
        f.flush()
        elf_path = f.name
    with tempfile.NamedTemporaryFile(delete=False, mode="w") as f:
        f.write("not elf")
        f.flush()
        txt_path = f.name
    try:
        match = (
            _is_elf(elf_path) == is_elf(elf_path)
            and _is_elf(txt_path) == is_elf(txt_path)
            and _is_elf("/nonexistent") == is_elf("/nonexistent")
        )
        if match:
            ok("_is_elf matches is_elf for all cases")
        else:
            fail("_is_elf and is_elf diverge")
    finally:
        os.unlink(elf_path)
        os.unlink(txt_path)

    # ----------------------------------------------------------------
    # Boot script template tests
    # ----------------------------------------------------------------

    print("=== boot_script: template renders with all fields ===")
    rendered = _SCRIPT_TEMPLATE.format(
        kernel="buck-out/v2/kernel/vmlinuz",
        initramfs="buck-out/v2/initramfs.cpio.gz",
        qemu_bin="qemu-system-x86_64",
        machine="q35",
        memory="512M",
        cpus="2",
        kernel_args="console=ttyS0 quiet",
        extra_args="",
    )
    if "qemu-system-x86_64" in rendered and "-machine q35" in rendered:
        ok("template renders with all fields")
    else:
        fail("template rendering missing expected content")

    print("=== boot_script: template contains shebang ===")
    if rendered.startswith("#!/bin/bash\n"):
        ok("template starts with bash shebang")
    else:
        fail(f"unexpected start: {rendered[:30]!r}")

    print("=== boot_script: template contains KERNEL variable ===")
    if 'KERNEL="buck-out/v2/kernel/vmlinuz"' in rendered:
        ok("KERNEL variable assignment present")
    else:
        fail("KERNEL variable assignment not found")

    print("=== boot_script: template contains INITRAMFS variable ===")
    if 'INITRAMFS="buck-out/v2/initramfs.cpio.gz"' in rendered:
        ok("INITRAMFS variable assignment present")
    else:
        fail("INITRAMFS variable assignment not found")

    print("=== boot_script: custom qemu_bin renders correctly ===")
    rendered_aarch64 = _SCRIPT_TEMPLATE.format(
        kernel="vmlinuz",
        initramfs="initramfs.cpio.gz",
        qemu_bin="qemu-system-aarch64",
        machine="virt",
        memory="1G",
        cpus="4",
        kernel_args="console=ttyAMA0",
        extra_args="-cpu cortex-a72",
    )
    if "qemu-system-aarch64" in rendered_aarch64:
        ok("custom qemu_bin renders correctly")
    else:
        fail("qemu-system-aarch64 not found in rendered template")

    print("=== boot_script: custom kernel_args in -append flag ===")
    if '-append "console=ttyAMA0"' in rendered_aarch64:
        ok("custom kernel_args in -append flag")
    else:
        fail("custom kernel_args not found in -append")

    print("=== boot_script: extra_args rendered in correct position ===")
    if "-cpu cortex-a72" in rendered_aarch64:
        ok("extra_args rendered")
    else:
        fail("extra_args not found in rendered template")

    # ----------------------------------------------------------------
    # Stage2 wrapper template tests
    # ----------------------------------------------------------------

    print("=== wrapper_template: renders with triple ===")
    triple = "x86_64-buckos-linux-gnu"
    wrapper = _WRAPPER_TEMPLATE.format(triple=triple)
    if triple in wrapper:
        ok("triple rendered in wrapper template")
    else:
        fail("triple not found in rendered wrapper")

    print("=== wrapper_template: contains ld-linux invocation ===")
    if "ld-linux-x86-64.so.2" in wrapper:
        ok("ld-linux-x86-64.so.2 present")
    else:
        fail("ld-linux-x86-64.so.2 not found")

    print("=== wrapper_template: contains --library-path ===")
    if "--library-path" in wrapper:
        ok("--library-path present")
    else:
        fail("--library-path not found")

    print("=== wrapper_template: shell variables present ===")
    has_vars = (
        "SCRIPT_DIR=" in wrapper
        and "TOOL_NAME=" in wrapper
        and "REAL_TOOL=" in wrapper
    )
    if has_vars:
        ok("SCRIPT_DIR, TOOL_NAME, REAL_TOOL assignments present")
    else:
        fail("one or more shell variable assignments missing")

    # ----------------------------------------------------------------
    # _fix_lib64 tests
    # ----------------------------------------------------------------

    print("=== _fix_lib64: lib64 merged into lib, becomes symlink ===")
    with tempfile.TemporaryDirectory() as staging:
        lib64 = os.path.join(staging, "lib64")
        os.makedirs(lib64)
        with open(os.path.join(lib64, "libfoo.so"), "w") as f:
            f.write("fake lib")
        _fix_lib64(staging)
        lib = os.path.join(staging, "lib")
        if (os.path.islink(lib64)
                and os.readlink(lib64) == "lib"
                and os.path.isfile(os.path.join(lib, "libfoo.so"))):
            ok("lib64 merged and became symlink to lib")
        else:
            fail("lib64 merge failed")

    print("=== _fix_lib64: usr/lib64 merged into usr/lib ===")
    with tempfile.TemporaryDirectory() as staging:
        usr_lib64 = os.path.join(staging, "usr", "lib64")
        os.makedirs(usr_lib64)
        with open(os.path.join(usr_lib64, "libbar.so"), "w") as f:
            f.write("fake lib")
        _fix_lib64(staging)
        usr_lib = os.path.join(staging, "usr", "lib")
        if (os.path.islink(usr_lib64)
                and os.readlink(usr_lib64) == "lib"
                and os.path.isfile(os.path.join(usr_lib, "libbar.so"))):
            ok("usr/lib64 merged and became symlink")
        else:
            fail("usr/lib64 merge failed")

    print("=== _fix_lib64: lib64 already a symlink -- no action ===")
    with tempfile.TemporaryDirectory() as staging:
        lib = os.path.join(staging, "lib")
        os.makedirs(lib)
        lib64 = os.path.join(staging, "lib64")
        os.symlink("lib", lib64)
        _fix_lib64(staging)
        if os.path.islink(lib64) and os.readlink(lib64) == "lib":
            ok("existing symlink left alone")
        else:
            fail("existing symlink was modified")

    print("=== _fix_lib64: lib64 doesn't exist -- no action ===")
    with tempfile.TemporaryDirectory() as staging:
        # staging is empty, no lib64
        _fix_lib64(staging)
        if not os.path.exists(os.path.join(staging, "lib64")):
            ok("no-op when lib64 absent")
        else:
            fail("lib64 created from nothing")

    print("=== _fix_lib64: files already in lib not overwritten ===")
    with tempfile.TemporaryDirectory() as staging:
        lib = os.path.join(staging, "lib")
        lib64 = os.path.join(staging, "lib64")
        os.makedirs(lib)
        os.makedirs(lib64)
        with open(os.path.join(lib, "libc.so"), "w") as f:
            f.write("original")
        with open(os.path.join(lib64, "libc.so"), "w") as f:
            f.write("duplicate")
        with open(os.path.join(lib64, "libm.so"), "w") as f:
            f.write("new")
        _fix_lib64(staging)
        with open(os.path.join(lib, "libc.so")) as f:
            content = f.read()
        has_new = os.path.isfile(os.path.join(lib, "libm.so"))
        if content == "original" and has_new:
            ok("existing file preserved, new file moved")
        else:
            fail(f"content={content!r}, libm.so exists={has_new}")

    print("=== _fix_lib64: both top-level and usr/ fixed in one call ===")
    with tempfile.TemporaryDirectory() as staging:
        for prefix in ("", "usr/"):
            d = os.path.join(staging, prefix + "lib64")
            os.makedirs(d)
            with open(os.path.join(d, "libtest.so"), "w") as f:
                f.write("test")
        _fix_lib64(staging)
        both_ok = (
            os.path.islink(os.path.join(staging, "lib64"))
            and os.path.islink(os.path.join(staging, "usr", "lib64"))
            and os.path.isfile(os.path.join(staging, "lib", "libtest.so"))
            and os.path.isfile(os.path.join(staging, "usr", "lib", "libtest.so"))
        )
        if both_ok:
            ok("both top-level and usr/ lib64 fixed")
        else:
            fail("one or both lib64 dirs not fixed")

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
