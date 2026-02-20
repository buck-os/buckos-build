#!/usr/bin/env python3
"""Cloud Hypervisor IMA test: boot CH with IMA test binary, check output.

Boots cloud-hypervisor with the IMA init (custom PID-1), an ext4 disk
containing the test binary (signed or unsigned), and verifies serial
output markers.

Env vars from sh_test:
    CH_BINARY          — path to cloud-hypervisor build output
    KERNEL             — path to CH kernel build output
    INITRAMFS          — path to IMA initramfs (with init + cert)
    DISK               — path to ext4 disk image (with test binary)
    CMDLINE_EXTRA      — IMA cmdline args (ima_appraise=... ima_test_mode=...)
    EXPECT_MARKER      — string that must appear in output
    EXPECT_TEST_OUTPUT — string that must appear (optional)
    EXPECT_NO_TEST_OUTPUT — string that must NOT appear (optional)
"""

import multiprocessing
import os
import selectors
import signal
import subprocess
import sys
import time


def find_file(base, patterns):
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
    disk = os.environ.get("DISK", "")
    cmdline_extra = os.environ.get("CMDLINE_EXTRA", "")
    expect_marker = os.environ.get("EXPECT_MARKER", "")
    expect_test_output = os.environ.get("EXPECT_TEST_OUTPUT", "")
    expect_no_test_output = os.environ.get("EXPECT_NO_TEST_OUTPUT", "")

    for name, val in [("CH_BINARY", ch_output), ("KERNEL", kernel_output),
                      ("INITRAMFS", initramfs_output), ("DISK", disk),
                      ("CMDLINE_EXTRA", cmdline_extra),
                      ("EXPECT_MARKER", expect_marker)]:
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
        # initramfs might be the file itself
        if os.path.isfile(initramfs_output):
            initramfs_bin = initramfs_output
        else:
            print(f"FAIL: initramfs not found in {initramfs_output}")
            sys.exit(1)

    if not os.path.isfile(disk):
        print(f"FAIL: disk image not found: {disk}")
        sys.exit(1)

    # Size VM conservatively
    host_cpus = min(multiprocessing.cpu_count(), 4)
    vm_mem_mb = 256

    cmd = [
        ch_bin,
        "--kernel", kernel_bin,
        "--initramfs", initramfs_bin,
        "--disk", f"path={disk},readonly=on",
        "--cmdline", f"console=ttyS0 panic=-1 {cmdline_extra}",
        "--cpus", f"boot={host_cpus}",
        "--memory", f"size={vm_mem_mb}M",
        "--serial", "tty",
        "--console", "off",
    ]

    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    output = ""
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
                # Check for our marker — can stop early
                if expect_marker in output:
                    break
            if expect_marker in output or proc.poll() is not None:
                break

        sel.close()
    finally:
        if proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()

    stderr = proc.stderr.read() if proc.stderr else ""
    print(output[-3000:] if len(output) > 3000 else output)
    print("---")

    failures = 0

    if expect_marker in output:
        print(f"PASS: found '{expect_marker}'")
    else:
        print(f"FAIL: '{expect_marker}' not found")
        if stderr:
            print(f"stderr (last 500): {stderr[-500:]}")
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
