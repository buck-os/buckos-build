---
id: "PACKAGE-SPEC-002"
title: "CMake and Meson Packages"
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
  - "cmake"
  - "meson"
  - "ninja"

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

# CMake and Meson Package Specification

## Overview

Wrapper macros for C/C++ packages using CMake or Meson. Both delegate to
`package()` and inherit the full set of common arguments from
PACKAGE-SPEC-001.

| Macro | Loaded from | Underlying rule |
|-------|-------------|-----------------|
| `cmake_package` | `//defs/packages:cmake.bzl` | `defs/rules/cmake.bzl::cmake_build` |
| `meson_package` | `//defs/packages:meson.bzl` | `defs/rules/meson.bzl::meson_build` |

Both rules drive Ninja as the build backend and run configure, build, and
install as three cacheable Buck2 actions.

## Wrapper Signature

```python
cmake_package(name, version, url, sha256, **kwargs)
meson_package(name, version, url, sha256, **kwargs)
```

## Required Arguments

| Argument | Type | Description |
|----------|------|-------------|
| `name` | string | Target name |
| `version` | string | Upstream version |
| `url` | string | Source tarball URL (or set `local_only=True`) |
| `sha256` | string | SHA-256 of the tarball |

## Common Optional Arguments

All of the common kwargs from PACKAGE-SPEC-001 apply: `description`,
`homepage`, `license`, `deps`, `host_deps`, `runtime_deps`, `patches`,
`configure_args`, `extra_cflags`, `extra_ldflags`, `linker`, `env`,
`transforms`, `use_transforms`, `use_deps`, `use_configure`,
`post_install_cmds`, `local_only`, `filename`, `strip_components`, etc.

`configure_args` is passed through to whatever the rule's configure step is
(`cmake` for cmake, `meson setup` for meson). Use it for cross-cutting
flags like `-DCMAKE_BUILD_TYPE=Release` or `--wrap-mode=nofallback`.

## CMake-Specific Arguments

Forwarded to `cmake_build` (see `defs/rules/cmake.bzl`):

| Argument | Type | Description |
|----------|------|-------------|
| `source_subdir` | string | Run `cmake` against `<source>/<subdir>` instead of root |
| `cmake_args` | list[string] | Extra `cmake -S . -B build` args (in addition to `configure_args`) |
| `cmake_defines` | list[string] | Plain strings appended as `-D...=...` |
| `cmake_dep_defines` | dict[string,dep] | Map a CMake var name to a dep — the var is set to that dep's install prefix at configure time |
| `make_args` | list[string] | Extra args to `ninja` / `ninja install` |

The rule automatically injects `CMAKE_INSTALL_PREFIX=/usr`,
`CMAKE_BUILD_TYPE=Release`, sysroot include / library paths, and the
toolchain CC/CXX/AR via the BuildToolchainInfo provider.

## Meson-Specific Arguments

Forwarded to `meson_build` (see `defs/rules/meson.bzl`):

| Argument | Type | Description |
|----------|------|-------------|
| `source_subdir` | string | Run `meson setup` against `<source>/<subdir>` |
| `meson_args` | list[string] | Extra `meson setup` args (in addition to `configure_args`) |
| `meson_defines` | list[string] | Plain `-D...=...` strings |
| `make_args` | list[string] | Extra args to `ninja` / `ninja install` |

The rule automatically injects `--prefix=/usr`, `--sysconfdir=/etc`,
`--localstatedir=/var`, `--buildtype=release`, and toolchain CC/CXX paths.

Meson packages also automatically pick up `meson` + `ninja` host tools
without needing explicit `host_deps` (see `defs/package.bzl:440-444`).

## Examples

### CMake — minimal

See `/home/hodgesd/buckos-build/packages/linux/ai/llama-cpp/BUCK`:

```python
load("//defs/packages:cmake.bzl", "cmake_package")

cmake_package(
    name = "llama-cpp",
    version = "b4154",
    url = "https://github.com/ggerganov/llama.cpp/archive/refs/tags/b4154.tar.gz",
    sha256 = "0fbaaf63d10108c0b49eb9aa99bd908bac04c3b301addb2d6da3b27a980da1e1",
    license = "MIT",
    configure_args = [
        "-DCMAKE_BUILD_TYPE=Release",
        "-DGGML_NATIVE=OFF",
        "-DLLAMA_BUILD_SERVER=ON",
    ],
    deps = ["//packages/linux/core/zlib:zlib"],
)
```

### CMake — `source_subdir`

See `/home/hodgesd/buckos-build/packages/linux/ai/benchmarks/mlcommons/BUCK`
(the `mlcommons-loadgen` target) for a tarball where the CMake project lives
in a subdirectory.

### Meson with USE flags

See `/home/hodgesd/buckos-build/packages/linux/dev-libs/glib/BUCK`:

```python
load("//defs/packages:meson.bzl", "meson_package")

meson_package(
    name = "glib",
    version = "2.80.0",
    url = "https://download.gnome.org/sources/glib/2.80/glib-2.80.0.tar.xz",
    sha256 = "8228a92f92a412160b139ae68b6345bd28f24434a7b5af150ebe21ff587a561d",
    license = "LGPL-2.1+",
    use_configure = {
        "introspection": ("-Dintrospection=enabled", "-Dintrospection=disabled"),
        "selinux":       ("-Dselinux=enabled", "-Dselinux=disabled"),
        "static-libs":   ("-Ddefault_library=both", "-Ddefault_library=shared"),
    },
    configure_args = [
        "--wrap-mode=nofallback",
        "-Dgtk_doc=false",
        "-Dtests=false",
    ],
    deps = [
        "//packages/linux/system/libs/utility/libffi:libffi",
        "//packages/linux/core/zlib:zlib",
        "//packages/linux/system/libs/utility/pcre2:pcre2",
    ],
)
```

## USE Flag Integration

Use the common `use_configure` kwarg with `-D...` strings — there is no
separate `use_options` argument. For example:

```python
use_configure = {
    "ssl":  ("-DENABLE_SSL=ON", "-DENABLE_SSL=OFF"),       # cmake
    "doc":  ("-Ddocumentation=true", "-Ddocumentation=false"),  # meson
}
```

Value forms (single string, list, or `(on, off)` tuple) are identical to
the autotools case; see PACKAGE-SPEC-001 and `defs/use_helpers.bzl`.

## Patches

Same model as PACKAGE-SPEC-001: list public patches in `patches`; private
patches are merged via the registry described in SPEC-005.

## Generated Targets

Same chain as PACKAGE-SPEC-001:

```
:{name}-archive  ->  :{name}-src  ->  :{name}-build  ->  transforms  ->  :{name}
```

## References

- `defs/packages/cmake.bzl`, `defs/packages/meson.bzl` — wrappers
- `defs/rules/cmake.bzl`, `defs/rules/meson.bzl` — rules
- PACKAGE-SPEC-001 — common kwargs, USE flag value forms, patch model
- SPEC-001 (Architecture), SPEC-002 (USE flag system), SPEC-005 (Patches)
- CMake: https://cmake.org/documentation/
- Meson: https://mesonbuild.com/
