#!/usr/bin/env python3
"""Cloud Hypervisor VM boot integration test.

Boots a VM using cloud-hypervisor with a kernel and initramfs,
verifies the kernel boots by checking serial output for a boot marker.

Env vars from sh_test:
    CH_BINARY      — path to cloud-hypervisor build output (dir or binary)
    KERNEL         — path to kernel build output (dir with vmlinuz* or file)
    INITRAMFS      — path to initramfs build output (dir with *.cpio.gz or file)
"""

import ctypes
import multiprocessing
import os
import platform
import re
import selectors
import signal
import subprocess
import sys
import time


def _pdeathsig():
    """Ensure VM process is killed when test runner exits."""
    ctypes.CDLL("libc.so.6", use_errno=True).prctl(1, signal.SIGKILL)

_CLEAR_RE = re.compile(r"\x1bc|\x1b\[[0-9]*[JH]|\x1b\[\?[0-9;]*[hl]")


def find_file(base, patterns):
    """Find a file matching any pattern under base, or return base if it's a file."""
    if os.path.isfile(base):
        return base
    if os.path.isdir(base):
        import glob as g
        for pat in patterns:
            matches = g.glob(os.path.join(base, "**", pat), recursive=True)
            if matches:
                return matches[0]
    return None


def main():
    ch_output = os.environ.get("CH_BINARY", "")
    kernel_output = os.environ.get("KERNEL", "")
    initramfs_output = os.environ.get("INITRAMFS", "")

    for name, val in [("CH_BINARY", ch_output), ("KERNEL", kernel_output),
                      ("INITRAMFS", initramfs_output)]:
        if not val:
            print(f"ERROR: {name} not set")
            sys.exit(1)

    # Skip if KVM unavailable
    if not os.access("/dev/kvm", os.R_OK | os.W_OK):
        print("SKIP: /dev/kvm not accessible")
        sys.exit(0)

    # Resolve artifacts
    ch_bin = find_file(ch_output, ["cloud-hypervisor"])
    if not ch_bin:
        print(f"FAIL: cloud-hypervisor binary not found in {ch_output}")
        sys.exit(1)
    os.chmod(ch_bin, 0o755)

    kernel_bin = find_file(kernel_output, ["vmlinuz*", "bzImage"])
    if not kernel_bin:
        print(f"FAIL: kernel not found in {kernel_output}")
        sys.exit(1)

    initramfs_bin = find_file(initramfs_output, ["*.cpio.gz", "initramfs*"])
    if not initramfs_bin:
        print(f"FAIL: initramfs not found in {initramfs_output}")
        sys.exit(1)

    # Size VM
    host_cpus = min(multiprocessing.cpu_count(), 16)
    host_mem_kb = 0
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("MemTotal:"):
                host_mem_kb = int(line.split()[1])
                break
    vm_mem_mb = min(max(256, int(host_mem_kb * 0.9 / 1024)), 4096)

    cmd = [
        ch_bin,
        "--kernel", kernel_bin,
        "--initramfs", initramfs_bin,
        "--cmdline", "console={} init=/init panic=-1".format(
            "ttyAMA0" if platform.machine() == "aarch64" else "ttyS0"),
        "--cpus", f"boot={host_cpus}",
        "--memory", f"size={vm_mem_mb}M",
        "--serial", "tty",
        "--console", "off",
    ]

    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                            preexec_fn=_pdeathsig, start_new_session=True)

    output = ""
    boot_string = "Run /init as init process"

    try:
        sel = selectors.DefaultSelector()
        sel.register(proc.stdout, selectors.EVENT_READ)
        deadline = 60
        start = time.monotonic()

        while time.monotonic() - start < deadline:
            events = sel.select(timeout=max(0.1, deadline - (time.monotonic() - start)))
            for key, _ in events:
                line = key.fileobj.readline()
                if not line:
                    break
                output += line
                if boot_string in line:
                    break
            if boot_string in output or proc.poll() is not None:
                break

        sel.close()
    finally:
        if proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
                proc.wait()

    stderr = proc.stderr.read() if proc.stderr else ""

    output = _CLEAR_RE.sub("", output)

    if boot_string in output:
        tail = "\n".join(output.splitlines()[-10:])
        print(tail)
        print("---")
        print(f"PASS: found '{boot_string}' in VM output")
        sys.exit(0)
    else:
        print(output)
        if stderr:
            print(f"stderr (last 500): {stderr[-500:]}")
        print("---")
        print(f"FAIL: '{boot_string}' not found in VM output")
        sys.exit(1)


if __name__ == "__main__":
    main()
