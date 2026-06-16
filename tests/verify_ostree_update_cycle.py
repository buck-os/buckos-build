#!/usr/bin/env python3
"""QEMU ostree update-cycle test (SPEC-006 P6).

Boots three pre-built ostree sysroots and asserts the booted version:

    base        deploy A                 -> boots A   (baseline)
    updated     deploy A, then B         -> boots B   (atomic update applied)
    rolledback  deploy A, B, redeploy A  -> boots A   (rollback restores A)

Each sysroot may hold several deployments; the *default* is always the one at
ostree index 0 (`ostree=.../0`), so we boot that deployment's kernel argument.
The deployment's init echoes a marker (CYCLE_BOOT_A / CYCLE_BOOT_B) over the
serial console; we assert the expected marker appears and the other does not.

Self-skips (exit 0) when /dev/kvm is unavailable (e.g. a GitHub-hosted runner).

Env (from buckos_test):
    SYSROOT_BASE / SYSROOT_UPDATED / SYSROOT_ROLLEDBACK  deployed sysroot trees
    KERNEL      kernel image (or dir containing bzImage/vmlinuz)
    INITRAMFS   the dynamic-capable ostree initramfs (.cpio.gz)
    MKE2FS_DIR  e2fsprogs install (provides sbin/mke2fs)
    QEMU_DIR    buckos QEMU package (qemu-system-x86_64 + BIOS ROMs)
    RUN_ENV     runtime-env wrapper so the portabilized QEMU finds its libs
"""

import ctypes
import glob
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading


def _pdeathsig():
    ctypes.CDLL("libc.so.6", use_errno=True).prctl(1, signal.SIGKILL)


def _find(base, names):
    if os.path.isfile(base):
        return base
    for dirpath, _, filenames in os.walk(base):
        for f in sorted(filenames):
            if f in names or any(f.startswith(n) for n in names):
                return os.path.join(dirpath, f)
    return None


def find_kernel(path):
    if os.path.isfile(path):
        return path
    for dirpath, dirnames, filenames in os.walk(path):
        dirnames[:] = [d for d in dirnames if d not in ("modules", "headers")]
        for f in sorted(filenames):
            if f.startswith("vmlinuz") or f in ("bzImage", "bzimage"):
                return os.path.join(dirpath, f)
    return None


def default_karg(sysroot):
    """The `ostree=...` kernel arg of the default deployment (index 0)."""
    for conf in sorted(glob.glob(os.path.join(sysroot, "boot/loader/entries/*.conf"))):
        with open(conf) as fh:
            for line in fh:
                m = re.search(r"ostree=(\S+)", line)
                if m and m.group(1).rstrip("/").endswith("/0"):
                    return "ostree=" + m.group(1)
    return None


def make_disk(sysroot, mke2fs, workdir, name):
    disk = os.path.join(workdir, name + ".ext4")
    with open(disk, "wb") as fh:
        fh.truncate(768 * 1024 * 1024)
    subprocess.run([mke2fs, "-q", "-F", "-t", "ext4", "-d", sysroot, disk], check=True)
    return disk


def boot(qemu_cmd, kernel, initramfs, karg, disk, expect, reject):
    """Boot one disk; return (ok, output)."""
    append = "console=ttyS0 root=/dev/vda %s rw panic=3" % karg
    cmd = qemu_cmd + [
        "-kernel",
        kernel,
        "-initrd",
        initramfs,
        "-append",
        append,
        "-drive",
        "file=%s,if=virtio,format=raw" % disk,
        "-display",
        "none",
        "-serial",
        "stdio",
        "-monitor",
        "none",
        "-no-reboot",
        "-m",
        "1024",
        "-smp",
        "2",
        "-enable-kvm",
        "-cpu",
        "host",
    ]
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        preexec_fn=_pdeathsig,
        start_new_session=True,
    )

    def _kill():
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass

    timer = threading.Timer(120, _kill)
    timer.daemon = True
    timer.start()
    lines = []
    try:
        for line in proc.stdout:
            lines.append(line)
            if expect in line:
                break
    finally:
        timer.cancel()
        _kill()
        proc.wait()
    output = "".join(lines)
    ok = expect in output and reject not in output
    return ok, output


def main():
    if not os.access("/dev/kvm", os.R_OK | os.W_OK):
        print("SKIP: /dev/kvm not accessible")
        return 0

    kernel = find_kernel(os.environ["KERNEL"])
    initramfs = _find(os.environ["INITRAMFS"], ["initramfs"]) or _find(
        os.environ["INITRAMFS"], [".cpio.gz"]
    )
    if not initramfs:
        # fall back: any *.cpio.gz under the dir
        for dp, _, fs in os.walk(os.environ["INITRAMFS"]):
            for f in fs:
                if f.endswith(".cpio.gz"):
                    initramfs = os.path.join(dp, f)
                    break
    mke2fs = _find(os.environ["MKE2FS_DIR"], ["mke2fs"])
    qemu_bin = _find(os.environ["QEMU_DIR"], ["qemu-system-x86_64"])
    bios = _find(os.environ["QEMU_DIR"], ["bios-256k.bin"])
    run_env = os.environ.get("RUN_ENV")

    for label, val in [
        ("kernel", kernel),
        ("initramfs", initramfs),
        ("mke2fs", mke2fs),
        ("qemu", qemu_bin),
        ("bios", bios),
    ]:
        if not val:
            print("FAIL: could not locate %s" % label)
            return 1

    os.chmod(qemu_bin, 0o755)
    qemu_cmd = []
    if run_env:
        os.chmod(run_env, 0o755)
        qemu_cmd.append(run_env)
    qemu_cmd += [qemu_bin, "-L", os.path.dirname(bios)]

    stages = [
        ("base", os.environ["SYSROOT_BASE"], "CYCLE_BOOT_A", "CYCLE_BOOT_B"),
        ("updated", os.environ["SYSROOT_UPDATED"], "CYCLE_BOOT_B", "CYCLE_BOOT_A"),
        (
            "rolledback",
            os.environ["SYSROOT_ROLLEDBACK"],
            "CYCLE_BOOT_A",
            "CYCLE_BOOT_B",
        ),
    ]

    workdir = tempfile.mkdtemp(prefix="ostree-cycle-")
    all_ok = True
    for label, sysroot, expect, reject in stages:
        karg = default_karg(sysroot)
        if not karg:
            print("FAIL[%s]: no default (index 0) deployment karg" % label)
            all_ok = False
            continue
        disk = make_disk(sysroot, mke2fs, workdir, label)
        ok, output = boot(qemu_cmd, kernel, initramfs, karg, disk, expect, reject)
        if ok:
            print("PASS[%s]: booted %s (%s)" % (label, expect, karg))
        else:
            all_ok = False
            print(
                "FAIL[%s]: expected %s (reject %s); karg=%s"
                % (label, expect, reject, karg)
            )
            print("\n".join(output.splitlines()[-25:]))
        os.remove(disk)

    print("---")
    print("ostree update-cycle: %s" % ("OK" if all_ok else "FAILED"))
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
