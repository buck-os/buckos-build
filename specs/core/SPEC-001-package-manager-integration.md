---
id: "SPEC-001"
title: "Package Manager Integration"
status: "approved"
version: "1.0.0"
created: "2025-11-20"
updated: "2025-12-27"

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
  - "SPEC-003"
  - "SPEC-004"
  - "SPEC-005"

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
    changes: "Migrated to formal specification system with lifecycle management"
---

# Package Manager Integration

**Status**: approved | **Version**: 1.0.0 | **Last Updated**: 2025-12-27

## Abstract

This specification defines how package managers should interact with the BuckOS Buck2 build system. It provides a complete specification for implementing package manager tooling that integrates with BuckOS, covering package definitions, metadata structures, query interfaces, configuration generation, build integration, dependency resolution, and all aspects of package management integration.


## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Package Definition Format](#package-definition-format)
3. [Metadata Structures](#metadata-structures)
4. [Query Interfaces](#query-interfaces)
5. [Configuration Generation](#configuration-generation)
6. [Build Integration](#build-integration)
7. [Dependency Resolution](#dependency-resolution)
8. [Version Management](#version-management)
9. [USE Flag System](#use-flag-system)
10. [Package Sets](#package-sets)
11. [Patch System](#patch-system)
12. [CLI Requirements](#cli-requirements)
13. [Export Formats](#export-formats)
14. [Error Handling](#error-handling)
15. [Extension Points](#extension-points)
16. [Security Considerations](#security-considerations)
17. [Best Practices](#best-practices)

---

## Architecture Overview

### System Components

```
┌─────────────────────────────────────────────────────────────┐
│                    Package Manager CLI                       │
├─────────────────────────────────────────────────────────────┤
│  Query Layer  │  Config Layer  │  Build Layer  │  UI Layer  │
└───────┬───────┴───────┬────────┴───────┬───────┴─────┬──────┘
        │               │                │             │
        ▼               ▼                ▼             ▼
┌───────────────────────────────────────────────────────────┐
│                   Integration Layer                        │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐    │
│  │ tooling.bzl │  │ registry.bzl│  │  package.bzl    │    │
│  └─────────────┘  └─────────────┘  └─────────────────┘    │
└───────────────────────────────────────────────────────────┘
        │               │                │
        ▼               ▼                ▼
┌───────────────────────────────────────────────────────────┐
│                   Buck2 Build System                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐    │
│  │   Targets   │  │   Rules     │  │   Providers     │    │
│  └─────────────┘  └─────────────┘  └─────────────────┘    │
└───────────────────────────────────────────────────────────┘
```

### Core Integration Files

| File | Purpose | Package Manager Usage |
|------|---------|----------------------|
| `defs/tooling.bzl` | External tool integration | Primary integration point |
| `defs/registry.bzl` | Central version registry | Version and package queries |
| `defs/package.bzl` | Package build rules | Build invocation |
| `defs/use_flags.bzl` | USE flag definitions | Flag management |
| `defs/package_sets.bzl` | Package collections | Set operations |
| `defs/versions.bzl` | Version management | Version/slot/subslot resolution |
| `defs/maintainers.bzl` | Maintainer registry | Package ownership |
| `defs/package_customize.bzl` | User customization | Configuration overlay |
| `defs/eclasses.bzl` | Eclass inheritance | Build pattern reuse |
| `defs/licenses.bzl` | License management | License validation and groups |
| `defs/eapi.bzl` | EAPI versioning | API feature management |

### Integration Principles

1. **Read-Only Access**: Package managers SHOULD NOT modify BUCK files directly
2. **Buck2 as Source of Truth**: All package metadata comes from Buck2 queries
3. **Configuration Export**: Use export functions for configuration generation
4. **Idempotent Operations**: All operations MUST be reproducible

---

## Package Definition Format

### Standard Package Structure

Package managers MUST understand the following package definition patterns:

#### 1. Basic Package (use_package)

```python
load("//defs:use_flags.bzl", "use_package")

use_package(
    name = "package-name",
    version = "1.0.0",
    url = "https://example.com/package-1.0.0.tar.gz",
    sha256 = "abc123...",

    # USE flag configuration
    iuse = ["feature1", "feature2", "debug"],
    use_defaults = ["feature1"],
    use_deps = {
        "feature1": "//path/to/dep1",
    },
    use_configure = {
        "feature1": ("--enable-feature1", "--disable-feature1"),
    },

    # Build configuration
    configure_args = ["--prefix=/usr"],
    make_args = [],
    install_args = ["DESTDIR=$DESTDIR"],

    # Lifecycle hooks
    post_install = "shell commands",

    # Metadata
    maintainers = ["team-name"],
)
```

#### 2. Multi-Version Package

```python
load("//defs:versions.bzl", "multi_version_package")

multi_version_package(
    name = "openssl",
    versions = {
        "3.2.0": {
            "slot": "3",
            "status": "stable",
            "url": "https://...",
            "sha256": "...",
        },
        "1.1.1w": {
            "slot": "1.1",
            "status": "stable",
            "url": "https://...",
            "sha256": "...",
        },
    },
    default_version = "3.2.0",
)
```

#### 3. Ebuild-Style Package

```python
load("//defs:package.bzl", "package")

package(
    build_rule = "ebuild",
    name = "complex-package",
    version = "2.0.0",

    phases = {
        "src_prepare": """
            # Patch application
            patch -p1 < fix.patch
        """,
        "src_configure": """
            ./configure --prefix=/usr
        """,
        "src_compile": """
            make -j$(nproc)
        """,
        "src_install": """
            make DESTDIR="$DESTDIR" install
        """,
    },
)
```

### Package Path Convention

```
//packages/linux/<category>/<subcategory>/<package-name>:<target>

Examples:
//packages/linux/core/bash:bash
//packages/linux/system/init/systemd:systemd
//packages/linux/network/dns/coredns:coredns
//packages/linux/dev-tools/compilers/gcc:gcc
```

### Required Package Attributes

Package managers MUST extract these attributes:

| Attribute | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | Yes | Package name |
| `version` | string | Yes | Package version |
| `url` | string | Yes | Source download URL |
| `sha256` | string | Yes | Source checksum |
| `iuse` | list | No | Available USE flags |
| `use_defaults` | list | No | Default enabled flags |
| `deps` | list | No | Runtime dependencies |
| `build_deps` | list | No | Build-time dependencies |
| `maintainers` | list | No | Package maintainers |

---

## Metadata Structures

### PackageInfo Provider

Package managers MUST parse the PackageInfo provider structure:

```python
PackageInfo = provider(fields = [
    "name",           # string: Package name
    "version",        # string: Package version
    "slot",           # string: Version slot (e.g., "3", "1.1")
    "description",    # string: Package description
    "homepage",       # string: Project homepage
    "license",        # string: License identifier
    "url",            # string: Source URL
    "sha256",         # string: SHA256 checksum
    "deps",           # list: Runtime dependencies
    "build_deps",     # list: Build dependencies
    "iuse",           # list: Available USE flags
    "use_enabled",    # list: Currently enabled flags
    "maintainers",    # list: Maintainer identifiers
    "installed_files",# list: Files installed by package
])
```

### Registry Entry Format

The central registry (`defs/registry.bzl`) uses this structure:

```python
PACKAGE_REGISTRY = {
    "category/package-name": {
        "default": "version-string",
        "description": "Package description",
        "homepage": "https://...",
        "license": "MIT",
        "versions": {
            "version-string": {
                "slot": "slot-id",
                "status": "stable|testing|deprecated|masked",
                "keywords": ["~amd64", "amd64"],
                "eapi": "8",
            },
        },
        "maintainers": ["team-id"],
    },
}
```

### Version Status Definitions

| Status | Description | Package Manager Behavior |
|--------|-------------|-------------------------|
| `stable` | Production ready | Install by default |
| `testing` | Under evaluation | Require explicit opt-in |
| `deprecated` | Scheduled for removal | Warn user, suggest alternative |
| `masked` | Blocked from installation | Require explicit unmask |

### Maintainer Registry Format

```python
MAINTAINERS = {
    "team-id": {
        "name": "Display Name",
        "email": "team@example.com",
        "github": "github-username",
        "description": "Team description",
        "packages": ["category/pkg1", "category/pkg2"],
    },
}
```

---

## Query Interfaces

### Buck2 Query Commands

Package managers MUST use these Buck2 query patterns:

#### List All Packages

```bash
buck2 query "//packages/linux/..." --output-attribute name --output-attribute version
```

#### Get Package Dependencies

```bash
buck2 query "deps(//packages/linux/core/bash:bash)"
```

#### Get Reverse Dependencies

```bash
buck2 query "rdeps(//packages/linux/..., //packages/linux/core/openssl:openssl)"
```

#### Filter by Attribute

```bash
buck2 query "attrfilter(maintainers, core-team, //packages/linux/...)"
```

#### Get Package Attributes

```bash
buck2 query "//packages/linux/core/bash:bash" --output-attribute name --output-attribute version --output-attribute iuse
```

### Registry Query Functions

Package managers SHOULD use these Starlark functions:

```python
# Get default version for a package
get_default_version("core/openssl")  # Returns "3.2.0"

# Get all versions
get_all_versions("core/openssl")  # Returns ["3.2.0", "1.1.1w", "1.0.2u"]

# Get versions in a specific slot
get_versions_in_slot("core/openssl", "3")  # Returns ["3.2.0"]

# Get stable versions only
get_stable_versions("core/openssl")  # Returns ["3.2.0", "1.1.1w"]

# Get version status
get_version_status("core/openssl", "1.0.2u")  # Returns "masked"

# List all packages
list_all_packages()  # Returns ["core/openssl", "core/bash", ...]

# List packages by category
list_packages_by_category("core")  # Returns ["openssl", "bash", ...]
```

### USE Flag Queries

```python
# Get all available USE flags
get_available_use_flags()

# Get flags by category
get_use_flags_by_category("security")  # Returns ["caps", "hardened", "pie", ...]

# Get package-specific flags
get_package_use_flags("core/bash")  # Returns ["readline", "nls", "plugins", "net"]
```

---

## Configuration Generation

### System Configuration Structure

Package managers MUST generate configuration using this function:

```python
generate_system_config(
    profile = "default",           # System profile
    detected_hardware = [],        # Hardware detection results
    detected_features = [],        # Feature detection results
    user_use_flags = [],          # User-specified USE flags
    package_overrides = {},       # Per-package overrides
    env_preset = None,            # Environment preset
    target_arch = "x86_64",       # Target architecture
)
```

### Configuration Output Structure

```python
{
    "profile": "server",
    "arch": "x86_64",
    "use_flags": {
        "global": ["ssl", "ipv6", "threads"],
        "package": {
            "curl": ["gnutls", "-ssl"],
            "nginx": ["http2", "ssl", "pcre2"],
        },
    },
    "env": {
        "CFLAGS": "-O2 -pipe -march=x86-64",
        "CXXFLAGS": "-O2 -pipe -march=x86-64",
        "LDFLAGS": "-Wl,-O1 -Wl,--as-needed",
        "MAKEOPTS": "-j8",
    },
    "package_env": {
        "ffmpeg": {"CFLAGS": "-O3 -march=native"},
    },
    "accept_keywords": ["~amd64"],
    "package_mask": ["//packages/linux/dev-libs/openssl:1.0"],
    "package_unmask": [],
}
```

### Hardware Detection Interface

Package managers SHOULD implement hardware detection for:

```python
HARDWARE_FLAGS = {
    # CPU Features
    "cpu_flags_x86_aes": detect_cpu_flag("aes"),
    "cpu_flags_x86_avx": detect_cpu_flag("avx"),
    "cpu_flags_x86_avx2": detect_cpu_flag("avx2"),
    "cpu_flags_x86_avx512": detect_cpu_flag("avx512f"),
    "cpu_flags_x86_sse4_2": detect_cpu_flag("sse4_2"),

    # GPU
    "nvidia": detect_gpu_vendor("nvidia"),
    "amdgpu": detect_gpu_vendor("amd"),
    "intel": detect_gpu_vendor("intel"),

    # Audio
    "audio": detect_audio_device(),
    "bluetooth-audio": detect_bluetooth_audio(),

    # Network
    "wifi": detect_wifi_device(),
    "bluetooth": detect_bluetooth_device(),

    # Storage
    "nvme": detect_nvme_device(),
    "ssd": detect_ssd_device(),

    # Virtualization
    "kvm": detect_kvm_support(),
    "container": detect_container_environment(),
}
```

### Profile Definitions

Package managers MUST understand these profiles:

| Profile | Base | Description | Default USE Flags |
|---------|------|-------------|-------------------|
| `minimal` | - | Absolute minimum | `ipv6` |
| `server` | `minimal` | Server systems | `ssl`, `ipv6`, `threads`, `caps` |
| `desktop` | `server` | Desktop systems | `X`, `dbus`, `pulseaudio`, `gtk` |
| `developer` | `desktop` | Development | `debug`, `doc`, `test` |
| `hardened` | `server` | Security-focused | `hardened`, `pie`, `ssp`, `caps` |
| `embedded` | `minimal` | Embedded systems | `static`, `-ipv6` |
| `container` | `minimal` | Containers | `static`, `-pam`, `-systemd` |

---

## Build Integration

### Build Command Interface

Package managers MUST invoke builds using:

```bash
# Build a single package
buck2 build //packages/linux/core/bash:bash

# Build with specific configuration
buck2 build //packages/linux/core/bash:bash \
    --config=build.use_flags="readline,nls" \
    --config=build.profile="server"

# Build with output path
buck2 build //packages/linux/core/bash:bash --out /path/to/output

# Build multiple packages
buck2 build //packages/linux/core/bash:bash //packages/linux/core/zlib:zlib
```

### Build Configuration Parameters

```python
[build]
# USE flags as comma-separated list
use_flags = "ssl,ipv6,threads"

# Active profile
profile = "server"

# Environment preset
env_preset = "optimize-speed"

# Target architecture
target_arch = "x86_64"

# Parallelism
jobs = 8
```

### Build Output Structure

```
output/
├── usr/
│   ├── bin/
│   ├── lib/
│   ├── include/
│   └── share/
├── etc/
├── var/
└── metadata/
    ├── CONTENTS      # Installed files list
    ├── DEPEND        # Dependencies
    ├── USE           # Enabled USE flags
    └── SLOT          # Package slot
```

### Build Phases

Package managers SHOULD track these build phases:

1. **fetch**: Download source archives
2. **unpack**: Extract source archives
3. **prepare**: Apply patches
4. **configure**: Run configuration
5. **compile**: Build from source
6. **test**: Run test suite (optional)
7. **install**: Install to staging area
8. **package**: Create final package

### Build Result Interface

```python
BuildResult = {
    "success": True,
    "package": "//packages/linux/core/bash:bash",
    "version": "5.2.21",
    "build_time": 120.5,  # seconds
    "output_path": "/path/to/output",
    "installed_files": [...],
    "size": 1048576,  # bytes
    "use_flags": ["readline", "nls"],
    "dependencies_built": [...],
}
```

---

## Dependency Resolution

### Dependency Types

| Type | Attribute | Phase | Description |
|------|-----------|-------|-------------|
| Runtime | `deps` | Install | Required at runtime |
| Build | `build_deps` | Compile | Required for building |
| Post | `post_deps` | Post-install | Required after installation |
| Optional | `use_deps` | Conditional | Controlled by USE flags |

### Dependency Specification Formats

```python
# Simple dependency
"//packages/linux/core/zlib:zlib"

# Version-constrained dependency
"//packages/linux/core/openssl:>=3.0.0"

# Slot dependency
"//packages/linux/core/openssl:3"

# USE-conditional dependency
{"ssl": ["//packages/linux/core/openssl:openssl"]}

# Any-of dependency
["//packages/linux/core/openssl:openssl", "//packages/linux/core/libressl:libressl"]
```

### Version Constraint Syntax

| Operator | Example | Matches |
|----------|---------|---------|
| (none) | `pkg` | Latest stable |
| `=` | `=pkg-1.0` | Exactly 1.0 |
| `>=` | `>=pkg-1.0` | 1.0 or higher |
| `>` | `>pkg-1.0` | Higher than 1.0 |
| `<=` | `<=pkg-2.0` | 2.0 or lower |
| `<` | `<pkg-2.0` | Lower than 2.0 |
| `~>` | `~>pkg-1.5` | 1.5.x (pessimistic) |
| `*` | `pkg-1.*` | Any 1.x version |

### Resolution Algorithm

Package managers MUST implement this resolution order:

1. **Explicit version**: User-specified version constraint
2. **Slot constraint**: Match specific slot
3. **Default version**: From registry default
4. **Stable version**: Highest stable version
5. **Testing version**: If user accepts ~arch

### Circular Dependency Handling

```python
# Detect cycles
def detect_cycles(package, visited=None, stack=None):
    if visited is None:
        visited = set()
        stack = set()

    visited.add(package)
    stack.add(package)

    for dep in get_dependencies(package):
        if dep not in visited:
            if detect_cycles(dep, visited, stack):
                return True
        elif dep in stack:
            return True

    stack.remove(package)
    return False
```

### Dependency Graph Output

Package managers SHOULD provide dependency visualization:

```
bash-5.2.21
├── ncurses-6.4
│   └── (no dependencies)
├── readline-8.2
│   └── ncurses-6.4 (already shown)
└── glibc-2.38
    ├── linux-headers-6.6
    └── (no dependencies)
```

---

## Version Management

### Slot System

Slots allow parallel installation of different major versions:

```python
# Slot naming conventions
"0"     # No slot (single version only)
"3"     # Major version slot
"3.2"   # Major.minor slot
"stable"# Named slot
```

### Subslot System

Subslots track ABI compatibility within a slot:

```python
# Slot/Subslot format: "SLOT/SUBSLOT"
"3/3.2"   # Slot 3, subslot 3.2 (for openssl 3.2.x)
"3/3.1"   # Slot 3, subslot 3.1 (for openssl 3.1.x)

# Subslot-aware dependencies
from defs.versions import subslot_dep

deps = [
    # Rebuild when ABI changes
    subslot_dep("//packages/linux/dev-libs/openssl", "3", "="),

    # Don't rebuild on ABI changes (build-time only)
    subslot_dep("//packages/linux/dev-util/cmake", "3", "*"),
]
```

Package managers MUST track subslot changes and trigger rebuilds of dependent packages when:
- The subslot value changes between versions in the same slot
- The library soname changes
- ABI-breaking changes are detected

#### Subslot Query Functions

```python
# Parse slot/subslot string
parse_slot_subslot("3/3.2")  # Returns: ("3", "3.2")

# Format slot and subslot
format_slot_subslot("3", "3.2")  # Returns: "3/3.2"

# Check ABI compatibility
check_abi_compatibility(old_version_info, new_version_info)
# Returns: {"compatible": bool, "reason": str, "rebuild_required": [...]}
```

### Version Lifecycle

```
testing → stable → deprecated → masked → removed
   │         │          │          │
   │         │          │          └── Package removed from tree
   │         │          └── Warn users, suggest migration
   │         └── Production ready, default choice
   └── Under evaluation, requires ~arch
```

### Version Selection Logic

```python
def select_version(package, constraint=None, accept_keywords=[]):
    versions = get_all_versions(package)

    # Apply constraint filter
    if constraint:
        versions = filter_by_constraint(versions, constraint)

    # Sort by preference
    versions.sort(key=lambda v: (
        get_version_status(package, v) == "stable",  # Prefer stable
        parse_version(v),  # Higher version
    ), reverse=True)

    # Apply keyword filtering
    for version in versions:
        status = get_version_status(package, version)
        if status == "stable":
            return version
        if status == "testing" and "~amd64" in accept_keywords:
            return version
        if status == "masked":
            continue  # Skip unless explicitly unmasked

    return None
```

### Upgrade Path Detection

```python
def get_upgrade_path(package, current_version, target_version):
    """
    Returns list of intermediate versions for safe upgrade
    """
    all_versions = get_all_versions(package)
    current_idx = all_versions.index(current_version)
    target_idx = all_versions.index(target_version)

    # Check for breaking changes between versions
    path = []
    for i in range(current_idx, target_idx + 1):
        version = all_versions[i]
        if has_breaking_changes(package, version):
            path.append(version)

    return path if path else [target_version]
```

---

## USE Flag System

### Global USE Flags

Package managers MUST support these global flag categories:

#### Build & Compilation
- `debug` - Build with debug symbols
- `doc` - Build and install documentation
- `examples` - Install examples
- `static` - Build static binaries
- `static-libs` - Build static libraries
- `test` - Build and run tests
- `lto` - Link Time Optimization
- `pgo` - Profile Guided Optimization
- `native` - Optimize for current CPU

#### Security
- `caps` - Linux capabilities support
- `hardened` - Hardened build flags
- `pie` - Position Independent Executable
- `seccomp` - Seccomp filtering
- `selinux` - SELinux support
- `ssp` - Stack Smashing Protection

#### Networking
- `ipv6` - IPv6 support
- `ssl` - OpenSSL support
- `gnutls` - GnuTLS support
- `libressl` - LibreSSL support
- `http2` - HTTP/2 support
- `curl` - libcurl support

#### Compression
- `brotli` - Brotli compression
- `bzip2` - Bzip2 compression
- `lz4` - LZ4 compression
- `lzma` - LZMA compression
- `zlib` - Zlib compression
- `zstd` - Zstandard compression

#### Graphics & Display
- `X` - X11 support
- `wayland` - Wayland support
- `opengl` - OpenGL support
- `vulkan` - Vulkan support
- `egl` - EGL support
- `gtk` - GTK+ support
- `qt5` - Qt5 support
- `qt6` - Qt6 support

#### Audio/Video
- `alsa` - ALSA audio support
- `pulseaudio` - PulseAudio support
- `pipewire` - PipeWire support
- `ffmpeg` - FFmpeg support

#### Language Bindings
- `python` - Python bindings
- `perl` - Perl bindings
- `ruby` - Ruby bindings
- `lua` - Lua bindings

#### System Integration
- `dbus` - D-Bus support
- `systemd` - systemd support
- `pam` - PAM support
- `acl` - ACL support
- `udev` - udev support

### USE Flag Resolution Order

1. **Profile defaults**: Base flags from profile
2. **Global user flags**: User's global USE settings
3. **Package defaults**: Package's `use_defaults`
4. **Package user flags**: User's per-package settings

```python
def resolve_use_flags(package):
    flags = set()

    # 1. Profile defaults
    flags.update(get_profile_use_flags())

    # 2. Global user flags
    for flag in get_user_global_flags():
        if flag.startswith("-"):
            flags.discard(flag[1:])
        else:
            flags.add(flag)

    # 3. Package defaults
    flags.update(get_package_defaults(package))

    # 4. Package user flags
    for flag in get_user_package_flags(package):
        if flag.startswith("-"):
            flags.discard(flag[1:])
        else:
            flags.add(flag)

    return flags
```

### USE Flag Validation

```python
def validate_use_flags(package, flags):
    """
    Validates USE flag configuration for a package

    Returns: {
        "valid": True/False,
        "errors": [...],
        "warnings": [...],
    }
    """
    result = {"valid": True, "errors": [], "warnings": []}

    available = get_package_use_flags(package)

    for flag in flags:
        clean_flag = flag.lstrip("-")

        # Check if flag exists
        if clean_flag not in available:
            result["errors"].append(f"Unknown USE flag: {clean_flag}")
            result["valid"] = False

        # Check for conflicts
        if has_conflict(package, flag):
            result["errors"].append(f"Conflicting USE flag: {flag}")
            result["valid"] = False

        # Check for required dependencies
        missing_deps = check_use_deps(package, flag)
        if missing_deps:
            result["warnings"].append(
                f"Flag {flag} requires: {', '.join(missing_deps)}"
            )

    return result
```

---

## Package Sets

### Set Types

| Type | Function | Purpose |
|------|----------|---------|
| System | `system_set()` | Base system profiles |
| Package | `package_set()` | Simple package collections |
| Combined | `combined_set()` | Union of multiple sets |
| Task | `task_set()` | Task-specific collections |
| Desktop | `desktop_set()` | Desktop environment sets |

### Predefined System Sets

```python
SYSTEM_SETS = {
    "minimal": {
        "description": "Minimal bootable system",
        "packages": ["core/bash", "core/busybox", "core/musl"],
    },
    "server": {
        "inherits": "minimal",
        "description": "Server base system",
        "packages": ["core/openssl", "network/openssh", "system/systemd"],
    },
    "desktop": {
        "inherits": "server",
        "description": "Desktop base system",
        "packages": ["graphics/mesa", "audio/pipewire", "desktop/xorg"],
    },
}
```

### Set Operations

```python
# Union of sets
union_sets("set1", "set2")

# Intersection of sets
intersection_sets("set1", "set2")

# Difference of sets
difference_sets("set1", "set2")

# Get packages in set
get_set_packages("server")

# Get set metadata
get_set_info("server")

# List all sets
list_all_sets()

# List sets by type
list_sets_by_type("task")

# Compare sets
compare_sets("set1", "set2")  # Returns added, removed, common
```

### Set Query Commands

```bash
# List packages in a set
buck2 query "//defs:package_sets.bzl#server"

# Get set inheritance chain
buck2 query "deps(//defs:package_sets.bzl#desktop)"

# Find sets containing a package
buck2 query "rdeps(//defs:package_sets.bzl#..., //packages/linux/core/bash:bash)"
```

---

## Eclass System

The eclass system provides reusable build patterns, similar to Gentoo's eclasses.

### Available Eclasses

Package managers MUST understand these built-in eclasses:

| Eclass | Purpose | Build Tools |
|--------|---------|-------------|
| `cmake` | CMake-based packages | cmake, ninja |
| `meson` | Meson-based packages | meson, ninja |
| `autotools` | Traditional configure/make | autoconf, automake, libtool |
| `python-single-r1` | Single Python implementation | setuptools |
| `python-r1` | Multiple Python versions | setuptools |
| `go-module` | Go module packages | go |
| `cargo` | Rust/Cargo packages | cargo |
| `xdg` | Desktop applications | update-desktop-database |
| `linux-mod` | Kernel modules | linux-headers |
| `systemd` | Systemd services | systemd |
| `qt5` | Qt5 applications | qt5 |

### Eclass Inheritance

```python
load("//defs:eclasses.bzl", "inherit", "ECLASSES", "get_eclass")

# Get merged configuration from multiple eclasses
config = inherit(["cmake", "xdg"])

# Use in package definition
package(
    build_rule = "ebuild",
    name = "my-app",
    source = ":my-app-src",
    version = "1.0.0",
    src_configure = config["src_configure"],
    src_compile = config["src_compile"],
    src_install = config["src_install"],
    bdepend = config["bdepend"],
    rdepend = config["rdepend"],
)
```

### Eclass Query Functions

```python
# List all available eclasses
list_eclasses()  # Returns: ["cmake", "meson", "autotools", ...]

# Get eclass definition
get_eclass("cmake")
# Returns: {
#   "name": "cmake",
#   "description": "Support for cmake-based packages",
#   "src_configure": "...",
#   "src_compile": "...",
#   "bdepend": [...],
#   "exports": [...],
# }

# Check if eclass provides a phase
eclass_has_phase("cmake", "src_configure")  # Returns: True
```

---

## License System

The license system provides license tracking, validation, and compliance checking.

### License Definitions

Package managers MUST understand the license metadata structure:

```python
LICENSES = {
    "GPL-2": {
        "name": "GNU General Public License v2",
        "url": "https://www.gnu.org/licenses/old-licenses/gpl-2.0.html",
        "free": True,
        "osi": True,
    },
    "MIT": {
        "name": "MIT License",
        "url": "https://opensource.org/licenses/MIT",
        "free": True,
        "osi": True,
    },
    # ... 60+ licenses defined
}
```

### License Groups

Package managers MUST support license group expansion:

| Group | Description | Examples |
|-------|-------------|----------|
| `@FREE` | All free software licenses | GPL-2, MIT, BSD, Apache-2.0 |
| `@OSI-APPROVED` | OSI-approved licenses | GPL-2, MIT, Apache-2.0 |
| `@GPL-COMPATIBLE` | GPL-compatible licenses | MIT, BSD, LGPL-2.1 |
| `@COPYLEFT` | Copyleft licenses | GPL-2, GPL-3, AGPL-3 |
| `@PERMISSIVE` | Permissive licenses | MIT, BSD, Apache-2.0 |
| `@BINARY-REDISTRIBUTABLE` | Binary redistribution allowed | Most free licenses |

### License Validation

```python
from defs.licenses import check_license, check_license_expression

# Simple check
if not check_license("GPL-2", ["@FREE"]):
    fail("License not accepted")

# Expression check (dual licensing)
if not check_license_expression("GPL-2 || MIT", ["@PERMISSIVE"]):
    fail("No acceptable license option")
```

### ACCEPT_LICENSE Configuration

Package managers MUST support ACCEPT_LICENSE configuration:

```python
# Default configurations
DEFAULT_ACCEPT_LICENSE = ["@FREE"]
SERVER_ACCEPT_LICENSE = ["@FREE", "@FIRMWARE"]
DESKTOP_ACCEPT_LICENSE = ["@FREE", "@FIRMWARE", "@BINARY-REDISTRIBUTABLE"]
DEVELOPER_ACCEPT_LICENSE = ["*", "-unknown"]
```

### License Query Functions

```python
# Expand license group
expand_license_group("@FREE")  # Returns: ["GPL-2", "MIT", ...]

# Get license info
get_license_info("GPL-2")
# Returns: {"name": "...", "url": "...", "free": True, "osi": True}

# Check if license is free
is_free_license("GPL-2")  # Returns: True

# Check if OSI approved
is_osi_approved("GPL-2")  # Returns: True

# Parse license expression
parse_license_expression("GPL-2 || MIT")
# Returns: {"type": "or", "licenses": ["GPL-2", "MIT"]}

# Generate license report
generate_license_report(packages)
# Returns: {"by_license": {...}, "free_count": N, "non_free_count": N}
```

---

## EAPI System

EAPI (Ebuild API) versioning allows safe evolution of the build macro API.

### Supported EAPI Versions

| EAPI | Status | Key Features |
|------|--------|--------------|
| 6 | Supported | Base functionality, eapply, user patches |
| 7 | Supported | BDEPEND, version functions, sysroot |
| 8 | Current | Subslots, selective fetch, strict USE |

### EAPI Feature Flags

Package managers MUST check EAPI features before using them:

```python
from defs.eapi import eapi_has_feature, require_eapi, CURRENT_EAPI

# Require minimum EAPI
require_eapi(8)

# Check for feature availability
if eapi_has_feature("subslots"):
    deps = [subslot_dep("//pkg/openssl", "3", "=")]

if eapi_has_feature("bdepend"):
    # Use BDEPEND for build-time dependencies
    pass
```

### EAPI Validation

```python
# Validate EAPI is supported
validate_eapi(8)  # Returns: True

# Get features for an EAPI
get_eapi_features(8)
# Returns: {"subslots": True, "bdepend": True, ...}

# Check if function is deprecated
is_deprecated("dohtml", 8)  # Returns: True

# Check if function is banned
is_banned("dohtml", 8)  # Returns: True
```

### EAPI Migration

Package managers SHOULD provide migration guidance:

```python
# Get migration steps between EAPI versions
migration_guide(6, 8)
# Returns: [
#   "Convert DEPEND to BDEPEND for build-time only dependencies",
#   "Replace dohtml with dodoc for HTML documentation",
#   "Add subslots for packages with ABI-sensitive libraries",
# ]

# Check compatibility
check_eapi_compatibility(package_eapi=6, system_eapi=8)
# Returns: {"compatible": True, "warnings": [...], "errors": [...]}
```

### Default Phase Implementations

Each EAPI defines default phase implementations:

```python
# Get default phase for EAPI
get_default_phase("src_prepare", eapi=8)
# Returns shell script for default prepare phase

get_default_phase("src_compile", eapi=8)
# Returns shell script for default compile phase
```

---

## Patch System

### Overview

The patch system allows users and distributions to customize package builds through multiple patch sources with clear precedence ordering.

### Patch Source Precedence

Patches are applied in this order (later patches override earlier ones):

1. **Package Patches** - Bundled with package definition
2. **Distribution Patches** - Applied by overlay/distribution
3. **Profile Patches** - Applied based on build profile
4. **USE Flag Patches** - Conditional on USE flag settings
5. **User Patches** - Applied from user configuration

### Patch Directory Structure

```
buckos-build/
├── patches/
│   ├── global/                    # Global patches
│   │   └── security/              # Security patches
│   ├── profiles/
│   │   ├── hardened/              # Hardened profile patches
│   │   └── musl/                  # musl compatibility patches
│   └── packages/
│       └── <category>/
│           └── <package>/
│               ├── *.patch        # Package-specific patches
│               └── series         # Patch application order
└── user/
    └── patches/                   # User-specific patches
        └── <category>/
            └── <package>/
```

### Patch Configuration in Buck Targets

#### Basic Patch Application

```python
package(
    build_rule = "autotools",
    name = "mypackage",
    source = ":mypackage-src",
    version = "1.0",
    pre_configure = """
        patch -p1 < "$FILESDIR/fix-build.patch"
        patch -p1 < "$FILESDIR/security-fix.patch"
    """,
)
```

#### USE-Conditional Patches

```python
use_package(
    name = "openssl",
    version = "3.2.0",
    url = "...",
    sha256 = "...",
    iuse = ["bindist", "ktls"],
    use_patches = {
        "bindist": ["//patches/packages/dev-libs/openssl:ec-curves-bindist.patch"],
        "ktls": ["//patches/packages/dev-libs/openssl:ktls-support.patch"],
    },
)
```

#### Package Customization Patches

```python
load("//defs:package_customize.bzl", "package_config")

CUSTOMIZATIONS = package_config(
    profile = "hardened",
    package_patches = {
        "glibc": [
            "//patches/packages/sys-libs/glibc:hardened-all.patch",
        ],
        "openssh": [
            "//patches/packages/net-misc/openssh:hpn-performance.patch",
        ],
    },
)
```

### Patch Management Functions

```python
# Apply patches in order
epatch(["fix.patch", "optimize.patch"])

# Apply directory of patches
eapply(["${FILESDIR}/patches"])

# Apply user patches automatically
eapply_user()
```

### Series File Format

Control patch application order with a `series` file:

```
# patches/packages/dev-libs/openssl/series
# Applied in order listed

# Core fixes
fix-build.patch
fix-tests.patch

# Security (apply last)
cve-2024-xxxx.patch
```

### Package Manager Patch Operations

Package managers SHOULD implement these patch-related commands:

```bash
# List patches for a package
pkgmgr patch list <package>

# Show patch information
pkgmgr patch info <package> <patch-name>

# Add user patch
pkgmgr patch add <package> <patch-file>

# Remove user patch
pkgmgr patch remove <package> <patch-name>

# Validate patches apply cleanly
pkgmgr patch check <package>

# Show patch application order
pkgmgr patch order <package>
```

### Patch Metadata Structure

```python
PatchInfo = {
    "name": "cve-2024-xxxx.patch",
    "package": "//packages/linux/dev-libs/openssl:openssl",
    "description": "Fix for CVE-2024-XXXX",
    "source": "user|package|profile|distribution",
    "strip_level": 1,
    "conditional": {
        "use_flag": "bindist",  # Optional: only if USE flag enabled
        "profile": "hardened",   # Optional: only for profile
        "platform": "linux",     # Optional: platform-specific
    },
}
```

### Patch Validation

Package managers MUST validate patches before application:

```python
def validate_patch(package, patch_file):
    """
    Validate that a patch applies cleanly

    Returns: {
        "valid": True/False,
        "fuzz_factor": 0,        # Lines of context fuzz needed
        "offset": 0,             # Offset from original location
        "warnings": [...],
        "errors": [...],
    }
    """
    pass
```

### Patch Query Functions

```python
# Get all patches for a package
get_package_patches(package) -> list[PatchInfo]

# Get patches by source
get_patches_by_source(package, source) -> list[PatchInfo]

# Get conditional patches
get_conditional_patches(package, use_flags, profile) -> list[PatchInfo]

# Check if patch is applied
is_patch_applied(package, patch_name) -> bool

# Get patch application order
get_patch_order(package) -> list[str]
```

### Integration with Build Phases

Patches are applied during the `prepare` build phase:

1. **fetch**: Download source archives
2. **unpack**: Extract source archives
3. **prepare**: Apply patches (in precedence order)
4. **configure**: Run configuration
5. **compile**: Build from source

### User Patch Directory

User patches are automatically applied from:

```
/etc/portage/patches/<category>/<package>/*.patch
```

Or configured via:

```toml
# /etc/buckos-pkgmgr.toml
[patches.user]
base_dir = "/etc/portage/patches"

[patches.package.openssl]
files = [
    "/path/to/custom.patch",
]
```

For complete patch system documentation, see [PATCHES.md](PATCHES.md).

---

## CLI Requirements

### Required Commands

Package managers MUST implement these commands:

#### Package Operations

```bash
# Search for packages
pkgmgr search <pattern>

# Show package information
pkgmgr info <package>

# Install package
pkgmgr install <package>

# Uninstall package
pkgmgr uninstall <package>

# Update package
pkgmgr update <package>

# List installed packages
pkgmgr list [--installed|--available]
```

#### Dependency Operations

```bash
# Show dependencies
pkgmgr deps <package>

# Show reverse dependencies
pkgmgr rdeps <package>

# Check for dependency issues
pkgmgr depcheck

# Generate dependency graph
pkgmgr depgraph <package> [--format=dot|json|text]
```

#### USE Flag Operations

```bash
# List available USE flags
pkgmgr use --list [category]

# Show package USE flags
pkgmgr use <package>

# Set global USE flags
pkgmgr use --global <+flag|-flag>...

# Set package USE flags
pkgmgr use --package <package> <+flag|-flag>...

# Show USE flag description
pkgmgr use --describe <flag>
```

#### Configuration Operations

```bash
# Show current configuration
pkgmgr config show

# Set profile
pkgmgr config profile <profile-name>

# Detect hardware
pkgmgr config detect-hardware

# Export configuration
pkgmgr config export [--format=json|toml|shell|buck]

# Validate configuration
pkgmgr config validate
```

#### Set Operations

```bash
# List available sets
pkgmgr set list [--type=system|task|desktop]

# Show set contents
pkgmgr set show <set-name>

# Install set
pkgmgr set install <set-name>

# Compare sets
pkgmgr set compare <set1> <set2>
```

#### System Operations

```bash
# Full system update
pkgmgr upgrade

# Verify installed packages
pkgmgr verify

# Clean build cache
pkgmgr clean [--all|--cache|--dist]

# Synchronize repository
pkgmgr sync
```

### Command Output Formats

Package managers MUST support these output formats:

```bash
# Human-readable (default)
pkgmgr info bash

# JSON output
pkgmgr info bash --format=json

# Quiet/script-friendly
pkgmgr list --quiet

# Verbose/debug
pkgmgr install bash --verbose
```

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| 2 | Invalid arguments |
| 3 | Package not found |
| 4 | Dependency resolution failed |
| 5 | Build failed |
| 6 | Permission denied |
| 7 | Network error |
| 8 | Checksum mismatch |
| 9 | Configuration error |

---

## Export Formats

### JSON Export

```python
export_config_json()
```

Output:
```json
{
  "profile": "server",
  "arch": "x86_64",
  "use_flags": {
    "global": ["ssl", "ipv6", "threads"],
    "package": {
      "curl": ["gnutls", "-ssl"]
    }
  },
  "env": {
    "CFLAGS": "-O2 -pipe",
    "MAKEOPTS": "-j8"
  },
  "packages": {
    "installed": [
      {
        "name": "bash",
        "version": "5.2.21",
        "slot": "0",
        "use": ["readline", "nls"]
      }
    ]
  }
}
```

### TOML Export

```python
export_config_toml()
```

Output:
```toml
[profile]
name = "server"
arch = "x86_64"

[use_flags]
global = ["ssl", "ipv6", "threads"]

[use_flags.package]
curl = ["gnutls", "-ssl"]

[env]
CFLAGS = "-O2 -pipe"
MAKEOPTS = "-j8"

[[packages.installed]]
name = "bash"
version = "5.2.21"
slot = "0"
use = ["readline", "nls"]
```

### Shell Export

```python
export_config_shell()
```

Output:
```bash
#!/bin/bash
# BuckOS Configuration

export PROFILE="server"
export ARCH="x86_64"

# USE flags
export USE="ssl ipv6 threads"

# Per-package USE
export CURL_USE="gnutls -ssl"

# Environment
export CFLAGS="-O2 -pipe"
export MAKEOPTS="-j8"
```

### Buck2 Export

```python
export_buck_config()
```

Output:
```python
# Generated BuckOS configuration

PROFILE = "server"
ARCH = "x86_64"

USE_FLAGS = [
    "ssl",
    "ipv6",
    "threads",
]

PACKAGE_USE = {
    "curl": ["gnutls", "-ssl"],
}

ENV = {
    "CFLAGS": "-O2 -pipe",
    "MAKEOPTS": "-j8",
}
```

---

## Error Handling

### Error Categories

```python
class PackageManagerError(Exception):
    """Base exception for package manager errors"""
    pass

class PackageNotFoundError(PackageManagerError):
    """Package does not exist in repository"""
    pass

class DependencyResolutionError(PackageManagerError):
    """Cannot resolve dependencies"""
    pass

class BuildError(PackageManagerError):
    """Build process failed"""
    pass

class ChecksumError(PackageManagerError):
    """Source checksum verification failed"""
    pass

class SlotConflictError(PackageManagerError):
    """Package slot conflict detected"""
    pass

class UseFlagError(PackageManagerError):
    """Invalid USE flag configuration"""
    pass

class ConfigurationError(PackageManagerError):
    """Invalid configuration"""
    pass
```

### Error Reporting Format

```python
{
    "error": "DependencyResolutionError",
    "message": "Cannot resolve dependencies for bash-5.2.21",
    "details": {
        "package": "//packages/linux/core/bash:bash",
        "version": "5.2.21",
        "missing_deps": [
            "//packages/linux/core/readline:readline"
        ],
        "conflicts": [],
    },
    "suggestions": [
        "Install readline: pkgmgr install readline",
        "Check USE flags: pkgmgr use bash",
    ],
}
```

### Recovery Strategies

| Error Type | Recovery Strategy |
|------------|-------------------|
| Network failure | Retry with exponential backoff |
| Checksum mismatch | Re-download from mirror |
| Build failure | Retry with reduced parallelism |
| Dependency conflict | Suggest version alternatives |
| Slot conflict | Suggest slot cleanup |

---

## Extension Points

### Plugin System

Package managers SHOULD support plugins for:

```python
class PackageManagerPlugin:
    """Base class for package manager plugins"""

    def on_pre_install(self, package, version):
        """Called before package installation"""
        pass

    def on_post_install(self, package, version, files):
        """Called after package installation"""
        pass

    def on_pre_uninstall(self, package, version):
        """Called before package removal"""
        pass

    def on_post_uninstall(self, package, version):
        """Called after package removal"""
        pass

    def on_build_start(self, package, version):
        """Called when build starts"""
        pass

    def on_build_complete(self, package, version, result):
        """Called when build completes"""
        pass
```

### Custom Build Rules

Package managers SHOULD allow custom rule registration:

```python
def register_custom_rule(name, rule_func, **kwargs):
    """
    Register a custom build rule

    Args:
        name: Rule name
        rule_func: Rule implementation function
        **kwargs: Rule attributes
    """
    pass
```

### Hook Points

| Hook | Timing | Use Case |
|------|--------|----------|
| `pre_fetch` | Before download | Mirror selection |
| `post_fetch` | After download | Signature verification |
| `pre_build` | Before compile | Environment setup |
| `post_build` | After compile | Binary stripping |
| `pre_install` | Before install | Backup creation |
| `post_install` | After install | Configuration generation |
| `pre_uninstall` | Before removal | Service shutdown |
| `post_uninstall` | After removal | Cleanup |

### Custom Configuration Providers

```python
class ConfigurationProvider:
    """Base class for configuration providers"""

    def get_use_flags(self):
        """Return list of USE flags"""
        pass

    def get_package_mask(self):
        """Return list of masked packages"""
        pass

    def get_environment(self):
        """Return environment variables"""
        pass
```

---

## Security Considerations

### Source Verification

Package managers MUST verify:

1. **Checksum verification**: SHA256 hash of downloaded sources
2. **Signature verification**: GPG signatures when available
3. **Mirror integrity**: HTTPS for all downloads

```python
def verify_source(src_uri, sha256, signature=None):
    """
    Verify downloaded source integrity

    Args:
        src_uri: Source URI
        sha256: Expected SHA256 hash
        signature: Optional GPG signature

    Returns:
        True if verification passes

    Raises:
        ChecksumError: If checksum fails
        SignatureError: If signature fails
    """
    pass
```

### Sandbox Execution

Build processes SHOULD run in sandboxed environments:

```python
SANDBOX_CONFIG = {
    "network": False,        # No network access during build
    "filesystem": {
        "read": ["/usr", "/lib", "/etc"],
        "write": ["$BUILD_DIR", "$DESTDIR"],
    },
    "environment": {
        "clear": True,       # Clear environment
        "allow": ["PATH", "HOME", "TERM"],
    },
}
```

### Privilege Management

- Build operations MUST NOT require root
- Installation MAY require elevated privileges
- Package manager SHOULD use capabilities when possible

### Audit Logging

```python
AUDIT_EVENTS = [
    "package_install",
    "package_uninstall",
    "package_update",
    "config_change",
    "privilege_escalation",
]

def log_audit_event(event, **kwargs):
    """
    Log security-relevant events

    Args:
        event: Event type
        **kwargs: Event details
    """
    pass
```

---

## Best Practices

### Performance

1. **Parallel builds**: Build independent packages concurrently
2. **Cache aggressively**: Cache downloads, build artifacts, metadata
3. **Incremental updates**: Only rebuild changed packages
4. **Lazy loading**: Load metadata on demand

### User Experience

1. **Progress reporting**: Show clear progress indicators
2. **Error messages**: Provide actionable error messages
3. **Confirmation prompts**: Confirm destructive operations
4. **Dry-run support**: Allow previewing operations

### Compatibility

1. **Version compatibility**: Support multiple Buck2 versions
2. **Platform support**: Handle platform-specific differences
3. **Migration paths**: Provide tools for configuration migration

### Maintenance

1. **Logging**: Comprehensive logging for debugging
2. **Metrics**: Track build times, success rates
3. **Testing**: Automated testing of package manager
4. **Documentation**: Keep documentation in sync

---

## Appendix A: Complete Example

### Package Manager Configuration File

```toml
# /etc/buckos-pkgmgr.toml

[general]
repository = "//packages/linux"
cache_dir = "/var/cache/buckos"
log_level = "info"

[profile]
name = "server"
arch = "x86_64"

[use_flags]
global = [
    "ssl",
    "ipv6",
    "threads",
    "caps",
    "-X",
    "-wayland",
]

[use_flags.package.nginx]
flags = ["http2", "ssl", "pcre2", "geoip"]

[use_flags.package.curl]
flags = ["gnutls", "-ssl", "http2"]

[environment]
CFLAGS = "-O2 -pipe -march=x86-64"
CXXFLAGS = "${CFLAGS}"
LDFLAGS = "-Wl,-O1 -Wl,--as-needed"
MAKEOPTS = "-j8"

[environment.package.ffmpeg]
CFLAGS = "-O3 -march=native"

[keywords]
accept = ["~amd64"]

[mask]
packages = [
    "//packages/linux/dev-libs/openssl:1.0",
]

[unmask]
packages = []
```

### Sample Package Query Session

```bash
$ pkgmgr search nginx
packages/linux/www/servers/nginx:nginx (1.24.0)
    High performance HTTP server
    USE: geoip http2 http3 lua pcre2 ssl stream threads

$ pkgmgr info nginx
Name:        nginx
Version:     1.24.0
Slot:        0
Homepage:    https://nginx.org
License:     BSD-2-Clause
Maintainer:  web-team <web@buckos.org>

Description:
    High performance HTTP and reverse proxy server

USE flags:
    + http2      HTTP/2 support
    + ssl        SSL/TLS support
    + pcre2      PCRE2 regular expressions
    - geoip      GeoIP support
    - http3      HTTP/3 (QUIC) support
    - lua        Lua scripting support
    - stream     TCP/UDP proxy support
    - threads    Thread pool support

Dependencies:
    //packages/linux/core/openssl:openssl
    //packages/linux/core/pcre2:pcre2
    //packages/linux/core/zlib:zlib

$ pkgmgr deps nginx --tree
nginx-1.24.0
├── openssl-3.2.0
│   └── zlib-1.3
├── pcre2-10.42
└── zlib-1.3 (already shown)

$ pkgmgr use nginx --set "+http2 +ssl +pcre2 +geoip"
USE flags for nginx updated:
    + http2  (enabled)
    + ssl    (enabled)
    + pcre2  (enabled)
    + geoip  (enabled)

Additional dependencies will be installed:
    //packages/linux/dev-libs/geoip:geoip

$ pkgmgr install nginx
Calculating dependencies... done
The following packages will be installed:
    nginx-1.24.0 [http2 ssl pcre2 geoip]
    geoip-1.6.12

Total download size: 2.1 MB
Total installed size: 8.5 MB

Continue? [y/N] y
>>> Fetching nginx-1.24.0.tar.gz
>>> Verifying checksum... OK
>>> Extracting... done
>>> Building nginx-1.24.0
    [########################################] 100%
>>> Installing nginx-1.24.0
>>> Installation complete

$ pkgmgr config export --format=json > config.json
Configuration exported to config.json
```

---

## Appendix B: Migration Guide

### From Portage

| Portage | BuckOS Package Manager |
|---------|------------------------|
| `/etc/portage/make.conf` | `/etc/buckos-pkgmgr.toml` |
| `/etc/portage/package.use` | `[use_flags.package]` section |
| `/etc/portage/package.mask` | `[mask]` section |
| `/etc/portage/package.accept_keywords` | `[keywords]` section |
| `emerge` | `pkgmgr` |
| `equery` | `pkgmgr info/deps` |
| `euse` | `pkgmgr use` |

### Configuration Translation

```bash
# Portage make.conf
USE="ssl ipv6 -X"
CFLAGS="-O2 -pipe"
MAKEOPTS="-j8"

# Translates to:
# /etc/buckos-pkgmgr.toml
[use_flags]
global = ["ssl", "ipv6", "-X"]

[environment]
CFLAGS = "-O2 -pipe"
MAKEOPTS = "-j8"
```

---

## Appendix C: API Reference

### Core Functions

```python
# Package queries
get_package_info(target) -> PackageInfo
get_package_versions(target) -> list[str]
get_package_dependencies(target) -> list[str]
get_package_use_flags(target) -> list[str]

# Registry queries
get_default_version(pkg_id) -> str
get_all_versions(pkg_id) -> list[str]
get_versions_in_slot(pkg_id, slot) -> list[str]
get_stable_versions(pkg_id) -> list[str]
get_version_status(pkg_id, version) -> str
list_all_packages() -> list[str]
list_packages_by_category(category) -> list[str]

# USE flag operations
get_available_use_flags() -> list[str]
get_use_flags_by_category(category) -> list[str]
resolve_use_flags(package) -> set[str]
validate_use_flags(package, flags) -> dict

# Set operations
get_set_packages(set_name) -> list[str]
get_set_info(set_name) -> dict
list_all_sets() -> list[str]
union_sets(*sets) -> list[str]
intersection_sets(*sets) -> list[str]
difference_sets(set1, set2) -> list[str]

# Configuration
generate_system_config(**kwargs) -> dict
export_config_json() -> str
export_config_toml() -> str
export_config_shell() -> str
export_buck_config() -> str

# Build operations
build_package(target, **kwargs) -> BuildResult
install_package(target, destdir) -> InstallResult
```

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2024-01-01 | Initial specification |

---

## References

- [Buck2 Documentation](https://buck2.build/)
- [BuckOS USE Flags Documentation](USE_FLAGS.md)
- [BuckOS Package Sets Documentation](PACKAGE_SETS.md)
- [BuckOS Versioning Documentation](VERSIONING.md)
- [BuckOS Patch System Documentation](PATCHES.md)
- [Gentoo Portage Specification](https://wiki.gentoo.org/wiki/Portage)
