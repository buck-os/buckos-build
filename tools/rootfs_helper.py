#!/usr/bin/env python3
"""Assemble a root filesystem from packages.

Replaces the inline bash in rootfs.bzl.  Handles merged-usr layout,
merged-bin for systemd, acct-user/acct-group merging, and ldconfig.
"""

import argparse
import hashlib
import os
import shutil
import struct
import stat
import subprocess
import sys
import tarfile
import tempfile

from _env import add_path_args, clean_env, setup_path


# ── System database merge ────────────────────────────────────────────
#
# /etc/{passwd,group,shadow,gshadow} are written by multiple packages
# (genrules with full databases AND acct packages with single entries).
# Tar-based rootfs merge overwrites files, so later packages clobber
# earlier ones.  These helpers accumulate entries across packages.

_MERGE_FILES = frozenset({
    "etc/passwd", "etc/group", "etc/shadow", "etc/gshadow",
})


def _parse_colon_file(text):
    """Parse colon-delimited file into {name: line}, last occurrence wins."""
    entries = {}
    for line in text.splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            entries[line.split(":")[0]] = line
    return entries


def _merge_group_files(existing_text, incoming_text):
    """Merge two group(5)/gshadow(5) files.

    Deduplicate by group name, union member lists, sort by GID.
    """
    existing = _parse_colon_file(existing_text)
    incoming = _parse_colon_file(incoming_text)

    merged = dict(existing)
    for name, line in incoming.items():
        if name not in merged:
            merged[name] = line
            continue
        old = merged[name].split(":")
        new = line.split(":")
        if len(old) >= 4 and len(new) >= 4:
            old_members = set(m for m in old[3].split(",") if m)
            new_members = set(m for m in new[3].split(",") if m)
            old[3] = ",".join(sorted(old_members | new_members))
            merged[name] = ":".join(old)

    def _gid(line):
        try:
            return int(line.split(":")[2])
        except (IndexError, ValueError):
            return 99999

    return "\n".join(sorted(merged.values(), key=_gid)) + "\n"


def _merge_passwd_files(existing_text, incoming_text):
    """Merge two passwd(5) files.

    Deduplicate by username, prefer entries with a real login shell
    over locked accounts, sort by UID.
    """
    _NOLOGIN = frozenset({"/bin/false", "/usr/sbin/nologin", "/sbin/nologin"})

    existing = _parse_colon_file(existing_text)
    incoming = _parse_colon_file(incoming_text)

    merged = dict(existing)
    for name, line in incoming.items():
        if name not in merged:
            merged[name] = line
            continue
        old_shell = merged[name].rsplit(":", 1)[-1]
        new_shell = line.rsplit(":", 1)[-1]
        if old_shell in _NOLOGIN and new_shell not in _NOLOGIN:
            merged[name] = line

    def _uid(line):
        try:
            return int(line.split(":")[2])
        except (IndexError, ValueError):
            return 99999

    return "\n".join(sorted(merged.values(), key=_uid)) + "\n"


def _merge_shadow_files(existing_text, incoming_text):
    """Merge two shadow(5) files.

    Deduplicate by username, prefer entries with a real password hash
    over locked (!) or empty entries, sort by username to match passwd.
    """
    _LOCKED = frozenset({"!", "!!", "", "*"})

    existing = _parse_colon_file(existing_text)
    incoming = _parse_colon_file(incoming_text)

    merged = dict(existing)
    for name, line in incoming.items():
        if name not in merged:
            merged[name] = line
            continue
        old_hash = merged[name].split(":")[1] if ":" in merged[name] else ""
        new_hash = line.split(":")[1] if ":" in line else ""
        if old_hash in _LOCKED and new_hash not in _LOCKED:
            merged[name] = line

    return "\n".join(merged.values()) + "\n"


_MERGE_FUNCS = {
    "etc/group": _merge_group_files,
    "etc/gshadow": _merge_group_files,
    "etc/passwd": _merge_passwd_files,
    "etc/shadow": _merge_shadow_files,
}


def _save_merge_files(src):
    """Read merge-mode files from a directory before tar overwrites them."""
    saved = {}
    for relpath in _MERGE_FILES:
        fpath = os.path.join(src, relpath)
        if os.path.isfile(fpath):
            with open(fpath) as f:
                saved[relpath] = f.read()
    return saved


