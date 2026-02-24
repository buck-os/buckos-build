#!/usr/bin/env python3
"""QEMU ISO boot test.

Extracts kernel and initramfs from the ISO, then boots them directly
with -kernel/-initrd/-append so we can inject console=ttyS0 for serial
output capture.

Env vars from sh_test:
    ISO       — path to .iso file or directory containing it
    QEMU_DIR  — path to buckos-built QEMU package (contains qemu-system-x86_64)
    RUN_ENV   — optional path to runtime env wrapper (sets LD_LIBRARY_PATH)
"""

import os
import subprocess
import sys
import tempfile


def find_file(base, name):
    """Find a named file under base, or return base if it's a file."""
    if os.path.isfile(base):
        return base
    for dirpath, _, filenames in os.walk(base):
        if name in filenames:
            return os.path.join(dirpath, name)
    return None


def extract_from_iso(iso_file, tmpdir):
    """Mount ISO and copy kernel + initramfs to tmpdir."""
    mnt = os.path.join(tmpdir, "mnt")
    os.makedirs(mnt, exist_ok=True)

    # Try mount (needs privileges) then fall back to xorriso/7z
    r = subprocess.run(
        ["mount", "-o", "loop,ro", iso_file, mnt],
        capture_output=True,
    )
    if r.returncode != 0:
        # Try xorriso extraction
        r2 = subprocess.run(
            ["xorriso", "-osirrox", "on", "-indev", iso_file,
             "-extract", "/boot", os.path.join(tmpdir, "boot")],
            capture_output=True,
        )
        if r2.returncode != 0:
            return None, None
        vmlinuz = os.path.join(tmpdir, "boot", "vmlinuz")
        initramfs = os.path.join(tmpdir, "boot", "initramfs.img")
        if os.path.isfile(vmlinuz) and os.path.isfile(initramfs):
            return vmlinuz, initramfs
        return None, None

    # Copy from mount
    vmlinuz_src = os.path.join(mnt, "boot", "vmlinuz")
    initramfs_src = os.path.join(mnt, "boot", "initramfs.img")
    vmlinuz = initramfs = None

    if os.path.isfile(vmlinuz_src) and os.path.isfile(initramfs_src):
        vmlinuz = os.path.join(tmpdir, "vmlinuz")
        initramfs = os.path.join(tmpdir, "initramfs.img")
        subprocess.run(["cp", vmlinuz_src, vmlinuz], check=True)
        subprocess.run(["cp", initramfs_src, initramfs], check=True)

    subprocess.run(["umount", mnt], capture_output=True)
    return vmlinuz, initramfs


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

    # Extract kernel + initramfs so we can inject console=ttyS0
    with tempfile.TemporaryDirectory() as tmpdir:
        vmlinuz, initramfs = extract_from_iso(iso_file, tmpdir)
        if not vmlinuz or not initramfs:
            print(f"FAIL: could not extract kernel/initramfs from {iso_file}")
            sys.exit(1)

        cmd = [
            qemu_bin,
            "-kernel", vmlinuz,
            "-initrd", initramfs,
            "-append", "console=ttyS0 rdinit=/init panic=1",
            "-cdrom", iso_file,
            "-nographic", "-no-reboot", "-m", "2G",
            "-enable-kvm", "-cpu", "host",
        ]

        # Prepend the runtime environment wrapper so QEMU finds its shared libs
        run_env = os.environ.get("RUN_ENV")
        if run_env:
            os.chmod(run_env, 0o755)
            cmd = [run_env] + cmd

        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
            output = r.stdout + r.stderr
        except subprocess.TimeoutExpired as e:
            # stdout/stderr may be bytes despite text=True
            def _decode(b):
                if b is None:
                    return ""
                return b.decode("utf-8", errors="replace") if isinstance(b, bytes) else b
            output = _decode(e.stdout) + _decode(e.stderr)

    kernel_marker = "Run /init as init process"
    shell_marker = "System initialization complete."

    print(output[-3000:] if len(output) > 3000 else output)
    print("---")

    ok = True
    for label, marker in [("kernel", kernel_marker), ("shell", shell_marker)]:
        if marker in output:
            print(f"PASS: {label}: found '{marker}'")
        else:
            print(f"FAIL: {label}: '{marker}' not found in output")
            ok = False

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
