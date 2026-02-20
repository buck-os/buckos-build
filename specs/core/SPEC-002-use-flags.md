---
id: "SPEC-002"
title: "USE Flag System"
status: "approved"
version: "1.0.0"
created: "2025-11-20"
updated: "2025-11-27"

authors:
  - name: "BuckOS Team"
    email: "team@buckos.org"

maintainers:
  - "team@buckos.org"

category: "core"
tags:
  - "use-flags"
  - "configuration"
  - "features"
  - "build-system"

related:
  - "SPEC-001"
  - "SPEC-004"

implementation:
  status: "complete"
  completeness: 90

compatibility:
  buck2_version: ">=2024.11.01"
  buckos_version: ">=1.0.0"
  breaking_changes: false

changelog:
  - version: "1.0.0"
    date: "2025-12-27"
    changes: "Migrated to formal specification system with lifecycle management"
---

# USE Flag System

**Status**: approved | **Version**: 1.0.0 | **Last Updated**: 2025-11-27

## Abstract

The USE flag system provides fine-grained control over package features, dependencies, and build configuration in BuckOS. Similar to Gentoo's USE flags but implemented for Buck2, this system enables conditional compilation, optional feature toggling, and dependency management based on user preferences and system profiles.

BuckOs implements a USE flag system similar to Gentoo's, allowing fine-grained control over package features, dependencies, and build configuration.

## Overview

USE flags are configuration options that control:
- **Features**: Which optional features to build into packages
- **Dependencies**: Which optional dependencies to include
- **Build options**: Compiler flags, optimizations, and build behavior

## Quick Start

### 1. Basic USE Flag Package

```python
load("//defs:use_flags.bzl", "use_package", "set_use_flags")

# Set global USE flags
GLOBAL_USE = set_use_flags(["ssl", "http2", "-debug"])

use_package(
    name = "curl",
    version = "8.5.0",
    url = "https://curl.se/download/curl-8.5.0.tar.xz",
    sha256 = "...",

    # Supported USE flags
    iuse = ["ssl", "gnutls", "http2", "ipv6", "debug"],

    # Default flags for this package
    use_defaults = ["ssl", "ipv6"],

    # Conditional dependencies
    use_deps = {
        "ssl": "//packages/linux/dev-libs/openssl",
        "http2": "//packages/linux/net-libs/nghttp2",
    },

    # Conditional configure arguments
    use_configure = {
        "ssl": ("--with-ssl", "--without-ssl"),
        "http2": ("--with-nghttp2", "--without-nghttp2"),
        "ipv6": ("--enable-ipv6", "--disable-ipv6"),
    },

    global_use = GLOBAL_USE,
)
```

### 2. Profile-Based Package

```python
load("//defs:use_flags.bzl", "profile_package")

profile_package(
    name = "nginx",
    version = "1.25.3",
    url = "...",
    sha256 = "...",
    iuse = ["ssl", "http2", "pcre", "debug"],
    profile = "server",  # Uses server profile defaults
    use_deps = {...},
    use_configure = {...},
)
```

## Core Concepts

### USE Flags

USE flags are string identifiers that enable or disable features. Prefix with `-` to disable:

```python
set_use_flags([
    "ssl",           # Enable SSL
    "http2",         # Enable HTTP/2
    "-debug",        # Disable debug
    "-ldap",         # Disable LDAP
])
```

### Profiles

Profiles are predefined USE flag configurations for common use cases:

| Profile | Description |
|---------|-------------|
| `minimal` | Bare essentials only |
| `server` | Headless server optimizations |
| `desktop` | Full desktop with multimedia |
| `developer` | Development tools enabled |
| `hardened` | Security-focused configuration |
| `default` | Balanced defaults |

### Flag Resolution Order

USE flags are resolved in this order (later overrides earlier):

1. Package IUSE defaults (`use_defaults`)
2. Profile defaults
3. Global USE flags (`set_use_flags`)
4. Per-package overrides (`package_use`)

## API Reference

### use_package()

Main macro for creating packages with USE flag support.

