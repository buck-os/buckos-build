#!/usr/bin/env python3
"""Validate the kernel was Secure-Boot-signed (SPEC-007 Tier 2).

Building //tests/fixtures/secureboot:signed-kernel runs osslsigncode sign + a
self-verify against the db cert, so a successful build already proves the
signature is valid. This test additionally asserts the signed image is a PE and
is larger than the unsigned kernel (an Authenticode certificate table was
appended).

Env:
    SIGNED      the signed kernel (//tests/fixtures/secureboot:signed-kernel)
    UNSIGNED    the unsigned kernel (//packages/linux/kernel/buckos-kernel:buckos-kernel-live)
"""

import os
import sys


def _is_pe(path):
    with open(path, "rb") as fh:
        return fh.read(2) == b"MZ"


def main():
    signed = os.environ["SIGNED"]
    unsigned = os.environ["UNSIGNED"]
    if not _is_pe(signed):
        print("FAIL: signed image is not a PE")
        return 1
    if not _is_pe(unsigned):
        print("FAIL: unsigned kernel is not a PE")
        return 1
    s_sz = os.path.getsize(signed)
    u_sz = os.path.getsize(unsigned)
    if s_sz <= u_sz:
        print(
            "FAIL: signed (%d) not larger than unsigned (%d) — no signature appended"
            % (s_sz, u_sz)
        )
        return 1
    print(
        "Secure Boot signing OK: signed PE %d bytes (+%d over unsigned)"
        % (s_sz, s_sz - u_sz)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
