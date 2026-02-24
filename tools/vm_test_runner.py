#!/usr/bin/env python3
"""Boot QEMU with a kernel + rootfs, run a test script, check for success.

Builds an initramfs from the rootfs directory (injecting any extra files and
the guest test script), boots QEMU via KVM, captures serial output, and
checks for a success marker string within the timeout.  Exits 0 on pass,
1 on fail.
"""

import argparse
import gzip
import os
import shutil
import signal
import subprocess
import sys
import tempfile

from _env import sanitize_global_env


def parse_inject(value):
    """Parse an --inject SRC:DEST argument."""
    if ":" not in value:
        raise argparse.ArgumentTypeError(
            f"inject must be SRC:DEST, got: {value}"
        )
    src, dest = value.split(":", 1)
    return (src, dest)


def build_init_script():
    """Return a minimal /init shell script that mounts essential filesystems
    and runs /test.sh."""
    return """\
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
exec /bin/sh /test.sh
poweroff -f
"""


def build_initramfs(rootfs_dir, guest_script, inject_files, output_path):
    """Build a cpio.gz initramfs from rootfs_dir with injected files.

    Steps:
      1. Copy rootfs_dir to a temp staging directory.
      2. Inject --inject SRC:DEST files into the staging dir.
      3. Copy the guest script as /test.sh.
      4. Create /init wrapper that mounts proc/sys/dev and runs /test.sh.
      5. Build cpio.gz from the staging dir.
    """
    staging = tempfile.mkdtemp(prefix="vm_test_initramfs_")
    try:
        # 1. Copy rootfs
        if os.path.isdir(rootfs_dir):
            # Use cp -a to preserve permissions and symlinks
            subprocess.check_call(
                ["cp", "-a", "--", rootfs_dir + "/.", staging],
            )

        # Ensure essential directories exist
        for d in ("bin", "sbin", "proc", "sys", "dev", "tmp", "etc"):
            os.makedirs(os.path.join(staging, d), exist_ok=True)

        # 2. Inject extra files
        for src, dest in inject_files:
            dest_path = os.path.join(staging, dest.lstrip("/"))
            os.makedirs(os.path.dirname(dest_path), exist_ok=True)
            shutil.copy2(src, dest_path)
            # Ensure binaries are executable
            os.chmod(dest_path, 0o755)

        # 3. Copy guest script as /test.sh
        test_sh = os.path.join(staging, "test.sh")
        shutil.copy2(guest_script, test_sh)
        os.chmod(test_sh, 0o755)

        # 4. Create /init wrapper
        init_path = os.path.join(staging, "init")
        with open(init_path, "w") as f:
            f.write(build_init_script())
        os.chmod(init_path, 0o755)

        # 5. Build cpio.gz
        find_proc = subprocess.Popen(
            ["find", ".", "-print0"],
            cwd=staging,
            stdout=subprocess.PIPE,
        )
        cpio_proc = subprocess.Popen(
            ["cpio", "--null", "-o", "-H", "newc", "--quiet"],
            cwd=staging,
            stdin=find_proc.stdout,
            stdout=subprocess.PIPE,
        )
        find_proc.stdout.close()

        cpio_data, _ = cpio_proc.communicate()
        find_proc.wait()

        if find_proc.returncode != 0:
            print(f"error: find exited with code {find_proc.returncode}", file=sys.stderr)
            sys.exit(1)
        if cpio_proc.returncode != 0:
            print(f"error: cpio exited with code {cpio_proc.returncode}", file=sys.stderr)
            sys.exit(1)

        os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
        with gzip.open(output_path, "wb") as f:
            f.write(cpio_data)

    finally:
        shutil.rmtree(staging, ignore_errors=True)


def kvm_available():
    """Check whether /dev/kvm exists and is accessible."""
    return os.access("/dev/kvm", os.R_OK | os.W_OK)


