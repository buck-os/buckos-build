"""
Image rules: iso_image, raw_disk_image, stage3_tarball.

Assembly rules that take rootfs/kernel/initramfs deps and produce images.
"""

load("//defs:providers.bzl", "KernelInfo", "Stage3Info")

def _get_kernel_image(dep):
    """Extract boot image from KernelInfo provider."""
    if KernelInfo not in dep:
        fail("kernel dep must provide KernelInfo")
    return dep[KernelInfo].bzimage

# =============================================================================
# RAW DISK IMAGE
# =============================================================================

def _raw_disk_image_impl(ctx: AnalysisContext) -> list[Provider]:
    """Create a raw disk image from a rootfs (for Cloud Hypervisor)."""
    image_file = ctx.actions.declare_output(ctx.attrs.name + ".raw")

    # Get rootfs directory
    rootfs_dir = ctx.attrs.rootfs[DefaultInfo].default_outputs[0]

    # Configuration
    size = ctx.attrs.size
    filesystem = ctx.attrs.filesystem
    label = ctx.attrs.label if ctx.attrs.label else ctx.attrs.name
    partition_table = ctx.attrs.partition_table

    # Build the script to create the disk image
    if partition_table:
        # GPT partition table with EFI system partition
        script_content = """#!/bin/bash
set -e

ROOTFS="$1"
OUTPUT="$2"
SIZE="{size}"
FS="{filesystem}"
LABEL="{label}"

echo "Creating raw disk image with GPT partition table..."
echo "  Size: $SIZE"
echo "  Filesystem: $FS"
echo "  Label: $LABEL"

# Create sparse file
truncate -s "$SIZE" "$OUTPUT"

# Create GPT partition table
# Partition 1: EFI System Partition (100M)
# Partition 2: Root filesystem (rest)
sgdisk -Z "$OUTPUT"
sgdisk -n 1:2048:+100M -t 1:EF00 -c 1:"EFI" "$OUTPUT"
sgdisk -n 2:0:0 -t 2:8300 -c 2:"$LABEL" "$OUTPUT"

# Get partition offsets
EFI_START=$((2048 * 512))
EFI_SIZE=$((100 * 1024 * 1024))
ROOT_START=$(($(sgdisk -p "$OUTPUT" | grep "^ *2" | awk '{{print $2}}') * 512))

# Create filesystems using loop device
LOOP=$(losetup --find --show --partscan "$OUTPUT")
trap "losetup -d $LOOP" EXIT

# Wait for partitions to appear
sleep 1

# Format EFI partition
mkfs.vfat -F 32 -n EFI "${{LOOP}}p1"

# Format root partition
case "$FS" in
    ext4)
        mkfs.ext4 -F -L "$LABEL" "${{LOOP}}p2"
        ;;
    xfs)
        mkfs.xfs -f -L "$LABEL" "${{LOOP}}p2"
        ;;
    btrfs)
        mkfs.btrfs -f -L "$LABEL" "${{LOOP}}p2"
        ;;
    *)
        echo "Unsupported filesystem: $FS"
        exit 1
        ;;
esac

# Mount and copy rootfs
MOUNT_DIR=$(mktemp -d)
trap "umount -R $MOUNT_DIR 2>/dev/null || true; rm -rf $MOUNT_DIR; losetup -d $LOOP" EXIT

mount "${{LOOP}}p2" "$MOUNT_DIR"
mkdir -p "$MOUNT_DIR/boot/efi"
mount "${{LOOP}}p1" "$MOUNT_DIR/boot/efi"

# Copy rootfs
cp -a "$ROOTFS"/* "$MOUNT_DIR"/ || true

# Apply IMA .sig sidecars as security.ima xattrs and clean up
if command -v evmctl >/dev/null 2>&1; then
    _ima_applied=0
    while IFS= read -r -d '' _sig; do
        _target="${{_sig%.sig}}"
        [ -f "$_target" ] || continue
        evmctl ima_setxattr --sigfile "$_sig" "$_target" >/dev/null 2>&1 && {{
            rm -f "$_sig"
            _ima_applied=$((_ima_applied + 1))
        }}
    done < <(find "$MOUNT_DIR" -name '*.sig' -print0 2>/dev/null)
    [ "$_ima_applied" -gt 0 ] && echo "Applied security.ima to $_ima_applied files"
fi

# Unmount
sync
umount "$MOUNT_DIR/boot/efi"
umount "$MOUNT_DIR"

echo "Disk image created: $OUTPUT"
""".format(
            size = size,
            filesystem = filesystem,
            label = label,
        )
    else:
        # Simple raw image without partition table
        script_content = """#!/bin/bash
set -e

ROOTFS="$1"
OUTPUT="$2"
SIZE="{size}"
FS="{filesystem}"
LABEL="{label}"

echo "Creating raw disk image..."
echo "  Size: $SIZE"
echo "  Filesystem: $FS"
echo "  Label: $LABEL"

# Create sparse file
truncate -s "$SIZE" "$OUTPUT"

# Create filesystem directly on the image
case "$FS" in
    ext4)
        mkfs.ext4 -F -L "$LABEL" "$OUTPUT"
        ;;
    xfs)
        mkfs.xfs -f -L "$LABEL" "$OUTPUT"
        ;;
    btrfs)
        mkfs.btrfs -f -L "$LABEL" "$OUTPUT"
        ;;
    *)
        echo "Unsupported filesystem: $FS"
        exit 1
        ;;
esac

# Mount and copy rootfs
MOUNT_DIR=$(mktemp -d)
trap "umount $MOUNT_DIR 2>/dev/null || true; rm -rf $MOUNT_DIR" EXIT

mount -o loop "$OUTPUT" "$MOUNT_DIR"

# Copy rootfs
cp -a "$ROOTFS"/* "$MOUNT_DIR"/ || true

# Apply IMA .sig sidecars as security.ima xattrs and clean up
if command -v evmctl >/dev/null 2>&1; then
    _ima_applied=0
    while IFS= read -r -d '' _sig; do
        _target="${{_sig%.sig}}"
        [ -f "$_target" ] || continue
        evmctl ima_setxattr --sigfile "$_sig" "$_target" >/dev/null 2>&1 && {{
            rm -f "$_sig"
            _ima_applied=$((_ima_applied + 1))
        }}
    done < <(find "$MOUNT_DIR" -name '*.sig' -print0 2>/dev/null)
    [ "$_ima_applied" -gt 0 ] && echo "Applied security.ima to $_ima_applied files"
fi

# Unmount
sync
umount "$MOUNT_DIR"

echo "Disk image created: $OUTPUT"
""".format(
            size = size,
            filesystem = filesystem,
            label = label,
        )

    script = ctx.actions.write("create_disk.sh", script_content, is_executable = True)

    # Note: This requires root/fakeroot to create the filesystem
    # In practice, this would be run with appropriate privileges
    # Build the command properly with cmd_args for Buck2
    cmd = cmd_args()
    cmd.add("bash")
    cmd.add(script)
    cmd.add(rootfs_dir)
    cmd.add(image_file.as_output())

    ctx.actions.run(
        cmd,
        category = "disk_image",
        identifier = ctx.attrs.name,
    )

    return [DefaultInfo(default_output = image_file)]

