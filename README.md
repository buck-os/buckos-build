# BuckOS Linux

A Buck2-based Linux distribution

## Overview

BuckOS uses Buck2 to define and build Linux packages as reproducible build
targets. Each package is as a Buck target with source downloads, build
configuration, and dependencies clearly specified.

## Project Structure

```
buckos-build/
├── .buckconfig          # Buck2 configuration
├── BUCK                  # Root build targets
├── defs/                 # Build rule definitions
│   ├── package_defs.bzl  # Core package build rules
│   ├── patch_registry.bzl # Private patch registry loader
│   ├── eclasses.bzl      # Eclass inheritance system (20 eclasses)
│   ├── use_flags.bzl     # USE flag system (65+ flags)
│   ├── versions.bzl      # Multi-version/slot support
│   ├── registry.bzl      # Central package version registry
│   ├── licenses.bzl      # License tracking (70+ licenses)
│   ├── eapi.bzl          # EAPI versioning (6-8)
│   ├── package_sets.bzl  # System profiles and package sets
│   ├── advanced_deps.bzl # Blockers, SRC_URI, REQUIRED_USE
│   ├── arch.bzl          # Architecture configuration
│   ├── platform_defs.bzl # Platform targeting
│   └── ...               # Additional definitions
├── patches/              # Private patch registry (gitignored)
│   ├── registry.bzl      # Target-to-patch mapping (user-maintained)
│   └── BUCK              # Patch file exports
├── platforms/
│   └── BUCK              # Platform definitions and constraints
├── toolchains/
│   ├── BUCK              # Toolchain configurations
│   └── bootstrap/        # 3-stage bootstrap toolchain
│       ├── BUCK          # Cross-compiler and core utilities
│       ├── go/BUCK       # Go toolchain (1.25.5)
│       ├── llvm/BUCK     # LLVM toolchain (21.1.8)
│       └── rust/BUCK     # Rust toolchain (1.90.0)
└── packages/linux/       # Linux packages by category
    ├── core/             # Core system libraries (musl, zlib, etc.)
    ├── dev-libs/         # Development libraries
    ├── dev-tools/        # Development tools
    ├── kernel/           # Linux kernel
    ├── system/           # System packages and rootfs
    ├── network/          # Networking packages
    ├── graphics/         # Graphics packages
    ├── desktop/          # Desktop environments
    └── ...               # Additional categories
```

## Requirements

