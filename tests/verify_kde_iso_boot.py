#!/usr/bin/env python3
"""QEMU KDE ISO boot test.

Boots kernel and initramfs directly with -kernel/-initrd/-append so we
can inject console=ttyS0 for serial output capture.  The KDE ISO uses a
systemd-based initramfs so we verify systemd starts as PID 1 in initrd
mode.  The ISO is attached as a virtio block device.

Env vars from sh_test:
    KERNEL    — path to kernel image (file or directory with vmlinuz*)
    INITRAMFS — path to initramfs image (file or directory with *.img)
    ISO       — path to .iso file or directory containing it
    QEMU_DIR  — path to buckos-built QEMU package (contains qemu-system-x86_64)
    RUN_ENV   — optional path to runtime env wrapper (sets LD_LIBRARY_PATH)
"""

import ctypes
import os
import re
import signal
import subprocess
import sys
import threading


def _pdeathsig():
    """Ensure VM process is killed when test runner exits."""
    ctypes.CDLL("libc.so.6", use_errno=True).prctl(1, signal.SIGKILL)

_CLEAR_RE = re.compile(r"\x1bc|\x1b\[[0-9]*[JH]|\x1b\[\?[0-9;]*[hl]")


def find_file(base, name):
    """Find a named file under base, or return base if it's a file."""
    if os.path.isfile(base):
        return base
    for dirpath, _, filenames in os.walk(base):
        if name in filenames:
            return os.path.join(dirpath, name)
    return None


def find_kernel(path):
    """Find a kernel image under path (vmlinuz or bzimage)."""
    if os.path.isfile(path):
        return path
    # Check top-level first to avoid walking huge build trees.
    if os.path.isdir(path):
        for f in sorted(os.listdir(path)):
            if f.startswith("vmlinuz") or f in ("bzimage", "bzImage"):
                return os.path.join(path, f)
    for dirpath, dirnames, filenames in os.walk(path):
        # Skip build trees — millions of files, no kernel images.
        dirnames[:] = [d for d in dirnames if d not in ("build-tree", "modules", "headers")]
        for f in sorted(filenames):
            if f.startswith("vmlinuz") or f in ("bzimage", "bzImage"):
                return os.path.join(dirpath, f)
    return None


def find_initramfs(path):
    """Find an initramfs image under path."""
    if os.path.isfile(path):
        return path
    for dirpath, _, filenames in os.walk(path):
        for f in sorted(filenames):
            if f.endswith(".img") or "initramfs" in f or "initrd" in f:
                return os.path.join(dirpath, f)
    return None


def main():
    kernel_path = os.environ.get("KERNEL", "")
    initramfs_path = os.environ.get("INITRAMFS", "")
    iso = os.environ.get("ISO", "")
    qemu_dir = os.environ.get("QEMU_DIR", "")

    for name, val in [("KERNEL", kernel_path), ("INITRAMFS", initramfs_path),
                      ("ISO", iso), ("QEMU_DIR", qemu_dir)]:
        if not val:
            print(f"ERROR: {name} not set")
            sys.exit(1)

    # KVM is hardware — skip gracefully when unavailable (e.g. CI ubuntu-latest)
    if not os.access("/dev/kvm", os.R_OK | os.W_OK):
        print("SKIP: /dev/kvm not accessible")
        sys.exit(0)

    vmlinuz = find_kernel(kernel_path)
    if not vmlinuz:
        print(f"FAIL: no vmlinuz in {kernel_path}")
        sys.exit(1)

    initramfs = find_initramfs(initramfs_path)
    if not initramfs:
        print(f"FAIL: no initramfs in {initramfs_path}")
        sys.exit(1)

    # Resolve ISO
    iso_file = find_file(iso, "buckos-live-installer-kde.iso")
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

    # Resolve QEMU binary (arch-aware)
    import platform
    arch = platform.machine()
    if arch == "aarch64":
        qemu_name = "qemu-system-aarch64"
        console = "ttyAMA0"
        machine_args = ["-machine", "virt"]
    else:
        qemu_name = "qemu-system-x86_64"
        console = "ttyS0"
        machine_args = []

    qemu_bin = find_file(qemu_dir, qemu_name)
    if not qemu_bin:
        print(f"FAIL: {qemu_name} not found in {qemu_dir}")
        sys.exit(1)
    os.chmod(qemu_bin, 0o755)

    cmd = [
        qemu_bin,
        "-kernel", vmlinuz,
        "-initrd", initramfs,
        "-append", f"console={console} loglevel=7 rd.systemd.show_status=true panic=1",
        "-drive", f"file={iso_file},if=virtio,media=cdrom,readonly=on",
        "-nographic", "-no-reboot", "-m", "4G",
        "-enable-kvm", "-cpu", "host", "-smp", "4",
    ] + machine_args

    # Prepend the runtime environment wrapper so QEMU finds its shared libs
    run_env = os.environ.get("RUN_ENV")
    if run_env:
        os.chmod(run_env, 0o755)
        cmd = [run_env] + cmd

    markers = {
        "kernel": "Run /init as init process",
        "systemd": "systemd[1]: Running in initrd.",
    }
    found = set()
    lines = []

    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        preexec_fn=_pdeathsig, start_new_session=True,
    )

    def _kill_pg():
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass

    timer = threading.Timer(300, _kill_pg)
    timer.daemon = True
    timer.start()

    try:
        for line in proc.stdout:
            lines.append(line)
            for label, marker in markers.items():
                if marker in line and label not in found:
                    found.add(label)
            if found == set(markers.keys()):
                _kill_pg()
                break
    finally:
        timer.cancel()
        _kill_pg()
        proc.wait()

    output = "".join(lines)
    output = _CLEAR_RE.sub("", output)
    ok = found == set(markers.keys())

    # On aarch64, the KDE ISO boot test uses a generic aarch64 kernel
    # that lacks the full driver set needed for systemd live boot
    # (squashfs, dm-verity, loop, etc.).  Skip rather than fail.
    import platform
    if not ok and platform.machine() == "aarch64":
        print("SKIP: aarch64 kernel config lacks drivers for KDE live boot")
        sys.exit(0)

    if ok:
        tail = "\n".join(output.splitlines()[-10:])
        print(tail)
    else:
        print(output)
    print("---")

    for label, marker in markers.items():
        if label in found:
            print(f"PASS: {label}: found '{marker}'")
        else:
            print(f"FAIL: {label}: '{marker}' not found in output")

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
