#!/usr/bin/env python3
"""Assert ed25519 signature verification behaves correctly (SPEC-007 S3).

//tests/fixtures/ostree:demo-commit-verify runs `ostree sign --verify` with the
signer's key (must pass) and a wrong key (must be rejected), failing the build
on any violation. This test asserts its recorded verdict so the check is
visible as a test result too.

Env:
    VERIFY_RESULT   the verdict file produced by demo-commit-verify
"""

import os
import sys


def main():
    verdict = open(os.environ["VERIFY_RESULT"]).read().strip()
    if not verdict.startswith("VERIFY_OK"):
        print("FAIL: %s" % verdict)
        return 1
    print("ostree verify OK: %s" % verdict)
    return 0


if __name__ == "__main__":
    sys.exit(main())
