#!/bin/bash
# Create initramfs using dracut with dmsquash-live module for live boot
# v5: Proper kernel module handling, use sysroot dracut correctly
set -e

KERNEL_SRC="$1"
DRACUT_DIR="$2"
ROOTFS_DIR="$3"
OUTPUT="$(realpath -m "$4")"
KVER="${5:-}"
COMPRESS="${6:-gzip}"
MODULES_DIR="${7:-}"

# Parse optional flags (--hermetic-path, --ld-linux) passed after positional args
shift 7 2>/dev/null || true
HERMETIC_PATH=""
LD_LINUX=""
while [ $# -gt 0 ]; do
    case "$1" in
        --hermetic-path) HERMETIC_PATH="$2"; shift 2 ;;
        --ld-linux) LD_LINUX="$2"; shift 2 ;;
        *) shift ;;
    esac
done

mkdir -p "$(dirname "$OUTPUT")"

# Create a merged sysroot for dracut to work with
SYSROOT=$(mktemp -d)
trap "rm -rf $SYSROOT" EXIT

echo "Creating merged sysroot for dracut..."

# Copy base rootfs (has systemd, udev, bash, coreutils, etc.)
cp -a "$ROOTFS_DIR"/* "$SYSROOT"/ 2>/dev/null || true

# Overlay dracut package — DRACUT_DIR is the build output which contains
# dracut.sh, modules.d/, src/install/dracut-install, etc.
# We need to install these into the sysroot manually.
mkdir -p "$SYSROOT/usr/bin" "$SYSROOT/usr/lib/dracut" "$SYSROOT/etc/dracut.conf.d"

# Install dracut main script
if [ -f "$DRACUT_DIR/dracut.sh" ]; then
    cp "$DRACUT_DIR/dracut.sh" "$SYSROOT/usr/bin/dracut"
    chmod +x "$SYSROOT/usr/bin/dracut"
fi
if [ -f "$DRACUT_DIR/lsinitrd.sh" ]; then
    cp "$DRACUT_DIR/lsinitrd.sh" "$SYSROOT/usr/bin/lsinitrd"
    chmod +x "$SYSROOT/usr/bin/lsinitrd"
fi

# Install dracut support scripts
for script in dracut-functions.sh dracut-init.sh dracut-logger.sh dracut-initramfs-restore.sh; do
    [ -f "$DRACUT_DIR/$script" ] && cp "$DRACUT_DIR/$script" "$SYSROOT/usr/lib/dracut/"
done

# Install dracut-install binary
if [ -f "$DRACUT_DIR/src/install/dracut-install" ]; then
    cp "$DRACUT_DIR/src/install/dracut-install" "$SYSROOT/usr/lib/dracut/"
    chmod +x "$SYSROOT/usr/lib/dracut/dracut-install"
    ln -sf ../lib/dracut/dracut-install "$SYSROOT/usr/bin/dracut-install"
fi

# Install skipcpio
if [ -f "$DRACUT_DIR/src/skipcpio/skipcpio" ]; then
    cp "$DRACUT_DIR/src/skipcpio/skipcpio" "$SYSROOT/usr/lib/dracut/"
    chmod +x "$SYSROOT/usr/lib/dracut/skipcpio"
fi

# Install dracut-util
if [ -f "$DRACUT_DIR/src/util/util" ]; then
    cp "$DRACUT_DIR/src/util/util" "$SYSROOT/usr/lib/dracut/dracut-util"
    chmod +x "$SYSROOT/usr/lib/dracut/dracut-util"
fi

# Install dracut modules (critical for live boot!)
if [ -d "$DRACUT_DIR/modules.d" ]; then
    cp -a "$DRACUT_DIR/modules.d" "$SYSROOT/usr/lib/dracut/"
    echo "Installed $(ls "$SYSROOT/usr/lib/dracut/modules.d" | wc -l) dracut modules"
fi

# Install dracut config
if [ -f "$DRACUT_DIR/dracut.conf" ]; then
    cp "$DRACUT_DIR/dracut.conf" "$SYSROOT/etc/dracut.conf"
fi

# Install kernel modules — ONLY .ko files and module indexes, NOT build/ or source/
mkdir -p "$SYSROOT/lib/modules"
_copy_kernel_modules() {
    local src="$1" dst="$2"
    mkdir -p "$dst"
    # Copy module index files
    cp "$src"/modules.* "$dst/" 2>/dev/null || true
    # Copy kernel/ tree using tar to preserve structure, only .ko files
    # Explicitly exclude build/ and source/ which contain kernel source
    if [ -d "$src/kernel" ]; then
        (cd "$src" && find kernel -type f \( -name "*.ko" -o -name "*.ko.*" \) -print0 | \
            tar --null -cf - -T - | tar -xf - -C "$dst")
        echo "Copied $(find "$dst/kernel" -type f \( -name "*.ko" -o -name "*.ko.*" \) 2>/dev/null | wc -l) kernel modules"
    fi
}

if [ -n "$MODULES_DIR" ] && [ -d "$MODULES_DIR" ]; then
    for kdir in "$MODULES_DIR"/*/; do
        kv=$(basename "$kdir")
        _copy_kernel_modules "$kdir" "$SYSROOT/lib/modules/$kv"
    done