_raw_disk_image_rule = rule(
    impl = _raw_disk_image_impl,
    attrs = {
        "rootfs": attrs.dep(),
        "size": attrs.string(default = "2G"),
        "filesystem": attrs.string(default = "ext4"),  # ext4, xfs, btrfs
        "label": attrs.option(attrs.string(), default = None),
        "partition_table": attrs.bool(default = False),  # True for GPT with EFI
        "labels": attrs.list(attrs.string(), default = []),
    },
)

def raw_disk_image(labels = [], **kwargs):
    _raw_disk_image_rule(
        labels = labels,
        **kwargs
    )

# =============================================================================
# ISO IMAGE
# =============================================================================

def _iso_image_impl(ctx: AnalysisContext) -> list[Provider]:
    """Create a bootable ISO image from kernel, initramfs, and optional rootfs."""
    iso_file = ctx.actions.declare_output(ctx.attrs.name + ".iso")

    # Get kernel and initramfs
    kernel_image = _get_kernel_image(ctx.attrs.kernel)
    initramfs_file = ctx.attrs.initramfs[DefaultInfo].default_outputs[0]

    # Modules directory: explicit dep > KernelInfo.modules_dir
    if ctx.attrs.modules:
        modules_dir = ctx.attrs.modules[DefaultInfo].default_outputs[0]
    elif KernelInfo in ctx.attrs.kernel:
        modules_dir = ctx.attrs.kernel[KernelInfo].modules_dir
    else:
        modules_dir = None

    # Optional rootfs for live system
    rootfs_dir = None
    if ctx.attrs.rootfs:
        rootfs_dir = ctx.attrs.rootfs[DefaultInfo].default_outputs[0]

    # Boot mode configuration
    boot_mode = ctx.attrs.boot_mode
    volume_label = ctx.attrs.volume_label
    kernel_args = ctx.attrs.kernel_args if ctx.attrs.kernel_args else "quiet"
    arch = ctx.attrs.arch if ctx.attrs.arch else "x86_64"

    # Architecture-specific EFI configuration
    if arch == "aarch64":
        efi_boot_file = "BOOTAA64.EFI"
        grub_format = "arm64-efi"
        # ARM64 doesn't use BIOS boot, force EFI if BIOS was requested
        if boot_mode == "bios":
            boot_mode = "efi"
    else:
        efi_boot_file = "BOOTX64.EFI"
        grub_format = "x86_64-efi"

    # GRUB configuration for EFI boot
    # Add serial console settings for aarch64 (needed for QEMU headless testing)
    if arch == "aarch64":
        grub_cfg = """
# GRUB configuration for BuckOS ISO (aarch64)
# Serial console for headless boot (QEMU virt uses ttyAMA0)
serial --unit=0 --speed=115200
terminal_input serial console
terminal_output serial console

set timeout=5
set default=0

menuentry "BuckOS Linux" {{
    linux /boot/vmlinuz {kernel_args} init=/init console=ttyAMA0,115200 console=tty0
    initrd /boot/initramfs.img
}}

menuentry "BuckOS Linux (recovery mode)" {{
    linux /boot/vmlinuz {kernel_args} init=/init console=ttyAMA0,115200 console=tty0 single
    initrd /boot/initramfs.img
}}

menuentry "BuckOS Linux (serial console only)" {{
    linux /boot/vmlinuz {kernel_args} init=/init console=ttyAMA0,115200
    initrd /boot/initramfs.img
}}
""".format(kernel_args = kernel_args)
    else:
        grub_cfg = """
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
""".format(kernel_args = kernel_args)

    # Isolinux configuration for BIOS boot
    isolinux_cfg = """
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
""".format(kernel_args = kernel_args)

    # Determine if we should include squashfs rootfs
    include_rootfs = "yes" if rootfs_dir else ""

    script = ctx.actions.write(
        "create_iso.sh",
        """#!/bin/bash
set -e

# Deterministic build environment — prevent ccache interference and
# pin timestamps so identical inputs always produce identical ISOs.
export CCACHE_DISABLE=1
export SOURCE_DATE_EPOCH="${{SOURCE_DATE_EPOCH:-315576000}}"

ISO_OUT="$1"
KERNEL_SRC="$2"
INITRAMFS="$3"
ROOTFS_DIR="$4"
MODULES_DIR="$5"
BOOT_MODE="{boot_mode}"
VOLUME_LABEL="{volume_label}"
EFI_BOOT_FILE="{efi_boot_file}"
GRUB_FORMAT="{grub_format}"
TARGET_ARCH="{arch}"

# Create ISO working directory
WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT

mkdir -p "$WORK/boot"
mkdir -p "$WORK/boot/grub"
mkdir -p "$WORK/isolinux"
mkdir -p "$WORK/EFI/BOOT"

# Kernel image comes from KernelInfo.bzimage — always a file
cp "$KERNEL_SRC" "$WORK/boot/vmlinuz"
cp "$INITRAMFS" "$WORK/boot/initramfs.img"

# Create GRUB configuration
cat > "$WORK/boot/grub/grub.cfg" << 'GRUBCFG'
{grub_cfg}
GRUBCFG

# Create isolinux configuration
cat > "$WORK/isolinux/isolinux.cfg" << 'ISOCFG'
{isolinux_cfg}
ISOCFG

# Include rootfs as squashfs if provided
if [ -n "{include_rootfs}" ] && [ -d "$ROOTFS_DIR" ]; then
    echo "Creating squashfs from rootfs..."
    mkdir -p "$WORK/live"

    # Create a working copy of rootfs to add kernel modules
    ROOTFS_WORK=$(mktemp -d)
    cp -a "$ROOTFS_DIR/." "$ROOTFS_WORK/"

    # Apply IMA .sig sidecars as security.ima xattrs and clean up
    if command -v evmctl >/dev/null 2>&1; then
        _ima_applied=0
        while IFS= read -r -d '' _sig; do
            _target="${{_sig%.sig}}"
            [ -f "$_target" ] || continue
            evmctl ima_setxattr --sigfile "$_sig" "$_target" >/dev/null 2>&1 && {{
                rm -f "$_sig"
                _ima_applied=$((_ima_applied + 1))
            }}
        done < <(find "$ROOTFS_WORK" -name '*.sig' -print0 2>/dev/null)
        [ "$_ima_applied" -gt 0 ] && echo "Applied security.ima to $_ima_applied files"
    fi

    # Copy kernel modules to rootfs
    _MOD_SRC=""
    if [ -n "$MODULES_DIR" ] && [ -d "$MODULES_DIR" ]; then
        _MOD_SRC="$MODULES_DIR"
    fi
    if [ -n "$_MOD_SRC" ]; then
        echo "Copying kernel modules from $_MOD_SRC to rootfs..."
        mkdir -p "$ROOTFS_WORK/lib/modules"
        cp -a "$_MOD_SRC/." "$ROOTFS_WORK/lib/modules/"
        # Run depmod to generate modules.dep
        KVER=$(ls "$_MOD_SRC" | head -1)
        if [ -n "$KVER" ] && command -v depmod >/dev/null 2>&1; then
            echo "Running depmod for kernel $KVER..."
            depmod -b "$ROOTFS_WORK" "$KVER" 2>/dev/null || true
        fi
    fi

    if command -v mksquashfs >/dev/null 2>&1; then
        mksquashfs "$ROOTFS_WORK" "$WORK/live/filesystem.squashfs" -comp xz -no-progress -all-root
    else
        echo "Warning: mksquashfs not found, skipping rootfs inclusion"
    fi

    rm -rf "$ROOTFS_WORK"
fi

# Pin all file timestamps in the staging tree for reproducibility.
# xorriso, genisoimage, and mkisofs all record file mtimes in the ISO
# metadata.  Without this, identical content produces different ISOs.
find "$WORK" -exec touch -h -d @"$SOURCE_DATE_EPOCH" {{}} + 2>/dev/null || true

# Create the ISO image based on boot mode
echo "Creating ISO image with boot mode: $BOOT_MODE"

if [ "$BOOT_MODE" = "bios" ] || [ "$BOOT_MODE" = "hybrid" ]; then
    # Check for isolinux/syslinux
    ISOLINUX_BIN=""
    for path in /usr/lib/syslinux/bios/isolinux.bin /usr/share/syslinux/isolinux.bin /usr/lib/ISOLINUX/isolinux.bin; do
        if [ -f "$path" ]; then
            ISOLINUX_BIN="$path"
            break
        fi
    done

    if [ -n "$ISOLINUX_BIN" ]; then
        cp "$ISOLINUX_BIN" "$WORK/isolinux/"

        # Copy ldlinux.c32 if available
        LDLINUX=""
        for path in /usr/lib/syslinux/bios/ldlinux.c32 /usr/share/syslinux/ldlinux.c32 /usr/lib/syslinux/ldlinux.c32; do
            if [ -f "$path" ]; then
                LDLINUX="$path"
                break
            fi
        done
        [ -n "$LDLINUX" ] && cp "$LDLINUX" "$WORK/isolinux/"
    fi
fi

# Create ISO using xorriso (preferred) or genisoimage
if command -v xorriso >/dev/null 2>&1; then
    case "$BOOT_MODE" in
        bios)
            ISOHDPFX=""
            for mbr in /usr/lib/syslinux/bios/isohdpfx.bin /usr/share/syslinux/isohdpfx.bin; do
                if [ -f "$mbr" ]; then ISOHDPFX="$mbr"; break; fi
            done
            xorriso -as mkisofs \\
                -o "$ISO_OUT" \\
                -iso-level 3 \\
                ${{ISOHDPFX:+-isohybrid-mbr "$ISOHDPFX"}} \\
                -c isolinux/boot.cat \\
                -b isolinux/isolinux.bin \\
                -no-emul-boot \\
                -boot-load-size 4 \\
                -boot-info-table \\
                -V "$VOLUME_LABEL" \\
                "$WORK"
            ;;
        efi)
            # Create EFI boot image
            mkdir -p "$WORK/EFI/BOOT"
            GRUB_MKIMAGE=""
            if command -v grub2-mkimage >/dev/null 2>&1; then
                GRUB_MKIMAGE="grub2-mkimage"
            elif command -v grub-mkimage >/dev/null 2>&1; then
                GRUB_MKIMAGE="grub-mkimage"
            fi
            if [ -n "$GRUB_MKIMAGE" ]; then
                # Create early config to search for ISO and load main config
                cat > "$WORK/boot/grub/early.cfg" << 'EARLYCFG'
search --no-floppy --set=root --label BUCKOS_LIVE
set prefix=($root)/boot/grub
configfile $prefix/grub.cfg
EARLYCFG
                $GRUB_MKIMAGE -o "$WORK/EFI/BOOT/$EFI_BOOT_FILE" -O $GRUB_FORMAT -p /boot/grub \\
                    -c "$WORK/boot/grub/early.cfg" \\
                    part_gpt part_msdos fat iso9660 normal boot linux configfile loopback chain \\
                    efifwsetup efi_gop ls search search_label search_fs_uuid search_fs_file \\
                    gfxterm gfxterm_background gfxterm_menu test all_video loadenv exfat ext2 ntfs serial \\
                    2>/dev/null || echo "Warning: $GRUB_MKIMAGE failed"
            else
                echo "Warning: neither grub-mkimage nor grub2-mkimage found"
            fi

            # Create EFI boot image file
            dd if=/dev/zero of="$WORK/boot/efi.img" bs=1M count=10
            if command -v mkfs.vfat >/dev/null 2>&1; then
                mkfs.vfat -i 0x42554B4F "$WORK/boot/efi.img"
            elif command -v mformat >/dev/null 2>&1; then
                mformat -i "$WORK/boot/efi.img" -F ::
            fi
            mmd -i "$WORK/boot/efi.img" ::/EFI ::/EFI/BOOT
            mcopy -i "$WORK/boot/efi.img" "$WORK/EFI/BOOT/$EFI_BOOT_FILE" ::/EFI/BOOT/ 2>/dev/null || true

            xorriso -as mkisofs \\
                -o "$ISO_OUT" \\
                -iso-level 3 \\
                -e boot/efi.img \\
                -no-emul-boot \\
                -V "$VOLUME_LABEL" \\
                "$WORK"
            ;;
        hybrid|*)
            # Hybrid BIOS+EFI boot
            # Create EFI boot image
            mkdir -p "$WORK/EFI/BOOT"
            GRUB_MKIMAGE=""
            if command -v grub2-mkimage >/dev/null 2>&1; then
                GRUB_MKIMAGE="grub2-mkimage"
            elif command -v grub-mkimage >/dev/null 2>&1; then
                GRUB_MKIMAGE="grub-mkimage"
            fi
            if [ -n "$GRUB_MKIMAGE" ]; then
                # Create early config to search for ISO and load main config
                cat > "$WORK/boot/grub/early.cfg" << 'EARLYCFG'
search --no-floppy --set=root --label BUCKOS_LIVE
set prefix=($root)/boot/grub
configfile $prefix/grub.cfg
EARLYCFG
                $GRUB_MKIMAGE -o "$WORK/EFI/BOOT/$EFI_BOOT_FILE" -O $GRUB_FORMAT -p /boot/grub \\
                    -c "$WORK/boot/grub/early.cfg" \\
                    part_gpt part_msdos fat iso9660 normal boot linux configfile loopback chain \\
                    efifwsetup efi_gop ls search search_label search_fs_uuid search_fs_file \\
                    gfxterm gfxterm_background gfxterm_menu test all_video loadenv exfat ext2 ntfs serial \\
                    2>/dev/null || echo "Warning: $GRUB_MKIMAGE failed"
            else
                echo "Warning: neither grub-mkimage nor grub2-mkimage found"
            fi

            # Create EFI boot image file
            dd if=/dev/zero of="$WORK/boot/efi.img" bs=1M count=10
            if command -v mkfs.vfat >/dev/null 2>&1; then
                mkfs.vfat -i 0x42554B4F "$WORK/boot/efi.img"
            elif command -v mformat >/dev/null 2>&1; then
                mformat -i "$WORK/boot/efi.img" -F ::
            else
                echo "Warning: No FAT formatter found (mkfs.vfat or mformat)"
            fi
            if command -v mmd >/dev/null 2>&1; then
                mmd -i "$WORK/boot/efi.img" ::/EFI ::/EFI/BOOT
                mcopy -i "$WORK/boot/efi.img" "$WORK/EFI/BOOT/$EFI_BOOT_FILE" ::/EFI/BOOT/ 2>/dev/null || true
            fi

            # Build ISO - detect available boot methods
            ISOHDPFX=""
            for mbr in /usr/lib/syslinux/bios/isohdpfx.bin /usr/share/syslinux/isohdpfx.bin; do
                if [ -f "$mbr" ]; then ISOHDPFX="$mbr"; break; fi
            done

            HAS_BIOS=false
            if [ -f "$WORK/isolinux/isolinux.bin" ]; then
                HAS_BIOS=true
            fi

            HAS_EFI=false
            if [ -f "$WORK/boot/efi.img" ]; then
                HAS_EFI=true
            fi

            if $HAS_BIOS && $HAS_EFI; then
                # Full hybrid: BIOS + EFI
                xorriso -as mkisofs \\
                    -o "$ISO_OUT" \\
                    -iso-level 3 \\
                    ${{ISOHDPFX:+-isohybrid-mbr "$ISOHDPFX"}} \\
                    -c isolinux/boot.cat \\
                    -b isolinux/isolinux.bin \\
                    -no-emul-boot \\
                    -boot-load-size 4 \\
                    -boot-info-table \\
                    -eltorito-alt-boot \\
                    -e boot/efi.img \\
                    -no-emul-boot \\
                    -isohybrid-gpt-basdat \\
                    -V "$VOLUME_LABEL" \\
                    "$WORK"
            elif $HAS_EFI; then
                # EFI only
                xorriso -as mkisofs \\
                    -o "$ISO_OUT" \\
                    -iso-level 3 \\
                    -e boot/efi.img \\
                    -no-emul-boot \\
                    -isohybrid-gpt-basdat \\
                    -V "$VOLUME_LABEL" \\
                    "$WORK"
            elif $HAS_BIOS; then
                # BIOS only
                xorriso -as mkisofs \\
                    -o "$ISO_OUT" \\
                    -iso-level 3 \\
                    ${{ISOHDPFX:+-isohybrid-mbr "$ISOHDPFX"}} \\
                    -c isolinux/boot.cat \\
                    -b isolinux/isolinux.bin \\
                    -no-emul-boot \\
                    -boot-load-size 4 \\
                    -boot-info-table \\
                    -V "$VOLUME_LABEL" \\
                    "$WORK"
            else
                # No bootloader available, create data-only ISO
                echo "Warning: No BIOS or EFI boot images found, creating non-bootable ISO"
                xorriso -as mkisofs \\
                    -o "$ISO_OUT" \\
                    -iso-level 3 \\
                    -V "$VOLUME_LABEL" \\
                    -J -R \\
                    "$WORK"
            fi
            ;;
    esac
elif command -v genisoimage >/dev/null 2>&1; then
    genisoimage \\
        -o "$ISO_OUT" \\
        -b isolinux/isolinux.bin \\
        -c isolinux/boot.cat \\
        -no-emul-boot \\
        -boot-load-size 4 \\
        -boot-info-table \\
        -V "$VOLUME_LABEL" \\
        -J -R \\
        "$WORK"
elif command -v mkisofs >/dev/null 2>&1; then
    mkisofs \\
        -o "$ISO_OUT" \\
        -b isolinux/isolinux.bin \\
        -c isolinux/boot.cat \\
        -no-emul-boot \\
        -boot-load-size 4 \\
        -boot-info-table \\
        -V "$VOLUME_LABEL" \\
        -J -R \\
        "$WORK"
else
    echo "Error: No ISO creation tool found (xorriso, genisoimage, or mkisofs required)"
    exit 1
fi

echo "Created ISO image: $ISO_OUT"
ls -lh "$ISO_OUT"
""".format(
            boot_mode = boot_mode,
            volume_label = volume_label,
            grub_cfg = grub_cfg,
            isolinux_cfg = isolinux_cfg,
            include_rootfs = include_rootfs,
            efi_boot_file = efi_boot_file,
            grub_format = grub_format,
            arch = arch,
        ),
        is_executable = True,
    )

    rootfs_arg = rootfs_dir if rootfs_dir else ""
    modules_arg = modules_dir if modules_dir else ""

    cmd = cmd_args([
        "bash",
        script,
        iso_file.as_output(),
        kernel_image,
        initramfs_file,
        rootfs_arg,
        modules_arg,
    ])

    # Write version to a file that contributes to action cache key
    # This ensures bumping the version forces an ISO rebuild
    version_key = ctx.actions.write(
        "version_key.txt",
        "version={}\n".format(ctx.attrs.version),
    )
    cmd.add(cmd_args(hidden = [version_key]))

    ctx.actions.run(
        cmd,
        category = "iso",
        identifier = ctx.attrs.name,
    )

    return [DefaultInfo(default_output = iso_file)]

