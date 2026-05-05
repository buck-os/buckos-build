#!/bin/sh
# Find and mount live boot media for systemd initrd
# This script is called by initrd-live-media.service

set -e

echo "BuckOS Live: Searching for live media..."

# Create mount points
mkdir -p /run/live/medium /run/live/rootfs /run/live/overlay

# Function to try mounting a device
try_mount() {
    dev="$1"
    if [ -b "$dev" ]; then
        echo "  Trying $dev..."
        if mount -o ro "$dev" /run/live/medium 2>/dev/null; then
            if [ -f /run/live/medium/live/filesystem.squashfs ]; then
                echo "  Found live filesystem on $dev"
                return 0
            fi
            umount /run/live/medium 2>/dev/null || true
        fi
    fi
    return 1
}

# Wait for devices with timeout
TIMEOUT=30
FOUND=0
i=1

while [ "$i" -le "$TIMEOUT" ]; do
    echo "Scan attempt $i/$TIMEOUT..."

    # Try CD/DVD first
    for dev in /dev/sr0 /dev/sr1 /dev/cdrom; do
        if try_mount "$dev"; then
            FOUND=1
            break 2
        fi
    done

    # Scan all block devices
    for block in /sys/block/*; do
        [ -d "$block" ] || continue
        devname=$(basename "$block")
        case "$devname" in
            ram*|loop*|dm-*) continue ;;
        esac

        # Try whole device
        if try_mount "/dev/$devname"; then
            FOUND=1
            break 2
        fi

        # Try partitions
        for part in "$block"/"$devname"*; do
            [ -d "$part" ] || continue
            partname=$(basename "$part")
            if try_mount "/dev/$partname"; then
                FOUND=1
                break 3
            fi
        done
    done

    # Try by label
    for label in BUCKOS_LIVE BUCKOS; do
        dev=$(blkid -L "$label" 2>/dev/null) || continue
        if [ -n "$dev" ] && try_mount "$dev"; then
            FOUND=1
            break 2
        fi
    done

    sleep 1
    i=$((i + 1))
done

if [ "$FOUND" -ne 1 ]; then
    echo "ERROR: Could not find live boot media!"
    exit 1
fi

# Mount squashfs
echo "Mounting squashfs..."
mount -t squashfs -o ro /run/live/medium/live/filesystem.squashfs /run/live/rootfs

# Setup overlay
echo "Setting up overlay filesystem..."
mount -t tmpfs tmpfs /run/live/overlay
mkdir -p /run/live/overlay/upper /run/live/overlay/work

# Mount overlay as /sysroot (systemd expects this)
mkdir -p /sysroot
mount -t overlay overlay \
    -o lowerdir=/run/live/rootfs,upperdir=/run/live/overlay/upper,workdir=/run/live/overlay/work \
    /sysroot

echo "Live media mounted successfully at /sysroot"

# Systemd's initrd-switch-root.service will handle the actual switch-root
# We just need to ensure /sysroot is mounted, which we've done above
exit 0
