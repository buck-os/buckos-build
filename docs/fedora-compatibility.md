# Fedora Compatibility Layer

This document describes BuckOS's Fedora compatibility system, which allows hybrid builds mixing BuckOS-native packages with Fedora RPM packages.

## Overview

The Fedora compatibility layer provides:

1. **RPM Package Support** - Install and use Fedora RPM packages directly
2. **FHS Filesystem Mapping** - Automatic translation between BuckOS and Fedora filesystem layouts
3. **Fedora Build Flags** - Match Fedora's compiler and linker flags for ABI compatibility
4. **Compatibility Tags** - Mark packages by which distributions they support
5. **Automatic Variant Selection** - Buck selects appropriate package variants based on USE=fedora flag

## Quick Start

### Enable Fedora Compatibility Mode

```bash
# Build a package with Fedora compatibility
USE=fedora buck2 build //packages/linux/fedora-compat:curl

# Build entire system with Fedora compatibility
USE=fedora buck2 build //:minimal
```

### Check Package Compatibility

```bash
# Query compatibility tags on a package
buck2 query "labels(compat_tags, //packages/linux/core/bash:bash)"

# Find all Fedora-compatible packages
buck2 query 'filter("fedora", labels(compat_tags, //packages/...))'
```

## Architecture

### 1. USE Flag System

The `fedora` USE flag controls Fedora compatibility mode:

```python
# In .buckconfig
# [use]
# fedora = true

# Affects:
# - Filesystem layout (FHS vs BuckOS)
# - Compiler flags (Fedora hardening flags)
# - Package selection (RPMs vs native builds)
# - Library paths (/usr/lib64 vs /usr/lib)
```

### 2. Compatibility Tags

Packages declare which distributions they support via `compat_tags`:

```python
autotools_package(
    name = "bash",
    version = "5.3",
    compat_tags = ["buckos-native", "fedora"],  # Works in both modes
    # ...
)

rpm_package(
    name = "firefox",
    compat_tags = ["fedora"],  # Only available in Fedora mode
    # ...
)
```

**Valid compatibility tags:**
- `buckos-native` - BuckOS native packages (default)
- `fedora` - Fedora compatible packages

### 3. Filesystem Layout Mapping

The FHS mapping system translates paths between layouts:

| BuckOS Native | Fedora FHS | Notes |
|---------------|------------|-------|
| `/usr/lib` | `/usr/lib64` | 64-bit libraries (x86_64) |
| `/usr/lib32` | `/usr/lib` | 32-bit compat libraries |
| `/usr/libexec` | `/usr/libexec` | Same |
| `/usr/bin` | `/usr/bin` | Same |

**FHS mapping is automatic** when `USE=fedora` is enabled:
- Configure scripts receive `--libdir=/usr/lib64`
- CMake receives `-DCMAKE_INSTALL_LIBDIR=lib64`
- Symlinks created for cross-layout compatibility

### 4. Fedora Build Flags

When `USE=fedora`, packages use Fedora's compiler flags:

```python
# Automatically applied:
CFLAGS="-O2 -flto=auto -fexceptions -g -pipe \
        -Wall -Werror=format-security \
        -Wp,-D_FORTIFY_SOURCE=2 -Wp,-D_GLIBCXX_ASSERTIONS \
        -fstack-clash-protection -fcf-protection"

LDFLAGS="-Wl,-z,relro -Wl,-z,now -Wl,--as-needed"
```

These match Fedora 40's default build flags for ABI compatibility.

## Package Types

### Native Packages with Fedora Compatibility

Standard packages built from source, compatible with both modes:

```python
autotools_package(
    name = "curl",
    version = "8.5.0",
    src_uri = "https://curl.se/download/curl-8.5.0.tar.xz",
    sha256 = "...",

    # Works in both BuckOS and Fedora modes
    compat_tags = ["buckos-native", "fedora"],

    # USE flags work the same
    iuse = ["ssl", "http2"],
    use_defaults = ["ssl"],

    use_configure = {
        "ssl": "--with-openssl",
        "http2": "--with-nghttp2",
    },
)
```

