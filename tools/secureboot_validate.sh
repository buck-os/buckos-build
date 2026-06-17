#!/bin/bash
# Validate UEFI Secure Boot end to end for BuckOS (SPEC-007 Tier 2, S5a-S5c).
#
# Proves the full chain with buckos-packaged tools:
#   1. efi_sign signs an EFI PE (the kernel stub, or a UKI) with the Secure Boot
#      db key (osslsigncode).
#   2. efitools (cert-to-efi-sig-list + flash-var) enrolls our PK/KEK/db into an
#      offline OVMF_VARS image (setup mode -> user mode, SB enforcing).
#   3. Firmware enforcement, via OVMF's LoadImage from a GPT ESP:
#        - a SIGNED EFI binary is ACCEPTED  (BdsDxe: starting Boot...)
#        - an UNSIGNED EFI binary is REJECTED (BdsDxe: failed ... Access Denied)
#   4. A signed Unified Kernel Image (systemd-stub + kernel + initramfs + cmdline,
#      all covered by ONE signature) boots all the way to init under real Secure
#      Boot (SECUREBOOT_INIT_OK); the unsigned UKI is rejected. This is the
#      complete chain: a single SB-verified artifact that reaches init.
#
# Note: QEMU's -kernel bypasses Secure Boot (it loads via fw_cfg, not LoadImage),
# so enforcement and the boot-to-init proof both go through the ESP/LoadImage
# path. The UKI carries its own cmdline + initrd, so it reaches init from the ESP
# (a bare kernel from the ESP starts but has no cmdline and runs silently).
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
OBJCOPY=${OBJCOPY:-/usr/local/bin/objcopy}
OBJDUMP=${OBJDUMP:-/usr/local/bin/objdump}
W=${W:-/tmp/secureboot_validate}; rm -rf "$W"; mkdir -p "$W"

if [ ! -r /dev/kvm ] || [ ! -r "$OVMF_CODE" ] || [ ! -x "$QEMU" ]; then
  echo "SKIP: need /dev/kvm + OVMF secboot + QEMU"; exit 0
fi

echo "### build: signed kernel + efitools + kernel + osslsigncode + systemd-boot stub"
./buck2 build //tests/fixtures/secureboot:signed-kernel \
              //packages/linux/system/security/efitools:efitools \
              //packages/linux/kernel/buckos-kernel:buckos-kernel-live \
              //packages/linux/system/security/osslsigncode:osslsigncode >/dev/null 2>&1
./buck2 build //packages/linux/boot/systemd-boot:systemd-boot \
              --target-platforms //platforms:linux-target-host >/dev/null 2>&1

