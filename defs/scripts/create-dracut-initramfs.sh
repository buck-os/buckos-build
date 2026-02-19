#!/bin/bash
# Create initramfs using dracut with dmsquash-live module for live boot
# v3: Use host dracut with complete sysroot
set -e

KERNEL_DIR="$1"
DRACUT_DIR="$2"
ROOTFS_DIR="$3"
OUTPUT="$(realpath -m "$4")"
KVER="${5:-}"
COMPRESS="${6:-gzip}"

mkdir -p "$(dirname "$OUTPUT")"

# Create a merged sysroot for dracut to work with
SYSROOT=$(mktemp -d)
trap "rm -rf $SYSROOT" EXIT

echo "Creating merged sysroot for dracut..."

# Copy base rootfs (has systemd, udev, bash, coreutils, etc.)
cp -a "$ROOTFS_DIR"/* "$SYSROOT"/ 2>/dev/null || true

# Overlay dracut package
cp -a "$DRACUT_DIR"/* "$SYSROOT"/ 2>/dev/null || true

# Install kernel modules
mkdir -p "$SYSROOT/lib/modules"
if [ -d "$KERNEL_DIR/lib/modules" ]; then
    cp -a "$KERNEL_DIR/lib/modules"/* "$SYSROOT/lib/modules"/
elif [ -d "$KERNEL_DIR/modules" ]; then
    cp -a "$KERNEL_DIR/modules"/* "$SYSROOT/lib/modules"/
fi

# Find kernel version if not provided
if [ -z "$KVER" ]; then
    KVER=$(ls "$SYSROOT/lib/modules" 2>/dev/null | head -1)
fi

echo "Using kernel version: $KVER"

# Ensure kernel modules directory exists
if [ ! -d "$SYSROOT/lib/modules/$KVER" ]; then
    echo "WARNING: Kernel modules not found at $SYSROOT/lib/modules/$KVER"
    echo "Checking kernel dir structure..."
    ls -la "$KERNEL_DIR/" || true
    ls -la "$SYSROOT/lib/modules/" || true
    # Continue anyway - dracut might work without modules if they're built-in
fi

# Create dracut configuration for live boot
mkdir -p "$SYSROOT/etc/dracut.conf.d"
cat > "$SYSROOT/etc/dracut.conf.d/live.conf" << 'LIVECONF'
# Live boot configuration
hostonly="no"
hostonly_cmdline="no"

# Essential modules for live boot
add_dracutmodules+=" dmsquash-live livenet "

# Include overlay filesystem support
add_dracutmodules+=" overlayfs "

# Include systemd for proper init
add_dracutmodules+=" systemd systemd-initrd "

# Include block device and filesystem support
add_dracutmodules+=" rootfs-block dm "

# Include USB and common storage drivers
add_drivers+=" usb_storage uas xhci_hcd xhci_pci ehci_hcd ehci_pci "
add_drivers+=" ohci_hcd ohci_pci uhci_hcd "
add_drivers+=" sd_mod sr_mod cdrom "
add_drivers+=" ahci nvme "
add_drivers+=" loop squashfs overlay iso9660 "
add_drivers+=" virtio virtio_pci virtio_blk virtio_scsi "

# Include udev for device detection
add_dracutmodules+=" udev-rules "

# Don't include host-specific modules only
no_hostonly_default_device="yes"
LIVECONF

# Set compression in config
echo "compress=\"$COMPRESS\"" >> "$SYSROOT/etc/dracut.conf.d/live.conf"

echo "Running dracut to generate initramfs..."

# First, try using the host dracut with sysroot option if available
if command -v dracut >/dev/null 2>&1; then
    echo "Using host dracut with sysroot..."
    dracut \
        --verbose \
        --force \
        --no-hostonly \
        --sysroot "$SYSROOT" \
        --kver "$KVER" \
        --add "dmsquash-live" \
        --add "systemd systemd-initrd" \
        --add "rootfs-block" \
        --include "$SYSROOT/etc/dracut.conf.d/live.conf" "/etc/dracut.conf.d/live.conf" \
        "$OUTPUT" && {
            echo "Created initramfs with host dracut: $OUTPUT"
            ls -lh "$OUTPUT"
            exit 0
        }
    echo "Host dracut failed, trying fallback method..."
fi

echo "Creating initramfs manually with systemd..."

# Manual fallback - create initramfs with systemd as init
WORK=$(mktemp -d)

# Copy essential components
echo "Copying base filesystem..."
mkdir -p "$WORK"/{bin,sbin,usr/bin,usr/sbin,usr/lib,lib,lib64,etc,proc,sys,dev,run,tmp,var}

# Copy systemd
if [ -d "$SYSROOT/usr/lib/systemd" ]; then
    cp -a "$SYSROOT/usr/lib/systemd" "$WORK/usr/lib/"
fi
if [ -d "$SYSROOT/lib/systemd" ]; then
    mkdir -p "$WORK/lib"
    cp -a "$SYSROOT/lib/systemd" "$WORK/lib/"
fi

# Copy udev
if [ -d "$SYSROOT/usr/lib/udev" ]; then
    cp -a "$SYSROOT/usr/lib/udev" "$WORK/usr/lib/"
fi
if [ -d "$SYSROOT/lib/udev" ]; then
    mkdir -p "$WORK/lib"
    cp -a "$SYSROOT/lib/udev" "$WORK/lib/"
fi

# Copy kernel modules if they exist
if [ -d "$SYSROOT/lib/modules/$KVER" ]; then
    mkdir -p "$WORK/lib/modules"
    cp -a "$SYSROOT/lib/modules/$KVER" "$WORK/lib/modules/"
fi

# Copy essential binaries
for bin in bash sh mount umount switch_root kmod modprobe insmod lsmod \
           blkid findfs losetup mkdir mknod ls cat echo sleep \
           systemctl journalctl udevadm; do
    for dir in bin sbin usr/bin usr/sbin; do
        if [ -f "$SYSROOT/$dir/$bin" ]; then
            cp "$SYSROOT/$dir/$bin" "$WORK/$dir/" 2>/dev/null || true
        fi
    done
done

# Copy libraries
echo "Copying libraries..."
if [ -d "$SYSROOT/lib64" ]; then
    cp -a "$SYSROOT/lib64"/* "$WORK/lib64/" 2>/dev/null || true
fi
if [ -d "$SYSROOT/usr/lib64" ]; then
    mkdir -p "$WORK/usr/lib64"
    cp -a "$SYSROOT/usr/lib64"/*.so* "$WORK/usr/lib64/" 2>/dev/null || true
fi
if [ -d "$SYSROOT/lib" ] && [ ! -L "$SYSROOT/lib" ]; then
    cp -a "$SYSROOT/lib"/*.so* "$WORK/lib/" 2>/dev/null || true
fi

# Copy dracut modules for live boot
if [ -d "$SYSROOT/usr/lib/dracut/modules.d" ]; then
    mkdir -p "$WORK/usr/lib/dracut"
    cp -a "$SYSROOT/usr/lib/dracut/modules.d" "$WORK/usr/lib/dracut/"
fi

# Create /init symlink to systemd
rm -f "$WORK/init"
if [ -x "$WORK/usr/lib/systemd/systemd" ]; then
    ln -sf /usr/lib/systemd/systemd "$WORK/init"
elif [ -x "$WORK/lib/systemd/systemd" ]; then
    ln -sf /lib/systemd/systemd "$WORK/init"
else
    echo "WARNING: systemd not found, creating minimal init..."
    cat > "$WORK/init" << 'MINIT'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
echo "Minimal init - systemd not found"
exec /bin/sh
MINIT
    chmod +x "$WORK/init"
fi

# Create necessary symlinks
ln -sf lib64 "$WORK/lib" 2>/dev/null || true
ln -sf usr/lib64 "$WORK/usr/lib" 2>/dev/null || true

# Create cpio archive
echo "Creating cpio archive..."
cd "$WORK"
if command -v fd >/dev/null 2>&1; then
    { printf '.\0'; fd --no-ignore --hidden -0 '' .; } | cpio --null -o -H newc 2>/dev/null | gzip -9 > "$OUTPUT"
else
    find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 > "$OUTPUT"
fi

rm -rf "$WORK"

echo "Created initramfs: $OUTPUT"
ls -lh "$OUTPUT"
