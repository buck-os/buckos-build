#!/usr/bin/env python3
"""Assemble a root filesystem from packages.

Replaces the inline bash in rootfs.bzl.  Handles merged-usr layout,
merged-bin for systemd, acct-user/acct-group merging, and ldconfig.
"""

import argparse
import hashlib
import os
import shutil
import subprocess
import sys

from _env import add_path_args, clean_env, setup_path


def _merge_package(src, rootfs, env):
    """Recursively merge a package directory into the rootfs."""
    # Follow symlinks to the real directory
    if os.path.islink(src):
        src = os.path.realpath(src)
    if not os.path.isdir(src):
        return

    # Check if this looks like a package directory
    has_top_level = any(
        os.path.isdir(os.path.join(src, d))
        for d in ("usr", "bin", "lib", "etc", "sbin")
    )
    if has_top_level:
        # Use tar to merge, preserving directory symlinks
        tar_c = subprocess.Popen(
            ["tar", "-C", src, "-c", "."],
            stdout=subprocess.PIPE, env=env,
        )
        tar_x = subprocess.Popen(
            ["tar", "-C", rootfs, "-x", "--keep-directory-symlink"],
            stdin=tar_c.stdout, stderr=subprocess.DEVNULL, env=env,
        )
        tar_c.stdout.close()
        tar_x.communicate()
        tar_c.wait()
    else:
        # Meta-package directory — recurse into subdirs
        for entry in sorted(os.listdir(src)):
            child = os.path.join(src, entry)
            if os.path.isdir(child) or os.path.islink(child):
                _merge_package(child, rootfs, env)


def _fix_merged_usr(rootfs, dirname):
    """If /dirname is a directory (not symlink), merge into /usr/dirname."""
    path = os.path.join(rootfs, dirname)
    usr_path = os.path.join(rootfs, "usr", dirname)
    if os.path.isdir(path) and not os.path.islink(path):
        os.makedirs(usr_path, exist_ok=True)
        for item in os.listdir(path):
            src = os.path.join(path, item)
            dst = os.path.join(usr_path, item)
            if os.path.exists(dst):
                if os.path.isdir(src) and not os.path.islink(src):
                    shutil.copytree(src, dst, symlinks=True, dirs_exist_ok=True)
                    continue
            shutil.move(src, dst)
        shutil.rmtree(path)
        os.symlink("usr/" + dirname, path)


def _fix_var_symlinks(rootfs):
    """Restore /var/run -> ../run and /var/lock -> ../run/lock."""
    var_run = os.path.join(rootfs, "var", "run")
    if os.path.isdir(var_run) and not os.path.islink(var_run):
        run_dir = os.path.join(rootfs, "run")
        os.makedirs(run_dir, exist_ok=True)
        for item in os.listdir(var_run):
            src = os.path.join(var_run, item)
            dst = os.path.join(run_dir, item)
            if not os.path.exists(dst):
                shutil.move(src, dst)
        shutil.rmtree(var_run)
        os.symlink("../run", var_run)
        print("Fixed /var/run symlink (was directory, moved contents to /run)")

    var_lock = os.path.join(rootfs, "var", "lock")
    if os.path.isdir(var_lock) and not os.path.islink(var_lock):
        run_lock = os.path.join(rootfs, "run", "lock")
        os.makedirs(run_lock, exist_ok=True)
        for item in os.listdir(var_lock):
            src = os.path.join(var_lock, item)
            dst = os.path.join(run_lock, item)
            if not os.path.exists(dst):
                shutil.move(src, dst)
        shutil.rmtree(var_lock)
        os.symlink("../run/lock", var_lock)
        print("Fixed /var/lock symlink (was directory, moved contents to /run/lock)")


