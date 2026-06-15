#!/usr/bin/env python3
"""Validate an ostree_sysroot deployment (SPEC-006 P3).

Building the dep already exercises the rule (it runs `ostree admin deploy` in
a user namespace).  This asserts the produced sysroot is bootable-shaped: the
/ostree repo + a checked-out deployment, and a BLS loader entry carrying the
ostree= kernel argument plus a staged kernel.

Env:
    OSTREE_SYSROOT  the sysroot from //tests/fixtures/ostree:mini-sysroot
"""

import glob
import os
import sys


def main():
    sr = os.environ["OSTREE_SYSROOT"]
    checks = []

    def chk(desc, cond):
        checks.append((desc, bool(cond)))

    chk("/ostree/repo present", os.path.isdir(os.path.join(sr, "ostree", "repo")))

    deploys = glob.glob(os.path.join(sr, "ostree", "deploy", "*", "deploy", "*.0"))
    chk("a deployment is checked out", len(deploys) >= 1)
    if deploys:
        chk("deployment has /usr", os.path.isdir(os.path.join(deploys[0], "usr")))

    entries = glob.glob(os.path.join(sr, "boot", "loader*", "entries", "*.conf"))
    chk("a BLS loader entry exists", len(entries) >= 1)
    has_ostree_karg = any("ostree=" in open(e).read() for e in entries)
    chk("BLS entry carries the ostree= kernel arg", has_ostree_karg)

    vmlinuz = glob.glob(os.path.join(sr, "boot", "ostree", "*", "vmlinuz*"))
    chk("kernel staged in /boot", len(vmlinuz) >= 1)

    ok = all(v for _, v in checks)
    for desc, value in checks:
        print(("ok   " if value else "FAIL ") + desc)
    print("ostree_sysroot deploy: %s" % ("OK" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