def _restore_merge_files(rootfs, saved):
    """Re-merge saved entries into the rootfs after tar has overwritten them."""
    for relpath, saved_content in saved.items():
        dst = os.path.join(rootfs, relpath)
        current = ""
        if os.path.isfile(dst):
            with open(dst) as f:
                current = f.read()
        merge_fn = _MERGE_FUNCS.get(relpath, _merge_passwd_files)
        result = merge_fn(saved_content, current)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "w") as f:
            f.write(result)
        if "shadow" in relpath:
            os.chmod(dst, 0o640)


# Accumulated setuid/setgid files across all merged packages.
# tar can't preserve setuid when run as non-root, so we record them
# from the source packages and restore after all merging is done.
_SETUID_FILES = {}  # relpath -> mode


def _scan_setuid(src):
    """Find files with setuid/setgid bits in a package directory."""
    for dirpath, _, filenames in os.walk(src):
        for fname in filenames:
            fpath = os.path.join(dirpath, fname)
            if os.path.islink(fpath):
                continue
            try:
                st = os.stat(fpath)
            except OSError:
                continue
            if st.st_mode & (stat.S_ISUID | stat.S_ISGID):
                relpath = os.path.relpath(fpath, src)
                _SETUID_FILES[relpath] = st.st_mode


def _restore_setuid(rootfs):
    """Restore setuid/setgid bits that were lost during tar merge."""
    for relpath, mode in _SETUID_FILES.items():
        fpath = os.path.join(rootfs, relpath)
        if os.path.isfile(fpath) and not os.path.islink(fpath):
            os.chmod(fpath, mode)
    if _SETUID_FILES:
        print(f"Restored setuid/setgid on {len(_SETUID_FILES)} files")


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
        # Record setuid/setgid files before tar loses them
        _scan_setuid(src)

        # Save existing append-mode files before tar overwrites them
        existing_saved = _save_merge_files(rootfs)
        incoming_saved = _save_merge_files(src)

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

        # Restore: merge the pre-existing entries back in
        if existing_saved:
            _restore_merge_files(rootfs, existing_saved)
        if incoming_saved:
            _restore_merge_files(rootfs, incoming_saved)
    else:
        # Meta-package directory — recurse into subdirs
        for entry in sorted(os.listdir(src)):
            child = os.path.join(src, entry)
            if os.path.isdir(child) or os.path.islink(child):
                _merge_package(child, rootfs, env)


def _move_preserving_symlinks(src, dst):
    """Move src to dst, preserving symlinks instead of following them."""
    if os.path.islink(src):
        # Never overwrite a real file with a symlink — the real file
        # takes priority (e.g. glibc's ldconfig vs a /sbin convenience
        # symlink that would clobber the binary during usr-merge).
        if os.path.isfile(dst) and not os.path.islink(dst):
            os.remove(src)
            return
        target = os.readlink(src)
        if os.path.islink(dst) or os.path.exists(dst):
            os.remove(dst)
        os.symlink(target, dst)
        os.remove(src)
    else:
        shutil.move(src, dst)


def _fix_merged_usr(rootfs, dirname):
    """If /dirname is a directory (not symlink), merge into /usr/dirname."""
    path = os.path.join(rootfs, dirname)
    usr_path = os.path.join(rootfs, "usr", dirname)
    if os.path.isdir(path) and not os.path.islink(path):
        os.makedirs(usr_path, exist_ok=True)
        for item in os.listdir(path):
            src = os.path.join(path, item)
            dst = os.path.join(usr_path, item)
            if os.path.exists(dst) or os.path.islink(dst):
                if os.path.isdir(src) and not os.path.islink(src):
                    shutil.copytree(src, dst, symlinks=True, dirs_exist_ok=True)
                    continue
            _move_preserving_symlinks(src, dst)
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
            if not os.path.exists(dst) and not os.path.islink(dst):
                _move_preserving_symlinks(src, dst)
            elif os.path.islink(src) or os.path.isfile(src):
                _move_preserving_symlinks(src, dst)
        shutil.rmtree(usr_sbin)
        os.symlink("bin", usr_sbin)
        print("Merged /usr/sbin into /usr/bin (systemd merged-bin layout)")

    # Update /sbin symlink for consistency
    sbin = os.path.join(rootfs, "sbin")
    if os.path.islink(sbin):
        os.remove(sbin)
        os.symlink("usr/bin", sbin)




