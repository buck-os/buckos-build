---
id: "PACKAGE-SPEC-003"
title: "Rust/Cargo Packages"
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
  - "rust"
  - "cargo"
  - "language-packages"

related:
  - "PACKAGE-SPEC-001"
  - "PACKAGE-SPEC-004"
  - "PACKAGE-SPEC-005"

implementation:
  status: "complete"
  completeness: 85

compatibility:
  buck2_version: ">=2024.11.01"
  buckos_version: ">=1.0.0"
  breaking_changes: false
---

# Rust/Cargo Package Specification

## Abstract

This specification defines how to create BuckOS packages for Rust projects using Cargo.

## Package Type

**`package(build_rule = "cargo")`** - Builds Rust projects with Cargo

## Quick Start

### Basic Cargo Package

```python
load("//defs:package.bzl", "package")

package(
    build_rule = "cargo",
    name = "ripgrep",
    version = "14.0.3",
    url = "https://github.com/BurntSushi/ripgrep/archive/14.0.3.tar.gz",
    sha256 = "cf04af86dc085268c5f4470fbae49b18afbc221b78096aab842d934a76bad0ab",
    maintainers = ["rust@buckos.org"],
)
```

### With Cargo Features

```python
package(
    build_rule = "cargo",
    name = "fd",
    version = "9.0.0",
    url = "https://github.com/sharkdp/fd/archive/v9.0.0.tar.gz",
    sha256 = "abc123...",
    cargo_args = ["--release"],
    iuse = ["jemalloc"],
    use_features = {
        "jemalloc": "use-jemalloc",
    },
    use_deps = {
        "jemalloc": "//packages/linux/dev-libs:jemalloc",
    },
)
```

## Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Package name (crate name) |
| `version` | string | Crate version |
| `url` | string | Source tarball URL |
| `sha256` | string | SHA-256 checksum |

## Cargo-Specific Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `bins` | list[string] | [] | Binary names to install |
| `cargo_args` | list[string] | [] | Additional cargo build arguments |
| `use_features` | dict | {} | Map USE flags to Cargo features |
| `use_deps` | dict | {} | Conditional dependencies based on USE flags |

## Cargo Features

Cargo features map to USE flags via `use_features`:

```python
iuse = ["pcre2", "simd"]
use_defaults = ["simd"]
use_features = {
    "pcre2": "pcre2",
    "simd": "simd-accel",
}
use_deps = {
    "pcre2": "//packages/linux/dev-libs/pcre2",
}
```

Features can map to single strings or lists:

```python
use_features = {
    "ssl": "tls",
    "compression": ["zstd", "brotli"],  # Multiple features for one USE flag
}
```

## Build Process

### 1. Dependency Vendoring

Cargo dependencies are vendored for reproducibility:

```bash
cargo vendor > .cargo/config.toml
```

### 2. Build

```bash
cargo build --release \
    --target-dir=$OUT \
    --locked \
    <cargo_args>
```

### 3. Installation

```bash
cargo install --path . \
    --root=$OUT \
    --locked \
    <cargo_features>
```

## Environment Variables

Use the `env` parameter for build customization:

```python
package(
    build_rule = "cargo",
    name = "tool",
    env = {
        "RUSTFLAGS": "-C target-feature=+crt-static",
        "CARGO_BUILD_FLAGS": "--release --locked",
    },
)
```

## Example Packages

- Simple CLI: `//packages/linux/sys-apps:ripgrep`
- With features: `//packages/linux/sys-apps:fd`
- Complex: `//packages/linux/dev-lang:rust`

## References

- Cargo Book: https://doc.rust-lang.org/cargo/
- Rust Reference: https://doc.rust-lang.org/reference/
- PACKAGE-SPEC-001: Base package specification
