---
id: "SPEC-006"
title: "Atomic Image-Based Updates (ostree)"
status: "approved"
version: "1.0.0"
created: "2026-06-12"
updated: "2026-06-17"

authors:
  - name: "BuckOS Team"
    email: "team@buckos.org"

maintainers:
  - "team@buckos.org"

category: "core"
tags:
  - "updates"
  - "ostree"
  - "atomic"
  - "boot"
  - "reproducible"

related:
  - "SPEC-001"
  - "SPEC-004"
---

# SPEC-006: Atomic Image-Based Updates (ostree)

## 1. Summary

Give installed BuckOS systems **atomic, image-based updates with rollback**,
built on **libostree**. BuckOS already produces reproducible, content-addressed
package outputs; ostree extends that property to the *whole booted system*: each
system version is a content-addressed, GPG-signed commit; updates are staged
out-of-band and activated by an atomic boot-deployment switch; a failed update
rolls back to the previous deployment.

This is additive. The existing source-based installer path (build packages onto
a mounted root) remains; ostree adds an *image* path for systems that want
atomic updates.

## 2. Motivation

Today, changing software on an installed BuckOS system means rebuilding packages
on the host (Gentoo-style). There is no binary update channel, no atomicity, and
no rollback: an interrupted or broken update can leave an unbootable system.

ostree is the natural fit because:

- BuckOS builds are already **reproducible and content-addressed** — exactly
  ostree's model (a commit is a content-addressed Merkle tree of the rootfs).
- ostree is **proven** for this exact use case (Fedora Silverblue/IoT, Endless
  OS, Automotive). We integrate a mature subsystem rather than invent one.
- ostree repos are **plain static HTTP** — distribution can reuse existing
  mirror infrastructure (see SPEC-001 mirror config).
- The `/usr` read-only + `/etc` 3-way-merge + `/var` persistent split matches
  the hermetic ethos and makes the system tamper-evident.

## 3. Goals / Non-Goals

