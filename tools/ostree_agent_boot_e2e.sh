#!/bin/bash
# End-to-end BOOT test of the buckos-update agent driving an atomic update from
# INSIDE a booted ostree guest (SPEC-006 P4 booted-context paths). This covers
# what tools/ostree_update_e2e.sh deliberately cannot: status/check/rollback
# parse the *booted* deployment, so they only work on a live system.
#
# One stateful disk is booted three times; the agent (running as the guest's
# init) drives the transitions and the host re-reads the default deployment's
# kernel arg between boots (via debugfs, unprivileged):
#
#   boot 1  (deployment A)  status=*A, check finds B, pull + deploy B   -> reboot
#   boot 2  (deployment B)  status=*B, rollback to A                    -> reboot
#   boot 3  (deployment A)  status=*A                                   -> done
#
# Proves: the agent identifies the booted deployment across the cycle (status),
# detects the signed update (check), applies it so the next boot lands on B
# (pull+deploy), and restores A on the boot after that (rollback).
#
# Requires: KVM, unprivileged user namespaces, and a QEMU with -cpu host
# (buckos userspace is x86-64-v3). Builds nothing heavy itself beyond what the
# slice/kernel/initramfs targets already produced; self-skips (exit 0) when KVM
# or userns is unavailable.
set -eu
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo /home/hodgesd/buckos-build)"
BB=$PWD
BUCK2=${BUCK2:-./buck2}
GEN=buck-out/v2/gen/buckos
find1(){ find "$GEN" -path "$1" 2>/dev/null | head -1; }

if ! unshare -r true 2>/dev/null; then echo "SKIP: no unprivileged user namespaces"; exit 0; fi
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then echo "SKIP: /dev/kvm not accessible"; exit 0; fi

echo "### build inputs (kernel, ostree initramfs, ostree+agent slice, e2fsprogs)"
"$BUCK2" build \
  //packages/linux/kernel/buckos-kernel:buckos-kernel-live \
  //packages/linux/system/ostree-image:buckos-ostree-initramfs \
  //packages/linux/system/ostree-image:ostree-update-rootfs \
  //packages/linux/system/filesystem/native/e2fsprogs:e2fsprogs >/dev/null 2>&1 || true

# Inputs default to the buck-out artifacts (local dev) but are env-overridable so
# a buckos_test wrapper can pass them hermetically via $(location).
BZIMAGE=${BZIMAGE:-$PWD/$(find1 '*buckos-kernel-live*/build-tree/arch/x86/boot/bzImage')}
INITRD=${INITRD:-$PWD/$(find1 '*buckos-ostree-initramfs*cpio.gz')}
SLICE=${SLICE:-$PWD/$(find1 '*__ostree-update-rootfs__/ostree-update-rootfs')}
MKE2FS=${MKE2FS:-$PWD/$(find1 '*e2fsprogs*/installed/usr/sbin/mke2fs')}
DEBUGFS=${DEBUGFS:-$PWD/$(find1 '*e2fsprogs*/installed/usr/sbin/debugfs')}
# QEMU portability: QEMU=binary; QEMU_PREFIX=optional run-env wrapper (for the
# portabilized buckos qemu); QEMU_L=optional firmware dir for -L. Default to a
# host qemu for local runs.
QEMU=${QEMU:-/opt/fb-qemu/bin/qemu-system-x86_64}
QEMU_CMD=()
[ -n "${QEMU_PREFIX:-}" ] && QEMU_CMD+=("$QEMU_PREFIX")
QEMU_CMD+=("$QEMU")
[ -n "${QEMU_L:-}" ] && QEMU_CMD+=(-L "$QEMU_L")
KEY=$PWD/defs/keys/ostree-test.ed25519.key
PUB=$(cat "$PWD/defs/keys/ostree-test.ed25519.pub")
REF=buckos/x86_64/test

