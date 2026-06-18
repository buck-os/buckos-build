#!/usr/bin/env python3
"""Reshape a rootfs tree into ostree's filesystem layout (SPEC-006 P2).

ostree deploys an immutable /usr and 3-way-merges configuration, so a tree
destined to become a commit must be "ostree-shaped".  This is a *composable*
transform: it does not touch the rootfs rule — it takes any rootfs tree and
emits an ostree-layout tree, which ostree_commit then commits.  Deterministic
(sorted, mode-preserving copy) so the downstream commit checksum stays stable.

Layout moves (the ostree convention):
  - /etc -> /usr/etc        config *defaults*; ostree merges them into /etc on
                            deploy (3-way merge against the running /etc)
  - /var emptied            persistent + machine-local; recreated at boot from
                            tmpfiles (populating /var is a later, P3 concern)
  - mutable top-level dirs become symlinks into /var:
        /home -> var/home, /opt -> var/opt, /srv -> var/srv,
        /root -> var/roothome, /usr/local -> ../var/usrlocal
  - /sysroot added          the physical root ostree mounts the real fs at
  - /ostree -> sysroot/ostree   so ostree (and the update agent), run with the
                            default sysroot (/) in a BOOTED deployment, resolve
                            the repo at /ostree/repo -> /sysroot/ostree/repo
  - runtime mountpoints (/proc /sys /dev /run /tmp /mnt /media) kept as empty
    dirs (populated at runtime)
"""

import argparse
import os
import shutil
import sys

# (link path, symlink target) — mutable state redirected into /var.
_VAR_SYMLINKS = [
    ("home", "var/home"),
    ("opt", "var/opt"),
    ("srv", "var/srv"),
    ("root", "var/roothome"),
]

# Kept as empty directories (runtime mountpoints + ostree's physical root).
_EMPTY_DIRS = ["sysroot", "var", "proc", "sys", "dev", "run", "tmp", "mnt", "media"]

# /var is empty in the commit; systemd-tmpfiles recreates these on a fresh
# deployment (including the symlink targets above), so the booted system has a
# working /var.  Shipped in /usr/lib/tmpfiles.d as part of the immutable /usr.
_VAR_TMPFILES = """\
# Created by buckos ostree_rootfs — recreate /var on a fresh deployment.
d /var/home 0755 root root -
d /var/roothome 0700 root root -
d /var/opt 0755 root root -
d /var/srv 0755 root root -
d /var/usrlocal 0755 root root -
d /var/mnt 0755 root root -
d /var/log 0755 root root -
d /var/cache 0755 root root -
d /var/lib 0755 root root -
d /var/spool 0755 root root -
d /var/tmp 1777 root root -
"""


def _replace_with_symlink(path, target):
    if os.path.islink(path):
        if os.readlink(path) == target:
            return
        os.remove(path)
    elif os.path.isdir(path):
        shutil.rmtree(path)
    elif os.path.exists(path):
        os.remove(path)
    os.symlink(target, path)


def _move_etc_to_usr_etc(root):
    """/etc -> /usr/etc (merging if /usr/etc already exists; /etc wins)."""
    etc = os.path.join(root, "etc")
    usr_etc = os.path.join(root, "usr", "etc")
    if not os.path.isdir(etc):
        return
    if not os.path.exists(usr_etc):
        os.makedirs(os.path.dirname(usr_etc), exist_ok=True)
        shutil.move(etc, usr_etc)
        return
    for cur, dirs, files in os.walk(etc):
        rel = os.path.relpath(cur, etc)
        dst = usr_etc if rel == "." else os.path.join(usr_etc, rel)
        os.makedirs(dst, exist_ok=True)
        for name in files:
            shutil.move(os.path.join(cur, name), os.path.join(dst, name))
        for name in [d for d in dirs if os.path.islink(os.path.join(cur, d))]:
            s = os.path.join(cur, name)
            shutil.move(s, os.path.join(dst, name))
            dirs.remove(name)
    shutil.rmtree(etc)


