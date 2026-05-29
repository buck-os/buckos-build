---
id: "PACKAGE-SPEC-001"
title: "Autotools, Make, and Binary Packages"
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
  - "autotools"
  - "make"
  - "binary"

related:
  - "SPEC-001"
  - "SPEC-002"
  - "SPEC-005"
  - "PACKAGE-SPEC-002"

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
    changes: "Rewrite against wrapper-based package() API (defs/packages/*.bzl)."
  - version: "1.0.0"
    date: "2025-12-27"
    changes: "Initial spec — superseded."
---

# Autotools, Make, and Binary Package Specification

## Overview

This spec covers the three BUCK file macros used for C/C++ packages that
build out-of-the-box from a source tarball:

| Macro | Loaded from | Build flow |
|-------|-------------|------------|
| `autotools_package` | `//defs/packages:autotools.bzl` | `./configure && make && make install` |
| `make_package` | `//defs/packages:autotools.bzl` | `make && make install` (`skip_configure=True`) |
| `binary_package` | `//defs/packages:binary.bzl` | User-supplied `install_script` shell snippet |

All three are 3-line wrappers that delegate to `package()` in
`defs/package.bzl`. The wrappers exist so BUCK files read better; the macro
handles source download, private patch merge, USE flag expansion, transform
chain, label injection, and host-tool wiring.

## Wrapper Signature

```python
autotools_package(name, version, url, sha256, **kwargs)
make_package(name, version, url, sha256, **kwargs)
binary_package(name, version, url, sha256, install_script, **kwargs)
```

## Required Arguments

| Argument | Type | Description |
|----------|------|-------------|
| `name` | string | Target name (matches directory name) |
| `version` | string | Upstream version string |
| `url` | string | Source tarball URL (or set `local_only=True`) |
| `sha256` | string | SHA-256 of the tarball |
| `install_script` | string | **binary_package only** — shell snippet that installs into `$OUT` |

## Optional Arguments (Common)

These flow through `package()` to every build rule:

| Argument | Type | Description |
|----------|------|-------------|
| `description`, `homepage`, `license`, `cpe` | string | SBOM metadata |
| `deps` | list[label] | Runtime deps (propagate via tsets) |
| `host_deps` | list[label] | Build-only exec deps |
| `runtime_deps` | list[label] | Runtime-only deps (no compile/link propagation) |
| `patches` | list[source] | Public patches in the package dir |
| `configure_args` | list[string] | Static `./configure` args |
| `extra_cflags` / `extra_ldflags` | list[string] | Compile/link flags |
| `linker` | list[string] | `bfd`, `mold`, `gold`, `lld`, `no-pie` |
| `env` | dict[str,str] | Per-phase env vars |
| `transforms` | list[string] | `"strip"`, `"stamp"`, `"ima"` (always applied) |
| `use_transforms` | dict[flag,transform] | USE-gated transforms |
| `use_deps` / `use_configure` | dict | USE-flag-gated deps / configure args |
| `local_only` | bool | Vendor/proprietary source (requires `filename` + mirror) |
| `filename` | string | Override archive filename (default: basename of url) |
| `strip_components` | int | `tar --strip-components` (default 1) |
| `format` | string | Override archive format detection |
| `exclude_patterns` | list[string] | Paths excluded from extraction |
| `libraries` | list[string] | Library names this package provides (for SBOM/linker tracking) |
| `post_install_cmds` | list[string] | Shell snippets run inside `$DESTDIR` after `make install` |
| `labels` | list[string] | Extra BXL labels (auto labels already added) |

## Optional Arguments (autotools/make-specific)

Forwarded to `defs/rules/autotools.bzl::autotools_build`:

| Argument | Type | Description |
|----------|------|-------------|
| `configure_script` | string | Path to alternate configure script |
| `configure_prefix_deps` | dict[flag,dep] | Pass `--with-FLAG=<dep prefix>` to configure |
| `skip_configure` | bool | Skip `./configure` (default for `make_package`) |
| `cc_as_configure_arg` | bool | Pass `CC=...` as a positional arg, not env (hand-rolled configures) |
| `skip_cc_auto_arg` | bool | Don't add `CC=...` automatically |
| `skip_host_arg` | bool | Don't add `--host=` / `--build=` |
| `build_subdir` | string | Configure / build inside a subdir of the source tree |
| `pre_build_cmds` | list[string] | Shell snippets run in the build dir before `make` |
| `pre_configure_cmds` | list[string] | Shell snippets run in the source dir before `./configure` |
| `make_args` | list[string] | Extra args appended to every `make` invocation |
| `install_args` | list[string] | Extra args appended only to `make install` |
| `install_targets` | list[string] | Replace `install` with custom targets |
| `install_prefix_var` | string | Name of the install-prefix variable (default `DESTDIR`) |

