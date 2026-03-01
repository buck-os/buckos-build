#!/usr/bin/env python3
"""ISO image creation helper.

Creates bootable ISO images from kernel, initramfs, and optional rootfs.
Supports hybrid BIOS+EFI boot, EFI-only, and aarch64 targets.

Replaces the inline bash that was previously embedded in the iso_image
Buck2 rule.  Follows the same helper pattern as build_helper.py and
install_helper.py (argparse, --hermetic-path, PROJECT_ROOT).
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

from _env import sanitize_global_env


def _resolve_path(path):
    """Resolve relative Buck2 artifact paths to absolute."""
    if path and not os.path.isabs(path) and os.path.exists(path):
        return os.path.abspath(path)
    return path


def _find_tool(name):
    """Find a tool on PATH, return its absolute path or None."""
    return shutil.which(name)


def _run(cmd, **kwargs):
    """Run a command, printing it on failure."""
    result = subprocess.run(cmd, **kwargs)
    if result.returncode != 0:
        print(f"error: command failed (rc={result.returncode}): {cmd}",
              file=sys.stderr)
        sys.exit(result.returncode)
    return result


_DEFAULT_SYSLINUX_DIRS = [
    "/usr/lib/syslinux/bios", "/usr/share/syslinux",
    "/usr/lib/ISOLINUX", "/usr/lib/syslinux",
]


def _find_syslinux_file(name, search_dirs=None):
    """Search syslinux paths for a file.

    When search_dirs is provided, search only those dirs.  Otherwise
    fall back to the default host paths (for --allow-host-path mode).
    """
    dirs = search_dirs if search_dirs else _DEFAULT_SYSLINUX_DIRS
    for d in dirs:
        p = os.path.join(d, name)
        if os.path.isfile(p):
            return p
    return None


def _setup_bios(work, search_dirs=None):
    """Copy isolinux/syslinux files for BIOS boot."""
    isolinux_dir = os.path.join(work, "isolinux")
    os.makedirs(isolinux_dir, exist_ok=True)

    isolinux_bin = _find_syslinux_file("isolinux.bin", search_dirs)
    if not isolinux_bin:
        print("warning: isolinux.bin not found, BIOS boot unavailable",
              file=sys.stderr)
        return False

    shutil.copy2(isolinux_bin, isolinux_dir)
    for mod in ["ldlinux.c32", "menu.c32", "libutil.c32", "libcom32.c32"]:
        src = _find_syslinux_file(mod, search_dirs)
        if src:
            shutil.copy2(src, isolinux_dir)
    return True


def _write_isolinux_cfg(work, kernel_args):
    """Write isolinux/syslinux config for BIOS boot."""
    cfg = os.path.join(work, "isolinux", "isolinux.cfg")
    os.makedirs(os.path.dirname(cfg), exist_ok=True)
    with open(cfg, "w") as f:
        f.write(f"""\
DEFAULT buckos
TIMEOUT 50
PROMPT 1

LABEL buckos
    MENU LABEL BuckOS Linux
    LINUX /boot/vmlinuz
    INITRD /boot/initramfs.img
    APPEND {kernel_args}

LABEL safe
    MENU LABEL BuckOS Linux (Safe Mode - no graphics)
    LINUX /boot/vmlinuz
    INITRD /boot/initramfs.img
    APPEND {kernel_args} nomodeset

LABEL recovery
    MENU LABEL BuckOS Linux (recovery mode)
    LINUX /boot/vmlinuz
    INITRD /boot/initramfs.img
    APPEND {kernel_args} single
""")


def _write_grub_cfg(work, kernel_args, arch):
    """Write GRUB config for EFI boot."""
    cfg = os.path.join(work, "boot", "grub", "grub.cfg")
    os.makedirs(os.path.dirname(cfg), exist_ok=True)

    if arch == "aarch64":
        console = "console=ttyAMA0,115200 console=tty0"
        content = f"""\
# GRUB configuration for BuckOS ISO (aarch64)
serial --unit=0 --speed=115200
terminal_input serial console
terminal_output serial console

set timeout=5
set default=0

menuentry "BuckOS Linux" {{
    linux /boot/vmlinuz {kernel_args} {console}
    initrd /boot/initramfs.img
}}

