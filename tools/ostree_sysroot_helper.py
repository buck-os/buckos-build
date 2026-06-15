#!/usr/bin/env python3
"""Deploy an ostree commit into a bootable sysroot (SPEC-006 P3).

Turns a committed ostree image into a physical sysroot: the /ostree repo +
stateroot, a checked-out deployment under /ostree/deploy/<os>/deploy/<csum>.0,
and /boot loader entries — i.e. what a disk would hold to boot via
ostree-prepare-root.

`ostree admin deploy` writes a *bare* repo and checks the deployment out with
real (root) ownership, which a normal build user can't do (fchown EPERM).  We
run the whole sequence inside a new **user namespace** mapping the build user
to uid/gid 0, the standard way to do ostree sysroot ops without real root.
buckos build actions already use namespaces (unshare --net), so this is
available in-action.

The committed image must contain a kernel (/usr/lib/modules/<kver>/vmlinuz);
ostree reads it to populate /boot.
"""

import argparse
import ctypes
import os
import subprocess
import sys

CLONE_NEWUSER = 0x10000000


def _become_root_in_userns():
    """unshare(CLONE_NEWUSER) + map build uid/gid -> 0 (like `unshare -r`)."""
    libc = ctypes.CDLL("libc.so.6", use_errno=True)
    uid, gid = os.getuid(), os.getgid()
    if libc.unshare(CLONE_NEWUSER) != 0:
        err = ctypes.get_errno()
        raise OSError(err, "unshare(CLONE_NEWUSER): " + os.strerror(err))
    with open("/proc/self/setgroups", "w") as fh:
        fh.write("deny")
    with open("/proc/self/uid_map", "w") as fh:
        fh.write("0 %d 1\n" % uid)
    with open("/proc/self/gid_map", "w") as fh:
        fh.write("0 %d 1\n" % gid)


def _read_lines(path):
    with open(path) as fh:
        return [ln.strip() for ln in fh if ln.strip()]


def main():
    ap = argparse.ArgumentParser(description="Deploy an ostree commit into a sysroot")
    ap.add_argument("--ld-linux", required=True)
    ap.add_argument("--ostree", required=True)
    ap.add_argument("--lib-dirs-file", required=True)
    ap.add_argument("--commit-repo", required=True, help="source ostree repo")
    ap.add_argument("--branch", required=True, help="ref to deploy")
    ap.add_argument("--sysroot", required=True, help="output sysroot directory")
    ap.add_argument("--os", default="buckos", help="stateroot / os name")
    ap.add_argument(
        "--karg", action="append", default=[], help="kernel arg (repeatable)"
    )
    args = ap.parse_args()

    _become_root_in_userns()

    ld = os.path.abspath(args.ld_linux)
    ostree = os.path.abspath(args.ostree)
    repo = os.path.abspath(args.commit_repo)
    sysroot = os.path.abspath(args.sysroot)
    lib_path = ":".join(os.path.abspath(d) for d in _read_lines(args.lib_dirs_file))
    os.makedirs(sysroot, exist_ok=True)
    env = {
        "PATH": "/usr/bin:/bin",
        "LC_ALL": "C",
        "LANG": "C",
        "TZ": "UTC",
        "HOME": sysroot,
    }

    def run(extra):
        subprocess.run(
            [ld, "--library-path", lib_path, ostree] + extra, env=env, check=True
        )

    run(["admin", "init-fs", "--modern", sysroot])
    run(
        [
            "pull-local",
            "--repo=" + os.path.join(sysroot, "ostree", "repo"),
            repo,
            args.branch,
        ]
    )
    run(["admin", "stateroot-init", "--sysroot=" + sysroot, args.os])

    deploy = ["admin", "deploy", "--sysroot=" + sysroot, "--os=" + args.os]
    for karg in args.karg:
        deploy.append("--karg=" + karg)
    deploy.append(args.branch)
    run(deploy)

    print("deployed %s (%s) into %s" % (args.branch, args.os, sysroot))
    return 0


if __name__ == "__main__":
    sys.exit(main())
