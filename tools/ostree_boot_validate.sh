#!/bin/bash
# Validate that a deployed BuckOS ostree commit boots to userspace in QEMU
# (SPEC-006 P3).  Manual/dev harness — assembles a tiny bootable commit from
# prebuilt buck-out artifacts, deploys it (ostree_sysroot-style, in a userns),
# builds an initramfs + ext4 disk, and boots it.
#
# Status:
#   * Deployed-content boot: VALIDATED.  The init tries ostree-prepare-root and
#     falls back to a direct deployment boot (bind the deployment + switch_root);
#     the fallback reaches userspace, proving commit -> deploy -> boot works.
#   * Faithful ostree-prepare-root boot (read-only /usr overlay + /etc 3-way
#     merge): BLOCKED.  ostree-prepare-root (a dynamic glibc binary) runs fine
#     on the host (chroot, fe195 glibc + stripped rpath -> reaches main), but
#     segfaults PRE-main under the buckos kernel inside the minimal initramfs.
#     Ruled out: QEMU/KVM (TCG reproduces it identically), CPU/AVX-512
#     (-cpu Haswell still crashes), CET/shadow-stack (not configured; binary
#     has no SHSTK/IBT), missing libs, glibc version (both 2.42), and rpath
#     (stripped).  It is a buckos kernel + dynamic-binary-in-initramfs issue:
#     buckos's own initramfs uses STATIC busybox precisely to avoid running
#     dynamic binaries early.  Fix path (distro-level follow-up): a static or
#     portabilized ostree-prepare-root, or a dynamic-capable initramfs
#     (dracut/systemd ostree module) like a production ostree distro uses.
#
# Requires: KVM + a QEMU with -cpu host (buckos userspace is x86-64-v3).
set -eu
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo /home/hodgesd/buckos-build)"

GEN=buck-out/v2/gen/buckos
find1() { find "$GEN" -path "$1" 2>/dev/null | head -1; }

BZIMAGE=$PWD/$(find1 '*buckos-kernel*/build-tree/arch/x86/boot/bzImage')
KMODDIR=$(find "$GEN" -path '*buckos-kernel*/modules/*' -maxdepth 9 -type d -regextype posix-extended -regex '.*/modules/[0-9].*' 2>/dev/null | head -1)
KVER=$(basename "${KMODDIR:-6.0.0}")
BUSYBOX=$PWD/$(find1 '*busybox-static-build*/installed/bin/busybox')
OPREFIX=$(find1 '*system/ostree*__ostree-build__/installed')
OSTREE=$PWD/$OPREFIX/usr/bin/ostree
PREPARE=$PWD/$OPREFIX/usr/lib/ostree/ostree-prepare-root
MKE2FS=$PWD/$(find1 '*e2fsprogs*/installed/usr/sbin/mke2fs')
PATCHELF=$PWD/$(find buck-out -path '*patchelf*' -name patchelf -type f 2>/dev/null | head -1)
HASH=$(echo "$OPREFIX" | sed -E 's#.*/gen/buckos/([^/]+)/.*#\1#')
GLIBC=$PWD/buck-out/v2/gen/buckos/$HASH/packages/linux/core/glibc/__glibc-build__/installed/usr/lib64
QEMU=${QEMU:-/opt/fb-qemu/bin/qemu-system-x86_64}
MARKER=OSTREE_BOOT_OK_MARKER

W=${W:-/tmp/ostree_boot_work}; rm -rf "$W"; mkdir -p "$W"
echo "### kernel=$KVER  ostree=$OPREFIX"

echo "### 1. assemble bootable rootfs (usr-merged: busybox + init + os-release + kernel)"
R="$W/rootfs"
mkdir -p "$R/usr/bin" "$R/usr/sbin" "$R/usr/lib/modules/$KVER"
ln -s usr/bin "$R/bin"; ln -s usr/sbin "$R/sbin"; ln -s usr/lib "$R/lib"
cp "$BUSYBOX" "$R/usr/bin/busybox"; chmod 0755 "$R/usr/bin/busybox"
cp "$BZIMAGE" "$R/usr/lib/modules/$KVER/vmlinuz"
printf 'ID=buckos\nNAME=BuckOS\nPRETTY_NAME="BuckOS boot test"\nVERSION_ID=0\n' > "$R/usr/lib/os-release"
cat > "$R/usr/sbin/init" <<EOF
#!/usr/bin/busybox sh
/usr/bin/busybox mount -t proc proc /proc 2>/dev/null || true
/usr/bin/busybox echo $MARKER
/usr/bin/busybox sync
/usr/bin/busybox poweroff -f
EOF
chmod 0755 "$R/usr/sbin/init"

echo "### 2. reshape into ostree layout"
python3 tools/ostree_rootfs_helper.py --input "$R" --output "$W/shaped"

echo "### 3. ostree commit (archive repo)"
REPO="$W/repo"
"$OSTREE" --repo="$REPO" init --mode=archive
CSUM=$("$OSTREE" --repo="$REPO" commit --branch=buckos/boot --tree=dir="$W/shaped" \
  --timestamp=@0 --owner-uid=0 --owner-gid=0 --no-xattrs --no-bindings)
