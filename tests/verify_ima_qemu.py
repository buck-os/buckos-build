#!/usr/bin/env python3
"""IMA QEMU enforcement test.

Boots QEMU with kernel/initramfs/disk and checks serial output for markers.

Env vars from sh_test:
    KERNEL             — path to kernel image (file or directory with boot/vmlinuz*)
    INITRAMFS          — path to initramfs cpio.gz
    DISK               — path to ext4 disk image
    CMDLINE_EXTRA      — extra kernel cmdline args
    EXPECT_MARKER      — string that must appear in output
    EXPECT_TEST_OUTPUT — string that must appear (optional)
    EXPECT_NO_TEST_OUTPUT — string that must NOT appear (optional)
"""

import os
import shutil
import subprocess
import sys


def find_kernel(path):
    if os.path.isfile(path):
        return path
    for dirpath, _, filenames in os.walk(path):
        for f in sorted(filenames):
            if f.startswith("vmlinuz"):
                return os.path.join(dirpath, f)
    return None


def main():
    kernel_path = os.environ.get("KERNEL", "")
    initramfs = os.environ.get("INITRAMFS", "")
    disk = os.environ.get("DISK", "")
    cmdline_extra = os.environ.get("CMDLINE_EXTRA", "")
    expect_marker = os.environ.get("EXPECT_MARKER", "")
    expect_test_output = os.environ.get("EXPECT_TEST_OUTPUT", "")
    expect_no_test_output = os.environ.get("EXPECT_NO_TEST_OUTPUT", "")

    for name, val in [("KERNEL", kernel_path), ("INITRAMFS", initramfs),
                      ("DISK", disk), ("CMDLINE_EXTRA", cmdline_extra),
                      ("EXPECT_MARKER", expect_marker)]:
        if not val:
            print(f"ERROR: {name} not set")
            sys.exit(1)

    kernel = find_kernel(kernel_path)
    if not kernel:
        print(f"FAIL: no vmlinuz in {kernel_path}")
        sys.exit(1)

    # Skip if prerequisites missing
    if not shutil.which("qemu-system-x86_64"):
        print("SKIP: qemu-system-x86_64 not found")
        sys.exit(0)
    if not os.access("/dev/kvm", os.R_OK | os.W_OK):
        print("SKIP: /dev/kvm not accessible")
        sys.exit(0)
    if not shutil.which("evmctl"):
        print("SKIP: evmctl not found")
        sys.exit(0)

    # Boot QEMU
    cmd = [
        "qemu-system-x86_64",
        "-kernel", kernel,
        "-initrd", initramfs,
        "-drive", f"file={disk},format=raw,if=virtio,readonly=on",
        "-append", f"console=ttyS0 panic=-1 {cmdline_extra}",
        "-nographic", "-no-reboot", "-m", "256M",
        "-enable-kvm", "-cpu", "host",
    ]

    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        output = r.stdout + r.stderr
    except subprocess.TimeoutExpired:
        output = ""

    print(output)
    print("---")

    failures = 0

    if expect_marker in output:
        print(f"PASS: found '{expect_marker}'")
    else:
        print(f"FAIL: '{expect_marker}' not found")
        failures += 1

    if expect_test_output:
        if expect_test_output in output:
            print(f"PASS: found '{expect_test_output}'")
        else:
            print(f"FAIL: '{expect_test_output}' not found")
            failures += 1

    if expect_no_test_output:
        if expect_no_test_output in output:
            print(f"FAIL: '{expect_no_test_output}' should not appear")
            failures += 1
        else:
            print(f"PASS: '{expect_no_test_output}' correctly absent")

    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
