---
id: "SPEC-001"
title: "Package Manager Integration"
status: "approved"
version: "1.0.0"
created: "2025-11-20"
updated: "2026-05-29"

authors:
  - name: "BuckOS Team"
    email: "team@buckos.org"

maintainers:
  - "team@buckos.org"

category: "core"
tags:
  - "package-manager"
  - "buck2"
  - "build-system"
  - "integration"

related:
  - "SPEC-002"
  - "SPEC-004"
  - "SPEC-005"

implementation:
  status: "complete"
  completeness: 100

compatibility:
  buck2_version: ">=2024.11.01"
  buckos_version: ">=1.0.0"
  breaking_changes: false

changelog:
  - version: "1.0.0"
    date: "2026-05-29"
    changes: "Rewrite against current package() macro (defs/package.bzl) and per-language wrappers under defs/packages/. Removes eclass/EAPI/license-helper/registry/multi-version/slot/maintainer/tooling sections that no longer exist."
---

# Package Manager Integration

**Status**: approved | **Version**: 1.0.0 | **Last Updated**: 2026-05-29

## Abstract

BuckOS packages are defined by calling the `package()` macro in `defs/package.bzl`
(usually via a thin per-language wrapper under `defs/packages/`). The macro wires
together source download, USE-flag expansion, private patch merging, host-tool
injection, transforms (strip/stamp/IMA sign), SBOM labels, and dispatch to a
language-specific build rule under `defs/rules/`. This spec documents the
user-facing API and the auto-generated targets that downstream tooling can rely
on.

## Overview

A package BUCK file does three things:

1. Loads a wrapper from `//defs/packages:<lang>.bzl` (e.g. `autotools_package`).
2. Calls the wrapper once with `name`, `version`, `url`, `sha256`, and any
   rule-specific kwargs.
3. Optionally declares USE-conditional deps/configure args/cargo features/transforms.

Everything else — fetching the tarball, extracting it, resolving USE flags,
merging private patches, injecting build-host tools, attaching SBOM metadata,
running strip/stamp/IMA transforms — is handled inside `package()`.

## Motivation

Previous iterations of the build system exposed a separate `ebuild` rule, an
eclass inheritance system, an EAPI version selector, a central package
registry, multi-version slots, and per-package maintainer/license helpers.
Most of these were never used or were thin proxies for what Buck2's native
`select()` / `alias()` / `glob()` already provide.

The current design collapses to:

- One macro (`package()`) plus nine wrappers.
- One provider (`PackageInfo`) consumed by every dep.
- One private-override mechanism (`PATCH_REGISTRY` in `patches/registry.bzl`).
- One USE-flag bridge (`use/` constraint subcell plus `defs/use_helpers.bzl`).

This spec only documents what is implemented today.

## Specification

### Architecture

```
packages/linux/<cat>/<name>/BUCK
        │
        │  loads
        ▼
defs/packages/<lang>.bzl       (3-line wrapper)
        │
        │  calls
        ▼
defs/package.bzl::package()    (cross-cutting logic)
        │
        ├── http_file / export_file        → :name-archive
        ├── extract_source                 → :name-src
        ├── merge PATCH_REGISTRY (private patches/configure_args/cflags)
        ├── resolve use_deps / use_configure / use_features
        ├── inject host_deps (bash, coreutils, make, ...) per build_rule
        ├── attach buckos:* labels (provenance, build system, iuse, sha256)
        ├── dispatch to defs/rules/<lang>.bzl::<lang>_build → :name-build
        ├── chain transforms (strip → stamp → ima)
        └── native.alias(name → last target)
```

### The `package()` Macro

Defined in `defs/package.bzl`. Common signature (lines 130–149):

