#!/bin/bash
# Validate UEFI Secure Boot end to end for BuckOS (SPEC-007 Tier 2 / S5b).
#
# Proves the full chain with buckos-packaged tools:
#   1. efi_sign signs the kernel's EFI stub with the Secure Boot db key
#      (osslsigncode).
#   2. efitools (cert-to-efi-sig-list + flash-var) enrolls our PK/KEK/db into an
#      offline OVMF_VARS image (setup mode -> user mode, SB enforcing).
#   3. Firmware enforcement, via OVMF's LoadImage from a GPT ESP:
#        - the SIGNED kernel is ACCEPTED  (BdsDxe: starting Boot...)
#        - the UNSIGNED kernel is REJECTED (BdsDxe: failed ... Access Denied)
#   4. The signed kernel boots all the way to init (SECUREBOOT_INIT_OK) with a
#      marker initramfs (direct kernel boot; proves it is a working bootable
#      kernel — the -kernel path is not SB-gated by OVMF, hence the ESP test
#      above for enforcement).
#
# Requires: KVM + a QEMU with -cpu host, and OVMF secboot firmware
# (/usr/share/edk2/ovmf/OVMF_CODE.secboot.fd + OVMF_VARS.fd).  Self-skips
# (exit 0) when those are unavailable.
set -eu
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo /home/hodgesd/buckos-build)"
BB=$PWD
GEN=$BB/buck-out/v2/gen/buckos
QEMU=${QEMU:-/opt/fb-qemu/bin/qemu-system-x86_64}
OVMF_CODE=${OVMF_CODE:-/usr/share/edk2/ovmf/OVMF_CODE.secboot.fd}
OVMF_VARS=${OVMF_VARS:-/usr/share/edk2/ovmf/OVMF_VARS.fd}
W=${W:-/tmp/secureboot_validate}; rm -rf "$W"; mkdir -p "$W"

if [ ! -r /dev/kvm ] || [ ! -r "$OVMF_CODE" ] || [ ! -x "$QEMU" ]; then
  echo "SKIP: need /dev/kvm + OVMF secboot + QEMU"; exit 0
fi

echo "### build: signed kernel (efi_sign) + efitools + kernel"
./buck2 build //tests/fixtures/secureboot:signed-kernel \
              //packages/linux/system/security/efitools:efitools \
              //packages/linux/kernel/buckos-kernel:buckos-kernel-live >/dev/null 2>&1

SIGNED=$(find "$GEN" -path '*secureboot*signed-kernel*' -name 'signed-kernel.efi' | head -1)
UNSIGNED=$(find "$GEN" -path '*buckos-kernel-live*' -name bzimage -type f | head -1)
EFIDIR=$(find "$GEN" -path '*efitools*/installed/usr/bin' -type d | head -1)
LD=$(find "$GEN" -path '*seed*sys-root/lib64/ld-linux-x86-64.so.2' -print 2>/dev/null | while read -r f; do [ -e "$f" ] && echo "$f" && break; done)
LIBS=$(for p in openssl zlib; do find "$GEN" -path "*${p}*/installed/usr/lib*" -maxdepth 8 -type d 2>/dev/null; done | tr '\n' ':')
BUSYBOX=$(find "$GEN" -path '*busybox-static*' -name busybox -type f | head -1)
ET(){ "$LD" --library-path "$LIBS" "$EFIDIR/$@"; }

echo "### enroll our PK/KEK/db into a fresh OVMF_VARS (efitools)"
GUID=11111111-2222-3333-4444-555555555555
for v in db KEK PK; do
  case $v in db) c=secureboot-db.crt;; KEK) c=secureboot-KEK.crt;; PK) c=secureboot-PK.crt;; esac
  ET cert-to-efi-sig-list -g "$GUID" "$BB/defs/keys/$c" "$W/$v.esl" >/dev/null
done
enroll_vars(){ local out=$1; cp "$OVMF_VARS" "$out"
  for v in db KEK PK; do ET flash-var -t "2024-01-01 00:00:00" "$out" "$v" "$W/$v.esl" >/dev/null 2>&1; done; }