### RPM Packages (Fedora-only)

Pre-built RPM packages from Fedora repositories:

```python
load("//defs:rpm_package.bzl", "rpm_package", "fedora_rpm_url")

rpm_package(
    name = "firefox",
    rpm_uri = fedora_rpm_url("firefox", "126.0-1.fc40", "40"),
    sha256 = "...",
    fedora_version = "40",

    # Map RPM dependencies to Buck targets
    rpm_deps = {
        "gtk3": "//packages/linux/desktop/gtk:gtk3",
        "dbus-libs": "//packages/linux/core/dbus:dbus",
        "libX11": "//packages/linux/graphics/xorg:libX11",
    },

    description = "Mozilla Firefox Web Browser",
    homepage = "https://www.mozilla.org/firefox/",
    license = "MPL-2.0",
)
```

### Conditional Package Selection

Use Buck's `select()` to choose variants based on mode:

```python
alias(
    name = "package",
    actual = select({
        "//platforms:fedora": ":package-rpm",        # Fedora mode: use RPM
        "DEFAULT": ":package-native",                # Default: native build
    }),
)
```

## RPM Dependency Translation

The system translates common RPM dependencies to Buck targets:

```python
rpm_deps = {
    "openssl-libs": "system//libs/crypto/openssl:openssl",
    "zlib": "//packages/linux/core/zlib:zlib",
    "gtk3": "//packages/linux/desktop/gtk:gtk3",
    # ... see defs/rpm_package.bzl for full list
}
```

**Unknown RPM dependencies** will trigger a warning. Add mappings to `RPM_DEPENDENCY_MAP` in `defs/rpm_package.bzl`.

## Hybrid System Example

Build a system with mixed packages:

```python
filegroup(
    name = "hybrid-system",
    srcs = [
        # Native packages (always available)
        "//packages/linux/core/bash:bash",
        "//packages/linux/core/coreutils:coreutils",

        # Compatibility-aware (adapts to mode)
        "//packages/linux/network/curl:curl",

        # Fedora RPMs (only with USE=fedora)
        "//packages/linux/fedora-compat:firefox-rpm",
    ],
)
```

Build:
```bash
# Native system (no Fedora packages)
buck2 build :hybrid-system

# With Fedora compatibility (includes RPMs)
USE=fedora buck2 build :hybrid-system
```

## Platform Constraints

Packages can declare constraints using Buck's platform system:

```python
# Defined in platforms/BUCK
constraint_setting(name = "distro_compat")
constraint_value(name = "buckos-native", constraint_setting = ":distro_compat")
constraint_value(name = "fedora", constraint_setting = ":distro_compat")

# Use in package definitions
platform(
    name = "fedora-x86_64",
    constraint_values = [
        "//platforms:fedora",
        "prelude//cpu/constraints:x86_64",
    ],
)
```

## Files Created

### Core Infrastructure

- `defs/distro_constraints.bzl` - Distribution constraint helpers
- `defs/fhs_mapping.bzl` - Filesystem layout mapping
- `defs/rpm_package.bzl` - RPM package rules
- `config/fedora_build_flags.bzl` - Fedora compiler flags
- `platforms/BUCK` - Distribution constraints

### USE Flag System

- `defs/use_flags.bzl` - Added `fedora` USE flag
- `.buckconfig` `[use]` section - USE flag configuration

### Package Definitions

- `defs/package_defs.bzl` - Added `compat_tags` parameter to:
  - `autotools_package()`
  - `cmake_package()`
  - `meson_package()`

### Examples

- `packages/linux/fedora-compat/BUCK` - Example packages

## Implementation Details

### FHS Mapping

The `fhs_mapping.bzl` module provides:

```python
# Path translation
fhs_to_buckos("/usr/lib64/libfoo.so")  # -> "/usr/lib/libfoo.so"
buckos_to_fhs("/usr/lib/libfoo.so")    # -> "/usr/lib64/libfoo.so"

# Get configure args for layout
get_configure_args_for_layout("fhs")
# Returns: ["--prefix=/usr", "--libdir=/usr/lib64", ...]

# Get library search paths
get_lib_dirs("fhs", "x86_64")
# Returns: ["/usr/lib64", "/lib64", "/usr/lib", "/lib"]
```

