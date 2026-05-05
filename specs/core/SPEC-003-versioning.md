---
id: "SPEC-003"
title: "Package Versioning and Slot System"
status: "approved"
version: "1.0.0"
created: "2025-11-19"
updated: "2025-11-19"

authors:
  - name: "BuckOS Team"
    email: "team@buckos.org"

maintainers:
  - "team@buckos.org"

category: "core"
tags:
  - "versioning"
  - "slots"
  - "subslots"
  - "multi-version"
  - "abi-tracking"

related:
  - "SPEC-001"

implementation:
  status: "complete"
  completeness: 85

compatibility:
  buck2_version: ">=2024.11.01"
  buckos_version: ">=1.0.0"
  breaking_changes: false

changelog:
  - version: "1.0.0"
    date: "2025-12-27"
    changes: "Migrated to formal specification system with lifecycle management"
---

# Package Versioning and Slot System

**Status**: approved | **Version**: 1.0.0 | **Last Updated**: 2025-11-19

## Abstract

This specification defines the versioning, slot, and subslot system for BuckOS packages. It enables parallel installation of multiple versions, ABI compatibility tracking, and automated dependency rebuilds when ABI changes occur. The system is compatible with Gentoo's slot system but extended with Buck2-specific features.

This document describes BuckOs Linux's multi-version package management system, inspired by Gentoo's ebuild slot system but implemented using Buck2.

## Overview

The versioning system enables:
- **Multiple concurrent versions** of the same package
- **Slot-based organization** for parallel installation
- **Version constraints** in dependencies
- **Default stable versions** with fallbacks
- **Scalability** to thousands of packages

## Core Concepts

### Slots

Slots allow multiple versions of a package to be installed simultaneously. Each slot represents a distinct "installation track" that doesn't conflict with others.

```python
# OpenSSL example:
# - Slot "3": OpenSSL 3.x series (current)
# - Slot "1.1": OpenSSL 1.1.x series (LTS)
# - Slot "1.0": OpenSSL 1.0.x series (legacy)
```

Packages in different slots install to different locations (e.g., `/usr/lib/openssl-1.1`), allowing applications to use whichever version they need.

### Version Status

Versions have one of four status levels:
- **stable**: Fully tested, recommended for production
- **testing**: New version, needs wider testing
- **deprecated**: Older version, will be removed in future
- **masked**: Known issues, not recommended

### Default Version

Each package has a designated default version that's used when no specific version is requested. This is typically the newest stable version.

## Directory Structure

```
defs/
├── versions.bzl      # Version management rules and utilities
├── registry.bzl      # Central version registry
└── package.bzl       # Base package rules

packages/
└── category/
    └── package-name/
        └── BUCK          # Package definition with versions
```

## Usage

### Method 1: multi_version_package (Recommended)

Define all versions in a single declaration:

```python
load("//defs:versions.bzl", "multi_version_package")

multi_version_package(
    name = "openssl",
    versions = {
        "3.2.0": {
            "slot": "3",
            "keywords": ["stable"],
            "url": "https://www.openssl.org/source/openssl-3.2.0.tar.gz",
            "sha256": "14c826f07c7e433706fb5c69fa9e25dab95684844b4c962a2cf1bf183eb4690e",
        },
        "1.1.1w": {
            "slot": "1.1",
            "keywords": ["stable"],
            "url": "https://www.openssl.org/source/openssl-1.1.1w.tar.gz",
            "sha256": "cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8",
            "configure_args": ["--prefix=/usr/lib/openssl-1.1"],
        },
    },
    default_version = "3.2.0",
    # Common settings
    description = "TLS/SSL and crypto library",
    license = "Apache-2.0",
    deps = ["//packages/linux/core/zlib"],
)
```

This creates:
- `openssl-3.2.0` - Specific version target
- `openssl-1.1.1w` - Specific version target
- `openssl:3` - Slot alias
- `openssl:1.1` - Slot alias
- `openssl` - Default version alias

### Method 2: versioned_package (More Control)

Define each version individually when they have significantly different configurations:

```python
load("//defs:versions.bzl", "versioned_package")

versioned_package(
    name = "python",
    version = "3.12.1",
    slot = "3.12",
    keywords = ["stable"],
    url = "https://www.python.org/ftp/python/3.12.1/Python-3.12.1.tar.xz",
    sha256 = "...",
    configure_args = [...],
    deps = [...],
)

versioned_package(
    name = "python",
    version = "2.7.18",
    slot = "2.7",
    keywords = ["masked"],
    url = "https://www.python.org/ftp/python/2.7.18/Python-2.7.18.tar.xz",
    sha256 = "...",
    configure_args = [...],  # Python 2 has different options
    deps = [...],
)
```

### Method 3: Manual Definition

For full control, define each version manually with aliases:

```python
load("//defs:package.bzl", "package")
load("//defs:package.bzl", "download_source")

# Version 3.2.0
download_source(name = "openssl-3.2.0-src", ...)
package(build_rule = "autotools", name = "openssl-3.2.0", ...)

# Version 1.1.1w
download_source(name = "openssl-1.1.1w-src", ...)
package(build_rule = "autotools", name = "openssl-1.1.1w", ...)

# Slot aliases
alias(name = "openssl:3", actual = ":openssl-3.2.0")
alias(name = "openssl:1.1", actual = ":openssl-1.1.1w")
alias(name = "openssl", actual = ":openssl-3.2.0")
```

## Dependency Specification

### Slot Dependencies

Request a specific slot (major version track):