```python
use_package(
    name,                  # Package name
    version,               # Package version
    url,                   # Source download URL
    sha256,                # Source checksum
    iuse = [],             # Supported USE flags
    use_defaults = [],     # Default enabled flags
    use_deps = {},         # USE -> dependencies mapping
    use_configure = {},    # USE -> configure args mapping
    use_env = {},          # USE -> environment vars mapping
    use_patches = {},      # USE -> patches mapping
    global_use = None,     # Global USE configuration
    package_overrides = None,  # Package-specific overrides
    ...
)
```

### use_ebuild_package()

Ebuild-style package with custom phase functions. USE flags available via `use()` shell function:

```python
use_ebuild_package(
    name = "libxml2",
    version = "2.12.3",
    url = "...",
    sha256 = "...",
    iuse = ["debug", "icu", "python"],

    src_configure = """
        ./configure --prefix=/usr \\
            $(use debug && echo --enable-debug) \\
            $(use icu && echo --with-icu) \\
            $(use python && echo --with-python)
    """,
    ...
)
```

### set_use_flags()

Set global USE flags:

```python
global_use = set_use_flags([
    "ssl", "http2", "ipv6",
    "-debug", "-test",
])
```

### package_use()

Override USE flags for specific packages:

```python
curl_override = package_use("curl", [
    "-ssl",      # Disable OpenSSL
    "gnutls",    # Use GnuTLS instead
    "brotli",
])
```

### profile_package()

Create package using a profile:

```python
profile_package(
    name = "nginx",
    ...,
    profile = "server",
)
```

## Package Customization

The `package_customize.bzl` module provides Gentoo-style `/etc/portage/` configuration.

### package_config()

Create comprehensive configuration:

```python
load("//defs:package_customize.bzl", "package_config")

MY_CONFIG = package_config(
    # Global USE flags
    use_flags = ["ssl", "http2", "-debug"],

    # Base profile
    profile = "server",

    # Per-package USE (like package.use)
    package_use = {
        "curl": ["gnutls", "-ssl"],
        "nginx": ["http2", "ssl", "pcre2"],
    },

    # Per-package environment (like package.env)
    package_env = {
        "ffmpeg": {"CFLAGS": "-O3 -march=native"},
    },

    # Package masks
    package_mask = [
        "//packages/linux/dev-libs/openssl:1.1",
    ],

    # Compiler flags
    cflags = "-O2 -pipe -march=x86-64",
    cxxflags = "-O2 -pipe -march=x86-64",
    makeopts = "-j$(nproc)",
)
```

### Environment Presets

```python
load("//defs:package_customize.bzl", "get_env_preset")

# Available presets:
# - optimize-size
# - optimize-speed
# - native
# - debug
# - debug-sanitize
# - hardened
# - lto
# - cross-aarch64
# - cross-riscv64

hardened_env = get_env_preset("hardened")
```

## Tooling Integration

The `tooling.bzl` module provides utilities for external tools to generate configurations.

### Generate System Configuration

```python
load("//defs:tooling.bzl", "generate_system_config")

config = generate_system_config(
    profile = "desktop",
    detected_hardware = ["nvidia", "nvme", "audio"],
    detected_features = ["systemd", "pipewire"],
    user_use_flags = ["http2", "-ldap"],
    target_arch = "x86_64",
)
```

### Export Configuration

```python
load("//defs:tooling.bzl",
     "export_config_json",
     "export_config_toml",
     "export_config_shell",
     "export_buck_config")

# Export as JSON
json_config = export_config_json(config)

# Export as TOML
toml_config = export_config_toml(config)

# Export as shell script
shell_config = export_config_shell(config)

# Export as Buck2 .bzl file
buck_config = export_buck_config(config)
```

### Query Available Options

```python
load("//defs:tooling.bzl",
     "get_available_use_flags",
     "get_available_profiles",
     "cmd_list_use_flags")

# Get all available USE flags
all_flags = get_available_use_flags()

# Get profile information
profiles = get_available_profiles()

# Generate formatted list (for CLI output)
output = cmd_list_use_flags(category = "network")
```