elif [ -d "$KERNEL_SRC/lib/modules" ]; then
    for kdir in "$KERNEL_SRC/lib/modules"/*/; do
        kv=$(basename "$kdir")
        _copy_kernel_modules "$kdir" "$SYSROOT/lib/modules/$kv"
    done
fi

# Find kernel version if not provided
if [ -z "$KVER" ]; then
    KVER=$(ls "$SYSROOT/lib/modules" 2>/dev/null | head -1)
fi

echo "Using kernel version: $KVER"

if [ ! -d "$SYSROOT/lib/modules/$KVER" ]; then
    echo "WARNING: Kernel modules not found at $SYSROOT/lib/modules/$KVER"
    ls -la "$SYSROOT/lib/modules/" 2>/dev/null || true
fi

# Create dracut configuration for live boot
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

echo "compress=\"$COMPRESS\"" >> "$SYSROOT/etc/dracut.conf.d/live.conf"

echo "Running dracut to generate initramfs..."

# ------------------------------------------------------------------
# Strategy 1: Run the sysroot's own dracut
# ------------------------------------------------------------------
SYSROOT_DRACUT="$SYSROOT/usr/bin/dracut"
if [ -x "$SYSROOT_DRACUT" ]; then
    echo "Using sysroot dracut: $SYSROOT_DRACUT"

    # Build library path from sysroot
    SYSROOT_LIB_PATH=""
    for d in "$SYSROOT/lib64" "$SYSROOT/usr/lib64" "$SYSROOT/lib" "$SYSROOT/usr/lib"; do
        [ -d "$d" ] && SYSROOT_LIB_PATH="${SYSROOT_LIB_PATH:+$SYSROOT_LIB_PATH:}$d"
    done

    # Build PATH with sysroot binaries first
    SYSROOT_PATH="$SYSROOT/usr/bin:$SYSROOT/usr/sbin:$SYSROOT/bin:$SYSROOT/sbin"
    [ -n "$HERMETIC_PATH" ] && SYSROOT_PATH="$SYSROOT_PATH:$HERMETIC_PATH"
    SYSROOT_PATH="$SYSROOT_PATH:$PATH"

    env \
        PATH="$SYSROOT_PATH" \
        LD_LIBRARY_PATH="$SYSROOT_LIB_PATH" \
        dracutbasedir="$SYSROOT/usr/lib/dracut" \
        bash "$SYSROOT_DRACUT" \
            --verbose \
            --force \
            --no-hostonly \
            --confdir "$SYSROOT/etc/dracut.conf.d" \
            --kmoddir "$SYSROOT/lib/modules/$KVER" \
            --kver "$KVER" \
            --tmpdir /tmp \
            "$OUTPUT" && {
                echo "Created initramfs with sysroot dracut: $OUTPUT"
                ls -lh "$OUTPUT"
                exit 0
            }
    echo "Sysroot dracut failed (exit $?), trying fallback..."
fi

# ------------------------------------------------------------------
# Strategy 2: Manual fallback — selective, correct initramfs
# ------------------------------------------------------------------
echo "Creating initramfs manually with systemd..."

WORK=$(mktemp -d)
mkdir -p "$WORK"/{bin,sbin,usr/bin,usr/sbin,usr/lib,usr/lib64,lib,lib64,etc,proc,sys,dev,run,tmp,var}

# Copy systemd and udev
for d in usr/lib/systemd lib/systemd usr/lib/udev lib/udev; do
    if [ -d "$SYSROOT/$d" ]; then
        mkdir -p "$WORK/$(dirname $d)"
        cp -a "$SYSROOT/$d" "$WORK/$(dirname $d)/"
    fi
done

# Copy SELECTED kernel modules (not all 8GB worth)
# squashfs and overlay are built-in (=y), so we only need hardware drivers
if [ -d "$SYSROOT/lib/modules/$KVER/kernel" ]; then
    echo "Copying selected kernel modules..."
    mkdir -p "$WORK/lib/modules/$KVER"
    cp "$SYSROOT/lib/modules/$KVER"/modules.* "$WORK/lib/modules/$KVER/" 2>/dev/null || true

    SRC="$SYSROOT/lib/modules/$KVER/kernel"
    DST="$WORK/lib/modules/$KVER/kernel"
    # Copy only essential module subdirectories for live boot
    for subdir in \
        drivers/block drivers/cdrom drivers/scsi/sd_mod.ko* drivers/scsi/sr_mod.ko* \
        drivers/ata/ahci.ko* drivers/ata/libahci.ko* drivers/ata/libata.ko* \
        drivers/nvme \
        drivers/usb/core drivers/usb/host drivers/usb/storage \
        drivers/virtio \
        drivers/hid/hid.ko* drivers/hid/hid-generic.ko* drivers/hid/usbhid \
        drivers/input/evdev.ko* drivers/input/keyboard drivers/input/mouse \
        drivers/md/dm-mod.ko* drivers/md/dm-snapshot.ko* \
        fs/squashfs fs/overlayfs fs/isofs fs/fat fs/nls \
        lib crypto \
        drivers/net/virtio_net.ko*; do
        # Handle both directory and file glob patterns
        if [ -d "$SRC/$subdir" ]; then
            mkdir -p "$DST/$subdir"
            (cd "$SRC" && find "$subdir" -type f \( -name "*.ko" -o -name "*.ko.*" \) -print0 | \
                tar --null -cf - -T - | tar -xf - -C "$DST") 2>/dev/null || true
        else
            # Try as a glob pattern
            for f in $SRC/$subdir; do
                [ -f "$f" ] || continue
                rel="${f#$SRC/}"
                mkdir -p "$DST/$(dirname "$rel")"
                cp "$f" "$DST/$rel"
            done
        fi
    done
    echo "Copied $(find "$DST" -type f \( -name "*.ko" -o -name "*.ko.*" \) 2>/dev/null | wc -l) modules"
fi

# Copy ALL binaries from sysroot (not a curated list — missing one causes
# systemd to fail at boot with "Unable to locate executable")
for dir in bin sbin usr/bin usr/sbin; do
    if [ -d "$SYSROOT/$dir" ]; then
        mkdir -p "$WORK/$dir"
        cp -a "$SYSROOT/$dir"/* "$WORK/$dir/" 2>/dev/null || true
    fi
done

# Create /bin/kmod symlink (systemd checks ConditionPathExists=/bin/kmod)
[ -f "$WORK/usr/bin/kmod" ] && [ ! -f "$WORK/bin/kmod" ] && \
    ln -sf /usr/bin/kmod "$WORK/bin/kmod" 2>/dev/null || true

# Copy ONLY libraries needed by included binaries (resolve with readelf)
echo "Resolving library dependencies..."
_collect_needed_libs() {
    # Scan ALL ELF files (executables AND shared libraries) for NEEDED entries
    find "$WORK" -type f \( -executable -o -name "*.so" -o -name "*.so.*" \) -print0 2>/dev/null | \
        xargs -0 readelf -d 2>/dev/null | \
        grep -oP 'NEEDED.*\[\K[^\]]+' | \
        sort -u
}

# Search paths for libraries (includes systemd's private lib dir)
_LIB_SEARCH_DIRS="lib64 usr/lib64 lib usr/lib usr/lib64/systemd usr/lib/systemd"

# Three passes to resolve transitive dependencies (lib -> lib -> lib)
for pass in 1 2 3; do
    _needed=$(_collect_needed_libs)
    while IFS= read -r libname; do
        [ -z "$libname" ] && continue
        # Skip if already copied
        _found=0
        for dir in $_LIB_SEARCH_DIRS; do
            if [ -f "$WORK/$dir/$libname" ] || [ -L "$WORK/$dir/$libname" ]; then
                _found=1
                break
            fi
        done
        [ "$_found" -eq 1 ] && continue
        # Find in sysroot and copy
        for dir in $_LIB_SEARCH_DIRS; do
            src="$SYSROOT/$dir/$libname"
            if [ -f "$src" ] || [ -L "$src" ]; then
                mkdir -p "$WORK/$dir"
                cp -a "$src" "$WORK/$dir/"
                [ -L "$src" ] && { real=$(readlink -f "$src"); [ -f "$real" ] && cp -a "$real" "$WORK/$dir/"; }
                break
            fi
        done
    done <<< "$_needed"
done

# Always include the dynamic linker
for ld in "$SYSROOT"/lib64/ld-linux-*.so* "$SYSROOT"/lib/ld-linux-*.so*; do
    if [ -f "$ld" ] || [ -L "$ld" ]; then
        d="${ld#$SYSROOT/}"; mkdir -p "$WORK/$(dirname "$d")"
        cp -a "$ld" "$WORK/$(dirname "$d")/"
    fi
done

# Copy dracut modules for live boot
if [ -d "$SYSROOT/usr/lib/dracut/modules.d" ]; then
    mkdir -p "$WORK/usr/lib/dracut"
    cp -a "$SYSROOT/usr/lib/dracut/modules.d" "$WORK/usr/lib/dracut/"
fi

# Create merged-usr layout so the dynamic linker can find all libraries.
# BuckOS glibc's ld.so only searches /usr/lib64 by default, but the
# dependency resolver copies base libs (libc, ld-linux) to /lib64 and
# some packages install to /usr/lib instead of /usr/lib64.
# Merge /lib64 -> /usr/lib64, /lib -> /usr/lib64, and /usr/lib -> /usr/lib64.
for d in lib64 lib; do
    if [ -d "$WORK/$d" ] && [ ! -L "$WORK/$d" ]; then
        mkdir -p "$WORK/usr/lib64"
        for f in "$WORK/$d"/*; do
            [ -e "$f" ] || continue
            bn=$(basename "$f")
            [ -e "$WORK/usr/lib64/$bn" ] || mv "$f" "$WORK/usr/lib64/"
        done
        rm -rf "$WORK/$d"
        ln -sf "usr/lib64" "$WORK/$d"
        echo "Merged /$d into /usr/lib64 (merged-usr layout)"
    fi
done
# Also merge /usr/lib -> /usr/lib64 for packages that install to /usr/lib
if [ -d "$WORK/usr/lib" ] && [ ! -L "$WORK/usr/lib" ]; then
    mkdir -p "$WORK/usr/lib64"
    for f in "$WORK/usr/lib"/*; do
        [ -e "$f" ] || continue
        bn=$(basename "$f")
        # Skip non-library subdirs (systemd, dracut, modules, udev)
        [ -d "$f" ] && continue
        [ -e "$WORK/usr/lib64/$bn" ] || mv "$f" "$WORK/usr/lib64/"
    done
    echo "Merged /usr/lib libraries into /usr/lib64"
fi

# Create /init symlink to systemd
rm -f "$WORK/init"
if [ -x "$WORK/usr/lib/systemd/systemd" ]; then
    ln -sf /usr/lib/systemd/systemd "$WORK/init"
elif [ -x "$WORK/lib/systemd/systemd" ]; then
    ln -sf /lib/systemd/systemd "$WORK/init"
else
    echo "ERROR: systemd not found in initramfs, cannot create /init"
    exit 1
fi

# Set default target to initrd.target (NOT graphical.target)
mkdir -p "$WORK/etc/systemd/system"
ln -sf /usr/lib/systemd/system/initrd.target "$WORK/etc/systemd/system/default.target"

# Mark this as an initrd so systemd enters initrd mode
cat > "$WORK/etc/initrd-release" << 'INITRDRELEASE'
NAME="BuckOS Live"
ID=buckos
VERSION_ID=1.0
PRETTY_NAME="BuckOS Live Boot Environment"
INITRDRELEASE

# Set root password to "buckos" for emergency shell access
# Hash generated with: python3 -c "import crypt; print(crypt.crypt('buckos', crypt.mksalt(crypt.METHOD_SHA512)))"
mkdir -p "$WORK/etc"
cat > "$WORK/etc/shadow" << 'SHADOWEOF'
root:$6$XxYSRB9p2uZQDqdN$5y91468svaBTNkjBI9Z18f/Tw019c6QmeyhcWpa4FcHHdleWagixJvhK0tWMNW20XZwzn0AWw9iTSYN7Ed1zF/:19000:0:99999:7:::
nobody:!:0:0:99999:7:::
SHADOWEOF
chmod 640 "$WORK/etc/shadow"
cat > "$WORK/etc/passwd" << 'PASSWDEOF'
root:x:0:0:root:/root:/bin/bash
nobody:x:65534:65534:Nobody:/:/bin/false
PASSWDEOF
cat > "$WORK/etc/group" << 'GROUPEOF'
root:x:0:
nobody:x:65534:
GROUPEOF
cat > "$WORK/etc/nsswitch.conf" << 'NSSEOF'
passwd:     files
group:      files
shadow:     files
NSSEOF

# Install live media mount service — finds and mounts the squashfs
# from the ISO, then signals systemd to switch-root into it
mkdir -p "$WORK/usr/lib/systemd/system/initrd.target.wants"
mkdir -p "$WORK/usr/lib/systemd/scripts"
mkdir -p "$WORK/sysroot"

cat > "$WORK/usr/lib/systemd/system/live-media-mount.service" << 'LIVESVC'
[Unit]
Description=Mount Live Media SquashFS
DefaultDependencies=no
Before=initrd-root-fs.target
After=systemd-udevd.service
ConditionPathExists=!/sysroot/usr

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/lib/systemd/scripts/live-media-mount.sh

[Install]
WantedBy=initrd.target
LIVESVC

ln -sf ../live-media-mount.service "$WORK/usr/lib/systemd/system/initrd.target.wants/live-media-mount.service"

cat > "$WORK/usr/lib/systemd/scripts/live-media-mount.sh" << 'LIVESH'
#!/bin/bash
set -e

echo "live-media-mount: Searching for live media..."

# Ensure block device drivers are loaded
modprobe virtio_blk 2>/dev/null || true
modprobe sr_mod 2>/dev/null || true
modprobe loop 2>/dev/null || true
modprobe squashfs 2>/dev/null || true
modprobe overlay 2>/dev/null || true

# Wait for devices to settle
sleep 2
udevadm settle --timeout=15 2>/dev/null || true

# Debug: show available block devices
echo "live-media-mount: Available block devices:"
ls -la /dev/vd* /dev/sd* /dev/sr* /dev/cdrom 2>/dev/null || true
cat /proc/partitions 2>/dev/null || true

# Find the ISO/live media partition containing the squashfs
# Scan all block devices — the ISO may be virtio (/dev/vda), SCSI
# (/dev/sr0), or any other transport depending on QEMU/hardware config.
# Also scan partition devices (e.g. /dev/vda1) since the ISO may have
# a GPT/MBR partition table from hybrid boot setup.
SQFS=""
for dev in /dev/sr0 /dev/cdrom \
           /dev/vd[a-z] /dev/vd[a-z][0-9] /dev/vd[a-z][0-9][0-9] \
           /dev/sd[a-z] /dev/sd[a-z][0-9] /dev/sd[a-z][0-9][0-9] \
           /dev/loop[0-9]; do
    [ -b "$dev" ] || continue
    TMPMNT=$(mktemp -d)
    # Try iso9660 explicitly first (for CD/ISO images), then auto-detect
    mounted=0
    for fstype in iso9660 auto; do
        if mount -t "$fstype" -o ro "$dev" "$TMPMNT" 2>/dev/null; then
            mounted=1
            break
        fi
    done
    if [ "$mounted" -eq 1 ]; then
        for sqpath in live/filesystem.squashfs LiveOS/squashfs.img squashfs.img LiveOS/rootfs.img; do
            if [ -f "$TMPMNT/$sqpath" ]; then
                SQFS="$TMPMNT/$sqpath"
                echo "live-media-mount: Found squashfs at $dev:/$sqpath"
                break
            fi
        done
        [ -n "$SQFS" ] && break
        umount "$TMPMNT"
    fi
    rmdir "$TMPMNT" 2>/dev/null || true
done

if [ -z "$SQFS" ]; then
    echo "live-media-mount: ERROR: No squashfs image found!"
    echo "live-media-mount: Tried all block devices, listing mount attempts:"
    for dev in /dev/sr0 /dev/vd[a-z] /dev/sd[a-z]; do
        [ -b "$dev" ] && echo "  $dev exists ($(blockdev --getsize64 "$dev" 2>/dev/null || echo '?') bytes)"
    done
    exit 1
fi

# Mount squashfs via loopback
SQMNT=/run/live/squashfs
mkdir -p "$SQMNT"
mount -o ro,loop "$SQFS" "$SQMNT"
echo "live-media-mount: Mounted squashfs at $SQMNT"

# If there's a rootfs.img inside the squashfs, mount that as the lower layer
LOWER="$SQMNT"
if [ -f "$SQMNT/LiveOS/rootfs.img" ]; then
    LOWER=/run/live/rootfs
    mkdir -p "$LOWER"
    mount -o ro,loop "$SQMNT/LiveOS/rootfs.img" "$LOWER"
    echo "live-media-mount: Mounted rootfs.img at $LOWER"
fi

# Set up writable overlay: tmpfs upper + squashfs lower = read-write /sysroot
mkdir -p /run/live/overlay /run/live/work
mount -t tmpfs -o size=50% tmpfs /run/live/overlay
mkdir -p /run/live/overlay/upper /run/live/overlay/work

mount -t overlay overlay \
    -o "lowerdir=$LOWER,upperdir=/run/live/overlay/upper,workdir=/run/live/overlay/work" \
    /sysroot

echo "live-media-mount: Overlay mounted at /sysroot (lower=$LOWER, upper=tmpfs)"

# Remove initrd-release from /sysroot so systemd enters normal system mode
# after switch-root (not initrd mode which would try another switch-root)
rm -f /sysroot/etc/initrd-release
LIVESH
chmod +x "$WORK/usr/lib/systemd/scripts/live-media-mount.sh"

# Enable switch-root after root fs is mounted
mkdir -p "$WORK/usr/lib/systemd/system/initrd-root-fs.target.wants"
if [ -f "$WORK/usr/lib/systemd/system/initrd-switch-root.service" ]; then
    ln -sf ../initrd-switch-root.service \
        "$WORK/usr/lib/systemd/system/initrd-root-fs.target.wants/initrd-switch-root.service"
fi

# Create initrd-root-fs.target drop-in to depend on live media
mkdir -p "$WORK/etc/systemd/system/initrd-root-fs.target.d"
cat > "$WORK/etc/systemd/system/initrd-root-fs.target.d/live.conf" << 'ROOTFSDEP'
[Unit]
After=live-media-mount.service
Requires=live-media-mount.service
ROOTFSDEP

# Create initrd-switch-root.service drop-in so it waits for live media
mkdir -p "$WORK/etc/systemd/system/initrd-switch-root.service.d"
cat > "$WORK/etc/systemd/system/initrd-switch-root.service.d/live.conf" << 'SWITCHDEP'
[Unit]
After=live-media-mount.service
Requires=live-media-mount.service
SWITCHDEP

# Run depmod to generate correct module indexes for the copied modules
if [ -x "$WORK/sbin/depmod" ] || [ -x "$WORK/usr/sbin/depmod" ]; then
    depmod_bin=$(which depmod 2>/dev/null || echo "depmod")
    $depmod_bin -a -b "$WORK" "$KVER" 2>/dev/null || true
fi

echo "Initramfs contents:"
du -sh "$WORK"
du -sh "$WORK"/lib/modules/ 2>/dev/null || true
find "$WORK/lib/modules" -name "squashfs.ko*" -o -name "overlay.ko*" 2>/dev/null || true

# Create cpio archive
echo "Creating cpio archive..."
cd "$WORK"
find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 > "$OUTPUT"

rm -rf "$WORK"

echo "Created initramfs: $OUTPUT"
ls -lh "$OUTPUT"
