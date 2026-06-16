#!/usr/bin/env python3
"""Validate that an ostree_commit was ed25519-signed (SPEC-007).

Building the signed fixture runs `ostree sign --sign-type=ed25519`, so its
success already proves our libostree accepts the key format. This test asserts
the signature actually landed: the commit's detached metadata (`.commitmeta`)
exists and carries an `ostree.sign.ed25519` signature.

Env:
    OSTREE_REPO     repo from //tests/fixtures/ostree:demo-commit-signed
    OSTREE_BRANCH   ref (default buckos/demo-signed)
"""

import os
import sys

_HEX = set("0123456789abcdef")


def main():
    repo = os.environ["OSTREE_REPO"]
    branch = os.environ.get("OSTREE_BRANCH", "buckos/demo-signed")

    ref = os.path.join(repo, "refs", "heads", *branch.split("/"))
    with open(ref) as fh:
        checksum = fh.read().strip()
    if len(checksum) != 64 or any(c not in _HEX for c in checksum):
        print("FAIL: bad commit checksum %r" % checksum)
        return 1

    # The ed25519 signature is stored as detached commit metadata.
    meta = os.path.join(repo, "objects", checksum[:2], checksum[2:] + ".commitmeta")
    if not os.path.exists(meta):
        print(
            "FAIL: no detached metadata (.commitmeta) — commit is unsigned: %s" % meta
        )
        return 1

    data = open(meta, "rb").read()
    if b"ostree.sign.ed25519" not in data:
        print("FAIL: .commitmeta carries no ostree.sign.ed25519 signature")
        return 1

    print(
        "ostree signing OK: %s carries an ostree.sign.ed25519 signature "
        "(%d-byte commitmeta)" % (checksum, len(data))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
