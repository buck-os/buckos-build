#!/usr/bin/env python3
"""Build an initramfs cpio archive from a rootfs directory.

Replaces the inline bash in initramfs.bzl.  Handles init script injection,
lib64 path fixups, and cpio+compression.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

from _env import add_path_args, clean_env, setup_path


def _merge_tree(src, dst):
    """Recursively merge src into dst, preserving existing files."""
    for item in os.listdir(src):
        s = os.path.join(src, item)
        d = os.path.join(dst, item)
        if os.path.isdir(s) and not os.path.islink(s):
            if os.path.isdir(d) and not os.path.islink(d):
                _merge_tree(s, d)
            elif not os.path.exists(d):
                shutil.move(s, d)
        elif not os.path.exists(d):
            shutil.move(s, d)


def _fix_lib64(staging):
    """Fix aarch64 library paths — merge lib64 into lib."""
    for prefix in ("", "usr/"):
        lib64 = os.path.join(staging, prefix + "lib64")
        lib = os.path.join(staging, prefix + "lib")
        if os.path.isdir(lib64) and not os.path.islink(lib64):
            os.makedirs(lib, exist_ok=True)
            _merge_tree(lib64, lib)
            shutil.rmtree(lib64)
            os.symlink("lib", lib64)


_DEFAULT_INIT = """\
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
[ -x /etc/init.d/rcS ] && /etc/init.d/rcS
exec /bin/sh
"""


def main():
    _host_path = os.environ.get("PATH", "")

    parser = argparse.ArgumentParser(description="Build initramfs cpio archive")
    parser.add_argument("--rootfs-dir", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--init-path", default="/sbin/init")
    parser.add_argument("--init-script", default=None,
                        help="Path to custom init script to install")
    parser.add_argument("--compression", default="gz",
                        choices=["gz", "xz", "lz4", "zstd"])
    add_path_args(parser)
    args = parser.parse_args()

    env = clean_env()
    setup_path(args, env, _host_path)
    output = os.path.abspath(args.output)
    os.makedirs(os.path.dirname(output) or ".", exist_ok=True)

    compress_cmds = {
        "gz": ["gzip", "-9"],
        "xz": ["xz", "-9", "--check=crc32"],
        "lz4": ["lz4", "-l", "-9"],
        "zstd": ["zstd", "-19"],
    }

    with tempfile.TemporaryDirectory() as staging:
        # Copy rootfs
        rootfs_dir = os.path.abspath(args.rootfs_dir)
        if os.path.isdir(rootfs_dir):
            subprocess.check_call(
                ["cp", "-a", rootfs_dir + "/.", staging],
                env=env,
            )

        # Fix lib64 paths
        _fix_lib64(staging)

        # Symlink non-standard lib dirs into standard locations so
        # ld.so finds them without RPATH (glibc 2.42 rejects RPATH
        # for init/PID1).
        for _subdir in ("usr/lib/systemd",):
            _sd = os.path.join(staging, _subdir)
            if os.path.isdir(_sd):
                _target = os.path.join(staging, "usr/lib64")
                os.makedirs(_target, exist_ok=True)
                for _f in os.listdir(_sd):
                    if _f.endswith(".so") or ".so." in _f:
                        _src = os.path.join(_sd, _f)
                        _dst = os.path.join(_target, _f)
                        if not os.path.exists(_dst):
                            os.symlink(os.path.join("..", "lib", "systemd", _f), _dst)

        # Create /etc/ld.so.conf listing non-standard lib dirs.
        _ldconf = os.path.join(staging, "etc", "ld.so.conf")
        os.makedirs(os.path.dirname(_ldconf), exist_ok=True)
        with open(_ldconf, "w") as f:
            f.write("/usr/lib/systemd\n/usr/lib\n/lib\n")

        # Rewrite padded sysroot ELF interpreters to standard path.
        # Buckos-built binaries have padded interpreters pointing to
        # build-time sysroot paths — those don't exist inside the
        # initramfs.  The padded path is longer than the standard one,
        # so we can overwrite it in-place (null-padded).
        _std_interp = b"/lib64/ld-linux-x86-64.so.2\x00"
        _std_rpath = b"/lib64:/usr/lib64:/usr/lib\x00"
        _sysroot_marker = b"buck-out/"
        import struct
        for dirpath, _, filenames in os.walk(staging):
            for fname in filenames:
                fpath = os.path.join(dirpath, fname)
                if os.path.islink(fpath):
                    continue
                try:
                    with open(fpath, "rb") as f:
                        data = f.read()
                    if data[:4] != b"\x7fELF" or len(data) < 64:
                        continue
                    if data[4] != 2:  # not 64-bit
                        continue
                    little = data[5] == 1
                    fmt = "<" if little else ">"
                    phoff = struct.unpack(fmt + "Q", data[32:40])[0]
                    phentsize = struct.unpack(fmt + "H", data[54:56])[0]
                    phnum = struct.unpack(fmt + "H", data[56:58])[0]
                    modified = False
                    mdata = bytearray(data)
                    for i in range(phnum):
                        off = phoff + i * phentsize
                        if off + 40 > len(mdata):
                            break
                        p_type = struct.unpack(fmt + "I", mdata[off:off+4])[0]
                        if p_type == 3:  # PT_INTERP
                            p_offset = struct.unpack(fmt + "Q", mdata[off+8:off+16])[0]
                            p_filesz = struct.unpack(fmt + "Q", mdata[off+32:off+40])[0]
                            if p_filesz >= len(_std_interp):
                                mdata[p_offset:p_offset+p_filesz] = _std_interp.ljust(p_filesz, b"\x00")
                                modified = True
                    # Rewrite DT_RPATH/DT_RUNPATH by parsing the
                    # .dynamic section.  Find PT_DYNAMIC to locate it,
                    # then find DT_STRTAB for the string table, then
                    # find DT_RPATH/DT_RUNPATH entries and rewrite
                    # their strings.
                    dyn_off = dyn_sz = 0
                    loads = []
                    for i in range(phnum):
                        off = phoff + i * phentsize
                        if off + 48 > len(mdata):
                            break
                        p_type = struct.unpack(fmt + "I", mdata[off:off+4])[0]
                        if p_type == 2:  # PT_DYNAMIC
                            dyn_off = struct.unpack(fmt + "Q", mdata[off+8:off+16])[0]
                            dyn_sz = struct.unpack(fmt + "Q", mdata[off+32:off+40])[0]
                        elif p_type == 1:  # PT_LOAD
                            p_vaddr = struct.unpack(fmt + "Q", mdata[off+16:off+24])[0]
                            p_off = struct.unpack(fmt + "Q", mdata[off+8:off+16])[0]
                            p_memsz = struct.unpack(fmt + "Q", mdata[off+40:off+48])[0]
                            loads.append((p_vaddr, p_off, p_memsz))
                    if dyn_off and dyn_sz:
                        def vaddr_to_off(va):
                            for v, o, s in loads:
                                if v <= va < v + s:
                                    return o + (va - v)
                            return va  # fallback
                        strtab_va = 0
                        rpath_entries = []  # (d_tag, d_val, dyn_entry_off)
                        j = dyn_off
                        while j < dyn_off + dyn_sz:
                            if j + 16 > len(mdata):
                                break
                            d_tag = struct.unpack(fmt + "q", mdata[j:j+8])[0]
                            d_val = struct.unpack(fmt + "Q", mdata[j+8:j+16])[0]
                            if d_tag == 0:  # DT_NULL
                                break
                            elif d_tag == 5:  # DT_STRTAB
                                strtab_va = d_val
                            elif d_tag in (15, 29):  # DT_RPATH=15, DT_RUNPATH=29
                                rpath_entries.append((d_tag, d_val, j))
                            j += 16
                        if strtab_va and rpath_entries:
                            strtab_file = vaddr_to_off(strtab_va)
                            has_runpath = any(t == 29 for t, _, _ in rpath_entries)
                            for d_tag, str_off, entry_off in rpath_entries:
                                # glibc asserts DT_RPATH==NULL when DT_RUNPATH
                                # exists.  Zero out DT_RPATH if DT_RUNPATH present.
                                # glibc 2.42 rejects both DT_RPATH and
                                # DT_RUNPATH for init (AT_SECURE).
                                # Remove them entirely — initramfs has
                                # libs in standard paths (/lib64 etc.)
                                # that ld.so finds by default.
                                struct.pack_into(fmt + "q", mdata, entry_off, 0x70000000)
                                struct.pack_into(fmt + "Q", mdata, entry_off + 8, 0)
                                modified = True
                    if modified:
                        os.chmod(fpath, os.stat(fpath).st_mode | 0o200)
                        with open(fpath, "wb") as f:
                            f.write(mdata)
                except (PermissionError, OSError):
                    pass

        # Install custom init script if provided
        init_script = args.init_script
        if init_script and os.path.isfile(init_script):
            init_dest = os.path.join(staging, args.init_path.lstrip("/"))
            os.makedirs(os.path.dirname(init_dest), exist_ok=True)
            shutil.copy2(init_script, init_dest)
            os.chmod(init_dest, 0o755)
        elif not os.path.exists(os.path.join(staging, args.init_path.lstrip("/"))):
            # Generate a default init if none exists
            busybox = os.path.join(staging, "bin", "busybox")
            if os.path.isfile(busybox):
                sbin = os.path.join(staging, "sbin")
                os.makedirs(sbin, exist_ok=True)
                init_path = os.path.join(sbin, "init")
                if not os.path.exists(init_path):
                    os.symlink("/bin/busybox", init_path)
            elif os.path.isfile(os.path.join(staging, "bin", "sh")):
                sbin = os.path.join(staging, "sbin")
                os.makedirs(sbin, exist_ok=True)
                init_path = os.path.join(sbin, "init")
                with open(init_path, "w") as f:
                    f.write(_DEFAULT_INIT)
                os.chmod(init_path, 0o755)

        # Create /init symlink
        init_link = os.path.join(staging, "init")
        if not os.path.exists(init_link):
            init_target = os.path.join(staging, args.init_path.lstrip("/"))
            if os.path.exists(init_target):
                os.symlink(args.init_path, init_link)
            elif os.path.isfile(os.path.join(staging, "sbin", "init")):
                os.symlink("/sbin/init", init_link)
            elif os.path.isfile(os.path.join(staging, "bin", "sh")):
                with open(init_link, "w") as f:
                    f.write(_DEFAULT_INIT)
                os.chmod(init_link, 0o755)

        # Build cpio archive
        find_proc = subprocess.Popen(
            ["find", ".", "-print0"],
            cwd=staging, stdout=subprocess.PIPE, env=env,
        )
        cpio_proc = subprocess.Popen(
            ["cpio", "--null", "-o", "-H", "newc", "--quiet"],
            cwd=staging, stdin=find_proc.stdout,
            stdout=subprocess.PIPE, env=env,
        )
        find_proc.stdout.close()

        compress_proc = subprocess.Popen(
            compress_cmds[args.compression],
            stdin=cpio_proc.stdout,
            stdout=open(output, "wb"), env=env,
        )
        cpio_proc.stdout.close()

        compress_proc.communicate()
        cpio_proc.wait()
        find_proc.wait()

        if find_proc.returncode != 0:
            print(f"error: find exited with code {find_proc.returncode}", file=sys.stderr)
            sys.exit(1)
        if cpio_proc.returncode != 0:
            print(f"error: cpio exited with code {cpio_proc.returncode}", file=sys.stderr)
            sys.exit(1)
        if compress_proc.returncode != 0:
            print(f"error: compression exited with code {compress_proc.returncode}", file=sys.stderr)
            sys.exit(1)

    print(f"Created initramfs: {output}")


if __name__ == "__main__":
    main()