| Kwarg              | Type                                       | Notes                                                                                |
| ------------------ | ------------------------------------------ | ------------------------------------------------------------------------------------ |
| `name`             | str                                        | Buck target name. Final alias gets `name`; underlying build target is `name-build`.  |
| `build_rule`       | str                                        | Dispatch key. Set by the wrapper — only specify when calling `package()` directly.   |
| `version`          | str                                        | Upstream version. Auto-forwarded to the build rule's `version` attr and SBOM labels. |
| `url`              | str                                        | Upstream source URL. Optional only when `local_only = True` or `source = …`.         |
| `sha256`           | str                                        | Required when `url` is set.                                                          |
| `local_only`       | bool                                       | Vendor/proprietary package with no public URL. Requires `filename`.                  |
| `filename`         | str                                        | Override archive filename (defaults to basename of `url`).                           |
| `strip_components` | int                                        | tar strip components for extraction (default 1).                                     |
| `format`           | str                                        | Force archive format detection (`tar.gz`, `tar.xz`, `zip`, …).                       |
| `transforms`       | list[str]                                  | Always-on transforms applied in order. Values: `"strip"`, `"stamp"`, `"ima"`.        |
| `use_transforms`   | dict[str, str]                             | `{ USE flag: transform }`. Transform target exists unconditionally; no-op when off.  |
| `use_deps`         | dict[str, dep \| list \| (on, off) tuple]  | USE-conditional dependencies appended via `select()`.                                |
| `use_configure`    | dict[str, str \| list \| (on, off) tuple]  | USE-conditional `configure_args`.                                                    |
| `use_features`     | dict[str, str]                             | USE-conditional cargo features.                                                      |
| `patches`          | list[source]                               | Public patches (typically `glob(["patches/*.patch"])`).                              |
| `configure_args`   | list[str]                                  | Static configure arguments.                                                          |
| `extra_cflags`     | list[str]                                  | Extra CFLAGS appended to toolchain defaults.                                         |
| `exclude_patterns` | list[str]                                  | tar exclude patterns at extraction time.                                             |
| `**build_kwargs`   | —                                          | Forwarded to the underlying `defs/rules/<lang>.bzl::<lang>_build` rule.              |

Valid `build_rule` values (defs/package.bzl:46–57):

`autotools`, `binary`, `cargo`, `cmake`, `go`, `make` (alias for autotools with
`skip_configure = True`), `meson`, `mozbuild`, `perl`, `python`.

### Per-Language Wrappers

Each wrapper under `defs/packages/` is a 3-line shim. They exist purely so BUCK
files read better — every wrapper accepts every common kwarg above, plus any
rule-specific kwarg that the underlying `<lang>_build` rule declares.

| Wrapper                                                  | Build rule | Rule-specific kwargs                                                                                                                       |
| -------------------------------------------------------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `autotools_package` (`defs/packages/autotools.bzl`)      | autotools  | `configure_prefix_deps`, `configure_script`, `skip_configure`, `cc_as_configure_arg`, `skip_cc_auto_arg`, `skip_host_arg`, `build_subdir`, |
|                                                          |            | `pre_build_cmds`, `make_args`, `install_args`, `install_targets`, `install_prefix_var`                                                     |
| `make_package` (same module)                             | make       | Same as autotools, `skip_configure` defaults to `True`.                                                                                    |
| `binary_package` (`defs/packages/binary.bzl`)            | binary     | `install_script`                                                                                                                           |
| `cargo_package` (`defs/packages/cargo.bzl`)              | cargo      | `features`, `cargo_args`, `bins`, `vendor_deps`                                                                                            |
| `cmake_package` (`defs/packages/cmake.bzl`)              | cmake      | `source_subdir`, `cmake_args`, `cmake_defines`, `cmake_dep_defines`, `make_args`                                                           |
| `go_package` (`defs/packages/go.bzl`)                    | go         | `go_args`, `ldflags`, `bins`, `packages`, `vendor_deps`, `lib_only`                                                                        |
| `meson_package` (`defs/packages/meson.bzl`)              | meson      | `meson_args`, `meson_defines`, `source_subdir`, `make_args`                                                                                |
| `mozbuild_package` (`defs/packages/mozbuild.bzl`)        | mozbuild   | `mozconfig_options`                                                                                                                        |
| `perl_package` (`defs/packages/perl.bzl`)                | perl       | `pre_build_cmds`                                                                                                                           |
| `python_package` (`defs/packages/python.bzl`)            | python     | `use_setup_py`, `pip_args`                                                                                                                 |

#### `src_compile` / `src_install` auto-conversion