### Build Flag Application

When `USE=fedora` is enabled, packages automatically receive:

```python
from config.fedora_build_flags import get_fedora_build_env

env = get_fedora_build_env(arch="x86_64", build_type="release")
# Returns:
# {
#     "CFLAGS": "-O2 -flto=auto ...",
#     "CXXFLAGS": "-O2 -flto=auto ...",
#     "LDFLAGS": "-Wl,-z,relro -Wl,-z,now ...",
#     "CC": "gcc",
#     "CXX": "g++",
# }
```

### RPM Extraction

RPM packages are:
1. Downloaded from Fedora mirrors
2. Extracted using `rpm2cpio | cpio`
3. Files mapped to target filesystem layout
4. Symlinks created for compatibility

## Best Practices

### 1. Use Compatibility Tags

Always specify `compat_tags` explicitly:

```python
# Good
autotools_package(
    name = "pkg",
    compat_tags = ["buckos-native", "fedora"],
    # ...
)

# Acceptable (defaults to buckos-native)
autotools_package(
    name = "pkg",
    # compat_tags defaults to ["buckos-native"]
    # ...
)
```

### 2. Prefer Native Builds

Use RPMs only when:
- Package is complex to build
- No source available
- Proprietary software
- Rapid prototyping/bootstrapping

Native builds are preferred for:
- Better control over build options
- Reproducibility
- Consistent toolchain

### 3. Test Both Modes

If package has `compat_tags = ["buckos-native", "fedora"]`, test both:

```bash
# Test native mode
buck2 build //path/to:package

# Test Fedora mode
USE=fedora buck2 build //path/to:package
```

### 4. Document RPM Dependencies

When adding RPM packages, document dependency mappings:

```python
rpm_package(
    name = "complex-app",
    rpm_deps = {
        # Document why each dependency is needed
        "gtk3": "//...:gtk3",          # UI framework
        "dbus-libs": "//...:dbus",     # IPC
        "libffi": "//...:libffi",      # Foreign function interface
    },
)
```

## Troubleshooting

### Package Won't Build in Fedora Mode

Check:
1. Does package have `compat_tags = ["fedora"]` or `["buckos-native", "fedora"]`?
2. Are Fedora build flags compatible? (Check `-fcf-protection`, `-fstack-clash-protection`)
3. Does package expect `/usr/lib64` vs `/usr/lib`?

### RPM Dependencies Missing

Add mappings to `RPM_DEPENDENCY_MAP` in `defs/rpm_package.bzl`:

```python
RPM_DEPENDENCY_MAP = {
    # ... existing ...
    "your-rpm-lib": "//packages/linux/category/pkg:target",
}
```

### Library Not Found at Runtime

Check `LD_LIBRARY_PATH` and symlinks:

```bash
# In Fedora mode, check for lib64 symlinks
ls -la /usr/lib64/libfoo.so
ls -la /usr/lib/libfoo.so  # Should symlink to lib64

# Verify library search paths
ldconfig -p | grep libfoo
```

## Future Enhancements

Potential future additions:

1. **Other distributions** - Debian, Arch, Alpine support
2. **Container integration** - Run RPMs in isolated containers
3. **Automatic dependency resolution** - Parse RPM metadata automatically
4. **Multi-version RPMs** - Support multiple Fedora versions simultaneously
5. **RPM building** - Generate RPMs from BuckOS packages

## See Also

- `defs/use_flags.bzl` - USE flag system documentation
- `defs/platform_defs.bzl` - Platform constraint system
- `defs/package_defs.bzl` - Package definition macros
- Fedora Packaging Guidelines: https://docs.fedoraproject.org/en-US/packaging-guidelines/
- FHS Specification: https://refspecs.linuxfoundation.org/FHS_3.0/