def _fix_elf_interpreters(rootfs):
    """Patch ELF interpreter paths from padded build-host paths to /lib64/ld-linux-x86-64.so.2.

    The toolchain pads PT_INTERP with leading slashes followed by the
    absolute build-host path.  Inside the rootfs these are invalid.
    Rewrite to the standard /lib64/ld-linux-x86-64.so.2.

    NOTE: x86-64 only (ELF64 LE, ld-linux-x86-64.so.2).  aarch64 would
    need /lib/ld-linux-aarch64.so.1 and a different ELF class check.
    """
    TARGET_INTERP = b"/lib64/ld-linux-x86-64.so.2"
    patched = 0
    for dirpath, _, filenames in os.walk(rootfs):
        for name in filenames:
            fpath = os.path.join(dirpath, name)
            if os.path.islink(fpath) or not os.path.isfile(fpath):
                continue
            try:
                with open(fpath, "rb") as f:
                    data = bytearray(f.read())
                if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
                    continue
                # Only patch files with build-host interp paths
                if b"/home/" not in data and b"buck-out" not in data:
                    continue

                e_phoff = struct.unpack_from("<Q", data, 32)[0]
                e_phentsize = struct.unpack_from("<H", data, 54)[0]
                e_phnum = struct.unpack_from("<H", data, 56)[0]

                modified = False
                for i in range(e_phnum):
                    off = e_phoff + i * e_phentsize
                    p_type = struct.unpack_from("<I", data, off)[0]
                    if p_type != 3:  # PT_INTERP
                        continue
                    p_offset = struct.unpack_from("<Q", data, off + 8)[0]
                    p_filesz = struct.unpack_from("<Q", data, off + 32)[0]
                    interp = data[p_offset:p_offset + p_filesz]
                    if b"ld-linux" not in interp:
                        continue
                    if len(TARGET_INTERP) + 1 <= p_filesz:
                        data[p_offset:p_offset + len(TARGET_INTERP)] = TARGET_INTERP
                        data[p_offset + len(TARGET_INTERP)] = 0
                        for j in range(p_offset + len(TARGET_INTERP) + 1,
                                       p_offset + p_filesz):
                            data[j] = 0
                        modified = True
                    break

                if modified:
                    orig_mode = os.stat(fpath).st_mode
                    os.chmod(fpath, stat.S_IRUSR | stat.S_IWUSR)
                    with open(fpath, "wb") as f:
                        f.write(data)
                    os.chmod(fpath, orig_mode)
                    patched += 1
            except (PermissionError, OSError, struct.error):
                pass

    if patched:
        print(f"Patched ELF interpreter in {patched} files")


