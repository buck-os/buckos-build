---
id: "SPEC-007"
title: "Verified Boot and Update Signing"
status: "draft"
version: "0.1.0"
created: "2026-06-16"
updated: "2026-06-16"

authors:
  - name: "BuckOS Team"
    email: "team@buckos.org"

maintainers:
  - "team@buckos.org"

category: "core"
tags:
  - "security"
  - "signing"
  - "verified-boot"
  - "ostree"
  - "ed25519"

related:
  - "SPEC-001"
  - "SPEC-006"
---

# SPEC-007: Verified Boot and Update Signing

## 1. Summary

Make every BuckOS system image **cryptographically signed and verified end to
end**. SPEC-006 distributes the whole booted system as a content-addressed
ostree commit served over plain HTTP; this spec adds **ed25519 signatures** to
those commits and **enforces verification** at every point content enters or
activates on a machine (pull, deploy, install), so a system only ever runs an
image signed by the BuckOS release key.

Signing is **ed25519**, not GPG: our libostree is built `--with-crypto=openssl`
+ `sign-ed25519` and `--without-gpgme` (SPEC-006 §5.1), so the GPG path is not
available and ed25519 is the native, modern choice. The `ostree_commit` rule
already scaffolds `--key-file` for this.

The work is layered into two tiers:

- **Tier 1 — update-path signing (this spec's core, implemented now):** sign
  release commits; clients fail closed on an unsigned or untrusted commit.
- **Tier 2 — UEFI Secure Boot chain (kernel signing + enforcement proven;
  full chain in progress):** the firmware verifies the boot artifact before
  Linux runs, so an *offline* attacker with disk access cannot substitute a
  deployment either. Kernel-EFI-stub signing (`efi_sign`/osslsigncode),
  PK/KEK/db enrollment (`efitools`), and firmware-enforced rejection of an
  unsigned kernel are **implemented and proven against OVMF**
  (`tools/secureboot_validate.sh`, §5.6). Signing the bootloader with `sbat`
  and a Unified Kernel Image (so the initramfs is signature-covered) remain.

This is additive to SPEC-006 and changes no default of the source-based path.

## 2. Motivation

BuckOS already gives **build integrity** (reproducible, content-addressed
outputs). It does not yet give **distribution authenticity**: SPEC-006 pulls
commits from an HTTP mirror, and a compromised mirror, cache, or
man-in-the-middle can serve a malicious image that ostree will happily deploy.
Content addressing detects accidental corruption, not a deliberately
substituted-but-self-consistent image. TLS authenticates the *transport*, not
the *content* — it does not help once a mirror is compromised or a stale/rogue
object is cached.

### Problems solved

- **Rogue/compromised mirror or MITM** serving a tampered system image.
- **Rollback safety:** only ever roll back to a previously *verified*
  deployment.
- **Provenance:** an operator can prove an installed system came from the
  BuckOS release pipeline.

## 3. Goals / Non-Goals

### Goals

1. Every published channel commit (SPEC-006 §5.7) is **ed25519-signed** by a
   release key.
2. `pull`, `deploy`, and first-boot install **refuse** an unsigned or
   untrusted-key commit (fail closed).
3. The **private** key lives only in CI; the **public** key is baked into the
   image and is the on-disk trust anchor.
4. A documented **key-rotation** procedure.
5. A negative CI gate: a tampered/unsigned commit is **rejected**.
6. Tier 2 (Secure Boot) designed well enough to implement later without rework.

### Non-Goals (initial)

1. **GPG signing** — no gpgme in our libostree.
2. **composefs / fs-verity** runtime integrity — libostree built without
   composefs (SPEC-006 §8); revisit for stronger at-rest integrity.
3. **Full UEFI Secure Boot** implementation (Tier 2): shim/CA, signed
   kernel+initramfs, MOK/sbat — specified, deferred.
4. **TPM measured boot / remote attestation.**
5. **Multi-key / threshold signing** — single release key initially.

## 4. Trust Model

### 4.1 Keys and roles

- **Release signing key** — an ed25519 keypair. The *secret* is a CI secret
  (`BUCKOS_OSTREE_SIGN_KEY`), never in the tree. The *public* key is, by
  definition, public: checked into `buckos-build` and shipped in every image.
- **On-disk trust anchor** — the public key materialized in the image and
  referenced by the ostree remote's `verification-file`, with the remote set
  `sign-verify=true`.

### 4.2 Where verification happens

| Stage | Actor | Mechanism |
|-------|-------|-----------|
| Release | CI | `ostree sign --sign-type=ed25519` on the channel commit (via `ostree_commit --key-file`) |
| Pull | client | remote `sign-verify=true` → ostree verifies the signature before the commit enters the local repo |
| Deploy | client | only commits already in the local (verified) repo are deployable |
| Boot | initramfs | the booted deployment is one verified at pull time (Tier 1); per-boot tamper-evidence is Tier 2 |

The key property: **content is verified at the moment it crosses the trust
boundary** (network → local repo). Everything downstream operates on
already-verified objects.

### 4.3 What is and is not protected (be honest)

- **Protected (Tier 1):** authenticity + integrity of every downloaded commit;
  rollback only to previously verified deployments; detection of a
  rogue/compromised mirror or MITM.
- **Not protected until Tier 2:** an attacker with **offline write access to
  the disk** can modify a local deployment or the unsigned kernel/initramfs.
  Closing this requires UEFI Secure Boot + signed kernel/initramfs (and ideally
  fs-verity). This gap is stated explicitly so the Tier-1 guarantee is not
  over-claimed.

## 5. BuckOS Integration

### 5.1 Key management (S1)

Generate an ed25519 keypair in libostree's ed25519 convention (base64 of the
64-byte secret and 32-byte public key). The secret is stored as the
`BUCKOS_OSTREE_SIGN_KEY` GitHub Actions secret; the public key is committed to
`buckos-build` (e.g. `keys/ostree-release.ed25519.pub`) and exported for the
image build. Exact generation mechanics are validated in S1 because SPEC-006
left `--key-file` signing untested.