- Buck2 (https://buck2.build)
- Standard build toolchain (gcc, make, etc.) - only for host toolchain mode
- curl (for downloading sources)

## Quick Start

### Install Buck2

```bash
# Download Buck2
curl -LO https://github.com/facebook/buck2/releases/latest/download/buck2-x86_64-unknown-linux-gnu.zst
zstd -d buck2-x86_64-unknown-linux-gnu.zst -o buck2
chmod +x buck2
sudo mv buck2 /usr/local/bin/
```

### Build Packages

```bash
# Build individual packages
buck2 build //packages/linux/core:zlib
buck2 build //packages/linux/core:busybox
buck2 build //packages/linux/kernel:linux

# Build with host toolchain for faster development
buck2 build //packages/linux/editors/entr:entr --target-platforms //platforms:linux-target-host

# Build complete rootfs
buck2 build //packages/linux/system:buckos-rootfs

# Build everything
buck2 build //:complete
```

### List Available Targets

```bash
# List all targets
buck2 targets //...

# List targets in a specific category
buck2 targets //packages/linux/core/...
buck2 targets //packages/linux/network/...
```

## Build Definitions (`defs/`)

The `defs/` directory contains the core build system with ~21 Starlark files:

### Core Package Rules (`package_defs.bzl`)

The main package build rules and macros:

| Rule | Use Case |
|------|----------|
| `download_source` | Download and extract source tarballs |
| `configure_make_package` | Standard autotools (./configure && make) |
| `cmake_package` | CMake-based projects |
| `meson_package` | Meson-based projects |
| `cargo_package` | Rust/Cargo projects |
| `go_package` | Go projects |
| `binary_package` | Custom install script |
| `kernel_build` | Linux kernel |
| `rootfs` | Assemble root filesystem |

### Eclass System (`eclasses.bzl`)

20 eclasses for standardized build configurations:

| Eclass | Description |
|--------|-------------|
| `cmake` | CMake with ninja backend |
| `meson` | Meson build system |
| `autotools` | Traditional autoconf/make |
| `cargo` | Rust/Cargo packages |
| `go-module` | Go module packages |
| `python-single-r1` | Single Python implementation |
| `python-r1` | Multiple Python versions |
| `npm` | Node.js packages |
| `perl` | CPAN/Perl modules |
| `ruby` | Ruby gems |
| `java` | Java compilation |
| `maven` | Maven-based Java |
| `qt5` / `qt6` | Qt packages |
| `systemd` | Systemd unit files |
| `xdg` | XDG desktop integration |
| `linux-mod` | Kernel modules |
| `acct-user` / `acct-group` | System accounts |
| `font` | Font installation |

Usage:
```python
load("//defs:eclasses.bzl", "inherit")

config = inherit(["cmake", "python-single-r1"])
```

### USE Flags (`use_flags.bzl`)

65+ global USE flags with 6 predefined profiles:

| Profile | Description |
|---------|-------------|
| `minimal` | Bare essentials |
| `server` | Headless server |
| `desktop` | Full desktop with multimedia |
| `developer` | Development tools |
| `hardened` | Security-focused |
| `default` | Balanced configuration |

### Package Sets (`package_sets.bzl`)

Predefined package collections:

- **Profiles**: minimal, server, desktop, developer, hardened, embedded, container
- **Tasks**: web-server, database-server, container-host, vpn-server, monitoring
- **Init Systems**: systemd, openrc, runit, s6, sysvinit, dinit, busybox-init
- **Desktops**: kde-desktop, xfce-desktop, sway-desktop, hyprland-desktop, i3-desktop
- **Languages**: python-dev, nodejs-dev, rust-dev, go-dev, cpp-dev, ruby-dev, php-dev

### Version Management (`versions.bzl`)

Multi-version support with Gentoo-style slots:

```python
load("//defs:versions.bzl", "multi_version_package")

multi_version_package(
    name = "openssl",
    versions = {
        "3.2.0": {"slot": "3", "keywords": ["stable"]},
        "1.1.1w": {"slot": "1.1", "keywords": ["stable"]},
    },
    default_version = "3.2.0",
)
```

### Licenses (`licenses.bzl`)

70+ licenses with 10 license groups:
- `@FSF-APPROVED`, `@OSI-APPROVED`, `@FREE`
- `@GPL-COMPATIBLE`, `@COPYLEFT`, `@PERMISSIVE`
- `@BINARY-REDISTRIBUTABLE`, `@DOCS`, `@FONTS`, `@FIRMWARE`


## Toolchain System (`toolchains/`)

BuckOS implements a proper multi-stage bootstrap similar to Linux From Scratch.

### Bootstrap Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│ STAGE 1: Cross-Compilation (Host → BuckOS)                              │
│                                                                         │
│ Host compiler → Cross-binutils → Cross-GCC-pass1 → Glibc →              │
│                 Cross-GCC-pass2 → Cross-libstdc++                       │
│                                                                         │
│ Target: x86_64-buckos-linux-gnu                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────┐
│ STAGE 2: Core System (Cross-compiled)                                   │
│                                                                         │
│ Cross-compiler → bash, coreutils, make, sed, gawk, grep, findutils,     │
│                  tar, gzip, xz, bzip2, pkg-config, patch                │
│               → Bootstrap GCC (native, self-hosted)                     │
└─────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────┐
│ STAGE 3: Language Toolchains                                            │
│                                                                         │
│ ├── Go:   go-bootstrap (1.23.6) → go-native (1.25.5)                    │
│ ├── LLVM: bootstrap-toolchain → llvm-bootstrap (21.1.8)                 │
│ └── Rust: rust-bootstrap (1.88.0) → rust-native (1.90.0)                │
└─────────────────────────────────────────────────────────────────────────┘
```

### Bootstrap Components

| Component | Version | Purpose |
|-----------|---------|---------|
| binutils | 2.44 | Cross-assembler/linker |
| GCC | 14.3.0 | Cross and native compiler |
| Glibc | 2.42 | C library |
| Linux headers | 6.12.6 | Kernel API headers |
| Go | 1.25.5 | Go compiler |
| Rust | 1.90.0 | Rust compiler |
| LLVM | 21.1.8 | Compiler infrastructure |

### Toolchain Modes

BuckOS supports two toolchain modes:

#### Bootstrap Mode (Default - Recommended for Production)

Uses the self-hosted 3-stage bootstrap process:

```bash
# Default - uses bootstrap toolchain
buck2 build //packages/linux/core:zlib
buck2 build //packages/linux/editors/entr:entr --target-platforms //platforms:linux-target
```

**Benefits:**
- Complete isolation from host system
- Reproducible builds across different hosts
- Portable binaries with consistent ABI

#### Host Toolchain Mode (For Development)

Uses the host system's GCC/clang directly:

```bash
# Use host toolchain for faster builds
buck2 build //packages/linux/editors/entr:entr --target-platforms //platforms:linux-target-host
```

Or set in `.buckconfig`:
```ini
[buckos]
use_host_toolchain = true
```

**Benefits:**
- Faster builds (no toolchain compilation)
- Less disk space
- Useful for rapid iteration

| Use Case | Recommended Mode |
|----------|------------------|
| Production builds | Bootstrap |
| Development/testing | Host |
| Creating distributable binaries | Bootstrap |
| Quick prototyping | Host |
| CI/CD builds | Bootstrap |

## Package System

### Package Types

#### `download_source`
Downloads and extracts source tarballs:
```python
download_source(
    name = "musl-src",
    src_uri = "https://musl.libc.org/releases/musl-1.2.4.tar.gz",
    sha256 = "...",
)
```

#### `configure_make_package`
Standard configure/make/make install workflow:
```python
configure_make_package(
    name = "musl",
    source = ":musl-src",
    version = "1.2.4",
    description = "Lightweight C library",
    configure_args = ["--disable-static"],
    deps = [...],
)
```

#### `kernel_build`
Linux kernel builds:
```python
kernel_build(
    name = "linux",
    source = ":linux-src",
    version = "6.6.10",
    config = "kernel.config",
)
```

#### `rootfs`
Assembles packages into a root filesystem:
```python
rootfs(
    name = "buckos-rootfs",
    packages = [
        "//packages/linux/core:busybox",
        "//packages/linux/core:musl",
        ...
    ],
)
```

### Adding New Packages

1. Create a directory in `packages/linux/<category>/<name>/`
2. Create a `BUCK` file with package definitions
3. Define source download and build rules
4. Add dependencies

Example:
```python
load("//defs:package_defs.bzl", "download_source", "configure_make_package")

download_source(
    name = "newpkg-src",
    src_uri = "https://example.com/newpkg-1.0.tar.gz",
    sha256 = "checksum...",
)

configure_make_package(
    name = "newpkg",
    source = ":newpkg-src",
    version = "1.0",
    description = "My new package",
    deps = ["//packages/linux/core:zlib"],
)
```

## Multi-Version Package Support

BuckOS supports maintaining multiple versions of the same package with slots.

### Key Concepts

- **Slots**: Logical groupings of package versions (e.g., `openssl:3` vs `openssl:1.1`)
- **Subslots**: Track ABI compatibility (triggers rebuilds on ABI changes)
- **Default Version**: The version used when no specific version is requested

### Defining Multi-Version Packages

```python
load("//defs:versions.bzl", "multi_version_package")

multi_version_package(
    name = "openssl",
    versions = {
        "3.2.0": {
            "slot": "3",
            "keywords": ["stable"],
            "src_uri": "https://www.openssl.org/source/openssl-3.2.0.tar.gz",
            "sha256": "...",
        },
        "1.1.1w": {
            "slot": "1.1",
            "keywords": ["stable"],
            "configure_args": ["--prefix=/usr/lib/openssl-1.1"],
        },
    },
    default_version = "3.2.0",
)
```

### Version Dependencies

```python
load("//defs:versions.bzl", "version_dep")

configure_make_package(
    name = "myapp",
    deps = [
        version_dep("//packages/linux/dev-libs/openssl", ">=3.0"),
        version_dep("//packages/linux/core:zlib", "~>1.2"),
    ],
)
```

Supported constraint operators: `>=`, `>`, `<=`, `<`, `~>` (pessimistic), `*` (wildcard)

## USE Flags

Conditional package features similar to Gentoo:

```python
load("//defs:use_flags.bzl", "use_package")

use_package(
    name = "curl",
    version = "8.5.0",
    src_uri = "https://curl.se/download/curl-8.5.0.tar.xz",
    sha256 = "...",
    iuse = ["ssl", "http2", "zstd", "ipv6"],
    use_defaults = ["ssl", "ipv6"],
    use_deps = {
        "ssl": ["//packages/linux/dev-libs/openssl"],
        "http2": ["//packages/linux/network:nghttp2"],
    },
    use_configure = {
        "ssl": "--with-ssl",
        "-ssl": "--without-ssl",
        "http2": "--with-nghttp2",
    },
)
```

## Platform Targeting

BuckOS supports tagging packages by platform:

```python
load("//defs:platform_defs.bzl", "PLATFORM_LINUX", "platform_filegroup")

platform_filegroup(
    name = "my-linux-package",
    srcs = [":my-package-build"],
    platforms = [PLATFORM_LINUX],
)
```

Supported platforms: `linux`, `bsd`, `macos`, `windows`

## Architecture Support

Currently supported architectures:
- **x86_64**: Full support with optimized kernel configs
- **aarch64**: Cross-compilation support

Architecture-specific configuration:
```python
load("//defs:arch.bzl", "get_arch_config", "arch_select")

config = get_arch_config("x86_64")
# Returns: target_triplet, kernel_arch, march, qemu settings, etc.
```

## Testing

### Boot in QEMU

```bash
# Build the complete QEMU testing environment
buck2 build //packages/linux/system:qemu-boot --show-output

# Run the generated boot script
./buck-out/v2/gen/root/<hash>/__qemu-boot__/qemu-boot.sh
```

Available QEMU targets:

| Target | Description |
|--------|-------------|
| `system:qemu-boot` | Basic QEMU boot (512MB RAM, 2 CPUs) |
| `system:qemu-boot-dev` | Development mode (2GB RAM, 4 CPUs, KVM) |
| `system:qemu-boot-net` | With network (SSH on port 2222) |

### ISO Image Generation

```bash
# Build a hybrid (BIOS+EFI) bootable ISO
buck2 build //packages/linux/system:buckos-iso --show-output
```

## Security Features

### Network Isolation During Build

All build phases run without network access using `unshare --net`:
- Prevents malicious build scripts from exfiltrating data
- Ensures all dependencies are explicitly declared
- Forces proper dependency management

### Checksum Verification

SHA256 required for all downloads with detailed mismatch reporting:
```
✗ Checksum verification FAILED
  Expected: 7c26c04df547877ebc3df71ab8fecb011b5f75f5c8b9c35e8423e69ba1a1ce88
  Actual:   8a9b2e3f4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f
```

### GPG Signature Verification

Optional GPG signature verification:
```python
download_source(
    name = "package-src",
    src_uri = "https://example.com/package-1.0.tar.gz",
    sha256 = "...",
    signature_uri = "https://example.com/package-1.0.tar.gz.asc",
    gpg_key = "ABCD1234...",
)
```

## Private Patch Registry

BuckOS supports applying private patches to any package without modifying the
upstream build graph. This is useful for internal/personal customizations that
shouldn't be committed to the public repository.

### Setup

The patch registry consists of three files in the `patches/` directory (all
gitignored so your changes stay private):

1. **`patches/registry.bzl`** - Maps package names to patches and overrides
2. **`patches/BUCK`** - Exports patch files as Buck2 sources
3. **Patch files** - Stored under `patches/` in any directory structure you prefer

### Quick Example

1. Create a patch file:
   ```bash
   mkdir -p patches/core/zlib
   # Create your patch file at patches/core/zlib/my-fix.patch
   ```

2. Export it in `patches/BUCK`:
   ```python
   export_file(
       name = "zlib-fix.patch",
       src = "core/zlib/my-fix.patch",
       visibility = ["PUBLIC"],
   )
   ```

3. Register it in `patches/registry.bzl`:
   ```python
   PATCH_REGISTRY = {
       "zlib": {
           "patches": ["//patches:zlib-fix.patch"],
       },
   }
   ```

4. Build normally - the patch is applied automatically:
   ```bash
   buck2 build //packages/linux/core/zlib:zlib
   ```

### Registry Format

Each entry maps a package name to an override config:

```python
PATCH_REGISTRY = {
    "package-name": {
        # Patch files (appended to any existing patches)
        "patches": ["//patches:my-fix.patch"],

        # Environment variable overrides (merged with existing)
        "env": {"CFLAGS": "-DCUSTOM_FLAG"},

        # Extra configure arguments (appended)
        "extra_configure_args": "--with-custom-option",

        # Additional pre-configure commands (appended)
        "pre_configure": "sed -i 's/old/new/' configure.ac",

        # Replace src_prepare phase entirely (use with caution)
        "src_prepare": "autoreconf -fiv",
    },
}
```

### Disabling the Registry

To temporarily disable all private patches without deleting your registry:

```ini
# .buckconfig
[buckos]
patch_registry_enabled = false
```

## License

GPL-2.0 License - See individual packages for their respective licenses.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add your packages following the existing patterns
4. Submit a pull request
