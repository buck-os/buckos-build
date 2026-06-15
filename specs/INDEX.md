# BuckOS Specifications Index

**Generated:** 2026-06-15

## Summary

**Total Specifications:** 11

**By Status:**
- ✅ approved: 11
- 🔄 rfc: 0
- 📝 draft: 0
- ⚠️ deprecated: 0
- ⛔ rejected: 0

**By Category:**
- core: 4
- bootstrap: 1
- features: 1
- packages: 5

## Status Legend

| Status | Badge | Description |
|--------|-------|-------------|
| approved | ✅ | Canonical specification, ready for implementation |
| rfc | 🔄 | Request for Comments, under review |
| draft | 📝 | Work in progress, not ready for review |
| rejected | ⛔ | Not accepted, kept for historical reference |
| deprecated | ⚠️ | Replaced or outdated, scheduled for removal |

## Specifications

### Core Specifications

| ID | Title | Status | Version | Updated |
|--- |-------|--------|---------|---------|
| [SPEC-001](core/SPEC-001-package-manager-integration.md) | Package Manager Integration | ✅ approved | 2.0.0 | 2026-05-29 |
| [SPEC-002](core/SPEC-002-use-flags.md) | USE Flag System | ✅ approved | 2.0.0 | 2026-05-29 |
| [SPEC-004](core/SPEC-004-package-sets.md) | Package Sets and System Profiles | ✅ approved | 1.0.0 | 2025-11-20 |
| [SPEC-005](core/SPEC-005-patches.md) | Patch System | ✅ approved | 2.0.0 | 2026-05-29 |

### Bootstrap Specifications

| ID | Title | Status | Version | Updated |
|--- |-------|--------|---------|---------|
| [SPEC-100](bootstrap/SPEC-100-toolchain-bootstrap.md) | Toolchain Bootstrap and Seed | ✅ approved | 1.0.0 | 2026-06-15 |

### Feature Specifications

| ID | Title | Status | Version | Updated |
|--- |-------|--------|---------|---------|
| [SPEC-300](features/SPEC-300-hermeticity-gate.md) | ELF Dependency-Closure Hermeticity Gate | ✅ approved | 1.3.0 | 2026-06-15 |

### Package Specifications

| ID | Title | Status | Version | Updated |
|--- |-------|--------|---------|---------|
| [PACKAGE-SPEC-001](packages/PACKAGE-SPEC-001-simple-autotools.md) | Simple and Autotools Packages | ✅ approved | 2.0.0 | 2026-05-29 |
| [PACKAGE-SPEC-002](packages/PACKAGE-SPEC-002-build-systems.md) | CMake and Meson Packages | ✅ approved | 2.0.0 | 2026-05-29 |
| [PACKAGE-SPEC-003](packages/PACKAGE-SPEC-003-rust-cargo.md) | Rust/Cargo Packages | ✅ approved | 2.0.0 | 2026-05-29 |
| [PACKAGE-SPEC-004](packages/PACKAGE-SPEC-004-go.md) | Go Packages | ✅ approved | 2.0.0 | 2026-05-29 |
| [PACKAGE-SPEC-005](packages/PACKAGE-SPEC-005-python.md) | Python Packages | ✅ approved | 2.0.0 | 2026-05-29 |

## Historical Specifications

Archived in `specs/historical/`. These are kept on disk for reference but
are not part of the active spec set, not installed to `/etc/buckos/specs/`,
and not counted in the totals above.

| ID | Title | Reason |
|--- |-------|--------|
| [SPEC-003](historical/SPEC-003-versioning.md) | Package Versioning and Slot System | Slot/multi-version API described in v1.0.0 was never implemented. Current minimal multi-version pattern is documented in SPEC-001; see also `use_versioned_dep` in `defs/use_helpers.bzl`. |

## References

- [TEMPLATE.md](TEMPLATE.md) - Template for creating new specs
- [README.md](README.md) - Guide to the specification system
- [REGISTRY.json](REGISTRY.json) - Machine-readable spec registry

---

For questions or suggestions about the specification system, please file an issue in the project repository.