# Resolve exact output paths via buck2 (a bare `find` over buck-out is minutes).
out(){ echo "$BB/$(./buck2 build "$@" --show-output 2>/dev/null | awk 'NF>=2{print $NF}' | head -1)"; }
SIGNED=$(out //tests/fixtures/secureboot:signed-kernel)
UNSIGNED=$(out //packages/linux/kernel/buckos-kernel:buckos-kernel-live)
STUB=$(out //packages/linux/boot/systemd-boot:systemd-boot --target-platforms //platforms:linux-target-host)/usr/lib/systemd/boot/efi/linuxx64.efi.stub
OSSL=$(out //packages/linux/system/security/osslsigncode:osslsigncode)/usr/bin/osslsigncode
EFIDIR=$(out //packages/linux/system/security/efitools:efitools)/usr/bin
LIBS="$(out //packages/linux/system/libs/crypto/openssl:openssl)/usr/lib:$(out //packages/linux/core/zlib:zlib)/usr/lib"
BUSYBOX=$(out //packages/linux/core/busybox:busybox-static)/bin/busybox
# The seed ld-linux is not a package output; scope the find to the tiny tc/seed subtree.
LD=$(find "$GEN"/*/tc/seed -path '*sys-root/lib64/ld-linux-x86-64.so.2' 2>/dev/null | head -1)
ET(){ "$LD" --library-path "$LIBS" "$EFIDIR/$@"; }
sign_efi(){ "$LD" --library-path "$LIBS" "$OSSL" sign -certs "$BB/defs/keys/secureboot-db.crt" \
  -key "$BB/defs/keys/secureboot-db.key" -h sha256 -in "$1" -out "$2" >/dev/null 2>&1; }

echo "### enroll our PK/KEK/db into a fresh OVMF_VARS (efitools)"
GUID=11111111-2222-3333-4444-555555555555
for v in db KEK PK; do
  case $v in db) c=secureboot-db.crt;; KEK) c=secureboot-KEK.crt;; PK) c=secureboot-PK.crt;; esac
  ET cert-to-efi-sig-list -g "$GUID" "$BB/defs/keys/$c" "$W/$v.esl" >/dev/null
done
enroll_vars(){ local out=$1; cp "$OVMF_VARS" "$out"
  for v in db KEK PK; do ET flash-var -t "2024-01-01 00:00:00" "$out" "$v" "$W/$v.esl" >/dev/null 2>&1; done; }

mk_esp(){ local img=$1 efi=$2; rm -f "$img"; truncate -s 64M "$img"
  parted -s "$img" mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on >/dev/null 2>&1
  mformat -i "$img@@1M" -F :: >/dev/null 2>&1
  mmd -i "$img@@1M" ::/EFI ::/EFI/BOOT >/dev/null 2>&1
  mcopy -i "$img@@1M" "$efi" ::/EFI/BOOT/BOOTX64.EFI >/dev/null 2>&1; }

boot_esp(){ local to=$1 vars=$2 esp=$3 log=$4
  timeout "$to" "$QEMU" -enable-kvm -machine q35,smm=on -cpu host -display none -serial stdio \
    -monitor none -m 2048 -no-reboot \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,unit=1,file="$vars" \
    -drive file="$esp",format=raw,if=virtio > "$log" 2>&1 || true
  tr -d '\000' < "$log"; }

rc=0

echo "### 1. NEGATIVE: unsigned kernel via ESP must be REJECTED"
enroll_vars "$W/vars-neg.fd"; mk_esp "$W/esp-neg.img" "$UNSIGNED"
out=$(boot_esp 30 "$W/vars-neg.fd" "$W/esp-neg.img" "$W/neg.log")
if echo "$out" | grep -qiE "Access Denied|failed to load"; then echo "  PASS: unsigned rejected (Access Denied)"
else echo "  FAIL: unsigned not rejected"; rc=1; fi

echo "### 2. POSITIVE: signed kernel via ESP must be ACCEPTED"
enroll_vars "$W/vars-pos.fd"; mk_esp "$W/esp-pos.img" "$SIGNED"
out=$(boot_esp 30 "$W/vars-pos.fd" "$W/esp-pos.img" "$W/pos.log")
if echo "$out" | grep -qiE "starting Boot" && ! echo "$out" | grep -qiE "Access Denied"; then
  echo "  PASS: signed accepted by Secure Boot (LoadImage started it)"
else echo "  FAIL: signed not accepted"; rc=1; fi

echo "### build a marker UKI (systemd-stub + kernel + initramfs + embedded cmdline)"
IR=$W/ir; mkdir -p "$IR/bin"; cp "$BUSYBOX" "$IR/bin/busybox"; ln -sf busybox "$IR/bin/sh"
printf '#!/bin/busybox sh\n/bin/busybox mount -t proc proc /proc 2>/dev/null\n/bin/busybox echo SECUREBOOT_INIT_OK\n/bin/busybox sync\n/bin/busybox poweroff -f\n' > "$IR/init"; chmod 0755 "$IR/init"
( cd "$IR" && find . | cpio -o -H newc 2>/dev/null | gzip > "$W/initrd.gz" )
printf 'console=ttyS0 panic=3\0' > "$W/cmdline.txt"
printf 'ID=buckos\nNAME="BuckOS"\nVERSION_ID=1\n' > "$W/os-release"
python3 "$BB/tools/assemble_uki.py" --stub "$STUB" --output "$W/uki.efi" \
  --objcopy "$OBJCOPY" --objdump "$OBJDUMP" \
  --osrel "$W/os-release" --cmdline "$W/cmdline.txt" --linux "$UNSIGNED" --initrd "$W/initrd.gz"
sign_efi "$W/uki.efi" "$W/uki-signed.efi"

echo "### 3. UKI POSITIVE: signed UKI boots to init under real Secure Boot"
enroll_vars "$W/vars-uki.fd"; mk_esp "$W/esp-uki.img" "$W/uki-signed.efi"
out=$(boot_esp 60 "$W/vars-uki.fd" "$W/esp-uki.img" "$W/uki-signed.log")
if echo "$out" | grep -qa SECUREBOOT_INIT_OK; then echo "  PASS: signed UKI reached init under Secure Boot (SECUREBOOT_INIT_OK)"
else echo "  FAIL: signed UKI did not reach init"; rc=1; fi

echo "### 4. UKI NEGATIVE: unsigned UKI must be REJECTED"
enroll_vars "$W/vars-ukin.fd"; mk_esp "$W/esp-ukin.img" "$W/uki.efi"
out=$(boot_esp 30 "$W/vars-ukin.fd" "$W/esp-ukin.img" "$W/uki-unsigned.log")
if echo "$out" | grep -qiE "Access Denied|failed to load" && ! echo "$out" | grep -qa SECUREBOOT_INIT_OK; then
  echo "  PASS: unsigned UKI rejected (Access Denied)"
else echo "  FAIL: unsigned UKI not rejected"; rc=1; fi

echo "### result"
[ "$rc" = 0 ] && echo "SECUREBOOT_VALIDATED: sign + enroll + firmware-enforced; signed UKI reaches init under Secure Boot, unsigned rejected" \
              || echo "SECUREBOOT_VALIDATION FAILED (see $W/*.log)"
exit $rc
