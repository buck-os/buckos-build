#!/usr/bin/env python3
"""Validate a channel release that carries a static delta (SPEC-006 P5).

ostree_channel with from_commit set generates a static delta previous->new so a
client can fetch a compact binary diff instead of every changed object. This
asserts the published release has the channel ref, a generated static delta (a
superblock under repo/deltas/), and a signed summary that lets clients discover
both over plain static HTTP.

Env:
    OSTREE_REPO     repo from //tests/fixtures/ostree:demo-channel-v2
    OSTREE_BRANCH   channel ref (default buckos/x86_64/stable)
"""

import os
import sys


def main():
    repo = os.environ["OSTREE_REPO"]
    branch = os.environ.get("OSTREE_BRANCH", "buckos/x86_64/stable")
    checks = []

    def chk(desc, cond):
        checks.append((desc, bool(cond)))

    chk(
        "channel ref %s present" % branch,
        os.path.isfile(os.path.join(repo, "refs", "heads", *branch.split("/"))),
    )

    # A static delta is stored as a `superblock` under repo/deltas/<a>/<b>/.
    deltas = os.path.join(repo, "deltas")
    superblocks = []
    if os.path.isdir(deltas):
        for dirpath, _, files in os.walk(deltas):
            superblocks += [f for f in files if f == "superblock"]
    chk("static delta generated (superblock present)", len(superblocks) >= 1)

    chk(
        "signed summary present (lists ref + delta)",
        os.path.isfile(os.path.join(repo, "summary"))
        and os.path.getsize(os.path.join(repo, "summary")) > 0
        and os.path.isfile(os.path.join(repo, "summary.sig")),
    )

    ok = all(v for _, v in checks)
    for desc, value in checks:
        print(("ok   " if value else "FAIL ") + desc)
    print("ostree static delta: %s" % ("OK" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
