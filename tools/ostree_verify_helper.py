#!/usr/bin/env python3
"""Verify an ed25519-signed ostree commit — positively and negatively (SPEC-007 S3).

Runs the buckos `ostree` CLI (via the seed loader + dep lib closure, like
ostree_helper.py) to check `ostree sign --verify` on a signed commit:

  - the CORRECT public key MUST verify (the commit is authentic), and
  - a WRONG public key MUST be rejected (a forged/incorrect signer fails closed).

Exits non-zero (failing the build) if either expectation is violated, and writes
a one-line result to --result-out for a downstream test to assert on.
"""

import argparse
import os
import subprocess
import sys


def _read_lines(path):
    with open(path) as fh:
        return [ln.strip() for ln in fh if ln.strip()]


def main():
    ap = argparse.ArgumentParser(description="Verify an ed25519-signed ostree commit")
    ap.add_argument("--ld-linux", required=True, help="seed dynamic loader")
    ap.add_argument("--ostree", required=True, help="ostree CLI binary")
    ap.add_argument(
        "--lib-dirs-file", required=True, help="dep lib dirs for --library-path"
    )
    ap.add_argument(
        "--repo", required=True, help="ostree repo holding the signed commit"
    )
    ap.add_argument("--branch", required=True, help="ref to verify")
    ap.add_argument(
        "--good-key", required=True, help="public key that signed the commit"
    )
    ap.add_argument(
        "--bad-key", required=True, help="a different public key (must be rejected)"
    )
    ap.add_argument(
        "--result-out", required=True, help="write the one-line verdict here"
    )
    args = ap.parse_args()

    ld = os.path.abspath(args.ld_linux)
    ostree = os.path.abspath(args.ostree)
    repo = os.path.abspath(args.repo)
    lib_path = ":".join(os.path.abspath(d) for d in _read_lines(args.lib_dirs_file))

    ref = os.path.join(repo, "refs", "heads", *args.branch.split("/"))
    with open(ref) as fh:
        commit = fh.read().strip()

    env = {
        "PATH": "/usr/bin:/bin",
        "LC_ALL": "C",
        "LANG": "C",
        "TZ": "UTC",
        "HOME": os.path.dirname(repo),
    }

    def verify(keyfile):
        cmd = [
            ld,
            "--library-path",
            lib_path,
            ostree,
            "--repo=" + repo,
            "sign",
            "--verify",
            "--sign-type=ed25519",
            "--keys-file=" + os.path.abspath(keyfile),
            commit,
        ]
        p = subprocess.run(
            cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        )
        return p.returncode, p.stdout.strip()

    good_rc, good_out = verify(args.good_key)
    bad_rc, bad_out = verify(args.bad_key)

    # Trust check: the signer's key verifies; any other key is rejected.
    ok = good_rc == 0 and bad_rc != 0
    verdict = "%s commit=%s good_rc=%d bad_rc=%d\n" % (
        "VERIFY_OK" if ok else "VERIFY_FAIL",
        commit,
        good_rc,
        bad_rc,
    )
    with open(args.result_out, "w") as fh:
        fh.write(verdict)

    if not ok:
        sys.stderr.write("ed25519 verification expectation violated:\n")
        sys.stderr.write("  correct key (must pass) rc=%d: %s\n" % (good_rc, good_out))
        sys.stderr.write(
            "  wrong key (must be rejected) rc=%d: %s\n" % (bad_rc, bad_out)
        )
        return 1
    print(verdict.strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
