# BuckOS Specifications Index

**Generated:** 2026-05-29

## Summary

**Total Specifications:** 10

**By Status:**
- ✅ approved: 1
- 🔄 rfc: 0
- 📝 draft: 9
- ⚠️ deprecated: 0
- ⛔ rejected: 0

**By Category:**
- core: 5
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
| [SPEC-001](core/SPEC-001-package-manager-integration.md) | Package Manager Integration | 📝 draft | 1.0.0 | 2025-12-27 |
| [SPEC-002](core/SPEC-002-use-flags.md) | USE Flag System | 📝 draft | 1.0.0 | 2025-11-27 |
| [SPEC-003](core/SPEC-003-versioning.md) | Package Versioning and Slot System | 📝 draft | 1.0.0 | 2025-11-19 |
| [SPEC-004](core/SPEC-004-package-sets.md) | Package Sets and System Profiles | ✅ approved | 1.0.0 | 2025-11-20 |
| [SPEC-005](core/SPEC-005-patches.md) | Patch System | 📝 draft | 1.0.0 | 2025-11-20 |

### Package Specifications

| ID | Title | Status | Version | Updated |
|--- |-------|--------|---------|---------|
| [PACKAGE-SPEC-001](packages/PACKAGE-SPEC-001-simple-autotools.md) | Simple and Autotools Packages | 📝 draft | 1.0.0 | 2025-12-27 |
| [PACKAGE-SPEC-002](packages/PACKAGE-SPEC-002-build-systems.md) | CMake and Meson Packages | 📝 draft | 1.0.0 | 2025-12-27 |
| [PACKAGE-SPEC-003](packages/PACKAGE-SPEC-003-rust-cargo.md) | Rust/Cargo Packages | 📝 draft | 1.0.0 | 2025-12-27 |
| [PACKAGE-SPEC-004](packages/PACKAGE-SPEC-004-go.md) | Go Packages | 📝 draft | 1.0.0 | 2025-12-27 |
| [PACKAGE-SPEC-005](packages/PACKAGE-SPEC-005-python.md) | Python Packages | 📝 draft | 1.0.0 | 2025-12-27 |

> **Note:** All draft specs describe a pre-2026-02 API that was replaced by the
> `package()` macro in `defs/package.bzl`. They are pending rewrite against the
> current API; do not use as authoritative until restored to "approved".

## References

- [TEMPLATE.md](TEMPLATE.md) - Template for creating new specs
- [README.md](README.md) - Guide to the specification system
- [REGISTRY.json](REGISTRY.json) - Machine-readable spec registry

---

For questions or suggestions about the specification system, please file an issue in the project repository.
