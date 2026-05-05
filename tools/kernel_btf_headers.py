#!/usr/bin/env python3
"""Generate vmlinux.h from kernel BTF data for BPF CO-RE programs.

Runs: bpftool btf dump file <vmlinux> format c > vmlinux.h

Validates that vmlinux has BTF data before extraction.  Fails loud
if BTF is missing (CONFIG_DEBUG_INFO_BTF=y is required).
"""

import argparse
import os
import subprocess
import sys

from _env import sanitize_global_env


def main():
    parser = argparse.ArgumentParser(description="Generate vmlinux.h from BTF")
    parser.add_argument("--vmlinux", required=True,
                        help="Path to vmlinux ELF (must have BTF data)")
    parser.add_argument("--output", required=True,
                        help="Output path for vmlinux.h")
    parser.add_argument("--bpftool", default="bpftool",
                        help="Path to bpftool binary (default: bpftool from PATH)")
    args = parser.parse_args()

    sanitize_global_env()

    vmlinux = os.path.abspath(args.vmlinux)
    output = os.path.abspath(args.output)

    if not os.path.isfile(vmlinux):
        print(f"error: vmlinux not found: {vmlinux}", file=sys.stderr)
        sys.exit(1)

    # Validate BTF data exists in vmlinux
    _validate_btf(vmlinux)

    # Generate vmlinux.h
    print(f"Generating vmlinux.h from {vmlinux}")
    cmd = [args.bpftool, "btf", "dump", "file", vmlinux, "format", "c"]
    print(f"  + {' '.join(cmd)}")

    os.makedirs(os.path.dirname(output), exist_ok=True)
    with open(output, "w") as outf:
        result = subprocess.run(cmd, stdout=outf, stderr=subprocess.PIPE, text=True)

    if result.returncode != 0:
        print(f"error: bpftool failed: {result.stderr}", file=sys.stderr)
        os.unlink(output)
        sys.exit(1)

    # Sanity check: vmlinux.h should be non-trivial
    size = os.path.getsize(output)
    if size < 1024:
        print(f"error: vmlinux.h is suspiciously small ({size} bytes)", file=sys.stderr)
        sys.exit(1)

    print(f"vmlinux.h generated: {output} ({size} bytes)")


def _validate_btf(vmlinux):
    """Check that vmlinux has a .BTF section."""
    try:
        result = subprocess.run(
            ["readelf", "-S", vmlinux],
            capture_output=True, text=True, timeout=30,
        )
        if ".BTF" not in result.stdout:
            print(
                "error: vmlinux has no .BTF section. "
                "The kernel must be built with CONFIG_DEBUG_INFO_BTF=y. "
                "Add this to your sched-ext.config or buckos-base.config fragment.",
                file=sys.stderr,
            )
            sys.exit(1)
        print("  BTF data present in vmlinux")
    except FileNotFoundError:
        print("warning: readelf not found, skipping BTF validation", file=sys.stderr)
    except subprocess.TimeoutExpired:
        print("warning: readelf timed out, skipping BTF validation", file=sys.stderr)


if __name__ == "__main__":
    main()