for v in BZIMAGE:"$BZIMAGE" INITRD:"$INITRD" SLICE:"$SLICE" MKE2FS:"$MKE2FS" DEBUGFS:"$DEBUGFS"; do
  p=${v#*:}; [ -e "$p" ] || { echo "SKIP: missing ${v%%:*} ($p)"; exit 0; }
done
[ -x "$QEMU" ] || { echo "SKIP: no qemu at $QEMU (set \$QEMU)"; exit 0; }
[ -x "$SLICE/usr/bin/buckos-update" ] || { echo "SKIP: no agent in slice"; exit 0; }

# buckos ostree PIE via the slice's own glibc env (for host-side repo setup).
LD="$SLICE/lib64/ld-linux-x86-64.so.2"; LIBS="$SLICE/usr/lib:$SLICE/lib64"
ostree(){ "$LD" --library-path "$LIBS" "$SLICE/usr/bin/ostree" "$@"; }

W=${W:-/tmp/ostree_agent_boot_e2e}; rm -rf "$W"; mkdir -p "$W"

# ---- the agent driver init (same in both A and B; branches on a state file on
# the persistent physical root /sysroot, which survives reboots) ---------------
write_init(){  # $1=dest
  cat > "$1" <<'INIT'
#!/usr/bin/busybox sh
bb=/usr/bin/busybox
$bb mount -t proc proc /proc 2>/dev/null || true
$bb mount -t sysfs sys /sys 2>/dev/null || true
$bb mount -t devtmpfs dev /dev 2>/dev/null || true
$bb mount -t tmpfs tmpfs /run 2>/dev/null || true
# ostree reports a *booted* deployment only when /run/ostree-booted exists; on a
# real system the ostree systemd units create it. We booted via
# ostree-prepare-root, so assert it.
$bb touch /run/ostree-booted 2>/dev/null || true
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
export BUCKOS_OSTREE=/usr/bin/ostree

S=/sysroot/e2e; $bb mkdir -p "$S"
state=$($bb cat "$S/state" 2>/dev/null || echo 0)
ver=$($bb cat /usr/share/e2e-version 2>/dev/null || echo "?")
A(){ /usr/bin/buckos-update --sysroot=/ --os=buckos --remote=buckos --branch=buckos/x86_64/test "$@" 2>&1; }
# booted? -> a leading "* " line in `buckos-update status`
booted(){ A status | $bb grep -q '^\* '; }

echo "E2E_MARK state=$state ver=$ver"
echo "--- status ---"; A status

case "$state" in
  0)
    [ "$ver" = a ] && echo "E2E_A_OK"            || echo "E2E_A_FAIL(ver=$ver)"
    booted          && echo "E2E_STATUS1_OK"     || echo "E2E_STATUS1_FAIL"
    echo "--- check ---"; A check
    echo "--- pull ---";  A pull   && echo "E2E_PULL_OK"   || echo "E2E_PULL_FAIL"
    echo "--- deploy ---";A deploy && echo "E2E_DEPLOY_OK" || echo "E2E_DEPLOY_FAIL"
    echo 1 > "$S/state"; echo "E2E_BOOT1_DONE"
    ;;
  1)
    [ "$ver" = b ] && echo "E2E_B_OK"            || echo "E2E_B_FAIL(ver=$ver)"
    booted          && echo "E2E_STATUS2_OK"     || echo "E2E_STATUS2_FAIL"
    echo "--- rollback ---"; A rollback && echo "E2E_ROLLBACK_OK" || echo "E2E_ROLLBACK_FAIL"
    echo 2 > "$S/state"; echo "E2E_BOOT2_DONE"
    ;;
  2)
    [ "$ver" = a ] && echo "E2E_A2_OK"           || echo "E2E_A2_FAIL(ver=$ver)"
    booted          && echo "E2E_STATUS3_OK"     || echo "E2E_STATUS3_FAIL"
    echo 3 > "$S/state"; echo "E2E_BOOT3_DONE"; echo "E2E_ALL_OK"
    ;;
  *) echo "E2E_UNEXPECTED_STATE=$state" ;;
esac
$bb sync
$bb poweroff -f
INIT
  chmod 0755 "$1"
}

mktree(){  # $1=dir $2=version  -- slice + driver init + os-release + dummy kernel
  cp -a "$SLICE" "$1"
  mkdir -p "$1/usr/sbin" "$1/usr/lib/modules/6.0.0-buckos" "$1/usr/share"
  printf 'ID=buckos\nNAME=BuckOS\nPRETTY_NAME="BuckOS %s"\nVERSION_ID=%s\n' "$2" "$2" > "$1/usr/lib/os-release"
  printf '%s\n' "$2" > "$1/usr/share/e2e-version"
  printf 'DUMMYKERNEL\n' > "$1/usr/lib/modules/6.0.0-buckos/vmlinuz"
  write_init "$1/usr/sbin/init"
}

echo "### assemble agent-capable trees A and B"
mktree "$W/treeA" a
mktree "$W/treeB" b
python3 tools/ostree_rootfs_helper.py --input "$W/treeA" --output "$W/shapedA" >/dev/null
python3 tools/ostree_rootfs_helper.py --input "$W/treeB" --output "$W/shapedB" >/dev/null

echo "### signed channel: commit A, deploy A into a sysroot, then commit B as the tip"
REPO="$W/channel"
ostree --repo="$REPO" init --mode=archive-z2 >/dev/null
# This is a scratch repo on whatever fs holds $W (often a near-full root fs);
# ostree's default 3% free-space guard would refuse to commit there.
ostree --repo="$REPO" config set core.min-free-space-percent 0
ostree --repo="$REPO" commit --branch="$REF" --tree=dir="$W/shapedA" \
  --timestamp=@1700000000 --owner-uid=0 --owner-gid=0 --no-bindings >/dev/null