If a caller passes `src_compile` or `src_install` to any wrapper, `package()`
auto-converts the call to `build_rule = "binary"` with the two snippets
concatenated into a single `install_script`. Autotools-specific kwargs
(`make_args`, `install_targets`, …) are dropped. This is how packages with
unusual build flows still get the same source download / labels / transforms
pipeline. (defs/package.bzl:614)

### Auto-Generated Targets

A single call to `package(name = "foo", ...)` produces:

| Target          | Type                                  | Always present?            | Purpose                                              |
| --------------- | ------------------------------------- | -------------------------- | ---------------------------------------------------- |
| `:foo-archive`  | `http_file` or `export_file`          | When `url+sha256` provided | Raw tarball / vendored archive (from mirror or URL). |
| `:foo-src`      | `extract_source`                      | Unless caller sets `source` | Extracted source tree, ready for build.              |
| `:foo-build`    | `<lang>_build` rule                   | Always                     | Installed package prefix. Returns `PackageInfo`.     |
| `:foo-stripped` | `strip_package` transform             | If `"strip"` in `transforms` / `use_transforms` | Binaries/libraries stripped of debug info.           |
| `:foo-stamped`  | `stamp_package` transform             | If `"stamp"`               | Build provenance stamp injected into prefix.         |
| `:foo-signed`   | `ima_sign_package` transform          | If `"ima"`                 | IMA-signed binaries for measured boot.               |
| `:foo`          | `native.alias`                        | Always                     | Points at the last node of the chain.                |

Cargo and Go packages with a mirror-hosted vendor tarball also get:

- `:foo-vendor-archive` — fetched vendor tarball.
- `:foo-vendor-src` — extracted vendor directory, auto-wired into the build
  rule's `vendor_deps`.

`vendor_deps` semantics (`defs/package.bzl:308–388`):

- `vendor_deps = True` — source tarball already contains a `vendor/` directory.
  For Go, `GOFLAGS=-mod=vendor` is injected automatically.
- `vendor_deps = "<64-hex-sha256>"` — mirror-hosted vendor tarball; archive +
  extraction targets created automatically.
- Unset, in `mirror.mode = vendor` — auto-wired from the local vendor directory.

### Host-Tool Auto-Injection

For `autotools`, `cmake`, `meson`, `mozbuild`, and `make` packages, `package()`
auto-appends a curated list of buckos-built host tools to `host_deps` so
configure/make/ninja never reach into `/usr/bin`. The full list is in
`defs/package.bzl:418–449` (bash, coreutils, findutils, sed, gawk, grep,
diffutils, patch, tar, gzip/xz/bzip2, python-host, perl, m4, make, pkg-config,
plus meson/ninja or cmake/ninja depending on the build system).

A blocklist (`_TOOL_BLOCKLIST`) prevents these tools from depending on
themselves transitively. Explicit `host_deps` passed by the caller are
preserved and merged with the auto-injected list.

When a prebuilt seed is configured (`buckos.seed_path` or `buckos.seed_url`),
auto-injection is skipped: the seed's hermetic PATH already provides the tools.

### USE Flag Integration

USE flags are constraints defined under `//use/constraints:<flag>-on|off`. The
helpers in `defs/use_helpers.bzl` translate flag names into `select()`
expressions that resolve at analysis time.

`package()` accepts four USE-keyed dicts:

| Kwarg             | Meaning                                                                                                       |
| ----------------- | ------------------------------------------------------------------------------------------------------------- |
| `use_deps`        | `{flag: dep}`, `{flag: [deps]}`, or `{flag: (on_dep, off_dep)}`. Resolved via `use_dep()` / inline `select()`. |
| `use_configure`   | `{flag: arg}`, `{flag: [args]}`, or `{flag: (on_arg, off_arg)}`. Resolved via `use_configure_arg()`.          |
| `use_features`    | `{flag: cargo_feature_name}`. Appended to the cargo rule's `features` attr.                                   |
| `use_transforms`  | `{flag: transform}`. Transform target is created with `enabled = use_bool(flag)`.                              |

