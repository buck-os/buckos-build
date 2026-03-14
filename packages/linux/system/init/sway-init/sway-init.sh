#!/bin/bash
# BuckOS Live CD with Sway - Simple init script
# Use this as /sbin/init for a minimal Sway-based live system

# Set PATH first - essential for finding commands
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

# Mount essential filesystems (skip if already mounted by initramfs)
mountpoint -q /proc  || mount -t proc proc /proc
mountpoint -q /sys   || mount -t sysfs sys /sys
mountpoint -q /dev   || mount -t devtmpfs dev /dev
mkdir -p /dev/pts /dev/shm
mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts
mountpoint -q /dev/shm || mount -t tmpfs tmpfs /dev/shm
mountpoint -q /tmp     || mount -t tmpfs tmpfs /tmp
mountpoint -q /run     || mount -t tmpfs tmpfs /run

# Set hostname
echo buckos-live > /etc/hostname
command -v hostname >/dev/null 2>&1 && hostname buckos-live

# Create XDG runtime directory
export XDG_RUNTIME_DIR=/run/user/0
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"

# Export environment
export HOME=/root
export TERM=linux

# Start udev if available
if [ -x /sbin/udevd ]; then
    /sbin/udevd --daemon
    udevadm trigger --action=add
    udevadm settle
fi

# Print welcome message
echo ""
echo "======================================"
echo "  Welcome to BuckOS Live CD"
echo "======================================"
echo ""

# Check if we have a display (DRM device)
if [ -e /dev/dri/card0 ]; then
    echo "Starting Sway Wayland compositor..."
    echo ""
    cd /root
    sway || {
        echo ""
        echo "Sway failed to start. Dropping to shell..."
        echo "You can try 'sway' again if you have a display."
        echo ""
    }
else
    echo "No display detected (no /dev/dri/card0)"
    echo "Skipping Sway, dropping to shell..."
    echo ""
fi

# Drop to interactive shell
echo "BuckOS shell ready. Type 'sway' to start desktop (if display available)."
cd /root
exec /bin/bash --noediting -i
