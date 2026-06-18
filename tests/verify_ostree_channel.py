#!/usr/bin/env python3
"""Validate an ostree_channel repo (SPEC-006 P5).

A published channel must be a discoverable, HTTP-servable, signed repo. This
asserts the four things a client needs to pull+verify a release over plain HTTP:

  1. a per-channel ref  buckos/<arch>/<channel>  -> a valid commit checksum
  2. the commit is ed25519-signed (detached .commitmeta)
  3. a repo summary exists (clients resolve refs from it over static HTTP)
  4. the summary is ed25519-signed (detached summary.sig)

Env:
    OSTREE_REPO     repo from //tests/fixtures/ostree:demo-channel
    OSTREE_BRANCH   channel ref (default buckos/x86_64/stable)
"""

import os
import sys

_HEX = set("0123456789abcdef")


def main():
    repo = os.environ["OSTREE_REPO"]
    branch = os.environ.get("OSTREE_BRANCH", "buckos/x86_64/stable")
    checks = []

    def chk(desc, cond):
        checks.append((desc, bool(cond)))
        return bool(cond)

    # 1. the channel ref resolves to a valid commit checksum
    ref = os.path.join(repo, "refs", "heads", *branch.split("/"))
    checksum = ""
    if chk("channel ref %s present" % branch, os.path.isfile(ref)):
        checksum = open(ref).read().strip()
    chk(
        "ref points at a valid commit",
        len(checksum) == 64 and all(c in _HEX for c in checksum),
    )

    # 2. the commit is ed25519-signed (detached metadata)
    meta = (
        os.path.join(repo, "objects", checksum[:2], checksum[2:] + ".commitmeta")
        if checksum
        else ""
    )
    chk(
        "commit is ed25519-signed",
        meta
        and os.path.exists(meta)
        and b"ostree.sign.ed25519" in open(meta, "rb").read(),
    )

    # 3. + 4. a signed summary so clients can resolve refs over static HTTP
    summary = os.path.join(repo, "summary")
    summary_sig = os.path.join(repo, "summary.sig")
    chk("summary present", os.path.isfile(summary) and os.path.getsize(summary) > 0)
    chk(
        "summary is signed (summary.sig)",
        os.path.isfile(summary_sig) and os.path.getsize(summary_sig) > 0,
    )

    ok = all(v for _, v in checks)
    for desc, value in checks:
        print(("ok   " if value else "FAIL ") + desc)
    print("ostree_channel: %s" % ("OK" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