USE flags also get exposed to install scripts as environment variables
(`USE_<FLAG_UPPERCASE>=1|0`) and tagged as labels (`buckos:iuse:<flag>`) for
BXL queries.

For the full USE-flag system, see SPEC-002.

### Provenance Labels

`package()` attaches the following labels automatically:

| Label                          | Source                                |
| ------------------------------ | ------------------------------------- |
| `buckos:compile`               | Every package                         |
| `buckos:build:<rule>`          | The selected `build_rule`             |
| `buckos:local_only`            | `local_only = True`                   |
| `buckos:source:<host>`         | Hostname from `url`                   |
| `buckos:url:<url>`             | Full source URL                       |
| `buckos:sha256:<hex>`          | Source archive sha256                 |
| `buckos:sig:none`              | Placeholder for future GPG signatures |
| `buckos:iuse:<flag>`           | One per declared USE flag             |
| `buckos:vendor:<name>`         | `local_only` packages without `url`   |

User-supplied `labels` are appended (not replaced).

### `PackageInfo` Provider

Every package rule returns `PackageInfo` (defined in `defs/providers.bzl:9–36`).
Fields:

| Field          | Type                          | Purpose                                                                  |
| -------------- | ----------------------------- | ------------------------------------------------------------------------ |
| `name`         | str                           | Package name.                                                            |
| `version`      | str                           | Upstream version.                                                        |
| `prefix`       | artifact                      | Install prefix directory (top-level output).                             |
| `libraries`    | list[str]                     | Library names exported for `-l` flags.                                   |
| `cflags`       | list[str]                     | Extra CFLAGS this package requires consumers to use.                     |
| `ldflags`      | list[str]                     | Extra LDFLAGS this package requires consumers to use.                    |
| `compile_info` | `CompileInfoTSet` \| None     | Transitive compile metadata (header paths, pkg-config dirs).             |
| `link_info`    | `LinkInfoTSet` \| None        | Transitive link metadata (lib dirs, libs).                               |
| `path_info`    | `PathInfoTSet` \| None        | Transitive PATH/bin/lib dirs (for runtime composition).                  |
| `runtime_deps` | `RuntimeDepTSet` \| None      | Transitive runtime deps for image composition.                           |
| `license`      | str                           | SPDX expression. Free-form — no enum check.                              |
| `src_uri`      | str                           | Upstream source URL.                                                     |
| `src_sha256`   | str                           | Source archive checksum.                                                 |
| `homepage`     | str \| None                   | Project homepage.                                                        |
| `supplier`     | str                           | SBOM supplier; defaults to `Organization: BuckOS`.                       |
| `description`  | str                           | One-line description.                                                    |
| `cpe`          | str \| None                   | CPE identifier for vulnerability matching.                               |

The transitive sets are `None` for bootstrap packages that have not yet wired
up the tset infrastructure.

### Private Patch Registry

`defs/package.bzl` imports `PATCH_REGISTRY` from `defs/empty_registry.bzl` by
default — an empty dict. Users who maintain private patches create
`patches/registry.bzl` and replace the load at the top of `package.bzl` with:

```python
load("//patches:registry.bzl", "PATCH_REGISTRY")
```

Registry format:

```python
PATCH_REGISTRY = {
    "<package_name>": {
        "patches": ["//patches:fix-foo.patch", ...],
        "extra_configure_args": ["--disable-bar", ...],
        "extra_cflags": ["-DCUSTOM=1", ...],
    },
}
```

`package()` merges public values (from the BUCK file) with private values
(from the registry) at macro time. Public patches/args come first; private
ones are appended (`_merge_private_registry`, defs/package.bzl:109–126).

For the full patch model see SPEC-005.

### Mirror Configuration

`package()` reads four `[mirror]` config keys at module-load time:

| Key           | Default      | Meaning                                                              |
| ------------- | ------------ | -------------------------------------------------------------------- |
| `mode`        | `upstream`   | `upstream` (fetch from `url`) or `vendor` (use local vendor dir).    |
| `base_url`    | `""`         | Optional secondary URL prefix tried before upstream.                 |
| `vendor_dir`  | `""`         | Cell-relative path to vendor directory (only when `mode = vendor`).  |
| `prefix`      | `""`         | URL prefix for content-addressed mirror (sha-suffixed filenames).    |
| `params`      | `""`         | Query string appended to mirror URLs.                                |

