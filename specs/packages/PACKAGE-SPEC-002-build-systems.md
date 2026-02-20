---
id: "PACKAGE-SPEC-002"
title: "Build System Packages (CMake, Meson, Ninja)"
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
  - "cmake"
  - "meson"
  - "ninja"
  - "build-system"

related:
  - "PACKAGE-SPEC-001"
  - "SPEC-002"

implementation:
  status: "complete"
  completeness: 90

compatibility:
  buck2_version: ">=2024.11.01"
  buckos_version: ">=1.0.0"
  breaking_changes: false
---

# Build System Package Specification

## Abstract

This specification defines packages using modern build systems: CMake, Meson, and Ninja.

## Package Types

- **`package(build_rule = "cmake")`** - CMake-based builds
- **`package(build_rule = "meson")`** - Meson/Ninja builds

## Quick Start Examples

### CMake Package

```python
load("//defs:package.bzl", "package")

package(
    build_rule = "cmake",
    name = "opencv",
    version = "4.8.0",
    url = "https://github.com/opencv/opencv/archive/4.8.0.tar.gz",
    sha256 = "abc123...",
    configure_args = [
        "-DBUILD_EXAMPLES=OFF",
        "-DWITH_FFMPEG=ON",
    ],
    iuse = ["cuda", "opencl", "python"],
    use_options = {
        "cuda": ("-DWITH_CUDA=ON", "-DWITH_CUDA=OFF"),
        "python": ("-DBUILD_PYTHON3=ON", "-DBUILD_PYTHON3=OFF"),
    },
)
```

### Meson Package

```python
load("//defs:package.bzl", "package")

package(
    build_rule = "meson",
    name = "glib",
    version = "2.78.0",
    url = "https://download.gnome.org/sources/glib/2.78/glib-2.78.0.tar.xz",
    sha256 = "xyz789...",
    configure_args = [
        "-Dselinux=disabled",
    ],
    iuse = ["doc", "systemtap"],
    use_options = {
        "doc": ("-Ddocumentation=true", "-Ddocumentation=false"),
    },
)
```

## CMake Packages

### Standard Arguments

CMake packages automatically receive:
- `-DCMAKE_INSTALL_PREFIX=/usr`
- `-DCMAKE_BUILD_TYPE=Release`
- `-DCMAKE_TOOLCHAIN_FILE=<buckos-toolchain>`

### USE Flag Integration

```python
use_options = {
    "ssl": ("-DENABLE_SSL=ON", "-DENABLE_SSL=OFF"),
    "test": ("-DBUILD_TESTING=ON", "-DBUILD_TESTING=OFF"),
}
```

## Meson Packages

### Standard Options

Meson packages automatically receive:
- `--prefix=/usr`
- `--buildtype=release`
- `--sysconfdir=/etc`
- `--localstatedir=/var`

### USE Flag Integration

```python
use_options = {
    "systemd": ("-Dsystemd=enabled", "-Dsystemd=disabled"),
    "doc": ("-Ddocs=true", "-Ddocs=false"),
}
```

## Common Fields

All fields from PACKAGE-SPEC-001 apply, plus:

### CMake-Specific

| Field | Type | Description |
|-------|------|-------------|
| `configure_args` | list[string] | Additional CMake arguments |
| `use_options` | dict | USE flag to CMake option mapping |

### Meson-Specific

| Field | Type | Description |
|-------|------|-------------|
| `configure_args` | list[string] | Additional Meson arguments |
| `use_options` | dict | USE flag to Meson option mapping |

## Examples

Real-world packages:
- CMake: `//packages/linux/media-libs:opencv`
- Meson: `//packages/linux/dev-libs:glib`

## References

- PACKAGE-SPEC-001: Base package specification
- CMake documentation: https://cmake.org/documentation/
- Meson documentation: https://mesonbuild.com/
