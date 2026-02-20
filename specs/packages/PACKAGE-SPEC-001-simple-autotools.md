---
id: "PACKAGE-SPEC-001"
title: "Simple and Autotools Packages"
status: "approved"
version: "1.0.0"
created: "2025-12-27"
updated: "2025-12-27"

authors:
  - name: "BuckOS Team"
    email: "team@buckos.org"

maintainers:
  - "team@buckos.org"

category: "packages"
tags:
  - "package-creation"
  - "autotools"
  - "make"
  - "build-system"

related:
  - "SPEC-001"
  - "SPEC-002"
  - "PACKAGE-SPEC-002"

implementation:
  status: "complete"
  completeness: 95

compatibility:
  buck2_version: ">=2024.11.01"
  buckos_version: ">=1.0.0"
  breaking_changes: false

changelog:
  - version: "1.0.0"
    date: "2025-12-27"
    changes: "Initial package specification for simple and autotools packages"
---

# Simple and Autotools Package Specification

**Status**: approved | **Version**: 1.0.0 | **Last Updated**: 2025-12-27

## Abstract

This specification defines how to create BuckOS packages for software that uses Autotools (./configure, make, make install) or simple Makefiles. These are the most common types of packages and form the foundation of the BuckOS package system.

## Package Types Covered

This specification covers:
- **`package(build_rule = "simple")`** - Basic Makefiles without configure
- **`package(build_rule = "autotools")`** - Full Autotools support with USE flags
- **`package(build_rule = "bootstrap")`** - Stage 0 bootstrap packages

## Quick Start

### Minimal Simple Package

```python
load("//defs:package.bzl", "package")

package(
    build_rule = "simple",
    name = "hello",
    version = "2.12",
    url = "https://ftp.gnu.org/gnu/hello/hello-2.12.tar.gz",
    sha256 = "cf04af86dc085268c5f4470fbae49b18afbc221b78096aab842d934a76bad0ab",
)
```

### Autotools Package with USE Flags

```python
load("//defs:package.bzl", "package")

package(
    build_rule = "autotools",
    name = "bash",
    version = "5.2.15",
    url = "https://ftp.gnu.org/gnu/bash/bash-5.2.15.tar.gz",
    sha256 = "13720965b5f4fc3a0d4b61dd37e7565c741da9a5be24edc2ae00182fc1b3588c",
    iuse = ["nls", "readline", "examples"],
    deps = [
        "//packages/linux/core:ncurses",
    ],
    use_configure = {
        "nls": ("--enable-nls", "--disable-nls"),
        "readline": ("--with-installed-readline", "--without-installed-readline"),
    },
    maintainers = ["shell@buckos.org"],
)
```

## Required Fields

All packages **MUST** include:

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Package name (lowercase, alphanumeric + hyphens) |
| `version` | string | Package version (SemVer recommended) |
| `url` | string | Source tarball download URL |
| `sha256` | string | SHA-256 checksum of source tarball |

## Optional Fields

### Basic Metadata

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `description` | string | "" | One-line package description |
| `homepage` | string | "" | Project homepage URL |
| `license` | string | "" | SPDX license identifier |
| `maintainers` | list[string] | [] | Maintainer email addresses |

### Build Configuration

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `configure_args` | list[string] | [] | Static arguments to `./configure` |
| `make_args` | list[string] | [] | Arguments to `make` command |
| `deps` | list[string] | [] | Runtime dependencies (Buck2 targets) |
| `build_deps` | list[string] | [] | Build-time only dependencies |
| `patches` | list[string] | [] | Patch files to apply |

### USE Flag Support (autotools build_rule only)

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `iuse` | list[string] | [] | USE flags this package supports |
| `use_configure` | dict | {} | Map USE flags to configure arguments |
| `use_deps` | dict | {} | Conditional dependencies based on USE flags |

### Security & Verification

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `signature_sha256` | string | None | SHA-256 of GPG signature file |
| `gpg_key` | string | None | GPG key ID for verification |
| `gpg_keyring` | string | None | Path to GPG keyring file |

### Advanced Options

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `exclude_patterns` | list[string] | [] | Patterns to exclude from extraction |
| `strip_components` | int | 1 | Number of leading path components to strip |
| `env` | dict | {} | Environment variables for build |

## Build Process

### 1. Source Download

```
http_file(name = "{name}-src", url = url, sha256 = sha256)
```

### 2. Source Extraction

```
extract_source(
    name = "{name}-extracted",
    archive = ":{name}-src",
    strip_components = 1,
)
```

### 3. Configuration (Autotools)

```bash
cd $SOURCE_DIR
./configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --localstatedir=/var \
    <configure_args...>
```

### 4. Compilation

```bash
make -j$(nproc) <make_args...>
```

### 5. Installation

```bash
make DESTDIR=$OUT install
```

## USE Flag Integration

USE flags control optional features following SPEC-002.

### Declaring USE Flags

```python
iuse = ["ssl", "ipv6", "doc", "examples"]
```

### Conditional Configure Arguments

```python
use_configure = {
    "ssl": ("--with-ssl", "--without-ssl"),
    "ipv6": ("--enable-ipv6", "--disable-ipv6"),
    "doc": ("--enable-doc", "--disable-doc"),
}
```

### Conditional Dependencies

```python
use_deps = {
    "ssl": "//packages/linux/network:openssl",
    "doc": "//packages/linux/dev-util:doxygen",
}
```

## Dependencies

### Runtime Dependencies (`deps`)

Packages required for the software to run:

