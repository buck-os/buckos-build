#!/bin/bash
# BuckOS Live CD/USB ISO Creation Script
# Creates a bootable hybrid ISO with BIOS and EFI support

set -e

# Configuration
ISO_OUT="${1:-buckos-live.iso}"
KERNEL_DIR="$2"
INITRAMFS="$3"
ROOTFS_DIR="$4"
INSTALLER_BIN="$5"
BOOT_MODE="${6:-hybrid}"
VOLUME_LABEL="${7:-BUCKOS_LIVE}"
KERNEL_ARGS="${8:-quiet splash}"

# Create working directory
WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT

echo "========================================"
echo "BuckOS Live ISO Creation"
echo "========================================"
echo "Output: $ISO_OUT"
echo "Boot Mode: $BOOT_MODE"
echo "Volume Label: $VOLUME_LABEL"
echo ""

# Create directory structure
mkdir -p "$WORK/boot/grub"
mkdir -p "$WORK/isolinux"
mkdir -p "$WORK/EFI/BOOT"
mkdir -p "$WORK/live"

# Find and copy kernel
echo "Copying kernel..."
KERNEL=""
for k in "$KERNEL_DIR/boot/vmlinuz"* "$KERNEL_DIR/boot/bzImage" "$KERNEL_DIR/vmlinuz"* \
         "$KERNEL_DIR/arch/x86/boot/bzImage" "$KERNEL_DIR/bzImage"; do
    if [ -f "$k" ]; then
        KERNEL="$k"
        break
    fi
done

if [ -z "$KERNEL" ]; then
    echo "Error: Cannot find kernel image in $KERNEL_DIR"
    echo "Contents of $KERNEL_DIR:"
    if command -v fd >/dev/null 2>&1; then
        fd --no-ignore --hidden '(vmlinuz|bzImage)' "$KERNEL_DIR" 2>/dev/null || ls -la "$KERNEL_DIR"
    else
        find "$KERNEL_DIR" -name "vmlinuz*" -o -name "bzImage" 2>/dev/null || ls -la "$KERNEL_DIR"
    fi
    exit 1
fi

cp "$KERNEL" "$WORK/boot/vmlinuz"
echo "Kernel: $KERNEL -> $WORK/boot/vmlinuz"

# Copy initramfs
echo "Copying initramfs..."
cp "$INITRAMFS" "$WORK/boot/initramfs.img"
echo "Initramfs: $INITRAMFS -> $WORK/boot/initramfs.img"