_iso_image_rule = rule(
    impl = _iso_image_impl,
    attrs = {
        "kernel": attrs.dep(),
        "initramfs": attrs.dep(),
        "modules": attrs.option(attrs.dep(), default = None),
        "rootfs": attrs.option(attrs.dep(), default = None),
        "boot_mode": attrs.string(default = "hybrid"),  # bios, efi, or hybrid
        "volume_label": attrs.string(default = "BUCKOS"),
        "kernel_args": attrs.string(default = "quiet"),
        "arch": attrs.string(default = "x86_64"),  # x86_64 or aarch64
        "version": attrs.string(default = "1"),  # Bump to invalidate cache
        "labels": attrs.list(attrs.string(), default = []),
    },
)

def iso_image(labels = [], **kwargs):
    _iso_image_rule(
        labels = labels,
        **kwargs
    )

# =============================================================================
# STAGE3 TARBALL
# =============================================================================
# Creates a stage3 tarball from a rootfs for distribution.
# Stage3 tarballs are self-contained root filesystems with a complete
# toolchain that can be used to bootstrap new BuckOS installations.

def _stage3_tarball_impl(ctx: AnalysisContext) -> list[Provider]:
    """Create a stage3 tarball from a rootfs with metadata."""

    # Determine compression settings
    compression = ctx.attrs.compression
    compress_opts = {
        "xz": ("-J", ".tar.xz", "xz -9 -T0"),
        "gz": ("-z", ".tar.gz", "gzip -9"),
        "zstd": ("--zstd", ".tar.zst", "zstd -19 -T0"),
    }

    if compression not in compress_opts:
        fail("Unsupported compression: {}. Use xz, gz, or zstd".format(compression))

    compress_flag, suffix, compress_cmd = compress_opts[compression]

    # Build tarball filename: stage3-{arch}-{variant}-{libc}-{date}.tar.{ext}
    arch = ctx.attrs.arch
    variant = ctx.attrs.variant
    libc = ctx.attrs.libc
    version = ctx.attrs.version

    tarball_basename = "stage3-{}-{}-{}".format(arch, variant, libc)
    if version:
        tarball_basename += "-" + version

    # Declare outputs
    tarball_file = ctx.actions.declare_output(tarball_basename + suffix)
    sha256_file = ctx.actions.declare_output(tarball_basename + suffix + ".sha256")
    contents_file = ctx.actions.declare_output(tarball_basename + ".CONTENTS.gz")

    # Get rootfs directory
    rootfs_dir = ctx.attrs.rootfs[DefaultInfo].default_outputs[0]

    # Create the stage3 assembly script
    script_content = '''#!/bin/bash
set -e

ROOTFS="$1"
TARBALL="$2"
SHA256_FILE="$3"
CONTENTS_FILE="$4"
ARCH="{arch}"
VARIANT="{variant}"
LIBC="{libc}"
VERSION="{version}"
BUILD_DATE=$(date -u +%Y%m%dT%H%M%SZ)
DATE_STAMP=$(date -u +%Y%m%d)

echo "Creating stage3 tarball..."
echo "  Architecture: $ARCH"
echo "  Variant: $VARIANT"
echo "  Libc: $LIBC"
echo "  Version: $VERSION"

# Create a working copy of rootfs to add metadata
WORKDIR=$(mktemp -d)
trap "rm -rf $WORKDIR" EXIT

# Copy rootfs to working directory
cp -a "$ROOTFS"/. "$WORKDIR/"

# Apply IMA .sig sidecars as security.ima xattrs and clean up
if command -v evmctl >/dev/null 2>&1; then
    _ima_applied=0
    while IFS= read -r -d '' _sig; do
        _target="${{_sig%.sig}}"
        [ -f "$_target" ] || continue
        evmctl ima_setxattr --sigfile "$_sig" "$_target" >/dev/null 2>&1 && {{
            rm -f "$_sig"
            _ima_applied=$((_ima_applied + 1))
        }}
    done < <(find "$WORKDIR" -name '*.sig' -print0 2>/dev/null)
    [ "$_ima_applied" -gt 0 ] && echo "Applied security.ima to $_ima_applied files"
fi

# Create metadata directory
mkdir -p "$WORKDIR/etc/buckos"

# Generate STAGE3_INFO file
cat > "$WORKDIR/etc/buckos/stage3-info" << EOF
# BuckOS Stage3 Information
# Generated: $BUILD_DATE

[stage3]
variant=$VARIANT
arch=$ARCH
libc=$LIBC
date=$DATE_STAMP
version=$VERSION

[build]
build_date=$BUILD_DATE

[packages]
# Package count will be updated after build
EOF

# Generate CONTENTS file (list of all files with types)
echo "Generating CONTENTS file..."
(
    cd "$WORKDIR"
    find . -mindepth 1 | sort | while read -r path; do
        # Remove leading ./
        relpath="${{path#./}}"
        if [ -L "$path" ]; then
            target=$(readlink "$path")
            echo "sym /$relpath -> $target"
        elif [ -d "$path" ]; then
            echo "dir /$relpath"
        elif [ -f "$path" ]; then
            # Get file hash
            hash=$(sha256sum "$path" 2>/dev/null | cut -d' ' -f1 || echo "0")
            echo "obj /$relpath $hash"
        fi
    done
) | gzip -9 > "$CONTENTS_FILE"

# Create the tarball
echo "Creating tarball with {compression} compression..."
(
    cd "$WORKDIR"
    # Use numeric owner to ensure reproducibility
    tar --numeric-owner --owner=0 --group=0 \\
        --xattrs \\
        --sort=name \\
        {compress_flag} \\
        -cf "$TARBALL" .
)

# Generate SHA256 checksum
echo "Generating SHA256 checksum..."
(
    cd "$(dirname "$TARBALL")"
    sha256sum "$(basename "$TARBALL")" > "$SHA256_FILE"
)

echo "Stage3 tarball created successfully!"
echo "  Tarball: $TARBALL"
echo "  Checksum: $SHA256_FILE"
echo "  Contents: $CONTENTS_FILE"
'''.format(
        arch = arch,
        variant = variant,
        libc = libc,
        version = version if version else "0.1",
        compression = compression,
        compress_flag = compress_flag,
    )

    script = ctx.actions.write("create_stage3.sh", script_content, is_executable = True)

    cmd = cmd_args([
        "bash",
        script,
        rootfs_dir,
        tarball_file.as_output(),
        sha256_file.as_output(),
        contents_file.as_output(),
    ])

    ctx.actions.run(
        cmd,
        category = "stage3",
        identifier = ctx.attrs.name,
    )

    return [
        DefaultInfo(default_outputs = [tarball_file, sha256_file, contents_file]),
        Stage3Info(
            tarball = tarball_file,
            checksum = sha256_file,
            contents = contents_file,
            arch = arch,
            variant = variant,
            libc = libc,
            version = version if version else "0.1",
        ),
    ]

_stage3_tarball_rule = rule(
    impl = _stage3_tarball_impl,
    attrs = {
        "rootfs": attrs.dep(),
        "variant": attrs.string(default = "base"),      # minimal, base, developer, complete
        "arch": attrs.string(default = "amd64"),        # amd64, arm64
        "libc": attrs.string(default = "glibc"),        # glibc, musl
        "compression": attrs.string(default = "xz"),    # xz, gz, zstd
        "version": attrs.string(default = ""),          # Optional version string
        "labels": attrs.list(attrs.string(), default = []),
    },
)

def stage3_tarball(labels = [], **kwargs):
    _stage3_tarball_rule(
        labels = labels,
        **kwargs
    )