mk_esp(){ local img=$1 efi=$2; rm -f "$img"; truncate -s 96M "$img"
  parted -s "$img" mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on >/dev/null 2>&1
  mformat -i "$img@@1M" -F :: >/dev/null 2>&1
  mmd -i "$img@@1M" ::/EFI ::/EFI/BOOT >/dev/null 2>&1
  mcopy -i "$img@@1M" "$efi" ::/EFI/BOOT/BOOTX64.EFI >/dev/null 2>&1; }

boot_esp(){ local vars=$1 esp=$2 log=$3
  # The SB accept/reject verdict (BdsDxe starting / Access Denied) is printed
  # within ~15s; a silently-started kernel never exits, so cap the wait short.
  timeout 30 "$QEMU" -enable-kvm -machine q35,smm=on -cpu host -display none -serial stdio \
    -monitor none -m 2048 -no-reboot \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,unit=1,file="$vars" \
    -drive file="$esp",format=raw,if=virtio > "$log" 2>&1 || true
  tr -d '\000' < "$log"; }

rc=0

echo "### 1. NEGATIVE: unsigned kernel via ESP must be REJECTED"
enroll_vars "$W/vars-neg.fd"; mk_esp "$W/esp-neg.img" "$UNSIGNED"
out=$(boot_esp "$W/vars-neg.fd" "$W/esp-neg.img" "$W/neg.log")
if echo "$out" | grep -qiE "Access Denied|failed to load"; then echo "  PASS: unsigned rejected (Access Denied)"
else echo "  FAIL: unsigned not rejected"; rc=1; fi

echo "### 2. POSITIVE: signed kernel via ESP must be ACCEPTED"
enroll_vars "$W/vars-pos.fd"; mk_esp "$W/esp-pos.img" "$SIGNED"
out=$(boot_esp "$W/vars-pos.fd" "$W/esp-pos.img" "$W/pos.log")
if echo "$out" | grep -qiE "starting Boot" && ! echo "$out" | grep -qiE "Access Denied"; then
  echo "  PASS: signed accepted by Secure Boot (LoadImage started it)"
else echo "  FAIL: signed not accepted"; rc=1; fi

echo "### 3. signed kernel reaches init (marker initramfs, -kernel)"
IR=$W/ir; mkdir -p "$IR/bin"; cp "$BUSYBOX" "$IR/bin/busybox"; ln -sf busybox "$IR/bin/sh"
printf '#!/bin/busybox sh\n/bin/busybox mount -t proc proc /proc 2>/dev/null\n/bin/busybox echo SECUREBOOT_INIT_OK\n/bin/busybox sync\n/bin/busybox poweroff -f\n' > "$IR/init"; chmod 0755 "$IR/init"
( cd "$IR" && find . | cpio -o -H newc 2>/dev/null | gzip > "$W/initrd.gz" )
enroll_vars "$W/vars-init.fd"
timeout 60 "$QEMU" -enable-kvm -machine q35,smm=on -cpu host -display none -serial stdio -monitor none -m 2048 -no-reboot \
  -global driver=cfi.pflash01,property=secure,value=on \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,unit=1,file="$W/vars-init.fd" \
  -kernel "$SIGNED" -initrd "$W/initrd.gz" -append "console=ttyS0 panic=3" > "$W/init.log" 2>&1 || true
if grep -aq SECUREBOOT_INIT_OK "$W/init.log"; then echo "  PASS: signed kernel booted to init (SECUREBOOT_INIT_OK)"
else echo "  FAIL: did not reach init"; rc=1; fi

echo "### result"
[ "$rc" = 0 ] && echo "SECUREBOOT_VALIDATED: sign + enroll + firmware-enforced (signed accepted, unsigned rejected) + boots to init" \
              || echo "SECUREBOOT_VALIDATION FAILED (see $W/*.log)"
exit $rc