echo "commit=$CSUM"

echo "### 4. deploy into a sysroot (in a user namespace)"
SYSROOT="$W/sysroot"; mkdir -p "$SYSROOT"
unshare -r bash -c "
  set -e
  '$OSTREE' admin init-fs --modern '$SYSROOT'
  '$OSTREE' pull-local --repo='$SYSROOT/ostree/repo' '$REPO' buckos/boot
  '$OSTREE' admin stateroot-init --sysroot='$SYSROOT' buckos
  '$OSTREE' admin deploy --sysroot='$SYSROOT' --os=buckos --karg=rw --karg=console=ttyS0 buckos/boot
"
OSTREE_KARG=$(grep -ohE 'ostree=[^ ]+' "$SYSROOT"/boot/loader*/entries/*.conf | head -1)
echo "ostree karg: $OSTREE_KARG"

echo "### 5. build initramfs (ostree-prepare-root + busybox + glibc/glib/openssl libs)"
I="$W/initramfs"; mkdir -p "$I/usr/bin" "$I/lib64" "$I/proc" "$I/sys" "$I/dev" "$I/sysroot"
ln -s usr/bin "$I/bin"
cp "$BUSYBOX" "$I/usr/bin/busybox"; chmod 0755 "$I/usr/bin/busybox"
cp "$PREPARE" "$I/usr/bin/ostree-prepare-root"
for lib in $(ldd "$PREPARE" 2>/dev/null | grep -oE '/[^ ]+\.so[^ ]*' | sort -u); do
  cp -L "$lib" "$I/lib64/" 2>/dev/null || true
done
# Use the buckos (target) glibc loader+libs the ostree libs were built for: the
# seed/toolchain loader mishandles them in a minimal root (relocations -> SEGV).
# Then strip build-time rpaths (a stray DT_RPATH also trips loader assertions),
# so the loader resolves only from /lib64.
cp -Lf "$GLIBC"/*.so* "$I/lib64/" 2>/dev/null || true
"$PATCHELF" --remove-rpath "$I/usr/bin/ostree-prepare-root" 2>/dev/null || true
for so in "$I"/lib64/*.so*; do "$PATCHELF" --remove-rpath "$so" 2>/dev/null || true; done
cat > "$I/init" <<EOF
#!/usr/bin/busybox sh
/usr/bin/busybox mount -t proc proc /proc
/usr/bin/busybox mount -t sysfs sysfs /sys
/usr/bin/busybox mount -t devtmpfs devtmpfs /dev
/usr/bin/busybox mkdir -p /run /sysroot
/usr/bin/busybox mount -t tmpfs tmpfs /run
/usr/bin/busybox mount --make-rprivate / 2>/dev/null || true
/usr/bin/busybox mount -t ext4 /dev/vda /sysroot || { echo "PREP: mount FAILED"; /usr/bin/busybox sh; }
# Faithful path (WIP): ostree-prepare-root sets up the read-only /usr + /etc merge.
/lib64/ld-linux-x86-64.so.2 --library-path /lib64 /usr/bin/ostree-prepare-root /sysroot 2>&1
if /usr/bin/busybox test -e /sysroot/sbin/init; then
  exec /usr/bin/busybox switch_root /sysroot /sbin/init
fi
# Fallback: boot the deployment directly (proves the deployed content boots).
DEPLOY=\$(/usr/bin/busybox find /sysroot/ostree/deploy -maxdepth 3 -name '*.0' -type d | /usr/bin/busybox head -1)
/usr/bin/busybox mkdir -p /newroot
/usr/bin/busybox mount --bind "\$DEPLOY" /newroot
/usr/bin/busybox mkdir -p /newroot/sysroot
/usr/bin/busybox mount --bind /sysroot /newroot/sysroot
exec /usr/bin/busybox switch_root /newroot /sbin/init
EOF
chmod 0755 "$I/init"
( cd "$I" && find . -print0 | cpio --null -o -H newc --quiet | gzip > "$W/initramfs.cpio.gz" )

echo "### 6. ext4 disk from the sysroot (mke2fs -d, unprivileged)"
DISK="$W/sysroot.ext4"
truncate -s 768M "$DISK"
"$MKE2FS" -q -F -t ext4 -d "$SYSROOT" "$DISK"

echo "### 7. boot QEMU (-cpu host: buckos userspace is x86-64-v3)"
timeout 120 "$QEMU" -enable-kvm -cpu host -display none -serial stdio -monitor none -m 1024 -smp 2 -no-reboot \
  -kernel "$BZIMAGE" -initrd "$W/initramfs.cpio.gz" \
  -append "console=ttyS0 $OSTREE_KARG rw panic=3" \
  -drive file="$DISK",if=virtio,format=raw > "$W/qemu.log" 2>&1 || true

echo "### result"
if grep -aq "$MARKER" "$W/qemu.log"; then
  echo "BOOT_VALIDATED: deployed ostree commit reached userspace ($MARKER)"
  exit 0
else
  echo "BOOT_NOT_VALIDATED (see $W/qemu.log)"; exit 1
fi
