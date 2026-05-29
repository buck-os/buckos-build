---
id: "SPEC-003"
title: "Package Versioning and Slot System"
status: "deprecated"
version: "1.1.0"
created: "2025-11-19"
updated: "2026-05-29"

authors:
  - name: "BuckOS Team"
    email: "team@buckos.org"

maintainers:
  - "team@buckos.org"

category: "core"
tags:
  - "versioning"
  - "slots"
  - "deprecated"

related:
  - "SPEC-001"

implementation:
  status: "not-started"
  completeness: 0

lifecycle:
  deprecated_date: "2026-05-29"
  deprecation_reason: "Slot/multi-version/version-constraint API described here was never implemented. Current BuckOS uses a much simpler manual per-version pattern; this spec is retained for historical context only."

changelog:
  - version: "1.1.0"
    date: "2026-05-29"
    changes: "Marked DEPRECATED. The slot/multi-version system described in v1.0.0 was never implemented; spec body replaced with a notice describing the current minimal approach."
  - version: "1.0.0"
    date: "2025-12-27"
    changes: "Original draft of slot/multi-version/version-constraint specification (never implemented)."
---

# Package Versioning and Slot System

**Status**: deprecated | **Version**: 1.1.0 | **Last Updated**: 2026-05-29

## Abstract

DEPRECATED. The slot, subslot, multi-version, and version-constraint system originally described in v1.0.0 of this spec (`multi_version_package`, `versioned_package`, `version_dep`, `virtual_package`, `any_of`, `subslot_dep`, registry helpers) was never implemented. `defs/versions.bzl` and `defs/registry.bzl` do not exist. Current BuckOS uses a much simpler manual pattern documented below.

## Overview

This spec is retained for historical context only. No symbol from v1.0.0 of this spec is available in the codebase, and there is no active plan to implement one. New work should not reference the v1.0.0 API.

## Motivation

The v1.0.0 design aimed to mirror Gentoo's slot/subslot model on top of Buck2. In practice, the multi-version need has been narrow enough (a handful of libraries such as OpenSSL) that a manual per-version pattern has been sufficient. A formal slot system was not built.

## Specification

The current minimal versioning approach in BuckOS is:

1. **Multiple `package()` calls with version-suffixed names.** Each version is a distinct top-level target. An `alias()` selects the default. There is no slot type, no version registry, and no version-constraint dependency syntax — consumers depend on a specific named target.

2. **USE-flag-driven version selection via `use_versioned_dep()`** in `defs/use_helpers.bzl` (see lines 110-125). This wraps a `select()` over `//use/constraints:<expand>-<value>` so a single dep edge can switch between version-suffixed targets at configure time. The "slot" label is purely a USE_EXPAND string convention; it is not enforced or registered anywhere.

Anything beyond the above (constraint solving, virtual packages, ABI subslot tracking, registry queries, automatic rebuilds on ABI change) is not implemented.

## Examples

Canonical multi-version pattern — `packages/linux/system/libs/crypto/openssl/BUCK`:

```python
load("//defs/packages:autotools.bzl", "autotools_package")

autotools_package(name = "openssl-3.6", version = "3.6.1", ...)
autotools_package(name = "openssl-3.3", version = "3.3.2", ...)  # LTS

alias(name = "openssl", actual = ":openssl-3.6")
```

Consumers depend on `:openssl-3.6`, `:openssl-3.3`, or `:openssl` (default). USE-flag-driven selection is available via `use_versioned_dep()` in `defs/use_helpers.bzl`.

## Implementation

Not implemented and not planned. The v1.0.0 API is not present in the codebase; this spec is deprecated.

## Security Considerations

None. This spec does not describe any active code path.

## Alternatives Considered

The manual per-version + `alias()` pattern described above is the alternative that was actually adopted, in place of building the v1.0.0 design. It carries no infrastructure cost and has covered observed needs.

## References

- `packages/linux/system/libs/crypto/openssl/BUCK` — canonical manual multi-version example
- `defs/use_helpers.bzl` — `use_versioned_dep()` for USE-flag-driven version selection
- SPEC-001 — package manager integration (related)