def _sanitize_rpath(rootfs):
    """Strip build-host paths from ELF RPATH/RUNPATH entries in the rootfs.

    GCC specs inject DT_RPATH with absolute build-machine paths. These are
    invalid inside the rootfs and cause glibc's ld.so to assert-fail
    (info[DT_RPATH] == NULL) on itself.  Walk every ELF file and null out
    build-host RPATH entries, keeping only $ORIGIN-relative paths.
    """
    sanitized = 0
    for dirpath, _, filenames in os.walk(rootfs):
        for name in filenames:
            fpath = os.path.join(dirpath, name)
            if os.path.islink(fpath) or not os.path.isfile(fpath):
                continue
            try:
                with open(fpath, "rb") as f:
                    data = bytearray(f.read())
                if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
                    continue
                if b"/home/" not in data and b"buck-out" not in data:
                    continue

                e_shoff = struct.unpack_from("<Q", data, 40)[0]
                e_shentsize = struct.unpack_from("<H", data, 58)[0]
                e_shnum = struct.unpack_from("<H", data, 60)[0]

                SHT_DYNAMIC = 6
                SHT_STRTAB = 3
                dyn_offset = dyn_size = dyn_link = 0
                strtab_sections = {}
                for i in range(e_shnum):
                    sh_off = e_shoff + i * e_shentsize
                    sh_type = struct.unpack_from("<I", data, sh_off + 4)[0]
                    sh_offset = struct.unpack_from("<Q", data, sh_off + 24)[0]
                    sh_size = struct.unpack_from("<Q", data, sh_off + 32)[0]
                    sh_link = struct.unpack_from("<I", data, sh_off + 40)[0]
                    if sh_type == SHT_DYNAMIC:
                        dyn_offset = sh_offset
                        dyn_size = sh_size
                        dyn_link = sh_link
                    if sh_type == SHT_STRTAB:
                        strtab_sections[i] = sh_offset

                if not dyn_offset or dyn_link not in strtab_sections:
                    continue

                dynstr_offset = strtab_sections[dyn_link]

                DT_RPATH = 15
                DT_RUNPATH = 29
                DT_SONAME = 14
                modified = False
                has_valid_rpath = False

                # Detect ld.so by SONAME — it must not have any rpath tag
                is_ldso = False
                pos = dyn_offset
                while pos < dyn_offset + dyn_size:
                    d_tag = struct.unpack_from("<q", data, pos)[0]
                    if d_tag == 0:
                        break
                    if d_tag == DT_SONAME:
                        d_val = struct.unpack_from("<Q", data, pos + 8)[0]
                        so = dynstr_offset + d_val
                        se = data.find(0, so)
                        if se > so:
                            soname = data[so:se].decode("ascii", errors="replace")
                            if "ld-linux" in soname:
                                is_ldso = True
                    pos += 16

                pos = dyn_offset
                while pos < dyn_offset + dyn_size:
                    d_tag = struct.unpack_from("<q", data, pos)[0]
                    d_val = struct.unpack_from("<Q", data, pos + 8)[0]
                    if d_tag == 0:  # DT_NULL
                        break
                    if d_tag in (DT_RPATH, DT_RUNPATH):
                        str_off = dynstr_offset + d_val
                        str_end = data.find(0, str_off)
                        if str_end < 0:
                            pos += 16
                            continue
                        rpath = data[str_off:str_end].decode("ascii", errors="replace")
                        parts = rpath.split(":")
                        clean = [p for p in parts
                                 if p and "/home/" not in p and "buck-out" not in p]
                        new_rpath = ":".join(clean)
                        new_bytes = new_rpath.encode("ascii")
                        old_len = str_end - str_off
                        if len(new_bytes) <= old_len:
                            data[str_off:str_off + len(new_bytes)] = new_bytes
                            for j in range(len(new_bytes), old_len):
                                data[str_off + j] = 0
                            modified = True
                        # Track which entries have empty vs non-empty cleaned paths
                        if new_rpath:
                            has_valid_rpath = True
                    pos += 16

                # Convert DT_RPATH to DT_RUNPATH (glibc asserts DT_RPATH
                # must not exist).  Remove entries with empty cleaned paths.
                new_entries = []
                removed = 0
                needs_rewrite = False
                pos = dyn_offset
                while pos < dyn_offset + dyn_size:
                    d_tag = struct.unpack_from("<q", data, pos)[0]
                    d_val = struct.unpack_from("<Q", data, pos + 8)[0]
                    if d_tag == 0:  # DT_NULL
                        break
                    if d_tag in (DT_RPATH, DT_RUNPATH):
                        if is_ldso or not has_valid_rpath:
                            # ld.so must not have any rpath tag, or
                            # no valid paths remain — remove entry entirely
                            removed += 1
                            needs_rewrite = True
                        else:
                            # Keep entry, but convert DT_RPATH to DT_RUNPATH
                            if d_tag == DT_RPATH:
                                needs_rewrite = True
                            new_entries.append((DT_RUNPATH, d_val))
                    else:
                        new_entries.append((d_tag, d_val))
                    pos += 16
                if needs_rewrite:
                    pos = dyn_offset
                    for tag, val in new_entries:
                        struct.pack_into("<q", data, pos, tag)
                        struct.pack_into("<Q", data, pos + 8, val)
                        pos += 16
                    # Fill removed slots with DT_NULL
                    for _ in range(removed):
                        struct.pack_into("<q", data, pos, 0)
                        struct.pack_into("<Q", data, pos + 8, 0)
                        pos += 16
                    modified = True

                if modified:
                    orig_mode = os.stat(fpath).st_mode
                    os.chmod(fpath, stat.S_IRUSR | stat.S_IWUSR)
                    with open(fpath, "wb") as f:
                        f.write(data)
                    os.chmod(fpath, orig_mode)
                    sanitized += 1
            except (PermissionError, OSError, struct.error):
                pass

    if sanitized:
        print(f"Sanitized RPATH in {sanitized} ELF files")


# Binaries that require setuid (mode 4755) for correct operation.
# These lose setuid during unprivileged rootfs assembly.
_SETUID_BINARIES = frozenset({
    "usr/bin/chfn",
    "usr/bin/chsh",
    "usr/bin/gpasswd",
    "usr/bin/mount",
    "usr/bin/newgrp",
    "usr/bin/passwd",
    "usr/bin/su",
    "usr/bin/umount",
})

# Per-file permission overrides: path -> (mode, uid, gid).
# dbus-daemon-launch-helper must be setuid root, group messagebus (4750).
_PERMISSION_OVERRIDES = {
    "usr/libexec/dbus-daemon-launch-helper": (0o4750, 0, 101),
}


