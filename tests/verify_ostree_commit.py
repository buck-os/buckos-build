#!/usr/bin/env python3
"""Validate an ostree_commit output (SPEC-006 P2).

Building the dep already exercises the rule (it runs the buckos `ostree` CLI
in a buck2 action to commit a tree).  This test asserts the produced repo is
a well-formed, content-addressed archive repo: the ref resolves to a 64-char
checksum and the corresponding commit object exists.

Env:
    OSTREE_REPO   the repo directory produced by //tests/fixtures/ostree:demo-commit
"""

import os
import sys

_HEX = set("0123456789abcdef")


def main():
    repo = os.environ["OSTREE_REPO"]

    ref = os.path.join(repo, "refs", "heads", "buckos", "demo")
    with open(ref) as fh:
        checksum = fh.read().strip()
    if len(checksum) != 64 or any(c not in _HEX for c in checksum):
        print("FAIL: bad commit checksum %r" % checksum)
        return 1

    with open(os.path.join(repo, "config")) as fh:
        config = fh.read()
    if "mode=archive-z2" not in config:
        print("FAIL: unexpected repo config:\n%s" % config)
        return 1

    # Content-addressed layout: objects/<first 2>/<rest>.commit
    obj = os.path.join(repo, "objects", checksum[:2], checksum[2:] + ".commit")
    if not os.path.exists(obj):
        print("FAIL: missing commit object %s" % obj)
        return 1

    print("ostree_commit OK: %s (archive-z2, commit object present)" % checksum)
    return 0


if __name__ == "__main__":
    sys.exit(main())