## Optional Arguments (binary-specific)

Forwarded to `defs/rules/binary.bzl::binary_build`:

| Argument | Type | Description |
|----------|------|-------------|
| `install_script` | string | Shell snippet — `$SRCS` = source dir, `$OUT` = install root |

Inside the script, the macro also defines:

- `$DESTDIR`/`$INSTALL_DIR` (autotools-compat aliases for `$OUT`)
- `$CC`, `$CXX`, `$AR`, `$CFLAGS`, `$LDFLAGS` from the active toolchain
- `USE_FOO=0|1` for each declared USE flag

Note: passing `src_compile` / `src_install` (and optionally `src_configure`)
to `autotools_package()` auto-converts the target to a `binary` build with
the three snippets joined into one `install_script`. See
`defs/package.bzl:614-637`.

## Examples

### Autotools with USE flags

See `/home/hodgesd/buckos-build/packages/linux/core/bash/BUCK`:

```python
load("//defs/packages:autotools.bzl", "autotools_package")

autotools_package(
    name = "bash",
    version = "5.3",
    url = "https://mirrors.kernel.org/gnu/bash/bash-5.3.tar.gz",
    sha256 = "0d5cd86965f869a26cf64f4b71be7b96f90a3ba8b3d74e27e8e9d9d5550f31ba",
    description = "The GNU Bourne Again SHell",
    license = "GPL-3.0",
    use_deps = {
        "readline": [
            "//packages/linux/system/terminal/readline:readline",
            "//packages/linux/system/terminal/ncurses:ncurses",
        ],
    },
    use_configure = {
        "nls": ("--enable-nls", "--disable-nls"),
        "readline": ("--with-installed-readline", "--without-installed-readline"),
    },
    configure_args = ["--without-bash-malloc"],
    post_install_cmds = ['ln -sf bash "$DESTDIR/usr/bin/sh"'],
)
```

### Raw Makefile (`make_package`)

See `/home/hodgesd/buckos-build/packages/linux/dev-libs/crypto/monocypher/BUCK`
for a `make_package` that builds via inline `src_compile` / `src_install`
(which auto-converts to `binary_build`).

### Binary package

See `/home/hodgesd/buckos-build/packages/linux/dev-tools/lsp/gopls/BUCK`
for `binary_package` invoking `go build` inside a custom install script.

## USE Flag Integration

USE flags are declared implicitly via the dict keys of `use_deps`,
`use_configure`, `use_features`, and `use_transforms`. The macro
auto-generates `buckos:iuse:FLAG` labels and exposes each flag as a
`USE_FLAG=1|0` environment variable in every phase. See SPEC-002 for the
constraint system and `defs/use_helpers.bzl` for the underlying helpers.

`use_configure` value forms (per defs/package.bzl:531-536):

```python
use_configure = {
    "nls":     ("--enable-nls", "--disable-nls"),   # tuple: on/off args
    "extras":  "--with-extras",                     # string: on-arg only
    "things":  ["--with-foo", "--with-bar"],        # list: multiple on-args
}
```

`use_deps` value forms (per defs/package.bzl:512-528):

```python
use_deps = {
    "ssl":  "//packages/linux/system/libs/crypto/openssl:openssl",       # single dep
    "x11":  ["//packages/.../libX11", "//packages/.../libXft"],          # list of deps (on only)
    "gtk":  ("//pkg/gtk3:gtk3", "//pkg/gtk-stub:stub"),                  # (on_dep, off_dep)
}
```

## Patches

Public patches live in the package directory and are listed in `patches`.
Private patches are merged automatically by the registry loader; see
SPEC-005 (Patch System) for the registry format and precedence rules.

## Generated Targets

Every wrapper expands to the same chain of intermediate targets:

```
:{name}-archive   # http_file / export_file (or mirror download)
:{name}-src       # extract_source
:{name}-build     # rule-specific build action chain
:{name}-stripped  # (transform) strip transform if requested
:{name}-stamped   # (transform) stamp transform if requested
:{name}-signed    # (transform) IMA-sign transform if requested
:{name}           # alias to the last target in the chain
```

All intermediate targets are visible and independently buildable.

## References

- `defs/package.bzl` — the central macro
- `defs/packages/autotools.bzl`, `defs/packages/binary.bzl` — wrappers
- `defs/rules/autotools.bzl`, `defs/rules/binary.bzl` — rule implementations
- SPEC-001 (Architecture), SPEC-002 (USE flag system), SPEC-005 (Patches)
- PACKAGE-SPEC-002 (CMake/Meson) for non-autotools C/C++ packages
