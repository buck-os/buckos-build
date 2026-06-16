#!/usr/bin/env python3
"""Validate the ostree_rootfs transform output (SPEC-006 P2).

Asserts a rootfs tree was reshaped into ostree's layout: /etc moved to
/usr/etc, mutable top-level dirs symlinked into /var, /var emptied, and
/sysroot added.

Env:
    OSTREE_ROOTFS  the tree from //tests/fixtures/ostree:mini-ostree-rootfs
"""

import os
import sys


def main():
    root = os.environ["OSTREE_ROOTFS"]
    checks = []

    def chk(desc, cond):
        checks.append((desc, bool(cond)))

    chk("/etc moved away", not os.path.exists(os.path.join(root, "etc")))
    chk(
        "/usr/etc holds the config default",
        os.path.isfile(os.path.join(root, "usr", "etc", "os-config")),
    )
    for name, target in [
        ("home", "var/home"),
        ("opt", "var/opt"),
        ("srv", "var/srv"),
        ("root", "var/roothome"),
    ]:
        p = os.path.join(root, name)
        chk(
            "/%s -> %s" % (name, target), os.path.islink(p) and os.readlink(p) == target
        )

    usrlocal = os.path.join(root, "usr", "local")
    chk(
        "/usr/local -> ../var/usrlocal",
        os.path.islink(usrlocal) and os.readlink(usrlocal) == "../var/usrlocal",
    )

    var = os.path.join(root, "var")
    chk(
        "/var is an empty dir",
        os.path.isdir(var) and not os.path.islink(var) and not os.listdir(var),
    )
    chk("/sysroot present", os.path.isdir(os.path.join(root, "sysroot")))

    # When a trusted key was baked in (SPEC-007 §5.3), assert it landed under
    # /usr/etc/ostree (the deployed /etc default) and matches the release key.
    keyfile = os.environ.get("OSTREE_EXPECT_KEY_FILE")
    if keyfile:
        baked = os.path.join(root, "usr", "etc", "ostree", "buckos.ed25519.pub")
        chk("trusted key baked at /usr/etc/ostree", os.path.isfile(baked))
        chk(
            "trusted key matches the release pubkey",
            os.path.isfile(baked)
            and open(baked).read().strip() == open(keyfile).read().strip(),
        )

    ok = all(v for _, v in checks)
    for desc, value in checks:
        print(("ok   " if value else "FAIL ") + desc)
    print("ostree_rootfs layout: %s" % ("OK" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