menuentry "BuckOS Linux (recovery mode)" {{
    linux /boot/vmlinuz {kernel_args} {console} single
    initrd /boot/initramfs.img
}}

menuentry "BuckOS Linux (serial console only)" {{
    linux /boot/vmlinuz {kernel_args} console=ttyAMA0,115200
    initrd /boot/initramfs.img
}}
"""
    else:
        content = f"""\
# GRUB configuration for BuckOS ISO
set timeout=5
set default=0

menuentry "BuckOS Linux" {{
    linux /boot/vmlinuz {kernel_args}
    initrd /boot/initramfs.img
}}

menuentry "BuckOS Linux (Safe Mode - no graphics)" {{
    linux /boot/vmlinuz {kernel_args} nomodeset
    initrd /boot/initramfs.img
}}

menuentry "BuckOS Linux (Debug Mode)" {{
    linux /boot/vmlinuz {kernel_args} debug ignore_loglevel earlyprintk=vga,keep
    initrd /boot/initramfs.img
}}

menuentry "BuckOS Linux (recovery mode)" {{
    linux /boot/vmlinuz {kernel_args} single
    initrd /boot/initramfs.img
}}
"""
    with open(cfg, "w") as f:
        f.write(content)


def _setup_efi(work, arch):
    """Create EFI boot image (grub-mkimage + FAT image)."""
    if arch == "aarch64":
        efi_boot_file = "BOOTAA64.EFI"
        grub_format = "arm64-efi"
    else:
        efi_boot_file = "BOOTX64.EFI"
        grub_format = "x86_64-efi"

    efi_dir = os.path.join(work, "EFI", "BOOT")
    os.makedirs(efi_dir, exist_ok=True)

    # Find grub-mkimage (Fedora: grub2-mkimage, Debian: grub-mkimage)
    grub_mkimage = _find_tool("grub2-mkimage") or _find_tool("grub-mkimage")
    if not grub_mkimage:
        print("warning: grub-mkimage not found, EFI boot image not created",
              file=sys.stderr)
        return False

    # Write early config for ISO boot
    early_cfg = os.path.join(work, "boot", "grub", "early.cfg")
    with open(early_cfg, "w") as f:
        f.write("search --no-floppy --set=root --label BUCKOS_LIVE\n")
        f.write("set prefix=($root)/boot/grub\n")
        f.write("configfile $prefix/grub.cfg\n")

    efi_binary = os.path.join(efi_dir, efi_boot_file)
    grub_modules = [
        "part_gpt", "part_msdos", "fat", "iso9660", "normal", "boot",
        "linux", "configfile", "loopback", "chain", "efifwsetup",
        "efi_gop", "ls", "search", "search_label", "search_fs_uuid",
        "search_fs_file", "gfxterm", "gfxterm_background", "gfxterm_menu",
        "test", "all_video", "loadenv", "exfat", "ext2", "ntfs", "serial",
    ]

    result = subprocess.run(
        [grub_mkimage, "-o", efi_binary, "-O", grub_format,
         "-p", "/boot/grub", "-c", early_cfg] + grub_modules,
        capture_output=True,
    )
    if result.returncode != 0:
        print(f"warning: {grub_mkimage} failed: {result.stderr.decode()!s:.200}",
              file=sys.stderr)
        return False

    # Create FAT image for EFI boot catalog
    efi_img = os.path.join(work, "boot", "efi.img")
    _run(["dd", "if=/dev/zero", f"of={efi_img}", "bs=1M", "count=10"],
         capture_output=True)

    mkfs_vfat = _find_tool("mkfs.vfat")
    if mkfs_vfat:
        _run([mkfs_vfat, "-i", "0x42554B4F", efi_img], capture_output=True)
    else:
        mformat = _find_tool("mformat")
        if mformat:
            _run([mformat, "-i", efi_img, "-F", "::"], capture_output=True)
        else:
            print("warning: no FAT formatter found (mkfs.vfat or mformat)",
                  file=sys.stderr)
            return False

    mmd = _find_tool("mmd")
    mcopy = _find_tool("mcopy")
    if mmd and mcopy:
        _run([mmd, "-i", efi_img, "::/EFI", "::/EFI/BOOT"],
             capture_output=True)
        subprocess.run(
            [mcopy, "-i", efi_img, efi_binary, "::/EFI/BOOT/"],
            capture_output=True,
        )
    return True


def _apply_ima_xattrs(rootfs_work):
    """Convert .sig sidecar files to security.ima xattrs."""
    evmctl = _find_tool("evmctl")
    if not evmctl:
        return 0

    applied = 0
    for dirpath, _dirnames, filenames in os.walk(rootfs_work):
        for fname in filenames:
            if not fname.endswith(".sig"):
                continue
            sig_path = os.path.join(dirpath, fname)
            target = sig_path[:-4]  # strip .sig
            if not os.path.isfile(target):
                continue
            result = subprocess.run(
                [evmctl, "ima_setxattr", "--sigfile", sig_path, target],
                capture_output=True,
            )
            if result.returncode == 0:
                os.remove(sig_path)
                applied += 1
    if applied:
        print(f"Applied security.ima to {applied} files")
    return applied


def _create_squashfs(rootfs_dir, modules_dir, work):
    """Create squashfs from rootfs, optionally adding kernel modules."""
    mksquashfs = _find_tool("mksquashfs")
    if not mksquashfs:
        print("error: mksquashfs not found, cannot create live rootfs",
              file=sys.stderr)
        sys.exit(1)

    live_dir = os.path.join(work, "live")
    os.makedirs(live_dir, exist_ok=True)

    # Create working copy (Buck2 artifacts are read-only)
    rootfs_work = tempfile.mkdtemp()
    try:
        print("Copying rootfs to staging area...")
        shutil.copytree(rootfs_dir, rootfs_work, symlinks=True,
                        dirs_exist_ok=True)

        # Apply IMA signatures before squashfs creation
        _apply_ima_xattrs(rootfs_work)

        # Copy kernel modules if provided
        if modules_dir and os.path.isdir(modules_dir):
            print(f"Copying kernel modules from {modules_dir}...")
            mod_dest = os.path.join(rootfs_work, "lib", "modules")
            os.makedirs(mod_dest, exist_ok=True)
            shutil.copytree(modules_dir, mod_dest, symlinks=True,
                            dirs_exist_ok=True)

            # Run depmod
            depmod = _find_tool("depmod")
            if depmod:
                kvers = os.listdir(modules_dir)
                if kvers:
                    kver = kvers[0]
                    print(f"Running depmod for kernel {kver}...")
                    subprocess.run(
                        [depmod, "-b", rootfs_work, kver],
                        capture_output=True,
                    )

        squashfs_out = os.path.join(live_dir, "filesystem.squashfs")
        print("Creating squashfs...")
        _run([mksquashfs, rootfs_work, squashfs_out,
              "-comp", "xz", "-no-progress", "-all-root"])
    finally:
        shutil.rmtree(rootfs_work, ignore_errors=True)


def _pin_timestamps(work, epoch):
    """Set all file timestamps to SOURCE_DATE_EPOCH for reproducibility."""
    for dirpath, dirnames, filenames in os.walk(work, topdown=False):
        for name in filenames + dirnames:
            path = os.path.join(dirpath, name)
            try:
                os.utime(path, (epoch, epoch), follow_symlinks=False)
            except OSError:
                pass
    try:
        os.utime(work, (epoch, epoch))
    except OSError:
        pass


def _create_iso_xorriso(work, output, volume_label, boot_mode, search_dirs=None):
    """Create ISO using xorriso."""
    xorriso = _find_tool("xorriso")
    if not xorriso:
        return False

    has_bios = os.path.isfile(os.path.join(work, "isolinux", "isolinux.bin"))
    has_efi = os.path.isfile(os.path.join(work, "boot", "efi.img"))
    isohdpfx = _find_syslinux_file("isohdpfx.bin", search_dirs)

    cmd = [xorriso, "-as", "mkisofs", "-o", output, "-iso-level", "3"]

    if boot_mode == "bios" and has_bios:
        if isohdpfx:
            cmd += ["-isohybrid-mbr", isohdpfx]
        cmd += ["-c", "isolinux/boot.cat",
                "-b", "isolinux/isolinux.bin",
                "-no-emul-boot", "-boot-load-size", "4",
                "-boot-info-table"]

    elif boot_mode == "efi" and has_efi:
        cmd += ["-e", "boot/efi.img", "-no-emul-boot"]

    elif boot_mode == "hybrid":
        if has_bios and has_efi:
            if isohdpfx:
                cmd += ["-isohybrid-mbr", isohdpfx]
            cmd += ["-c", "isolinux/boot.cat",
                    "-b", "isolinux/isolinux.bin",
                    "-no-emul-boot", "-boot-load-size", "4",
                    "-boot-info-table",
                    "-eltorito-alt-boot",
                    "-e", "boot/efi.img",
                    "-no-emul-boot", "-isohybrid-gpt-basdat"]
        elif has_efi:
            cmd += ["-e", "boot/efi.img", "-no-emul-boot",
                    "-isohybrid-gpt-basdat"]
        elif has_bios:
            if isohdpfx:
                cmd += ["-isohybrid-mbr", isohdpfx]
            cmd += ["-c", "isolinux/boot.cat",
                    "-b", "isolinux/isolinux.bin",
                    "-no-emul-boot", "-boot-load-size", "4",
                    "-boot-info-table"]
        else:
            print("warning: no BIOS or EFI boot images, creating non-bootable ISO",
                  file=sys.stderr)
            cmd += ["-J", "-R"]

    cmd += ["-V", volume_label, work]
    _run(cmd)
    return True


def _create_iso_fallback(work, output, volume_label):
    """Create ISO using genisoimage or mkisofs as fallback."""
    tool = _find_tool("genisoimage") or _find_tool("mkisofs")
    if not tool:
        return False

    cmd = [tool, "-o", output,
           "-b", "isolinux/isolinux.bin",
           "-c", "isolinux/boot.cat",
           "-no-emul-boot", "-boot-load-size", "4",
           "-boot-info-table",
           "-V", volume_label, "-J", "-R", work]
    _run(cmd)
    return True


def main():
    _host_path = os.environ.get("PATH", "")

    parser = argparse.ArgumentParser(description="Create bootable ISO image")
    parser.add_argument("--kernel", required=True,
                        help="Path to kernel image (bzImage/vmlinuz)")
    parser.add_argument("--initramfs", required=True,
                        help="Path to initramfs image")
    parser.add_argument("--output", required=True,
                        help="Path for output ISO file")
    parser.add_argument("--rootfs", default=None,
                        help="Path to rootfs directory (creates squashfs live image)")
    parser.add_argument("--modules", default=None,
                        help="Path to kernel modules directory")
    parser.add_argument("--boot-mode", default="hybrid",
                        choices=["hybrid", "efi", "bios"],
                        help="Boot mode (default: hybrid)")
    parser.add_argument("--volume-label", default="BUCKOS",
                        help="ISO volume label (default: BUCKOS)")
    parser.add_argument("--kernel-args", default="quiet",
                        help="Kernel command line arguments")
    parser.add_argument("--arch", default="x86_64",
                        choices=["x86_64", "aarch64"],
                        help="Target architecture (default: x86_64)")
    parser.add_argument("--hermetic-path", action="append",
                        dest="hermetic_path", default=[],
                        help="Set PATH to only these dirs (repeatable)")
    parser.add_argument("--allow-host-path", action="store_true",
                        help="Allow host PATH (bootstrap escape hatch)")
    parser.add_argument("--hermetic-empty", action="store_true",
                        help="Start with empty PATH (populated by --path-prepend)")
    parser.add_argument("--path-prepend", action="append", dest="path_prepend", default=[],
                        help="Directory to prepend to PATH (repeatable, resolved to absolute)")
    parser.add_argument("--syslinux-dir", action="append", dest="syslinux_dirs", default=[],
                        help="Directory to search for syslinux files (repeatable)")
    args = parser.parse_args()

    sanitize_global_env()

    # Resolve Buck2 artifact paths
    kernel = _resolve_path(args.kernel)
    initramfs = _resolve_path(args.initramfs)
    output = os.path.abspath(args.output)
    rootfs = _resolve_path(args.rootfs) if args.rootfs else None
    modules = _resolve_path(args.modules) if args.modules else None

    # Hermetic PATH setup
    if args.hermetic_path:
        resolved = [os.path.abspath(p) if not os.path.isabs(p) else p
                    for p in args.hermetic_path]
        os.environ["PATH"] = ":".join(resolved)
        # Derive LD_LIBRARY_PATH from hermetic bin dirs so dynamically
        # linked tools (e.g. cross-ar needing libzstd) find their libs.
        _lib_dirs = []
        for _bp in resolved:
            _parent = os.path.dirname(_bp)
            for _ld in ("lib", "lib64"):
                _d = os.path.join(_parent, _ld)
                if os.path.isdir(_d):
                    _lib_dirs.append(_d)
        if _lib_dirs:
            _existing = os.environ.get("LD_LIBRARY_PATH", "")
            os.environ["LD_LIBRARY_PATH"] = ":".join(_lib_dirs) + (":" + _existing if _existing else "")
        _py_paths = []
        for _bp in resolved:
            _parent = os.path.dirname(_bp)
            for _pattern in ("lib/python*/site-packages", "lib/python*/dist-packages",
                             "lib64/python*/site-packages", "lib64/python*/dist-packages"):
                for _sp in __import__("glob").glob(os.path.join(_parent, _pattern)):
                    if os.path.isdir(_sp):
                        _py_paths.append(_sp)
        if _py_paths:
            _existing = os.environ.get("PYTHONPATH", "")
            os.environ["PYTHONPATH"] = ":".join(_py_paths) + (":" + _existing if _existing else "")
    elif args.hermetic_empty:
        os.environ["PATH"] = ""
    elif args.allow_host_path:
        os.environ["PATH"] = _host_path
    else:
        print("error: build requires --hermetic-path, --hermetic-empty, or --allow-host-path",
              file=sys.stderr)
        sys.exit(1)
    if args.path_prepend:
        prepend = ":".join(os.path.abspath(p) for p in args.path_prepend)
        os.environ["PATH"] = prepend + (":" + os.environ["PATH"] if os.environ.get("PATH") else "")
        _dep_lib_dirs = []
        for _bp in args.path_prepend:
            _parent = os.path.dirname(os.path.abspath(_bp))
            for _ld in ("lib", "lib64"):
                _d = os.path.join(_parent, _ld)
                if os.path.isdir(_d):
                    _dep_lib_dirs.append(_d)
        if _dep_lib_dirs:
            _existing = os.environ.get("LD_LIBRARY_PATH", "")
            os.environ["LD_LIBRARY_PATH"] = ":".join(_dep_lib_dirs) + (":" + _existing if _existing else "")

    epoch = int(os.environ.get("SOURCE_DATE_EPOCH", "315576000"))

    # Resolve syslinux search dirs (empty list → use default host paths)
    syslinux_dirs = [os.path.abspath(d) for d in args.syslinux_dirs] or None

    # aarch64 forces EFI (no BIOS boot on ARM)
    boot_mode = args.boot_mode
    if args.arch == "aarch64" and boot_mode == "bios":
        boot_mode = "efi"

    # Create staging directory
    work = tempfile.mkdtemp()
    try:
        os.makedirs(os.path.join(work, "boot", "grub"), exist_ok=True)

        # Copy kernel and initramfs
        shutil.copy2(kernel, os.path.join(work, "boot", "vmlinuz"))
        shutil.copy2(initramfs, os.path.join(work, "boot", "initramfs.img"))

        # Write boot configs
        _write_grub_cfg(work, args.kernel_args, args.arch)
        if boot_mode in ("bios", "hybrid"):
            _write_isolinux_cfg(work, args.kernel_args)

        # Create squashfs if rootfs provided
        if rootfs and os.path.isdir(rootfs):
            _create_squashfs(rootfs, modules, work)

        # Set up boot methods
        if boot_mode in ("bios", "hybrid"):
            _setup_bios(work, syslinux_dirs)
        if boot_mode in ("efi", "hybrid"):
            _setup_efi(work, args.arch)

        # Pin timestamps for reproducibility
        _pin_timestamps(work, epoch)

        # Create ISO
        print(f"Creating ISO image ({boot_mode} boot)...")
        if not _create_iso_xorriso(work, output, args.volume_label, boot_mode, syslinux_dirs):
            if not _create_iso_fallback(work, output, args.volume_label):
                print("error: no ISO creation tool found "
                      "(xorriso, genisoimage, or mkisofs required)",
                      file=sys.stderr)
                sys.exit(1)

        size = os.path.getsize(output)
        print(f"Created ISO image: {output} ({size / 1048576:.1f} MiB)")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
