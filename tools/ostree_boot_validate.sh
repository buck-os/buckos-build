#!/bin/bash
# Validate that a deployed BuckOS ostree commit boots in QEMU via the FAITHFUL
# ostree-prepare-root path (SPEC-006 P3).
#
# Pipeline: assemble a tiny bootable commit -> reshape (ostree_rootfs) ->
# commit (ostree_commit) -> deploy into a sysroot (ostree_sysroot-style, in a
# user namespace) -> ext4 disk (mke2fs -d) -> boot kernel + the dynamic-capable
# ostree initramfs + the disk.
#
# The initramfs is //packages/linux/system/ostree-image:buckos-ostree-initramfs
# -- a real rootfs slice (glibc + ostree + busybox, ldconfig'd) so the *dynamic*
# ostree-prepare-root binary runs.  Its /init has NO fallback, so reaching the
# marker means ostree-prepare-root set up the deployment (read-only /usr + /etc
# merge) and switch_root'd into it.
#
# (A hand-assembled /lib64 initramfs does NOT work: prepare-root segfaults
# pre-main under the buckos kernel.  The fix is this proper glibc environment.)
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
MKE2FS=$PWD/$(find1 '*e2fsprogs*/installed/usr/sbin/mke2fs')
QEMU=${QEMU:-/opt/fb-qemu/bin/qemu-system-x86_64}
MARKER=OSTREE_BOOT_OK_MARKER

W=${W:-/tmp/ostree_boot_work}; rm -rf "$W"; mkdir -p "$W"
echo "### kernel=$KVER  ostree=$OPREFIX"

echo "### 1. assemble bootable rootfs (busybox + init + os-release + kernel)"
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

echo "### 2. reshape into ostree layout + commit (archive repo)"
python3 tools/ostree_rootfs_helper.py --input "$R" --output "$W/shaped"
REPO="$W/repo"
"$OSTREE" --repo="$REPO" init --mode=archive
"$OSTREE" --repo="$REPO" commit --branch=buckos/boot --tree=dir="$W/shaped" \
  --timestamp=@0 --owner-uid=0 --owner-gid=0 --no-xattrs --no-bindings >/dev/null

echo "### 3. deploy into a sysroot (in a user namespace)"
SYSROOT="$W/sysroot"; mkdir -p "$SYSROOT"
unshare -r bash -c "
  set -e
  '$OSTREE' admin init-fs --modern '$SYSROOT'
  '$OSTREE' pull-local --repo='$SYSROOT/ostree/repo' '$REPO' buckos/boot
  '$OSTREE' admin stateroot-init --sysroot='$SYSROOT' buckos
  '$OSTREE' admin deploy --sysroot='$SYSROOT' --os=buckos --karg=rw buckos/boot
"
KARG=$(grep -ohE 'ostree=[^ ]+' "$SYSROOT"/boot/loader*/entries/*.conf | head -1)
echo "ostree karg: $KARG"

echo "### 4. build the dynamic-capable ostree initramfs (buck2)"
./buck2 build //packages/linux/system/ostree-image:buckos-ostree-initramfs >/dev/null 2>&1
INITRD=$PWD/$(find "$GEN" -path '*buckos-ostree-initramfs*' -name '*.cpio.gz' | head -1)

echo "### 5. ext4 disk from the sysroot (mke2fs -d, unprivileged)"
DISK="$W/sysroot.ext4"; truncate -s 768M "$DISK"
"$MKE2FS" -q -F -t ext4 -d "$SYSROOT" "$DISK"

echo "### 6. boot QEMU via ostree-prepare-root (-cpu host: x86-64-v3)"
timeout 120 "$QEMU" -enable-kvm -cpu host -display none -serial stdio -monitor none -m 1024 -smp 2 -no-reboot \
  -kernel "$BZIMAGE" -initrd "$INITRD" \
  -append "console=ttyS0 root=/dev/vda $KARG rw panic=3" \
  -drive file="$DISK",if=virtio,format=raw > "$W/qemu.log" 2>&1 || true

echo "### result"
if grep -aq "$MARKER" "$W/qemu.log"; then
  echo "BOOT_VALIDATED: deployed ostree commit booted via ostree-prepare-root ($MARKER)"
  exit 0
else
  echo "BOOT_NOT_VALIDATED (see $W/qemu.log)"; tail -20 "$W/qemu.log"; exit 1
fi