```python
deps = [
    "//packages/linux/dev-libs/openssl:3",      # Any OpenSSL 3.x
    "//packages/linux/lang/python:3.11",        # Python 3.11.x
    "//packages/linux/dev-libs/boost:1.84",     # Boost 1.84.x
]
```

### Version Constraints

Use version_dep for constraint-based resolution:

```python
load("//defs:versions.bzl", "version_dep")

deps = [
    version_dep("//packages/linux/dev-libs/openssl", ">=3.0"),
    version_dep("//packages/linux/core/zlib", "~>1.2"),      # >=1.2.0, <2.0.0
    version_dep("//packages/linux/lang/python", ">=3.10 <4.0"),
]
```

Supported constraints:
- `1.2.3` - Exact match
- `>=1.2.3` - Greater than or equal
- `>1.2.3` - Greater than
- `<=1.2.3` - Less than or equal
- `<1.2.3` - Less than
- `~>1.2` - Pessimistic (>=1.2.0, <2.0.0)
- `1.2.*` - Wildcard match

### Virtual Packages

Define alternatives for a capability:

```python
load("//defs:versions.bzl", "virtual_package", "any_of")

virtual_package(
    name = "libc",
    providers = [
        "//packages/linux/core/musl",
        "//packages/linux/core/glibc",
    ],
    default = "//packages/linux/core/musl",
)

# Or in deps:
deps = [
    any_of(
        "//packages/linux/core/musl",
        "//packages/linux/core/glibc",
    ),
]
```

## Version Registry

The central registry (`defs/registry.bzl`) tracks all available versions:

```python
load("//defs:registry.bzl",
     "get_default_version",
     "get_versions_in_slot",
     "get_stable_versions")

# Get default version
default = get_default_version("core/openssl")  # "3.2.0"

# Get all versions in a slot
versions = get_versions_in_slot("lang/python", "3.11")  # ["3.11.7", "3.11.6"]

# Get all stable versions
stable = get_stable_versions("dev-libs/boost")
```

### Registry Functions

| Function | Description |
|----------|-------------|
| `get_package_info(pkg_id)` | Get full package metadata |
| `get_default_version(pkg_id)` | Get default stable version |
| `get_all_versions(pkg_id)` | List all available versions |
| `get_versions_in_slot(pkg_id, slot)` | Get versions in a slot |
| `get_stable_versions(pkg_id)` | Get all stable versions |
| `get_version_status(pkg_id, ver)` | Get version status |
| `list_all_packages()` | List all registered packages |
| `list_packages_by_category(cat)` | List packages in category |

## Scalability

The system scales to thousands of packages through:

1. **Efficient Data Structures**: Dict-based lookups provide O(1) access
2. **Category Organization**: Packages grouped by category for manageability
3. **Lazy Loading**: Versions resolved only when needed
4. **Machine-Readable Format**: Easy tooling integration

### Adding New Packages

1. Add entry to `defs/registry.bzl`:
```python
CATEGORY_PACKAGES = {
    "category/new-package": {
        "default": "1.0.0",
        "versions": {
            "1.0.0": {"slot": "1", "status": "stable"},
        },
    },
}
```

2. Create package BUCK file using versioning rules

### Bulk Updates

Use scripts to update the registry:
```bash
# Update all checksums
./tools/update-checksums.sh

# Add new version to all packages
./tools/add-version.sh --version 2.0.0 --slot 2 --status testing
```

## Best Practices

### 1. Slot Naming

- Use major version for libraries: `1`, `2`, `3`
- Use major.minor for interpreters: `3.11`, `3.12`
- Use `0` for single-slot packages

### 2. Version Lifecycle

```
testing → stable → deprecated → masked → removed
```

- New versions start as `testing`
- After sufficient testing, promote to `stable`
- When superseded, mark as `deprecated`
- If issues found, mark as `masked`
- Eventually remove from registry

### 3. Dependency Constraints

- Prefer slot dependencies for flexibility
- Use version constraints only when necessary
- Document why specific versions are needed

### 4. Parallel Installation

When packages need parallel installation:
- Install to versioned prefix: `/usr/lib/pkg-X.Y`
- Create versioned binaries: `python3.11`, `python3.12`
- Symlink default version to `/usr/bin`

## Examples

See example packages in:
- `packages/examples/multi-version/openssl/BUCK`
- `packages/examples/multi-version/python/BUCK`

## Version Comparison

The system handles complex version strings:

```python
# All these compare correctly:
"1.2.3" < "1.2.4"
"1.2.3" < "1.10.0"
"1.2.3a" < "1.2.3b"
"1.2.3_rc1" < "1.2.3"
"1.2.3_beta1" < "1.2.3_rc1"
"1.2.3_alpha1" < "1.2.3_beta1"
```

## Migration Guide

### Converting Existing Packages

1. Identify current version in BUCK file
2. Add to registry with status "stable"
3. Add older versions with appropriate status
4. Update BUCK to use versioning macros
5. Create slot aliases

### Example Migration

Before:
```python
package(
    build_rule = "autotools",
    name = "zlib",
    version = "1.3.1",
    ...
)
```

After:
```python
multi_version_package(
    name = "zlib",
    versions = {
        "1.3.1": {"slot": "0", "keywords": ["stable"]},
        "1.3": {"slot": "0", "keywords": ["stable"]},
        "1.2.13": {"slot": "0", "keywords": ["deprecated"]},
    },
    ...
)
```

## Future Enhancements

- [ ] Automatic version resolution with SAT solver
- [ ] Version deprecation warnings in builds
- [ ] Automatic security update detection
- [ ] Integration with upstream version tracking
- [ ] Automated testing of version combinations
