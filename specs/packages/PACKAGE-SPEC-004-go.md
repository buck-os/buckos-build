---
id: "PACKAGE-SPEC-004"
title: "Go Packages"
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
  - "go"
  - "golang"
  - "language-packages"

related:
  - "SPEC-001"
  - "SPEC-002"
  - "SPEC-005"
  - "PACKAGE-SPEC-001"

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

# Go Package Specification

## Overview

`go_package` builds Go projects via `go build` against the buckos Go SDK
(`//tc/bootstrap/go:go-native`). One Buck2 action drives `go_helper.py`,
which handles `GOFLAGS`, vendor wiring, and offline-cache integration.

| Macro | Loaded from | Underlying rule |
|-------|-------------|-----------------|
| `go_package` | `//defs/packages:go.bzl` | `defs/rules/go.bzl::go_build` |

## Wrapper Signature

```python
go_package(name, version, url, sha256, **kwargs)
```

## Required Arguments

| Argument | Type | Description |
|----------|------|-------------|
| `name` | string | Target name |
| `version` | string | Module version |
| `url` | string | Source tarball URL |
| `sha256` | string | SHA-256 of the tarball |

## Common Optional Arguments

All common kwargs from PACKAGE-SPEC-001 apply: `description`, `homepage`,
`license`, `deps`, `host_deps`, `runtime_deps`, `patches`, `env`,
`extra_cflags`, `extra_ldflags`, `transforms`, `use_transforms`,
`use_deps`, `local_only`, `filename`, `strip_components`, etc.

## Go-Specific Arguments

Forwarded to `go_build` (see `defs/rules/go.bzl`):

| Argument | Type | Description |
|----------|------|-------------|
| `go_args` | list[string] | Extra args appended to `go build` |
| `ldflags` | string | Value passed to `go build -ldflags=...` (single string) |
| `bins` | list[string] | Binary names to install |
| `packages` | list[string] | Go import paths / relative paths to build (default `["."]`) |
| `vendor_deps` | bool / sha256 / dep | Offline vendoring; see below |
| `lib_only` | bool | Build a library/module (no binaries) |

Note: `ldflags` here is a **string** for `go build -ldflags=` — distinct
from the common `extra_ldflags` (list) which controls the C/C++ linker.

## `vendor_deps` Semantics

Identical to cargo (see PACKAGE-SPEC-003), with one extra behaviour:

- `vendor_deps = True` also injects `GOFLAGS=-mod=vendor` so `go build`
  uses the bundled `vendor/` directory (`defs/package.bzl:314-319`).
- A 64-hex-char SHA-256 fetches `<name>-<version>-vendor.tar.zst` from
  the mirror prefix.
- Unset: in `mirror.mode = vendor`, the macro auto-wires the local mirror's
  vendor archive (`defs/package.bzl:369-388`).

## Build Tags

There is **no** `use_tags` kwarg. Pass Go build tags via either:

```python
env = {"GOFLAGS": "-tags=netgo,osusergo"}
```

or via `go_args`:

```python
go_args = ["-tags", "netgo,osusergo"]
```

To gate tags on a USE flag, build the string with `select()`:

```python
env = {
    "GOFLAGS": select({
        "//use/constraints:netgo-on": "-tags=netgo",
        "DEFAULT": "",
    }),
}
```

## Examples

### Minimal library

See `/home/hodgesd/buckos-build/packages/linux/dev-libs/cloud/finnhub-go/BUCK`:

```python
load("//defs/packages:go.bzl", "go_package")

go_package(
    name = "finnhub-go",
    version = "2.0.17",
    url = "https://github.com/Finnhub-Stock-API/finnhub-go/archive/v2.0.17.tar.gz",
    sha256 = "beaffe92ae96a6aafc540d95c98e3f4866121c45b6162da513c64ed59e9c2223",
    license = "Apache-2.0",
    deps = [
        "//packages/linux/dev-libs/cloud/golang-oauth2:golang-oauth2",
    ],
)
```

### Library with bundled vendor/

See `/home/hodgesd/buckos-build/packages/linux/dev-libs/crypto/cloudflare-circl/BUCK`:

```python
go_package(
    name = "cloudflare-circl",
    version = "1.3.9",
    url = "https://github.com/cloudflare/circl/archive/refs/tags/v1.3.9.tar.gz",
    sha256 = "0a1ff8ceddfd4f37a21869588adcfb0f9accfb8c55ef1990caaa9be7e345de67",
    license = "BSD-3",
    lib_only = True,
    vendor_deps = True,   # tarball already has vendor/; macro injects -mod=vendor
)
```

### Binary build with custom flow

When you need full control (custom `go build` invocation, multi-step build
scripts, environment plumbing), drop down to `binary_package` and call
`go build` yourself — see
`/home/hodgesd/buckos-build/packages/linux/dev-tools/lsp/gopls/BUCK` for
the gopls language server.

## USE Flag Integration

Standard model: dict keys of `use_deps`, `use_configure`, `use_transforms`
implicitly declare flags. Each becomes a `buckos:iuse:FLAG` label and
`USE_FLAG=1|0` env var. For Go-specific build tags, see "Build Tags" above.

## CGO

Toggle via `env`:

```python
env = {"CGO_ENABLED": "0"}                # pure-Go binary
env = {"CGO_ENABLED": "1"}                # cgo enabled (default in helper)
```

When CGO is on, list any required C libraries in `deps` like a regular
C package — they propagate through tsets and configure `CGO_CFLAGS` /
`CGO_LDFLAGS` automatically.

## Patches

Same model as PACKAGE-SPEC-001; see SPEC-005.

## Generated Targets

```
:{name}-archive          # source tarball
:{name}-src              # extracted source
:{name}-vendor-archive   # vendor tarball (when vendor_deps is a sha256 / local-mirror)
:{name}-vendor-src       # extracted vendor dir
:{name}-build            # go build action
:{name}                  # alias
```

## References

- `defs/packages/go.bzl` — wrapper
- `defs/rules/go.bzl` — rule
- `tools/go_helper.py` — build driver
- PACKAGE-SPEC-001 — common kwargs
- SPEC-001 (Architecture), SPEC-002 (USE flags), SPEC-005 (Patches)
- Go Modules: https://go.dev/ref/mod