def _ensure_os_release(root):
    """ostree reads /usr/lib/os-release to name boot entries (and a deployed
    /etc/os-release should resolve there).  Many rootfses ship only
    /etc/os-release (now /usr/etc after the move); copy it to the canonical
    /usr/lib/os-release so `ostree admin deploy` can label the deployment."""
    canonical = os.path.join(root, "usr", "lib", "os-release")
    if os.path.exists(canonical):
        return
    for cand in (
        os.path.join(root, "usr", "etc", "os-release"),
        os.path.join(root, "etc", "os-release"),
    ):
        if os.path.isfile(cand):
            os.makedirs(os.path.dirname(canonical), exist_ok=True)
            shutil.copy2(cand, canonical)
            return


def _install_trusted_key(root, key_path, remote_name, remote_url):
    """Bake the ed25519 PUBLIC key (and, if a URL is given, a signature-verified
    remote) into the image so a deployed system trusts the release key on disk
    (SPEC-007 §5.3). Written under /usr/etc — ostree's config default that is
    merged into /etc on deploy.
    """
    key = open(key_path).read().strip()
    etc_ostree = os.path.join(root, "usr", "etc", "ostree")
    os.makedirs(etc_ostree, exist_ok=True)
    with open(os.path.join(etc_ostree, "buckos.ed25519.pub"), "w") as fh:
        fh.write(key + "\n")
    if remote_url:
        remotes_d = os.path.join(etc_ostree, "remotes.d")
        os.makedirs(remotes_d, exist_ok=True)
        conf = (
            '[remote "%s"]\n'
            "url=%s\n"
            "sign-verify=true\n"
            "verification-ed25519-key=%s\n"
        ) % (remote_name, remote_url, key)
        with open(os.path.join(remotes_d, remote_name + ".conf"), "w") as fh:
            fh.write(conf)


def main():
    ap = argparse.ArgumentParser(description="Reshape a rootfs into ostree layout")
    ap.add_argument("--input", required=True, help="input rootfs tree")
    ap.add_argument("--output", required=True, help="output ostree-shaped tree")
    ap.add_argument(
        "--trusted-key",
        default=None,
        help="ed25519 public key (base64) to bake in as the trusted release key",
    )
    ap.add_argument("--remote-name", default="buckos", help="ostree remote name")
    ap.add_argument(
        "--remote-url",
        default="",
        help="channel URL; when set, bake a sign-verify remote config",
    )
    args = ap.parse_args()

    src, dst = args.input, args.output
    shutil.copytree(src, dst, symlinks=True, dirs_exist_ok=True)

    _move_etc_to_usr_etc(dst)
    _ensure_os_release(dst)

    for name, target in _VAR_SYMLINKS:
        _replace_with_symlink(os.path.join(dst, name), target)
    _replace_with_symlink(os.path.join(dst, "usr", "local"), "../var/usrlocal")

    # /var is emptied — its content belongs to the deployed, persistent system.
    var = os.path.join(dst, "var")
    if os.path.isdir(var) and not os.path.islink(var):
        shutil.rmtree(var)
    for d in _EMPTY_DIRS:
        os.makedirs(os.path.join(dst, d), exist_ok=True)

    # /ostree -> sysroot/ostree: in a booted deployment the physical root is
    # mounted at /sysroot, so this lets `ostree`/the update agent run with the
    # default sysroot (/) and still find the repo (/ostree/repo). Without it
    # ostree must be told --sysroot=/sysroot, which suppresses booted-deployment
    # detection (no `*` in `ostree admin status`) and breaks the agent's
    # status/check/rollback.
    _replace_with_symlink(os.path.join(dst, "ostree"), "sysroot/ostree")

    tmpfiles_dir = os.path.join(dst, "usr", "lib", "tmpfiles.d")
    os.makedirs(tmpfiles_dir, exist_ok=True)
    with open(os.path.join(tmpfiles_dir, "ostree-buckos-var.conf"), "w") as fh:
        fh.write(_VAR_TMPFILES)

    if args.trusted_key:
        _install_trusted_key(dst, args.trusted_key, args.remote_name, args.remote_url)

    return 0


if __name__ == "__main__":
    sys.exit(main())
