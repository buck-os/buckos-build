---
id: "PACKAGE-SPEC-003"
title: "Rust / Cargo Packages"
status: "approved"
version: "2.0.0"
created: "2025-12-27"
updated: "2026-05-29"

authors:
  - name: "BuckOS Team"
    email: "team@buckos.org"

category: "packages"
tags:
  - "package-creation"
  - "rust"
  - "cargo"
  - "language-packages"

related:
  - "SPEC-001"
  - "SPEC-002"
  - "SPEC-005"
  - "PACKAGE-SPEC-001"
  - "PACKAGE-SPEC-004"

implementation:
  status: "complete"
  completeness: 100

compatibility:
  buck2_version: ">=2024.11.01"
  buckos_version: ">=2026.02"
  breaking_changes: false

changelog:
  - version: "2.0.0"
    date: "2026-05-29"
    changes: "Rewrite against wrapper-based package() API."
  - version: "1.0.0"
    date: "2025-12-27"
    changes: "Initial spec — superseded."
---

# Rust / Cargo Package Specification

## Overview

`cargo_package` builds Rust crates via `cargo build` against the buckos
Rust toolchain. The single build action runs `cargo_helper.py`, which
handles linker flag injection (`RUSTFLAGS`, `CARGO_HOST_LINKER`), offline
vendoring, and the buckos sysroot wiring.

| Macro | Loaded from | Underlying rule |
|-------|-------------|-----------------|
| `cargo_package` | `//defs/packages:cargo.bzl` | `defs/rules/cargo.bzl::cargo_build` |

## Wrapper Signature

```python
cargo_package(name, version, url, sha256, **kwargs)
```

## Required Arguments

| Argument | Type | Description |
|----------|------|-------------|
| `name` | string | Target name |
| `version` | string | Crate version |
| `url` | string | Source tarball URL |
| `sha256` | string | SHA-256 of the tarball |

## Common Optional Arguments

All common kwargs from PACKAGE-SPEC-001 apply: `description`, `homepage`,
`license`, `deps`, `host_deps`, `runtime_deps`, `patches`, `env`,
`extra_cflags`, `extra_ldflags`, `linker`, `transforms`, `use_transforms`,
`use_deps`, `local_only`, `filename`, `strip_components`, etc.