These drive whether `:name-archive` is an `http_file` (upstream / prefix mirror)
or an `export_file` (vendor mirror).

## Examples

### Canonical autotools package (`packages/linux/core/bash/BUCK`)

```python
load("//defs/packages:autotools.bzl", "autotools_package")

autotools_package(
    name = "bash",
    version = "5.3",
    url = "https://mirrors.kernel.org/gnu/bash/bash-5.3.tar.gz",
    sha256 = "0d5cd86965f869a26cf64f4b71be7b96f90a3ba8b3d74e27e8e9d9d5550f31ba",
    description = "The GNU Bourne Again SHell",
    homepage = "https://www.gnu.org/software/bash/",
    license = "GPL-3.0",

    use_deps = {
        "readline": [
            "//packages/linux/system/terminal/readline:readline",
            "//packages/linux/system/terminal/ncurses:ncurses",
        ],
    },

    use_configure = {
        "nls":       ("--enable-nls",      "--disable-nls"),
        "readline":  ("--with-installed-readline", "--without-installed-readline"),
        "examples":  ("--enable-examples", "--disable-examples"),
    },

    configure_args = ["--without-bash-malloc"],

    post_install_cmds = ['ln -sf bash "$DESTDIR/usr/bin/sh"'],
)
```

This single call produces `:bash-archive`, `:bash-src`, `:bash-build`, `:bash`,
plus four `buckos:iuse:*` labels and full SBOM metadata.

### Multi-version package (`packages/linux/system/libs/crypto/openssl/BUCK`)

Multiple versions are defined as independent packages with an alias to the
default. There is no slot abstraction.

```python
load("//defs/packages:autotools.bzl", "autotools_package")

autotools_package(
    name = "openssl-3.6",
    version = "3.6.1",
    configure_script = "Configure",
    skip_host_arg = True,
    url = "https://github.com/openssl/openssl/releases/download/openssl-3.6.1/openssl-3.6.1.tar.gz",
    sha256 = "b1bfedcd5b289ff22aee87c9d600f515767ebf45f77168cb6d64f231f518a82e",
    libraries = ["ssl", "crypto"],
    configure_args = ["--prefix=/usr", "--openssldir=/etc/ssl", "--libdir=lib"],
    pre_build_cmds = ["make || true"],
    deps = ["//packages/linux/core/zlib:zlib"],
    patches = glob(["patches/3.6/*.patch"]),
    transforms = ["strip", "stamp"],
    use_transforms = {"ima": "ima"},
    license = "Apache-2.0",
    cpe = "cpe:2.3:a:openssl:openssl:3.6.1:*:*:*:*:*:*:*",
)

autotools_package(
    name = "openssl-3.3",
    version = "3.3.2",
    # ...
)

alias(name = "openssl", actual = ":openssl-3.6")
```

`openssl-3.6` carries `transforms = ["strip", "stamp"]` (always on) plus
`use_transforms = {"ima": "ima"}` (gated on the `ima` USE flag), producing
the chain `:openssl-3.6-build → :openssl-3.6-stripped →
:openssl-3.6-stamped → :openssl-3.6-signed → :openssl-3.6` (alias).

### Cargo package with vendored deps

```python
load("//defs/packages:cargo.bzl", "cargo_package")

cargo_package(
    name = "ripgrep",
    version = "14.1.1",
    url = "https://github.com/BurntSushi/ripgrep/archive/14.1.1.tar.gz",
    sha256 = "...",
    vendor_deps = "<64-hex sha256 of vendor tarball on mirror>",
    bins = ["rg"],
    license = "Unlicense OR MIT",
)
```

`package()` auto-creates `:ripgrep-vendor-archive` and `:ripgrep-vendor-src`
from the mirror and wires the latter into the cargo rule.

## Implementation