def _merge_sbin_into_bin(rootfs):
    """Merge /usr/sbin into /usr/bin (systemd merged-bin layout)."""
    usr_sbin = os.path.join(rootfs, "usr", "sbin")
    usr_bin = os.path.join(rootfs, "usr", "bin")
    if os.path.isdir(usr_sbin) and not os.path.islink(usr_sbin):
        os.makedirs(usr_bin, exist_ok=True)
        for item in os.listdir(usr_sbin):
            src = os.path.join(usr_sbin, item)
            dst = os.path.join(usr_bin, item)
            if not os.path.exists(dst):
                shutil.move(src, dst)
            elif os.path.isfile(src):
                shutil.copy2(src, dst)
        shutil.rmtree(usr_sbin)
        os.symlink("bin", usr_sbin)
        print("Merged /usr/sbin into /usr/bin (systemd merged-bin layout)")

    # Update /sbin symlink for consistency
    sbin = os.path.join(rootfs, "sbin")
    if os.path.islink(sbin):
        os.remove(sbin)
        os.symlink("usr/bin", sbin)


def _merge_acct_entries(rootfs):
    """Merge acct-group and acct-user entries into /etc databases."""
    acct_group_dir = os.path.join(rootfs, "usr", "share", "acct-group")
    acct_user_dir = os.path.join(rootfs, "usr", "share", "acct-user")

    if not os.path.isdir(acct_group_dir) and not os.path.isdir(acct_user_dir):
        return

    print("Merging system users and groups from acct packages...")

    etc = os.path.join(rootfs, "etc")
    group_file = os.path.join(etc, "group")
    passwd_file = os.path.join(etc, "passwd")
    shadow_file = os.path.join(etc, "shadow")

    def _read_names(path):
        """Read existing entry names from a colon-delimited file."""
        names = set()
        if os.path.isfile(path):
            with open(path) as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#"):
                        names.add(line.split(":")[0])
        return names

    # Merge groups
    if os.path.isdir(acct_group_dir):
        existing_groups = _read_names(group_file)
        for gf in sorted(os.listdir(acct_group_dir)):
            if not gf.endswith(".group"):
                continue
            path = os.path.join(acct_group_dir, gf)
            with open(path) as f:
                content = f.read().strip()
            name = content.split(":")[0]
            if name not in existing_groups:
                with open(group_file, "a") as f:
                    f.write(content + "\n")
                existing_groups.add(name)
                print(f"  Added group: {name}")

    # Merge users
    if os.path.isdir(acct_user_dir):
        existing_users = _read_names(passwd_file)
        for pf in sorted(os.listdir(acct_user_dir)):
            if not pf.endswith(".passwd"):
                continue
            path = os.path.join(acct_user_dir, pf)
            with open(path) as f:
                content = f.read().strip()
            name = content.split(":")[0]
            if name not in existing_users:
                with open(passwd_file, "a") as f:
                    f.write(content + "\n")
                existing_users.add(name)
                print(f"  Added user: {name}")

        # Merge shadow entries
        if os.path.isfile(shadow_file):
            existing_shadow = _read_names(shadow_file)
            for sf in sorted(os.listdir(acct_user_dir)):
                if not sf.endswith(".shadow"):
                    continue
                path = os.path.join(acct_user_dir, sf)
                with open(path) as f:
                    content = f.read().strip()
                name = content.split(":")[0]
                if name not in existing_shadow:
                    with open(shadow_file, "a") as f:
                        f.write(content + "\n")
                    existing_shadow.add(name)

        # Add users to supplementary groups
        for gf in sorted(os.listdir(acct_user_dir)):
            if not gf.endswith(".groups"):
                continue
            user_name = gf[:-len(".groups")]
            path = os.path.join(acct_user_dir, gf)
            with open(path) as f:
                supp_groups = f.read().strip()
            if not supp_groups:
                continue

            for group_name in supp_groups.split(","):
                group_name = group_name.strip()
                if not group_name:
                    continue
                # Read current group file
                if not os.path.isfile(group_file):
                    continue
                lines = []
                modified = False
                with open(group_file) as f:
                    for line in f:
                        stripped = line.rstrip("\n")
                        parts = stripped.split(":")
                        if len(parts) >= 4 and parts[0] == group_name:
                            members = parts[3].split(",") if parts[3] else []
                            if user_name not in members:
                                members.append(user_name)
                                parts[3] = ",".join(members)
                                line = ":".join(parts) + "\n"
                                modified = True
                                print(f"  Added {user_name} to group: {group_name}")
                        lines.append(line)
                if modified:
                    with open(group_file, "w") as f:
                        f.writelines(lines)


