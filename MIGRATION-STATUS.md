# BuckOS Migration Status

## Batch 1: Foundation
- [x] 1A: Providers + Registry (defs/providers.bzl, defs/new_registry.bzl, defs/empty_registry.bzl)
- [x] 1B: Python Helpers (tools/*.py, tools/BUCK — 11 scripts)
- [x] 1C: USE Subcell (use/, defs/use_helpers.bzl — 106 flags, 5 profiles)
- Verified: buck2 targets //tools/... and //defs/... parse OK

## Batch 2: Core Rules
- [x] 2A: Core Rules (defs/rules/source.bzl, autotools.bzl, transforms.bzl)
- [x] 2B: Package Macro (defs/package.bzl)
- Verified: clean merge, rules + macro aligned

## Batch 3: First Migration + More Rules
- [x] 3A: Migrate zlib (new package() macro, download_source, SBOM metadata)
- [x] 3B: cmake + meson rules (defs/rules/cmake.bzl, meson.bzl)
- [x] 3C: cargo + go rules (defs/rules/cargo.bzl, go.bzl + helper scripts)
- Verified: conflict in package.bzl resolved (all 5 build rules registered)

## Batch 4: Package Wave
- [x] 4A: Migrate musl (autotools, libraries=["c"])
- [x] 4B: Migrate busybox (Kconfig support: skip_configure, pre_build_cmds, destdir_var)
- [x] 4C: Migrate curl (6 USE flags via select(), 5 conditional deps)
- [x] 4D: Migrate openssl (3.6 + 3.3 slots, version-specific patch dirs)
- Verified: all 4 merged cleanly

## Batch 5: Kernel + VM
- [x] 5A: kernel_build + rootfs + initramfs rules (defs/rules/kernel.bzl, rootfs.bzl — KernelInfo provider, 6-phase kernel build, merged-usr rootfs assembly)
- [x] 5B: VM test infrastructure (defs/rules/vm_test.bzl, tools/vm_test_runner.py — ExternalRunnerTestInfo, QEMU boot with KVM fallback)
- Verified: clean merge, no file conflicts

## Batch 6: Testing + SBOM
- [x] 6A: BXL graph tests (tests/graph/test_deps.bxl, test_transforms.bxl, test_registry.bxl — 59 assertions)
- [x] 6B: SBOM generation (tools/sbom.bxl — SPDX 2.3 + CycloneDX 1.5, provider-based + fallback collection)
- Verified: clean merge, no file conflicts

## Batch 7: Toolchains
- [x] 7A: tc/ host + cross modes (tc/.buckconfig, tc/exec/BUCK, tc/host/BUCK, tc/cross/BUCK, tc/toolchain_rules.bzl, defs/integration.bzl)
- [ ] 7B: Bootstrap stages (deferred — cross mode sufficient for correct images)
- Verified: clean merge

## Batch 8: Remaining Packages
- [ ] Remaining unmigrated packages (incremental — old and new coexist)
- Infrastructure complete: all build rules, tools, USE flags, toolchains, tests, and SBOM ready
- Template: each package follows the same pattern as zlib/musl/curl/openssl migrations