## Global USE Flags Reference

### Build Options
- `debug` - Enable debugging symbols and assertions
- `doc` - Build and install documentation
- `examples` - Install example files
- `static` - Build static libraries
- `test` - Enable test suite during build
- `lto` - Enable Link Time Optimization
- `verify-signatures` - Verify GPG signatures on source downloads (see below)

### Security
- `hardened` - Enable security hardening features
- `pie` - Build position independent executables
- `ssp` - Enable stack smashing protection
- `caps` - Use Linux capabilities library
- `seccomp` - Enable seccomp sandboxing
- `selinux` - Enable SELinux support

### Networking
- `ipv6` - Enable IPv6 support
- `ssl` - Enable SSL/TLS support (OpenSSL)
- `gnutls` - Enable GnuTLS support
- `http2` - Enable HTTP/2 support
- `curl` - Use libcurl for HTTP operations

### Compression
- `zlib` - Enable zlib compression
- `bzip2` - Enable bzip2 compression
- `zstd` - Enable Zstandard compression
- `lz4` - Enable LZ4 compression
- `brotli` - Enable Brotli compression

### Graphics
- `X` - Enable X11 support
- `wayland` - Enable Wayland support
- `opengl` - Enable OpenGL support
- `vulkan` - Enable Vulkan support
- `gtk` - Enable GTK+ toolkit
- `qt5` / `qt6` - Enable Qt toolkit

### Audio/Video
- `alsa` - Enable ALSA audio support
- `pulseaudio` - Enable PulseAudio support
- `pipewire` - Enable PipeWire support
- `ffmpeg` - Enable FFmpeg support

### Language Bindings
- `python` - Build Python bindings
- `perl` - Build Perl bindings
- `ruby` - Build Ruby bindings
- `lua` - Build Lua bindings

### System
- `dbus` - Enable D-Bus support
- `systemd` - Enable systemd integration
- `pam` - Enable PAM authentication
- `acl` - Enable Access Control Lists
- `udev` - Enable udev device management

## Example Workflow

### For buckos Tool

```bash
# 1. Detect system capabilities
buckos detect > system_flags.txt

# 2. Generate configuration
buckos configure \
    --profile server \
    --use "ssl http2 -debug" \
    --output buckos_config.bzl

# 3. Build with configuration
buck2 build //packages/linux/... --config //buckos_config.bzl
```

### For Package Maintainers

```python
# Define package with comprehensive USE support
use_package(
    name = "mypackage",
    version = "1.0",
    ...,

    # Document all supported USE flags
    iuse = [
        "ssl",      # SSL/TLS support
        "http2",    # HTTP/2 support
        "debug",    # Debug build
    ],

    # Set sensible defaults
    use_defaults = ["ssl"],

    # Map USE flags to dependencies
    use_deps = {...},

    # Map USE flags to configure options
    use_configure = {...},
)
```

## Environment Variables

Some USE flags can be controlled via environment variables for global override:

### BUCKOS_VERIFY_SIGNATURES

Controls GPG signature verification globally, similar to the `verify-signatures` USE flag:

```bash
# Disable signature verification for all packages
BUCKOS_VERIFY_SIGNATURES=0 buck2 build //packages/linux/...

# Enable signature verification for all packages
BUCKOS_VERIFY_SIGNATURES=1 buck2 build //packages/linux/...

# Set persistently in your shell profile
export BUCKOS_VERIFY_SIGNATURES=0
```

**Values:**
- `1` or `true` - Enable signature verification globally
- `0` or `false` - Disable signature verification globally
- Not set - Use per-package `auto_detect_signature` setting

See `SIGNATURE_VERIFICATION.md` for more details.

## See Also

- `//defs/use_flags.bzl` - Core USE flag system
- `//defs/package_customize.bzl` - Package customization
- `//defs/tooling.bzl` - Tooling integration
- `//packages/linux/examples/use-flags/BUCK` - Example packages
- `SIGNATURE_VERIFICATION.md` - GPG signature verification documentation