def main():
    _host_path = os.environ.get("PATH", "")

    parser = argparse.ArgumentParser(description="Assemble root filesystem")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--package-dir", action="append", dest="package_dirs",
                        default=[], help="Package directory to merge (repeatable)")
    parser.add_argument("--prefix-list", default=None,
                        help="File with package prefix paths (one per line, from tset projection)")
    parser.add_argument("--version", default="1")
    parser.add_argument("--manifest-output", default=None,
                        help="Write content manifest for cache invalidation")
    add_path_args(parser)
    args = parser.parse_args()

    rootfs = os.path.abspath(args.output_dir)
    env = clean_env()
    setup_path(args, env, _host_path)

    # Read prefix list from tset projection file (one path per line)
    if args.prefix_list:
        with open(args.prefix_list) as f:
            for line in f:
                line = line.strip()
                if line:
                    args.package_dirs.append(line)

    # Create base directory structure
    for d in ("usr/bin", "usr/sbin", "usr/lib", "etc", "var", "tmp",
              "proc", "sys", "dev", "run", "root", "home"):
        os.makedirs(os.path.join(rootfs, d), exist_ok=True)

    # Merge packages
    for pkg_dir in args.package_dirs:
        pkg_abs = os.path.abspath(pkg_dir)
        if os.path.isdir(pkg_abs) or os.path.islink(pkg_abs):
            _merge_package(pkg_abs, rootfs, env)

    # Fix merged-usr layout
    _fix_merged_usr(rootfs, "bin")
    _fix_merged_usr(rootfs, "sbin")
    _fix_merged_usr(rootfs, "lib")

    # Fix var symlinks
    _fix_var_symlinks(rootfs)

    # Merged-bin (systemd)
    _merge_sbin_into_bin(rootfs)

    # Compatibility symlinks
    for cmd in ("sh", "bash"):
        usr_cmd = os.path.join(rootfs, "usr", "bin", cmd)
        bin_cmd = os.path.join(rootfs, "bin", cmd)
        if os.path.isfile(usr_cmd) and not os.path.exists(bin_cmd):
            # /bin is a symlink to usr/bin in merged-usr, so this already
            # exists if merged-usr is correct.  Only create if missing.
            bin_dir = os.path.join(rootfs, "bin")
            if os.path.isdir(bin_dir) and not os.path.islink(bin_dir):
                os.symlink("../usr/bin/" + cmd, bin_cmd)

    # Set permissions
    tmp_dir = os.path.join(rootfs, "tmp")
    if os.path.isdir(tmp_dir):
        os.chmod(tmp_dir, 0o1777)
    root_dir = os.path.join(rootfs, "root")
    if os.path.isdir(root_dir):
        os.chmod(root_dir, 0o755)

    # Merge acct entries
    _merge_acct_entries(rootfs)

    # Run ldconfig
    ld_so_conf = os.path.join(rootfs, "etc", "ld.so.conf")
    if os.path.isfile(ld_so_conf):
        subprocess.run(["ldconfig", "-r", rootfs], env=env,
                        capture_output=True)

    # Compute manifest if requested
    if args.manifest_output:
        manifest_path = os.path.abspath(args.manifest_output)
        os.makedirs(os.path.dirname(manifest_path) or ".", exist_ok=True)
        h = hashlib.sha256()
        for dirpath, _, filenames in sorted(os.walk(rootfs)):
            for fname in sorted(filenames):
                fpath = os.path.join(dirpath, fname)
                if os.path.isfile(fpath) and not os.path.islink(fpath):
                    st = os.stat(fpath)
                    h.update(f"{fpath} {st.st_size} {st.st_mtime}\n".encode())
        with open(manifest_path, "w") as f:
            f.write(f"rootfs_hash: {h.hexdigest()}\n")


if __name__ == "__main__":
    main()