```python
deps = [
    "//packages/linux/core:glibc",
    "//packages/linux/core:ncurses",
]
```

### Build Dependencies (`build_deps`)

Packages only needed during compilation:

```python
build_deps = [
    "//packages/linux/dev-util:pkg-config",
    "//packages/linux/dev-lang:perl",
]
```

## Patches

Apply patches in order:

```python
patches = [
    "//packages/linux/patches/{category}/{name}:fix-makefile.patch",
    "//packages/linux/patches/{category}/{name}:security-update.patch",
]
```

Patches follow SPEC-005 precedence rules.

## File Layout

### Expected Package Structure

```
packages/linux/
└── {category}/
    └── {name}/
        ├── BUCK
        ├── patches/
        │   ├── fix-build.patch
        │   └── security.patch
        └── files/
            └── config.h
```

### BUCK File Example

```python
load("//defs:package.bzl", "package")

package(
    build_rule = "autotools",
    name = "vim",
    version = "9.0.1",
    url = "https://github.com/vim/vim/archive/v9.0.1.tar.gz",
    sha256 = "abc123...",
    iuse = ["python", "perl", "ruby", "X", "gtk"],
    deps = [
        "//packages/linux/core:ncurses",
    ],
    use_configure = {
        "python": ("--enable-pythoninterp", "--disable-pythoninterp"),
        "X": ("--with-x", "--without-x"),
    },
    use_deps = {
        "python": "//packages/linux/dev-lang:python",
        "X": "//packages/linux/x11-libs:libX11",
    },
    maintainers = ["editor@buckos.org"],
)
```

## Bootstrap Packages

Special packages for stage 0 bootstrap:

```python
load("//defs:package.bzl", "package")

package(
    build_rule = "bootstrap",
    name = "m4",
    version = "1.4.19",
    url = "https://ftp.gnu.org/gnu/m4/m4-1.4.19.tar.xz",
    sha256 = "63aede5c6d33b6d9b13511cd0be2cac046f2e70fd0a07aa9573a04a82783af96",
    # Bootstrap packages have minimal dependencies
    # and are built with host toolchain
)
```

## Best Practices

### 1. Naming Conventions

- Package names: lowercase with hyphens (`my-package`)
- USE flags: lowercase, descriptive (`ssl`, `doc`, `examples`)
- Maintainer format: `category@buckos.org`

### 2. Version Strings

- Use upstream version numbers unchanged
- Include patchlevel if applicable: `1.2.3_p4`
- For git snapshots: `1.2.3_pre20231201`

### 3. Source URLs

- Prefer official project releases
- Use HTTPS when available
- Include version in filename for cacheability

### 4. SHA-256 Checksums

Generate with:
```bash
sha256sum /path/to/tarball
```

### 5. GPG Verification

When upstream provides signatures:
```python
signature_sha256 = "abc123...",
gpg_key = "0x1234567890ABCDEF",
```

### 6. Dependencies

- List **all** runtime dependencies explicitly
- Don't rely on transitive dependencies
- Order by importance (critical deps first)

### 7. USE Flags

- Follow existing flag conventions (see SPEC-002)
- Document non-obvious flags in comments
- Provide sensible defaults

## Validation

### Required Checks

1. **Name**: Must match directory name
2. **Version**: Must be valid version string
3. **SHA-256**: Must be 64 hex characters
4. **url**: Must be valid URL
5. **deps**: Must be valid Buck2 targets

### Recommended Checks

1. GPG signature verification when available
2. License compatibility
3. Dependency version constraints
4. USE flag conflicts

## Common Patterns

### Conditional Patching

```python
patches = select({
    "//config:kernel_5_x": ["//patches:kernel5.patch"],
    "//config:kernel_6_x": ["//patches:kernel6.patch"],
    "//conditions:default": [],
})
```

### Multi-Output Packages

```python
package(
    build_rule = "autotools",
    name = "ncurses",
    # ... standard fields ...
    outs = {
        "default": [],  # Libraries and headers
        "terminfo": ["share/terminfo/**"],  # Separate terminfo database
    },
)
```

### Cross-Compilation

```python
package(
    build_rule = "autotools",
    name = "busybox",
    # ... standard fields ...
    configure_args = [
        "--host=" + ctx.attrs.target_triple,
        "--build=" + ctx.attrs.build_triple,
    ],
)
```

## Migration from Gentoo

Converting Gentoo ebuilds:

| Gentoo ebuild | BuckOS equivalent |
|---------------|-------------------|
| `SRC_URI` | `url` |
| `DEPEND` | `build_deps` |
| `RDEPEND` | `deps` |
| `IUSE` | `iuse` |
| `src_configure()` | `configure_args` |
| `src_compile()` | `make_args` |
| `PATCHES` | `patches` |

See PACKAGE-SPEC-003 for full ebuild conversion guide.

## Examples

See `//packages/linux/` for 500+ real-world examples:

- **Simple**: `core/hello`, `core/which`
- **Autotools**: `core/bash`, `core/coreutils`
- **Complex**: `core/glibc`, `x11-wm/i3`

## References

- SPEC-001: Package Manager Integration
- SPEC-002: USE Flag System
- SPEC-005: Patch System
- Buck2 Documentation: https://buck2.build
- Autotools Documentation: https://www.gnu.org/software/automake/

## Changelog

### 1.0.0 (2025-12-27)

- Initial package specification
- Covers simple_package and autotools_package
- Includes bootstrap package support
- Migration guide from Gentoo ebuilds