# Create squashfs from rootfs if provided
if [ -n "$ROOTFS_DIR" ] && [ -d "$ROOTFS_DIR" ]; then
    echo "Creating live filesystem squashfs..."

    # Create a staging directory for the live rootfs
    LIVE_ROOTFS=$(mktemp -d)
    trap "rm -rf $WORK $LIVE_ROOTFS" EXIT

    # Copy the rootfs
    cp -a "$ROOTFS_DIR"/* "$LIVE_ROOTFS"/ 2>/dev/null || true

    # Add installer if provided
    if [ -n "$INSTALLER_BIN" ] && [ -f "$INSTALLER_BIN" ]; then
        mkdir -p "$LIVE_ROOTFS/usr/bin"
        cp "$INSTALLER_BIN" "$LIVE_ROOTFS/usr/bin/buckos-installer"
        chmod 755 "$LIVE_ROOTFS/usr/bin/buckos-installer"
        echo "Added installer: $INSTALLER_BIN"

        # Create desktop shortcut
        mkdir -p "$LIVE_ROOTFS/usr/share/applications"
        cat > "$LIVE_ROOTFS/usr/share/applications/buckos-installer.desktop" << 'DESKTOP_EOF'
[Desktop Entry]
Type=Application
Name=Install BuckOS
GenericName=System Installer
Comment=Install BuckOS to your computer
Exec=pkexec /usr/bin/buckos-installer
Icon=system-software-install
Terminal=false
Categories=System;
Keywords=install;installer;setup;
X-KDE-StartupNotify=false
DESKTOP_EOF
    fi

    # Configure live system
    echo "Configuring live system..."

    # Create live user
    if [ -f "$LIVE_ROOTFS/etc/passwd" ]; then
        if ! grep -q "^live:" "$LIVE_ROOTFS/etc/passwd"; then
            echo "live:x:1000:1000:Live User:/home/live:/bin/bash" >> "$LIVE_ROOTFS/etc/passwd"
        fi
    fi

    if [ -f "$LIVE_ROOTFS/etc/group" ]; then
        if ! grep -q "^live:" "$LIVE_ROOTFS/etc/group"; then
            echo "live:x:1000:" >> "$LIVE_ROOTFS/etc/group"
        fi
        # Add live user to useful groups
        for grp in wheel audio video input; do
            if grep -q "^${grp}:" "$LIVE_ROOTFS/etc/group"; then
                sed -i "s/^${grp}:.*$/&,live/" "$LIVE_ROOTFS/etc/group" 2>/dev/null || true
            fi
        done
    fi

    if [ -f "$LIVE_ROOTFS/etc/shadow" ]; then
        if ! grep -q "^live:" "$LIVE_ROOTFS/etc/shadow"; then
            echo "live:*:19000:0:99999:7:::" >> "$LIVE_ROOTFS/etc/shadow"
        fi
    fi

    mkdir -p "$LIVE_ROOTFS/home/live"
    chmod 755 "$LIVE_ROOTFS/home/live"

    # Create os-release for live system
    cat > "$LIVE_ROOTFS/etc/os-release" << 'OSREL_EOF'
NAME="BuckOS Linux"
VERSION="0.1 Live"
ID=buckos
ID_LIKE=gentoo
PRETTY_NAME="BuckOS Linux 0.1 Live"
HOME_URL="https://github.com/buck-os/buckos-build"
VARIANT="Live"
VARIANT_ID=live
OSREL_EOF

    # Set live hostname
    echo "buckos-live" > "$LIVE_ROOTFS/etc/hostname"

    # Create squashfs
    if command -v mksquashfs >/dev/null 2>&1; then
        mksquashfs "$LIVE_ROOTFS" "$WORK/live/filesystem.squashfs" \
            -comp xz -Xbcj x86 -b 1M -no-progress
        echo "Created squashfs: $(ls -lh "$WORK/live/filesystem.squashfs" | awk '{print $5}')"
    else
        echo "Warning: mksquashfs not found, copying rootfs as tarball"
        tar -cf - -C "$LIVE_ROOTFS" . | xz -9 > "$WORK/live/filesystem.tar.xz"
    fi
fi

# Create GRUB configuration for EFI boot
cat > "$WORK/boot/grub/grub.cfg" << GRUB_EOF
# BuckOS Live System - GRUB Configuration
set timeout=10
set default=0

# Colors
set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

# Boot entries
menuentry "BuckOS Live" {
    linux /boot/vmlinuz $KERNEL_ARGS init=/sbin/init root=live:LABEL=$VOLUME_LABEL
    initrd /boot/initramfs.img
}

menuentry "BuckOS Live (Safe Mode)" {
    linux /boot/vmlinuz $KERNEL_ARGS init=/sbin/init root=live:LABEL=$VOLUME_LABEL nomodeset
    initrd /boot/initramfs.img
}

menuentry "BuckOS Live (Serial Console)" {
    linux /boot/vmlinuz $KERNEL_ARGS console=tty0 console=ttyS0,115200 init=/sbin/init root=live:LABEL=$VOLUME_LABEL
    initrd /boot/initramfs.img
}

menuentry "Boot from local disk" {
    chainloader +1
}
GRUB_EOF

# Create isolinux configuration for BIOS boot
cat > "$WORK/isolinux/isolinux.cfg" << ISOLINUX_EOF
# BuckOS Live System - ISOLINUX Configuration
DEFAULT live
TIMEOUT 100
PROMPT 1

UI menu.c32
MENU TITLE BuckOS Live System

LABEL live
    MENU LABEL BuckOS Live
    MENU DEFAULT
    LINUX /boot/vmlinuz
    INITRD /boot/initramfs.img
    APPEND $KERNEL_ARGS init=/sbin/init root=live:LABEL=$VOLUME_LABEL

LABEL safe
    MENU LABEL BuckOS Live (Safe Mode)
    LINUX /boot/vmlinuz
    INITRD /boot/initramfs.img
    APPEND $KERNEL_ARGS init=/sbin/init root=live:LABEL=$VOLUME_LABEL nomodeset

LABEL serial
    MENU LABEL BuckOS Live (Serial Console)
    LINUX /boot/vmlinuz
    INITRD /boot/initramfs.img
    APPEND $KERNEL_ARGS console=tty0 console=ttyS0,115200 init=/sbin/init root=live:LABEL=$VOLUME_LABEL

LABEL local
    MENU LABEL Boot from local disk
    LOCALBOOT 0
ISOLINUX_EOF

# Copy BIOS bootloader files
if [ "$BOOT_MODE" = "bios" ] || [ "$BOOT_MODE" = "hybrid" ]; then
    echo "Setting up BIOS boot..."
    ISOLINUX_BIN=""
    SYSLINUX_DIR=""
    for path in /usr/lib/syslinux/bios /usr/share/syslinux /usr/lib/ISOLINUX /usr/lib/syslinux; do
        if [ -f "$path/isolinux.bin" ]; then
            ISOLINUX_BIN="$path/isolinux.bin"
            SYSLINUX_DIR="$path"
            break
        fi
    done

    if [ -n "$ISOLINUX_BIN" ]; then
        cp "$ISOLINUX_BIN" "$WORK/isolinux/"
        echo "Copied isolinux.bin from $SYSLINUX_DIR"

        # Copy additional modules
        for mod in ldlinux.c32 menu.c32 libutil.c32 libcom32.c32; do
            if [ -f "$SYSLINUX_DIR/$mod" ]; then
                cp "$SYSLINUX_DIR/$mod" "$WORK/isolinux/"
            fi
        done
    else
        echo "Warning: isolinux.bin not found, BIOS boot may not work"
    fi
fi

# Create EFI bootloader
if [ "$BOOT_MODE" = "efi" ] || [ "$BOOT_MODE" = "hybrid" ]; then
    echo "Setting up EFI boot..."

    # Try to create GRUB EFI image
    if command -v grub-mkimage >/dev/null 2>&1; then
        grub-mkimage -o "$WORK/EFI/BOOT/BOOTX64.EFI" -O x86_64-efi -p /boot/grub \
            part_gpt part_msdos fat iso9660 normal boot linux configfile loopback chain \
            efifwsetup efi_gop efi_uga ls search search_label search_fs_uuid search_fs_file \
            gfxterm gfxterm_background test all_video loadenv exfat ext2 ntfs \
            2>/dev/null && echo "Created GRUB EFI image" || echo "Warning: grub-mkimage failed"
    elif [ -f /usr/lib/grub/x86_64-efi/grub.efi ]; then
        cp /usr/lib/grub/x86_64-efi/grub.efi "$WORK/EFI/BOOT/BOOTX64.EFI"
    fi

    # Create EFI boot image for ISO
    if command -v mkfs.vfat >/dev/null 2>&1; then
        dd if=/dev/zero of="$WORK/boot/efi.img" bs=1M count=16 2>/dev/null
        mkfs.vfat -F 12 "$WORK/boot/efi.img" >/dev/null

        if command -v mmd >/dev/null 2>&1 && command -v mcopy >/dev/null 2>&1; then
            mmd -i "$WORK/boot/efi.img" ::/EFI ::/EFI/BOOT
            mcopy -i "$WORK/boot/efi.img" "$WORK/boot/grub/grub.cfg" ::/EFI/BOOT/grub.cfg 2>/dev/null || true
            if [ -f "$WORK/EFI/BOOT/BOOTX64.EFI" ]; then
                mcopy -i "$WORK/boot/efi.img" "$WORK/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
            fi
            echo "Created EFI boot image"
        fi
    fi
fi

# Create ISO
echo ""
echo "Creating ISO image..."

if command -v xorriso >/dev/null 2>&1; then
    case "$BOOT_MODE" in
        bios)
            xorriso -as mkisofs \
                -o "$ISO_OUT" \
                -isohybrid-mbr /usr/lib/syslinux/bios/isohdpfx.bin 2>/dev/null || true \
                -c isolinux/boot.cat \
                -b isolinux/isolinux.bin \
                -no-emul-boot \
                -boot-load-size 4 \
                -boot-info-table \
                -V "$VOLUME_LABEL" \
                -J -R \
                "$WORK"
            ;;
        efi)
            xorriso -as mkisofs \
                -o "$ISO_OUT" \
                -e boot/efi.img \
                -no-emul-boot \
                -V "$VOLUME_LABEL" \
                -J -R \
                "$WORK"
            ;;
        hybrid|*)
            if [ -f "$WORK/isolinux/isolinux.bin" ]; then
                # Full hybrid boot (BIOS + EFI)
                ISOHDPFX=""
                for pfx in /usr/lib/syslinux/bios/isohdpfx.bin /usr/share/syslinux/isohdpfx.bin; do
                    if [ -f "$pfx" ]; then ISOHDPFX="$pfx"; break; fi
                done
                HYBRID_MBR=""
                if [ -n "$ISOHDPFX" ]; then
                    HYBRID_MBR="-isohybrid-mbr $ISOHDPFX"
                fi
                xorriso -as mkisofs \
                    -o "$ISO_OUT" \
                    $HYBRID_MBR \
                    -c isolinux/boot.cat \
                    -b isolinux/isolinux.bin \
                    -no-emul-boot \
                    -boot-load-size 4 \
                    -boot-info-table \
                    -eltorito-alt-boot \
                    -e boot/efi.img \
                    -no-emul-boot \
                    -isohybrid-gpt-basdat \
                    -V "$VOLUME_LABEL" \
                    -J -R \
                    "$WORK"
            else
                # EFI-only fallback (isolinux not available)
                echo "Warning: isolinux.bin not found, creating EFI-only ISO"
                xorriso -as mkisofs \
                    -o "$ISO_OUT" \
                    -e boot/efi.img \
                    -no-emul-boot \
                    -isohybrid-gpt-basdat \
                    -V "$VOLUME_LABEL" \
                    -J -R \
                    "$WORK"
            fi
            ;;
    esac
elif command -v genisoimage >/dev/null 2>&1; then
    genisoimage \
        -o "$ISO_OUT" \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -V "$VOLUME_LABEL" \
        -J -R \
        "$WORK"
else
    echo "Error: No ISO creation tool found (xorriso or genisoimage required)"
    exit 1
fi

echo ""
echo "========================================"
echo "ISO creation complete!"
echo "========================================"
ls -lh "$ISO_OUT"
echo ""
echo "To test with QEMU:"
echo "  qemu-system-x86_64 -cdrom $ISO_OUT -m 4G -enable-kvm"
echo ""
echo "To write to USB:"
echo "  sudo dd if=$ISO_OUT of=/dev/sdX bs=4M status=progress"
echo "========================================"