def run_qemu(kernel, initramfs, timeout, memory, cpus, success_marker):
    """Boot QEMU, capture serial output, check for success marker."""
    qemu_cmd = [
        "qemu-system-x86_64",
        "-nographic",
        "-serial", "stdio",
        "-m", str(memory),
        "-smp", str(cpus),
        "-kernel", kernel,
        "-initrd", initramfs,
        "-append", "console=ttyS0",
        "-no-reboot",
    ]

    if kvm_available():
        qemu_cmd.insert(1, "-enable-kvm")
    else:
        print("warning: KVM not available, using -cpu max (slow)", file=sys.stderr)
        qemu_cmd.extend(["-cpu", "max"])

    proc = subprocess.Popen(
        qemu_cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )

    output_lines = []
    found = False

    def alarm_handler(_signum, _frame):
        raise TimeoutError

    # Use SIGALRM for the timeout — simpler than threading and works on
    # Linux which is the only platform this runs on.
    old_handler = signal.signal(signal.SIGALRM, alarm_handler)
    signal.alarm(timeout)

    try:
        for raw_line in proc.stdout:
            line = raw_line.decode("utf-8", errors="replace")
            output_lines.append(line)
            if success_marker in line:
                found = True
                break
    except TimeoutError:
        pass
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old_handler)
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()

    return found, output_lines


def main():
    parser = argparse.ArgumentParser(
        description="Boot QEMU with a kernel + rootfs, run a test, check output",
    )
    parser.add_argument("--kernel", required=True, help="Path to kernel image (bzImage)")
    parser.add_argument("--rootfs", required=True, help="Path to rootfs directory")
    parser.add_argument("--guest-script", required=True, help="Path to guest test script")
    parser.add_argument("--timeout", type=int, default=60, help="Timeout in seconds (default: 60)")
    parser.add_argument("--memory", type=int, default=512, help="VM memory in MB (default: 512)")
    parser.add_argument("--cpus", type=int, default=2, help="VM CPU count (default: 2)")
    parser.add_argument("--success-marker", default="VM_TEST_PASSED",
                        help="String to search for in serial output (default: VM_TEST_PASSED)")
    parser.add_argument("--inject", action="append", type=parse_inject, default=[],
                        help="Inject file into initramfs as SRC:DEST (repeatable)")
    args = parser.parse_args()
    sanitize_global_env()

    # Validate inputs
    if not os.path.isfile(args.kernel):
        print(f"error: kernel not found: {args.kernel}", file=sys.stderr)
        sys.exit(1)
    if not os.path.isdir(args.rootfs):
        print(f"error: rootfs directory not found: {args.rootfs}", file=sys.stderr)
        sys.exit(1)
    if not os.path.isfile(args.guest_script):
        print(f"error: guest script not found: {args.guest_script}", file=sys.stderr)
        sys.exit(1)
    for src, _dest in args.inject:
        if not os.path.exists(src):
            print(f"error: inject source not found: {src}", file=sys.stderr)
            sys.exit(1)

    # Build initramfs
    initramfs_path = tempfile.mktemp(suffix=".cpio.gz", prefix="vm_test_")
    try:
        build_initramfs(
            rootfs_dir=args.rootfs,
            guest_script=args.guest_script,
            inject_files=args.inject,
            output_path=initramfs_path,
        )

        # Boot QEMU and check
        found, output = run_qemu(
            kernel=args.kernel,
            initramfs=initramfs_path,
            timeout=args.timeout,
            memory=args.memory,
            cpus=args.cpus,
            success_marker=args.success_marker,
        )

        if found:
            print(f"PASS: found '{args.success_marker}' in VM output")
            sys.exit(0)
        else:
            print(f"FAIL: '{args.success_marker}' not found within {args.timeout}s",
                  file=sys.stderr)
            print("--- VM output ---", file=sys.stderr)
            for line in output:
                print(line, end="", file=sys.stderr)
            print("--- end VM output ---", file=sys.stderr)
            sys.exit(1)
    finally:
        if os.path.exists(initramfs_path):
            os.unlink(initramfs_path)


if __name__ == "__main__":
    main()