| Component                  | Path                          | Notes                                                                        |
| -------------------------- | ----------------------------- | ---------------------------------------------------------------------------- |
| Macro                      | `defs/package.bzl`            | `package()` at line 130. Dispatch table at lines 46–57.                       |
| Wrappers                   | `defs/packages/*.bzl`         | One file per language. All are 3-line shims.                                  |
| Build rules                | `defs/rules/*.bzl`            | `autotools.bzl`, `cmake.bzl`, `meson.bzl`, `cargo.bzl`, `go.bzl`, etc.       |
| Common rule attrs          | `defs/rules/_common.bzl`      | `COMMON_PACKAGE_ATTRS` used by every build rule.                              |
| Source extraction          | `defs/rules/source.bzl`       | `extract_source` (anon-target backed).                                       |
| Transforms                 | `defs/rules/transforms.bzl`   | `strip_package`, `stamp_package`, `ima_sign_package`.                        |
| USE helpers                | `defs/use_helpers.bzl`        | `use_bool`, `use_dep`, `use_configure_arg`, `use_feature`, `use_expand_*`.   |
| Provider                   | `defs/providers.bzl`          | `PackageInfo`, `BuildToolchainInfo`, kernel/image providers.                 |
| Patch registry (empty)     | `defs/empty_registry.bzl`     | `PATCH_REGISTRY = {}` default.                                               |
| Patch registry (private)   | `patches/registry.bzl`        | User-supplied override (gitignored).                                         |
| Package sets               | `defs/package_sets.bzl`       | `system_set`, `package_set`, `combined_set`, profile USE-flag presets.       |
| Host-tool seed list        | `tc/bootstrap/host-tools/packages.bzl` | `HOST_TOOL_PACKAGES` — gates explicit `host_deps` in seed mode.    |

`scripts/validate-spec.py` validates this spec's frontmatter (id, version,
date, status, category).

## Security Considerations

- **Checksum verification.** `sha256` is required for every `http_file`
  download. `package()` rejects calls that have `url` without `sha256`
  (defs/package.bzl:189–194).
- **Network isolation.** Build phases run under `unshare --net`; vendor
  tarballs for Cargo/Go packages are required for offline builds.
- **Host PATH escape.** Host-tool auto-injection (see above) ensures
  configure/make never finds `/usr/bin/python`, `/usr/bin/perl`, etc., which
  would break ABI assumptions on heterogeneous build hosts.
- **Provenance.** Every build target carries `buckos:url:`, `buckos:sha256:`,
  and `buckos:source:<host>` labels for SBOM generation.
- **Private patches.** The `PATCH_REGISTRY` loading mechanism is opt-in;
  default builds use the empty registry. Private patches are merged
  deterministically (public first, then private).

## Alternatives Considered

- **Eclass inheritance (Gentoo-style).** Removed. Eclass logic now lives
  inline in the language-specific `defs/rules/<lang>.bzl` modules, and
  cross-cutting logic lives in `package()`. Wrappers are too small to need
  inheritance.
- **EAPI versioning.** Removed. The macro is internal API; we version the
  spec instead.
- **Central package registry.** Removed. Buck2 already provides target
  enumeration via `buck2 targets` and BXL queries.
- **Slot/subslot system.** Removed. Versioned packages are defined as
  independent targets with an `alias()` for the default (see openssl example).
  This is simpler, fully explicit, and avoids select() explosions.
- **`build_rule = "ebuild" | "simple" | "bootstrap"`.** Removed. The dispatch
  table is restricted to language-specific rules (`autotools`, `cmake`,
  `meson`, `cargo`, `go`, `make`, `binary`, `perl`, `python`, `mozbuild`).

## References

- SPEC-002: USE Flag System — the constraint and helper machinery `package()`
  consumes via `use_deps`, `use_configure`, `use_features`, `use_transforms`.
- SPEC-004: Package Sets and System Profiles — `system_set` / `package_set` /
  `combined_set` and the profile USE-flag presets.
- SPEC-005: Patch System — `patches` kwarg, `PATCH_REGISTRY` format, patch
  application semantics.
- `defs/package.bzl` — the macro source of truth.
- `defs/providers.bzl` — `PackageInfo` and related providers.
- `defs/rules/_common.bzl::COMMON_PACKAGE_ATTRS` — the attrs every build rule
  accepts.
