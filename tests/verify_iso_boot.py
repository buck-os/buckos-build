#!/usr/bin/env python3
"""QEMU ISO boot test.

Boots the buckos-iso in QEMU via -cdrom and checks serial output
for the kernel init marker.

Env vars from sh_test:
    ISO       — path to .iso file
    QEMU_DIR  — path to buckos-built QEMU package (contains qemu-system-x86_64)
"""

import os
import subprocess
import sys


def find_file(base, name):
    """Find a named file under base, or return base if it's a file."""
    if os.path.isfile(base):
        return base
    for dirpath, _, filenames in os.walk(base):
        if name in filenames:
            return os.path.join(dirpath, name)
    return None


def main():
    iso = os.environ.get("ISO", "")
    qemu_dir = os.environ.get("QEMU_DIR", "")

    for name, val in [("ISO", iso), ("QEMU_DIR", qemu_dir)]:
        if not val:
            print(f"ERROR: {name} not set")
            sys.exit(1)

    # KVM is required — fail, don't skip
    if not os.access("/dev/kvm", os.R_OK | os.W_OK):
        print("FAIL: /dev/kvm not accessible")
        sys.exit(1)

    # Resolve ISO
    iso_file = find_file(iso, "buckos.iso")
    if not iso_file:
        # Fall back to any .iso
        for dirpath, _, filenames in os.walk(iso):
            for f in filenames:
                if f.endswith(".iso"):
                    iso_file = os.path.join(dirpath, f)
                    break
            if iso_file:
                break
    if not iso_file:
        if os.path.isfile(iso):
            iso_file = iso
        else:
            print(f"FAIL: no .iso found in {iso}")
            sys.exit(1)

    # Resolve QEMU binary
    qemu_bin = find_file(qemu_dir, "qemu-system-x86_64")
    if not qemu_bin:
        print(f"FAIL: qemu-system-x86_64 not found in {qemu_dir}")
        sys.exit(1)
    os.chmod(qemu_bin, 0o755)

    cmd = [
        qemu_bin,
        "-cdrom", iso_file,
        "-nographic", "-no-reboot", "-m", "512M",
        "-enable-kvm", "-cpu", "host",
        "-boot", "d",
    ]

    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        output = r.stdout + r.stderr
    except subprocess.TimeoutExpired:
        output = ""

    boot_marker = "Run /init as init process"

    print(output[-3000:] if len(output) > 3000 else output)
    print("---")

    if boot_marker in output:
        print(f"PASS: found '{boot_marker}'")
        sys.exit(0)
    else:
        print(f"FAIL: '{boot_marker}' not found in output")
        sys.exit(1)


if __name__ == "__main__":
    main()