def _create_rootfs_tarball(rootfs, tarball_path):
    """Pack assembled rootfs as a tarball with correct ownership and permissions.

    All entries are set to root:root (uid/gid 0).  Setuid bits are applied
    to known binaries, and per-file permission overrides are applied for
    helpers that need specific ownership (e.g. dbus-daemon-launch-helper).
    Runs unprivileged using Python's tarfile module.
    """
    # Parse /etc/group to resolve group names for uname/gname fields.
    gid_to_name = {0: "root"}
    group_file = os.path.join(rootfs, "etc", "group")
    if os.path.isfile(group_file):
        with open(group_file) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    parts = line.split(":")
                    if len(parts) >= 3:
                        gid_to_name[int(parts[2])] = parts[0]

    def _fixup(tarinfo):
        tarinfo.uid = 0
        tarinfo.gid = 0
        tarinfo.uname = "root"
        tarinfo.gname = "root"
        rel = tarinfo.name
        if rel.startswith("./"):
            rel = rel[2:]
        if rel in _PERMISSION_OVERRIDES and tarinfo.isreg():
            mode, uid, gid = _PERMISSION_OVERRIDES[rel]
            tarinfo.mode = mode
            tarinfo.uid = uid
            tarinfo.gid = gid
            tarinfo.gname = gid_to_name.get(gid, str(gid))
        elif rel in _SETUID_BINARIES and tarinfo.isreg():
            tarinfo.mode = 0o4755
        return tarinfo

    with tarfile.open(tarball_path, "w") as tar:
        tar.add(rootfs, arcname=".", filter=_fixup)

    print(f"Packed rootfs tarball: {tarball_path}")


def main():
    _host_path = os.environ.get("PATH", "")

    parser = argparse.ArgumentParser(description="Assemble root filesystem")
    parser.add_argument("--output-dir", default=None)
    parser.add_argument("--output-tarball", default=None,
                        help="Pack the rootfs as a tarball with correct ownership")
    parser.add_argument("--package-dir", action="append", dest="package_dirs",
                        default=[], help="Package directory to merge (repeatable)")
    parser.add_argument("--prefix-list", default=None,
                        help="File with package prefix paths (one per line, from tset projection)")
    parser.add_argument("--version", default="1")
    parser.add_argument("--manifest-output", default=None,
                        help="Write content manifest for cache invalidation")
    add_path_args(parser)
    args = parser.parse_args()

    if not args.output_dir and not args.output_tarball:
        parser.error("--output-dir or --output-tarball is required")

    _tarball_workdir = None
    if args.output_tarball:
        if args.output_dir:
            rootfs = os.path.abspath(args.output_dir)
        else:
            _tarball_workdir = tempfile.mkdtemp(prefix="rootfs-")
            rootfs = _tarball_workdir
    else:
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

    # Restore setuid/setgid bits lost during tar merge
    _restore_setuid(rootfs)

    # Fix merged-usr layout
    _fix_merged_usr(rootfs, "bin")
    _fix_merged_usr(rootfs, "sbin")
    _fix_merged_usr(rootfs, "lib")
    _fix_merged_usr(rootfs, "lib64")

    # Ensure /lib64 exists for ELF interpreter resolution
    lib64 = os.path.join(rootfs, "lib64")
    if not os.path.exists(lib64) and not os.path.islink(lib64):
        usr_lib64 = os.path.join(rootfs, "usr", "lib64")
        if os.path.isdir(usr_lib64):
            os.symlink("usr/lib64", lib64)

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

    # Fix ELF interpreter paths (build-host -> /lib64/ld-linux-x86-64.so.2)
    _fix_elf_interpreters(rootfs)

    # Strip build-host RPATH from ELF binaries
    _sanitize_rpath(rootfs)

    # Run ldconfig — use the rootfs's own ldconfig (from glibc) since the
    # host ldconfig may not be on the hermetic PATH.
    ld_so_conf = os.path.join(rootfs, "etc", "ld.so.conf")
    _ldconfig = shutil.which("ldconfig", path=env.get("PATH", ""))
    if not _ldconfig:
        # Fall back to the rootfs's own copy
        for _candidate in (os.path.join(rootfs, "usr", "sbin", "ldconfig"),
                           os.path.join(rootfs, "usr", "bin", "ldconfig"),
                           os.path.join(rootfs, "sbin", "ldconfig")):
            if os.path.isfile(_candidate):
                _ldconfig = _candidate
                break
    if os.path.isfile(ld_so_conf) and _ldconfig:
        subprocess.run([_ldconfig, "-r", rootfs], env=env,
                        capture_output=True)

    # Compute manifest if requested (before tarball packing)
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

    # Pack tarball if requested
    if args.output_tarball:
        _create_rootfs_tarball(rootfs, os.path.abspath(args.output_tarball))
        if _tarball_workdir:
            shutil.rmtree(_tarball_workdir)


if __name__ == "__main__":
    main()
