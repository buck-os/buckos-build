#!/usr/bin/env python3
"""Commit a filesystem tree into an ostree repo, reproducibly.

Runs the buckos-built `ostree` CLI inside a buck2 action to turn a built
rootfs tree into a content-addressed (optionally ed25519-signed) commit.
This is the build-graph entry point for SPEC-006 atomic image-based updates:
each system version becomes an ostree commit whose checksum is byte-stable
across builders.

The `ostree` binary is a buckos PIE whose PT_INTERP points at the seed
sysroot loader; rather than rely on that absolute path resolving inside the
action sandbox, we invoke the loader explicitly:

    <ld-linux> --library-path <dep lib closure> <ostree> --repo=<repo> ...

The lib closure (from the package's path_info tset) and the loader are
action inputs, so they are materialised before the commit runs.

Reproducibility: a fixed --timestamp, normalised owner uid/gid, and
canonical handling make the resulting commit checksum independent of when
or where the build runs.
"""

import argparse
import os
import subprocess
import sys


def _read_lines(path):
    with open(path) as fh:
        return [ln.strip() for ln in fh if ln.strip()]


def _clean_env(home):
    """Minimal, deterministic environment for the ostree subprocess."""
    return {
        "PATH": "/usr/bin:/bin",
        "LC_ALL": "C",
        "LANG": "C",
        "TZ": "UTC",
        "HOME": home,
    }


def main():
    ap = argparse.ArgumentParser(description="Commit a tree into an ostree repo")
    ap.add_argument("--ld-linux", required=True, help="seed dynamic loader")
    ap.add_argument("--ostree", required=True, help="ostree CLI binary")
    ap.add_argument(
        "--lib-dirs-file",
        required=True,
        help="file of dep lib dirs (one per line) for --library-path",
    )
    ap.add_argument("--tree", required=True, help="filesystem tree to commit")
    ap.add_argument("--repo", required=True, help="output repo directory")
    ap.add_argument(
        "--checksum-out", required=True, help="write the resulting commit checksum here"
    )
    ap.add_argument("--branch", required=True, help="ref to commit onto")
    ap.add_argument("--subject", default="", help="commit subject")
    ap.add_argument(
        "--timestamp",
        default="0",
        help="fixed commit timestamp (epoch seconds) for reproducibility",
    )
    ap.add_argument(
        "--mode",
        default="archive",
        help="repo mode (archive, bare, bare-user, bare-user-only)",
    )
    ap.add_argument(
        "--key-file",
        default=None,
        help="ed25519 secret key (base64) to sign the commit",
    )
    ap.add_argument(
        "--preserve-xattrs",
        action="store_true",
        help="keep file xattrs (capabilities) — required for real OS commits",
    )
    ap.add_argument(
        "--summary",
        action="store_true",
        help="generate (and, with --key-file, ed25519-sign) the repo summary so "
        "the repo is a discoverable, HTTP-servable channel (SPEC-006 P5)",
    )
    args = ap.parse_args()

    ld = os.path.abspath(args.ld_linux)
    ostree = os.path.abspath(args.ostree)
    tree = os.path.abspath(args.tree)
    repo = os.path.abspath(args.repo)
    lib_path = ":".join(os.path.abspath(d) for d in _read_lines(args.lib_dirs_file))

    os.makedirs(repo, exist_ok=True)
    home = os.path.join(os.path.dirname(repo), "ostree-home")
    os.makedirs(home, exist_ok=True)
    env = _clean_env(home)

    def ostree_run(extra, capture=False):
        cmd = [ld, "--library-path", lib_path, ostree, "--repo=" + repo] + extra
        return subprocess.run(
            cmd,
            env=env,
            check=True,
            stdout=subprocess.PIPE if capture else None,
            text=True,
        )

    # 1. init the repo. Disable ostree's runtime min-free-space guard: this repo
    # is ephemeral build output, so the guard (meant to protect a running
    # system's repo) only causes spurious build failures on a full dev/CI disk.
    # It is repo config, not commit content, so the checksum stays reproducible.
    ostree_run(["init", "--mode=" + args.mode])
    ostree_run(["config", "set", "core.min-free-space-percent", "0"])

    # 2. commit the tree — reproducibly.  ostree parses --timestamp with GNU
    # parse_datetime, which reads a bare "0" as "today at 00:00" (NOT the
    # epoch!).  The "@SECONDS" form forces an absolute epoch, so the commit
    # timestamp — and thus the checksum — is independent of the build date.
    ts = args.timestamp
    if ts.lstrip("-").isdigit():
        ts = "@" + ts
    commit = [
        "commit",
        "--branch=" + args.branch,
        "--tree=dir=" + tree,
        "--timestamp=" + ts,
        "--owner-uid=0",
        "--owner-gid=0",
        "--no-bindings",
    ]
    if not args.preserve_xattrs:
        commit.append("--no-xattrs")
    if args.subject:
        commit.append("--subject=" + args.subject)
    proc = ostree_run(commit, capture=True)
    checksum = proc.stdout.strip().splitlines()[-1].strip()
    if len(checksum) != 64:
        sys.stderr.write("ostree commit did not return a checksum: %r\n" % proc.stdout)
        return 1

    # 3. optional ed25519 signature (deterministic per RFC 8032)
    if args.key_file:
        ostree_run(
            [
                "sign",
                "--sign-type=ed25519",
                "--keys-file=" + os.path.abspath(args.key_file),
                checksum,
            ]
        )

    # 4. optional channel summary: clients resolve refs over plain HTTP from the
    # summary, so a published channel needs one. Sign it with the same release
    # key (ed25519 summary signing takes the base64 secret inline via --sign;
    # there is no --keys-file for `summary`).
    if args.summary:
        summary_cmd = ["summary", "--update"]
        if args.key_file:
            secret = _read_lines(args.key_file)[0]
            summary_cmd += ["--sign=" + secret, "--sign-type=ed25519"]
        ostree_run(summary_cmd)

    with open(args.checksum_out, "w") as fh:
        fh.write(checksum + "\n")
    print("committed %s -> %s (%s)" % (args.branch, checksum, args.mode))
    return 0


if __name__ == "__main__":
    sys.exit(main())