CKA=$(ostree --repo="$REPO" rev-parse "$REF")
ostree --repo="$REPO" sign --sign-type=ed25519 --keys-file="$KEY" "$CKA"

SYS="$W/sysroot"; mkdir -p "$SYS"
unshare -r bash -c "
  set -e
  O(){ '$LD' --library-path '$LIBS' '$SLICE/usr/bin/ostree' \"\$@\"; }
  O admin init-fs --modern '$SYS'
  O --repo='$SYS/ostree/repo' config set core.min-free-space-percent 0
  O pull-local --repo='$SYS/ostree/repo' '$REPO' '$CKA'
  O admin stateroot-init --sysroot='$SYS' buckos
  O admin deploy --sysroot='$SYS' --os=buckos --karg=rw '$CKA'
"
ostree --repo="$REPO" commit --branch="$REF" --tree=dir="$W/shapedB" \
  --timestamp=@1700000001 --owner-uid=0 --owner-gid=0 --no-bindings >/dev/null
CKB=$(ostree --repo="$REPO" rev-parse "$REF")
ostree --repo="$REPO" sign --sign-type=ed25519 --keys-file="$KEY" "$CKB"
echo "    A=${CKA%${CKA#????????}}  B=${CKB%${CKB#????????}}"

echo "### verifying remote + embed the channel at /sysroot/channel"
ostree remote add --repo="$SYS/ostree/repo" buckos "file:///sysroot/channel" "$REF" \
  --set=sign-verify=true --set=verification-ed25519-key="$PUB"
cp -a "$REPO" "$SYS/channel"

echo "### ext4 disk (mke2fs -d, unprivileged)"
DISK="$W/disk.ext4"; truncate -s 4G "$DISK"
"$MKE2FS" -q -F -t ext4 -d "$SYS" "$DISK"

# The default (index-0) deployment's `ostree=` karg, read from the on-disk BLS
# entries with debugfs (no mount needed). ostree numbers the boot path trailing
# component by deployment index, so the default is the entry ending in /0.
default_karg(){  # $1=disk
  local names n karg
  names=$("$DEBUGFS" -R "ls -p /boot/loader/entries" "$1" 2>/dev/null \
          | tr '/' '\n' | grep '\.conf$' || true)
  for n in $names; do
    karg=$("$DEBUGFS" -R "cat /boot/loader/entries/$n" "$1" 2>/dev/null \
           | grep -oE 'ostree=[^ ]+' | head -1)
    case "$karg" in */0) echo "$karg"; return 0;; esac
  done
  return 1
}

echo "### multi-boot cycle"
rc=0
have(){ grep -aq "$1" "$2"; }
for n in 1 2 3; do
  karg=$(default_karg "$DISK") || { echo "FAIL: no default karg before boot $n"; rc=1; break; }
  log="$W/boot$n.log"
  timeout 180 "${QEMU_CMD[@]}" -enable-kvm -cpu host -display none -serial stdio -monitor none \
    -m 2048 -smp 2 -no-reboot \
    -kernel "$BZIMAGE" -initrd "$INITRD" \
    -append "console=ttyS0 root=/dev/vda $karg rw panic=3" \
    -drive file="$DISK",if=virtio,format=raw > "$log" 2>&1 || true
  echo "--- boot $n (karg=${karg##*/buckos/}) ---"
  sed -n '/E2E_MARK/,/E2E_BOOT'"$n"'_DONE/p' "$log" | grep -E '^E2E_|available' || tail -5 "$log"
  case "$n" in
    1) for m in E2E_A_OK E2E_STATUS1_OK E2E_PULL_OK E2E_DEPLOY_OK E2E_BOOT1_DONE; do
         have "$m" "$log" || { echo "  MISSING: $m"; rc=1; }; done ;;
    2) for m in E2E_B_OK E2E_STATUS2_OK E2E_ROLLBACK_OK E2E_BOOT2_DONE; do
         have "$m" "$log" || { echo "  MISSING: $m"; rc=1; }; done ;;
    3) for m in E2E_A2_OK E2E_STATUS3_OK E2E_ALL_OK; do
         have "$m" "$log" || { echo "  MISSING: $m"; rc=1; }; done ;;
  esac
  grep -aq E2E_ALL_OK "$log" && break
done

echo "### result"
if [ "$rc" = 0 ] && grep -aq E2E_ALL_OK "$W/boot3.log" 2>/dev/null; then
  echo "OSTREE_AGENT_BOOT_E2E_OK: agent status/check/pull/deploy/rollback verified across A->B->A reboots"
  exit 0
else
  echo "OSTREE_AGENT_BOOT_E2E FAILED (logs in $W)"; exit 1
fi