### 5.2 Signing at release (S2)

The per-channel release step (SPEC-006 §5.7) passes the CI key to the existing
`ostree_commit` `signing_key` / `tools/ostree_helper.py --key-file`, so each
channel ref (`buckos/x86_64/{stable,lts,mainline}`) is signed. Verify with
`ostree show --print-detached-metadata-key=ostree.sign.ed25519` (or
`ostree sign --verify`). The repo `summary` is signed as well.

### 5.3 Public key in the image (S3)

The ostree-image rootfs (SPEC-006 `buckos-ostree-rootfs`) materializes the
public key and a remote config fragment with `sign-verify=true` +
`verification-file=<key path>`, so a freshly deployed system already trusts the
release key with no first-run step.

### 5.4 Update-agent enforcement (S3)

`buckos-update` (SPEC-006 §5.6, a standalone crate) uses a remote with
`sign-verify=true`; `pull` and `deploy` **fail closed** on a verification
error; `status` surfaces the signature state of the running and pending
deployments.

### 5.5 Installer enforcement (S3)

The installer's ostree image-mode (SPEC-006 §5.5) writes the remote with the
trusted public key and `sign-verify=true` **before** the first `pull`, so an
install can never pull an unverified initial commit.

### 5.6 Verified boot — Tier 2 (UEFI Secure Boot)

For at-rest / offline-tamper resistance, the firmware itself verifies the boot
chain before Linux runs.

**Key hierarchy** (standard UEFI SB): Platform Key (PK) → Key Exchange Key
(KEK) → signature database (db). Test keys are in `defs/keys/secureboot-*` (NOT
for production — real keys belong in CI / an HSM). The db key signs boot
artifacts; PK/KEK authorize updates to the firmware key store.

**Signing — implemented.** `efi_sign` (`defs/rules/secureboot.bzl`) signs an EFI
PE binary — the kernel's EFI stub, and later the bootloader — with the db key
using the buckos-built `osslsigncode` (an OpenSSL-based Authenticode/PE signer),
then self-verifies against the db cert (the same check firmware does against the
enrolled db). `//tests/fixtures/secureboot:signed-kernel` signs the live kernel;
`//tests:test-secureboot-sign` asserts the signature was attached. `osslsigncode`
is the chosen route over the canonical `sbsign`/`shim` because it is already
packaged — no shim or Microsoft-CA dependency for a self-managed key set.

**Enrollment — implemented.** `efitools` (host tools `cert-to-efi-sig-list` +
`flash-var`, plus `gnu-efi` headers) is packaged
(`//packages/linux/system/security/efitools`). `cert-to-efi-sig-list` turns each
X.509 cert (PK/KEK/db) into an EFI signature list; `flash-var` writes them into
an offline `OVMF_VARS` image, taking the firmware from setup mode to user mode
with Secure Boot enforcing.

**Firmware enforcement — proven.** `tools/secureboot_validate.sh` exercises the
whole chain against OVMF Secure Boot (`q35,smm=on`, `secure=on`, the enrolled
vars) and asserts:

- the **signed** kernel placed at `\EFI\BOOT\BOOTX64.EFI` on a GPT ESP is
  **accepted** — OVMF's `LoadImage` SB-verifies it and `BdsDxe` starts it;
- the **unsigned** kernel in the same slot is **rejected** —
  `BdsDxe: failed to load … : Access Denied`;
- the signed kernel **boots to init** (a busybox marker initramfs prints
  `SECUREBOOT_INIT_OK`).