### Goals
- Package `libostree` and its tooling in BuckOS.
- Produce a signed ostree **commit** from a buck2-built rootfs, reproducibly.
- Boot a deployment via the ostree initramfs hook + bootloader integration.
- A `buckos-update` agent: `check` / `pull` / `deploy` / `rollback` / `status`.
- Host ostree **channels** (e.g. `stable`, `lts`, `mainline` — mirroring the
  installer's existing kernel channels) over static HTTP.
- An installer path that deploys an initial commit instead of building to disk.
- A CI test of the **full update cycle**, including rollback.

### Non-Goals (initial)
- Per-package layering on top of the base image (`rpm-ostree`-style overlays) —
  deferred; the base image is the unit of update first.
- Replacing the source-based installer — both paths coexist.
- A/B partition slots or btrfs snapshots — see §7 alternatives.
- Delta-optimized network transfer beyond ostree's built-in static deltas.

## 4. Architecture

### 4.1 Filesystem model
ostree deployments impose a specific layout:

- `/usr` — read-only, owned by the commit. The bulk of the system.
- `/etc` — per-deployment, created by a **3-way merge** (pristine `/usr/etc` vs.
  the running `/etc` vs. the new commit's defaults).
- `/var` — persistent, shared across deployments (state, home if not separate).
- `/sysroot` — the physical root; deployments live under
  `/ostree/deploy/buckos/deploy/<checksum>.<n>/`.
- The booted `/` is a read-only bind/overlay of the active deployment, with
  `/etc` and `/var` made writable.

This requires a **usr-merged, var-relocated** rootfs (see §5.3).

### 4.2 Update flow
```
buckos-update check     # query channel ref, compare to booted commit
buckos-update pull      # ostree pull <remote> <ref>   (signed, resumable)
buckos-update deploy    # ostree admin deploy <ref>    (stage new deployment)
<reboot>                # bootloader boots the new deployment (boot-counting)
buckos-update rollback  # pin/boot the prior deployment
```
Activation is atomic: the new deployment is fully written and fsync'd before the
bootloader default is flipped. The prior deployment remains on disk for instant
rollback.

### 4.3 Boot integration
- Kernel cmdline carries `ostree=/ostree/boot.<n>/...`.
- An **initramfs hook** runs `ostree-prepare-root` to set the deployment as the
  real root before `switch_root`.
- ostree generates **bootloader entries** (BLS, or GRUB fragments) per
  deployment; integrates with the existing GRUB setup (`root=UUID` + an added
  `ostree=` arg).
- **Boot-counting / greenboot-style** health check: a new deployment boots once;
  a systemd unit marks it "successful"; if it never does, the bootloader falls
  back to the prior deployment.

## 5. BuckOS Integration

### 5.1 Package libostree (P1)
New packages under `packages/linux/system/`:
- `ostree` (libostree + the `ostree` CLI). Deps already present: `glib`,
  `gpgme`, `curl` (libcurl HTTP backend, avoids needing libsoup), `e2fsprogs`,
  `fuse`, `xz`, `zlib`, `libgpg-error`, `openssl`. Optional/deferred:
  `composefs` (integrity), `libsoup`.
- Verify `ostree --version` and a local `ostree init`/`commit`/`checkout`
  round-trip via a `src_test` (SPEC: src_test phase) or a buckos_test.

### 5.2 Commit-generation rule (P2)
A buck2 rule (e.g. `defs/rules/ostree.bzl: ostree_commit`) that takes a rootfs
tree and produces an **ostree repo with one signed commit**:
- Input: the reproducible rootfs (reuse `rootfs.bzl` output).
- `ostree commit --repo=<out> --branch=buckos/<arch>/<channel> --no-bindings
  --timestamp=$SOURCE_DATE_EPOCH ...` → reproducible commit (pin timestamp,
  sort, canonical perms — leverage the reproducibility work in this repo).
- Sign with a release key (`--gpg-sign`); the key id is a build config.
- Output is HTTP-servable. A sibling target produces **static deltas** between
  the previous and current commit.
- Reproducibility is enforced by the SPEC-006 addition to the nightly
  reproducibility check (`tools/repro_check.py`): the commit checksum must be
  byte-stable across independent builds.

### 5.3 Rootfs adaptation (P2)
The rootfs that becomes a commit must be ostree-shaped:
- **usr-merged** (`/bin`→`/usr/bin`, etc.) — confirm current layout; add if not.
- Move state out of the image: `/var` is empty in the commit; `/home` →
  `/var/home`; `/root` → `/var/roothome`; tmpfiles recreate runtime dirs.
- `/etc` defaults shipped under `/usr/etc` (ostree convention).
- This is the riskiest layout change; gate behind a USE flag / dedicated rootfs
  target (`buckos-ostree-rootfs`) so the traditional rootfs is untouched.

### 5.4 Initramfs hook (P3)
Extend `defs/rules/initramfs.bzl` / the live initramfs to include
`ostree-prepare-root` and the ostree initramfs module, plus parsing the
`ostree=` cmdline. A new `buckos-ostree-initramfs` target.

### 5.5 Installer integration (P4)
Add an "image (ostree)" install mode to `../buckos/installer`:
- Partition: ESP + a single `/sysroot` (ext4/xfs/btrfs) + optional LUKS — reuses
  existing disk.rs presets; no A/B slots needed.
- `ostree admin init-fs` + `ostree admin deploy` the initial commit (pulled from
  the install media or a channel) instead of building packages to the root.
- Install the bootloader with ostree's generated entries.

### 5.6 Update agent (P4/P5)
`buckos-update` (new subcommand of the `buckos` cli in `../buckos`, or a small
crate) wrapping libostree: `check`, `pull`, `deploy`, `rollback`, `status`,
`cleanup`. Thin wrapper over `ostree admin` + the repo HTTP remote; a systemd
timer offers periodic `check`.

### 5.7 Repo hosting + channels (P5)
Publish per-channel ostree repos over static HTTP (reuse mirror infra,
SPEC-001). Channels: `stable`, `lts`, `mainline` (mirror the installer's kernel
channels). A release step commits the new rootfs to the channel ref + generates
static deltas + updates the summary.

### 5.8 Testing (P6)
Extend the QEMU boot test (`tests/verify_kde_iso_boot.py` pattern) into a
**full update-cycle integration test**:
1. Deploy commit A to a VM disk; boot; assert healthy.
2. `pull` + `deploy` commit B; reboot; assert booted B.
3. Inject a failing B; assert **automatic rollback** to A.
Runs as a heavy/nightly job (like the reproducibility gate).

## 6. Phased Implementation Plan

| Phase | Deliverable | Gates | Status |
|-------|-------------|-------|--------|
| P1 | Package `libostree` + CLI; round-trip test | `ostree` builds + commits locally | ✅ done |
| P2 | `ostree_commit` rule + ostree-shaped `buckos-ostree-rootfs`; reproducible signed commit | commit checksum byte-stable; repro_check covers it | ✅ done |
| P3 | Initramfs `ostree-prepare-root` hook; bootloader deployment entries | a deployment boots in QEMU | ✅ done |
| P4 | `buckos-update` agent + installer image-mode deploy | install→boot→`status` works end-to-end | 🔄 functionally complete in the `buckos` repo (pending merge) |
| P5 | Channel repos over HTTP + release/delta step | `pull`+`deploy` from a hosted channel | ⬜ remaining |
| P6 | Full update-cycle CI test incl. rollback | A→B update + forced-rollback green | ✅ done |

Each phase is independently landable and testable; P1–P3 are the high-risk core
(packaging + boot integration), P4–P6 productionize it. As of v1.0.0, P1–P3 and
P6 are landed; P4 is functionally complete in the sibling `buckos` repo (the
`buckos-update` agent + installer image-mode) and P5 (channel hosting) remains.
Update-path signing (the "signed commit" in P2) is specified and implemented in
SPEC-007 (ed25519); wiring the production release key into the published images
is tracked there.

## 7. Considered Alternatives

- **A/B image slots** (ChromeOS/mender): dual root partitions, whole-image swap.
  Simpler boot logic and dead-simple rollback, but ~2× root space, no dedup, and
  a coarser update unit. Rejected as the primary model but its boot-counting
  rollback informs §4.3.
- **Btrfs snapshot transactional** (openSUSE MicroOS): reuses the installer's
  existing `@`/`@snapshots`, space-efficient via CoW. Rejected as primary because
  it is btrfs-only and the "apply new content into a snapshot" step lacks
  ostree's content-addressed integrity and signed-commit story. May be offered
  later as a lighter alternative.
- **ostree (chosen)**: content-addressed, signed, dedup'd, static-HTTP
  distribution, mature. Highest implementation lift, best fit for BuckOS's
  reproducible/hermetic model.

## 8. Risks & Open Questions

- **Layout shift** (§5.3): usr-merge + `/var` relocation + `/etc` merge is the
  biggest compatibility risk; isolate behind a dedicated rootfs target.
- **Commit reproducibility**: `ostree commit` must be byte-stable across builds
  (timestamps, xattrs, sort order). Mitigated by the existing reproducibility
  work; verified in P2.
- **Initramfs integration**: `ostree-prepare-root` + the live/systemd initramfs
  variants must cooperate; QEMU boot test is the gate.
- **Signing/key management**: release signing key storage + rotation (CI secret).
- **`composefs`**: deferred; revisit for stronger runtime integrity.
- **Installer scope**: image-mode is additive; ensure the source path is
  unaffected.

## 9. Acceptance Criteria

- `libostree` packaged and tested (P1).
- A signed, reproducible BuckOS ostree commit is produced by buck2 (P2).
- A deployed commit boots in QEMU and `buckos-update status` reports it (P3/P4).
- `buckos-update` performs `pull`→`deploy`→reboot to a new commit from a hosted
  channel, and auto-rolls-back a failing deployment (P5/P6).
- The update cycle (incl. rollback) is covered by a CI integration test (P6).