Rust packages typically need `//packages/linux/lang/rust:rust` in
`host_deps` (it's not auto-injected — see the examples).

## Cargo-Specific Arguments

Forwarded to `cargo_build` (see `defs/rules/cargo.bzl`):

| Argument | Type | Description |
|----------|------|-------------|
| `features` | list[string] | Cargo features to enable (`--features`) |
| `cargo_args` | list[string] | Extra args to `cargo build` (e.g. `--package foo`, `--no-default-features`) |
| `bins` | list[string] | Binary names to build (`--bin`). When set, only the listed bins are produced |
| `vendor_deps` | bool / sha256 / dep | Offline-vendor wiring; see below |
| `use_features` | dict[flag,feature] | USE-flag-gated cargo features (handled by `package()`) |

## `vendor_deps` Semantics

Vendoring keeps the build hermetic (the rule runs under `unshare --net`).
The `package()` macro (`defs/package.bzl:308-364`) understands three forms:

| Value | Behaviour |
|-------|-----------|
| `True` | Source tarball already contains a `vendor/` directory; the macro strips the kwarg and trusts the in-tree vendor dir |
| `<64-hex-char string>` | SHA-256 of a mirror-hosted `<name>-<version>-vendor.tar.zst`; the macro auto-creates `:name-vendor-archive` and `:name-vendor-src` targets |
| unset | In `mirror.mode = vendor`, the macro auto-wires `<vendor_dir>/<name>-<version>-vendor.tar.zst` from the local mirror. Otherwise the rule trusts whatever offline-cache the host already has |

## USE-Flag-Gated Features

The macro accepts `use_features = { flag: feature_name }` (or a list of
features per flag). It expands them via `use_feature()` and merges into
`features`. See `defs/package.bzl:539-543`.

## Examples

### Minimal — vendor from mirror

See `/home/hodgesd/buckos-build/packages/linux/dev-tools/dev-utils/ripgrep/BUCK`:

```python
load("//defs/packages:cargo.bzl", "cargo_package")

cargo_package(
    name = "ripgrep",
    version = "14.1.0",
    url = "https://github.com/BurntSushi/ripgrep/archive/refs/tags/14.1.0.tar.gz",
    sha256 = "33c6169596a6bbfdc81415910008f26e0809422fda2d849562637996553b2ab6",
    host_deps = ["//packages/linux/lang/rust:rust"],
)
```

### Custom features + cargo_args

See `/home/hodgesd/buckos-build/packages/linux/dev-tools/dev-utils/sccache/BUCK`:

```python
cargo_package(
    name = "sccache",
    version = "0.14.0",
    url = "https://github.com/mozilla/sccache/archive/refs/tags/v0.14.0.tar.gz",
    sha256 = "f2f194874e6b435896201655432f623d749f5583256f773743c376a6d06cede5",
    license = "Apache-2.0",
    cargo_args = ["--no-default-features", "--features", "gha"],
    deps = [
        "//packages/linux/system/libs/crypto/openssl:openssl",
        "//packages/linux/core/zlib:zlib",
    ],
    host_deps = ["//packages/linux/lang/rust:rust"],
)
```

### USE-flag-gated cargo features

See `/home/hodgesd/buckos-build/packages/linux/emulation/utilities/cloud-hypervisor/BUCK`:

```python
cargo_package(
    name = "cloud-hypervisor",
    version = "50.0",
    url = "...",
    sha256 = "...",
    use_features = {
        "io-uring":     "io_uring",
        "kvm":          "kvm",
        "dbus":         "dbus_api",
    },
    host_deps = [
        "//packages/linux/lang/rust:rust",
        "//packages/linux/core/llvm:llvm-native",
        "//packages/linux/lang/linkers:mold",
    ],
)
```

### Single-binary install

See `/home/hodgesd/buckos-build/packages/linux/dev-tools/build-systems/cbindgen/BUCK`
for a `bins = ["cbindgen"]` package.

## USE Flag Integration

Standard model: declare flags via the dict keys of `use_features`,
`use_deps`, `use_configure`, or `use_transforms`. Each flag becomes a
`buckos:iuse:FLAG` label and a `USE_FLAG=1|0` env var. See SPEC-002.

For Cargo, `use_features` is the canonical hook — it maps USE flags to
the project's `Cargo.toml` feature names.

## RUSTFLAGS Warning

Do **not** set `RUSTFLAGS` globally via `env`. Setting `RUSTFLAGS` outside
`cargo_helper.py` breaks `rust-build` (proc-macro `dlopen` fails because
the buckos sysroot path leaks into host-compiled artifacts).
`cargo_helper.py` handles linker flags correctly via `RUSTFLAGS` +
`CARGO_HOST_LINKER`. If you need extra flags, prefer `cargo_args` or
`extra_cflags` / `extra_ldflags`.

## Patches

Same model as PACKAGE-SPEC-001; see SPEC-005 for the patch registry.

## Generated Targets

```
:{name}-archive          # source tarball
:{name}-src              # extracted source
:{name}-vendor-archive   # vendor tarball (when vendor_deps is a sha256 or local-mirror)
:{name}-vendor-src       # extracted vendor dir
:{name}-build            # cargo build action
:{name}                  # alias
```

## References

- `defs/packages/cargo.bzl` — wrapper
- `defs/rules/cargo.bzl` — rule
- `tools/cargo_helper.py` — build driver (linker flag handling)
- PACKAGE-SPEC-001 — common kwargs, USE-flag value forms
- SPEC-001 (Architecture), SPEC-002 (USE flags), SPEC-005 (Patches)
- Cargo Book: https://doc.rust-lang.org/cargo/