Two QEMU specifics drove the test design and are recorded so the gate is not
over-claimed: (1) QEMU's `-kernel` loads the image via `fw_cfg`, **not**
`LoadImage`, so it bypasses Secure Boot (an unsigned kernel boots that way too) —
hence enforcement is tested via the **ESP/`LoadImage`** path, not `-kernel`;
(2) `flash-var` only writes time-based-authenticated variables (PK/KEK/db), not
regular `Boot####`, so the ESP-booted kernel gets no cmdline and runs silently
after a verified start — the *boots-to-init* assertion therefore uses `-kernel`
(SB-bypassing but proving the signed binary is a working bootable kernel), while
*enforcement* is proven by the ESP accept/reject pair above.

**`sbat`, bootloader, initramfs — remaining.** A complete chain also signs the
bootloader (GRUB/systemd-boot EFI) with `sbat` revocation metadata, and either
signs the initramfs or uses a Unified Kernel Image (systemd-stub, not yet
packaged) so the initramfs is covered by the kernel signature and a *single*
SB-verified artifact reaches init via `LoadImage`. These compose with `efi_sign`
and are follow-ons.

This is additive and does not change the Tier-1 design.

## 6. Phased Implementation Plan

| Phase | Deliverable | Gate |
|-------|-------------|------|
| S1 | ed25519 keypair + CI secret + public key in `buckos-build`; validate `ostree sign` round-trip | `ostree sign --verify` accepts a locally signed commit |
| S2 | Release/channel step signs each commit + summary | `ostree show` reports an `ostree.sign.ed25519` signature |
| S3 | `sign-verify=true` remote baked in image; agent + installer fail closed | a system trusts only the release key out of the box |
| S4 | CI: positive (signed pull/deploy) + negative (tampered → rejected) | green nightly, userns-aware like the sysroot gate |
| S5a | `efi_sign` signs the kernel EFI stub with the db key (osslsigncode) | `test-secureboot-sign` passes; the signed image self-verifies against db |
| S5b | Package `efitools`/`gnu-efi`; enroll PK/KEK/db into firmware + an OVMF Secure-Boot boot test | `secureboot_validate.sh`: signed accepted, unsigned rejected (Access Denied), boots to init |
| S5c (remaining) | Sign the bootloader (GRUB/systemd-boot) with `sbat`; UKI so initramfs is signature-covered | a single SB-verified artifact reaches init via `LoadImage` |

S1–S4 are Tier 1 and land alongside SPEC-006 P4/P5. S5a–S5b (Tier-2 kernel
signing + key enrollment + the firmware-enforced boot test) are **done** — real
Secure Boot enforcement is proven against OVMF with buckos-packaged tools. S5c
(signed bootloader + `sbat` + UKI) is the remaining follow-on. Each is
independently testable.

## 7. Considered Alternatives

- **GPG signing** (ostree's traditional path). Rejected: our libostree is built
  `--without-gpgme`; adding gpgme enlarges the trusted surface for no benefit
  over ed25519.
- **TLS-only distribution.** Rejected: authenticates the transport, not the
  content; a compromised mirror or poisoned cache still serves bad images.
- **The Update Framework (TUF).** Richer (role separation, threshold keys,
  freeze/rollback attack resistance) but heavier; ostree's native ed25519 is
  sufficient for a single-key release model. Revisit if multi-party / threshold
  signing is needed.
- **composefs + fs-verity** for at-rest integrity. Deferred: not compiled into
  our libostree; complementary to (not a replacement for) signing, and closer
  to the Tier-2 concern.

## 8. Risks & Open Questions

- **Single key is a SPOF.** Rotation: publish the new public key in an update
  signed by the *current* key, switch the release key, then retire the old one
  (clients trust both during the overlap). Multi-key/threshold is future work.
- **Tier-1 boot gap** (offline disk tamper) is real and must be documented in
  user-facing docs, not papered over.
- **ed25519 mechanics unproven in our build.** SPEC-006 shipped `--key-file`
  support but never exercised it; S1/S2 must validate keygen, sign, and verify
  against our exact libostree version.
- **Summary + static-delta signing** details (what metadata is signed, and how
  `buckos-update check` validates it) to be pinned in S2.
- **Key storage hygiene** in CI (least-privilege secret, audit, no echo into
  logs).

## 9. Acceptance Criteria

1. Every published channel commit and summary carries an `ostree.sign.ed25519`
   signature from the release key.
2. A client holding the trusted public key pulls and deploys a signed commit,
   and **rejects** a tampered or unsigned one.
3. `buckos-update` and the installer both **fail closed** on a verification
   error.
4. A freshly installed system trusts only the release key with no manual step.
5. CI gates both the positive and negative paths.
6. Tier 1 is implemented; Tier 2 (Secure Boot) is fully specified for a later
   pass.
