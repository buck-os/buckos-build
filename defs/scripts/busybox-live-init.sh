#!/usr/bin/busybox sh
# BuckOS Live System Init (Static Busybox)
# This runs from initramfs to boot the live system

# Kernel runs this as PID 1 - we must not exit!
# NOTE: Do NOT use set -e as it causes exit on any error

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mount -t tmpfs tmpfs /dev

# Create essential device nodes if devtmpfs not available
if [ ! -c /dev/null ]; then
    mknod -m 666 /dev/null c 1 3
    mknod -m 666 /dev/zero c 1 5
    mknod -m 666 /dev/random c 1 8
    mknod -m 666 /dev/urandom c 1 9
    mknod -m 600 /dev/console c 5 1
    mknod -m 666 /dev/tty c 5 0
fi

# Create tty devices that getty/systemd might need
for i in 1 2 3 4 5 6; do
    [ ! -c /dev/tty$i ] && mknod -m 666 /dev/tty$i c 4 $i 2>/dev/null || true
done

echo "=== INIT STARTED ==="
echo "System initialization complete."

mkdir -p /dev/pts /run /mnt/cdrom /mnt/live /mnt/root /mnt/overlay
mount -t devpts devpts /dev/pts 2>/dev/null || true
mount -t tmpfs tmpfs /run

echo "BuckOS Live Boot"
echo "================"

# Function to try mounting a device and check for live filesystem
try_mount_device() {
    _dev="$1"
    if [ -b "$_dev" ]; then
        echo "  Trying $_dev..."
        if mount -o ro "$_dev" /mnt/cdrom 2>/dev/null; then
            if [ -f /mnt/cdrom/live/filesystem.squashfs ]; then
                echo "  Found live filesystem on $_dev"
                BOOT_DEV="$_dev"
                return 0
            fi
            umount /mnt/cdrom 2>/dev/null || true
        fi
    fi
    return 1
}

# Function to scan for boot device
scan_for_boot_device() {
    BOOT_DEV=""

    # First try common device names
    for dev in /dev/sr0 /dev/sr1 /dev/cdrom; do
        try_mount_device "$dev" && return 0
    done

    # Scan all block devices from /sys/block
    for block in /sys/block/*; do
        devname=$(basename "$block")
        # Skip ram, loop, dm devices
        case "$devname" in
            ram*|loop*|dm-*) continue ;;
        esac

        dev="/dev/$devname"

        # Try the whole device first (for ISO on USB stick)
        try_mount_device "$dev" && return 0

        # Try partitions
        for part in "$block"/"$devname"*; do
            [ -d "$part" ] || continue
            partname=$(basename "$part")
            try_mount_device "/dev/$partname" && return 0
        done
    done

    # Try by label as last resort
    for label in BUCKOS_LIVE BUCKOS; do
        dev=$(findfs "LABEL=$label" 2>/dev/null) || true
        if [ -n "$dev" ] && [ -b "$dev" ]; then
            echo "  Found device by label $label: $dev"
            try_mount_device "$dev" && return 0
        fi
    done

    return 1
}

# Wait for devices with retry loop
echo "Waiting for boot device..."
MAX_TRIES=30
i=1
while [ $i -le $MAX_TRIES ]; do
    echo "Scan attempt $i/$MAX_TRIES..."

    # Show available devices for debugging
    echo "  Block devices in /sys/block:"
    ls /sys/block 2>/dev/null | tr '\n' ' '
    echo ""

    if scan_for_boot_device; then
        break
    fi

    if [ $i -lt $MAX_TRIES ]; then
        echo "  Device not found, waiting..."
        sleep 1
    fi
    i=$((i + 1))
done

if [ -z "$BOOT_DEV" ]; then
    echo "ERROR: Could not find live boot media!"
    echo "Available block devices:"
    ls -la /dev/sd* /dev/sr* /dev/nvme* /dev/vd* 2>/dev/null || true
    echo ""
    echo "Dropping to emergency shell..."
    exec /bin/sh
fi

# Mount squashfs
echo "Mounting squashfs..."
if ! mount -t squashfs -o ro /mnt/cdrom/live/filesystem.squashfs /mnt/live; then
    echo "ERROR: Failed to mount squashfs"
    exec /bin/sh
fi

# Setup overlay for writable root
echo "Setting up overlay filesystem..."
mount -t tmpfs tmpfs /mnt/overlay
mkdir -p /mnt/overlay/upper /mnt/overlay/work

if mount -t overlay overlay -o lowerdir=/mnt/live,upperdir=/mnt/overlay/upper,workdir=/mnt/overlay/work /mnt/root; then
    echo "Overlay filesystem ready"
else
    echo "WARNING: Overlay failed, using read-only root"
    mount --bind /mnt/live /mnt/root
fi

# Prepare new root
mkdir -p /mnt/root/proc /mnt/root/sys /mnt/root/dev /mnt/root/run
mount --move /proc /mnt/root/proc
mount --move /sys /mnt/root/sys
mount --move /dev /mnt/root/dev
mount --move /run /mnt/root/run

# Move backing mounts into new root
mkdir -p /mnt/root/run/live/medium /mnt/root/run/live/rootfs /mnt/root/run/live/overlay
mount --move /mnt/cdrom /mnt/root/run/live/medium 2>/dev/null || true
mount --move /mnt/live /mnt/root/run/live/rootfs 2>/dev/null || true
mount --move /mnt/overlay /mnt/root/run/live/overlay 2>/dev/null || true

# Clean up
umount /dev/pts 2>/dev/null || true

# Find init in new root
INIT=""
if [ -x /mnt/root/usr/lib/systemd/systemd ]; then
    INIT=/usr/lib/systemd/systemd
elif [ -x /mnt/root/lib/systemd/systemd ]; then
    INIT=/lib/systemd/systemd
elif [ -x /mnt/root/sbin/init ]; then
    INIT=/sbin/init
else
    INIT=/sbin/init
fi

echo "Switching to root filesystem, init=$INIT"
cd /mnt/root
exec switch_root /mnt/root "$INIT"

# Should never reach here
exec /bin/sh
