# BuckOS Linux

[![CI](https://github.com/buck-os/buckos-build/actions/workflows/ci.yml/badge.svg)](https://github.com/buck-os/buckos-build/actions/workflows/ci.yml)

A Buck2-based Linux distribution

## Overview

BuckOS uses Buck2 to define and build Linux packages as reproducible build
targets. Each package is as a Buck target with source downloads, build
configuration, and dependencies clearly specified.

## Testing (aka capabilities atm)

All builds and tests run entirely rootless — no `sudo`, no privileged
daemons. Everything is a pure Buck2 target: `buck2 test //tests:`. Many
tests double as runnable demos of the subsystems they exercise.

### Test Inventory

**Provenance and IMA signing** — build small ELF fixtures and verify
`.note.package` injection and IMA `.sig` sidecar generation. Good
starting points for understanding the provenance pipeline.

| Target | What it covers |
|--------|----------------|
| `test-hello-provenance` | ELF binary has `.note.package` section |
| `test-hello-no-provenance` | Unstamped binary has no `.note.package` |
| `test-testlib-provenance` | Shared library `.note.package` injection |
| `test-hello-ima` | IMA `.sig` sidecar files are generated |

**Cloud Hypervisor VM tests** — same IMA matrix as above but running
under Cloud Hypervisor, plus boot script and minimal VM boot verification.
Demonstrates CH as an alternative VMM. Labeled `vm`, `slow`.

| Target | What it covers |
|--------|----------------|
| `test-ch-boot-script` | Generated CH boot script is well-formed |
| `test-ch-vm-boot` | Minimal CH VM boots to init |
| `test-ch-ima-noima` | Unsigned workload binary runs with IMA off (CH) |
| `test-ch-ima-enforce-signed` | Signed workload binary executes under IMA enforce (CH) |
| `test-ch-ima-enforce-unsigned` | Unsigned workload binary rejected (CH) |
| `test-ch-ima-file-signed` | Signed workload binary reads signed data file (CH) |
| `test-ch-ima-file-unsigned` | Signed workload binary denied reading unsigned data file (CH) |

Kernel configs are composable Buck targets — each feature area (filesystem,
network, security, IMA, etc.) is a standalone config fragment merged by the
`kernel_config` rule. USE flag constraints gate which fragments are included
via `select()`, so toggling IMA on or off is a one-line config change
(`?//use/constraints:ima-on`) rather than a manual kernel config edit. Patches that
haven't landed in-tree yet can be applied transparently through the private
patch registry (`patches/`), which injects patches at build time without
modifying the upstream build graph.

**Seed isolation** — audits the exported seed archive for host-path leaks
in RPATH/RUNPATH and cross-contamination between host-tools and sysroot.
Requires a full bootstrap, labeled `slow`.

| Target | What it covers |
|--------|----------------|
| `test-seed-isolation` | ELF RPATH/RUNPATH and NEEDED audit of seed archive |

**ISO boot** — minimal boot verification of the hybrid BIOS+EFI ISO
image in QEMU. Labeled `vm`, `slow`.

| Target | What it covers |
|--------|----------------|
| `test-iso-boot` | BuckOS ISO boots in QEMU to login prompt |
| `qemu-env` | Runtime environment providing QEMU binary to VM tests |

**Build smoke tests** — end-to-end builds of representative packages,
useful for verifying the toolchain works after changes.

| Target | What it covers |
|--------|----------------|
| `build-smoke-zlib` | zlib builds and produces `libz.so` + headers |
| `build-smoke-ch` | Cloud Hypervisor (Rust/Cargo) builds |

**IMA QEMU enforcement** — boot a QEMU VM with an IMA-enabled kernel and
exercise the full appraisal chain: signed workload binaries run, unsigned
workload binaries are rejected, FILE_CHECK appraisal gates data file
access. These demonstrate the IMA policy lifecycle end-to-end. Labeled
`vm`, `slow`.

| Target | What it covers |
|--------|----------------|
| `test-ima-enforce-signed` | Signed workload binary executes under `ima_appraise=enforce` (QEMU) |
| `test-ima-enforce-unsigned` | Unsigned workload binary rejected under enforcement (QEMU) |
| `test-ima-noima` | Unsigned workload binary runs when IMA is off (QEMU) |
| `test-ima-file-signed` | Signed workload binary reads signed data file via FILE_CHECK (QEMU) |
| `test-ima-file-unsigned` | Signed workload binary denied reading unsigned data file (QEMU) |

**Unit tests** — exercise Python helpers and shell scripts in isolation, no
build deps. Run the group with `buck2 test //tests: --labels tools-unit`.

| Target | What it covers |
|--------|----------------|
| `test-provenance-stamp` | `provenance-stamp.sh` ELF note injection logic |
| `test-env-unit` | Environment variable helpers |
| `test-path-resolution` | Buck2 artifact path resolution |
| `test-extract-unit` | Source tarball extraction |
| `test-rootfs-unit` | Rootfs assembly helpers |
| `test-small-helpers` | Miscellaneous small utility functions |
| `test-merge-and-hash` | FHS tree merge and content hashing |
| `test-kernel-helpers` | Kernel config and build helpers |
| `test-iso-config` | ISO image configuration generation |
| `test-build-install` | `build_helper.py` / `install_helper.py` logic |
| `test-stage3-strip` | Stage 3 binary stripping |
| `test-bootstrap-helpers` | Bootstrap rule helpers (configure, sysroot) |
| `test-lang-helpers` | Go / Rust / LLVM toolchain helpers |
| `test-patch-acct` | Patch application and acct-user/group helpers |
| `test-sysroot-merge` | Sysroot directory merge logic |
| `test-toolchain-unpack` | Seed toolchain unpacking and validation |
| `test-vm-helpers` | QEMU / Cloud Hypervisor launch helpers |

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

## Quick Start

The fastest way to get building is with `setup.sh`, which installs system
packages and downloads Buck2:

```bash
bash setup.sh
```

Supports Arch, Debian/Ubuntu, and Fedora/RHEL. Pass `--yes` to skip
confirmation (useful for CI/Docker).

Then build:

```bash
buck2 build //packages/linux/core:zlib
buck2 build //packages/linux/core:busybox
buck2 build //packages/linux/kernel:linux

# Build complete rootfs
buck2 build //packages/linux/system:buckos-rootfs

# Build everything
buck2 build //:complete
```

### Manual Setup

If you prefer to manage packages yourself, you need:

- Buck2 (https://buck2.build)
- GCC, G++, binutils, make, cmake, meson, ninja, autotools
- python3, perl, curl, tar, xz, bzip2, gzip, lzip, zstd, file, patch
- pkg-config, bison, flex, gperf, texinfo, gettext

Install Buck2:

```bash
curl -sL https://github.com/facebook/buck2/releases/download/latest/buck2-x86_64-unknown-linux-gnu.zst \
  | zstd -d -o ~/.local/bin/buck2
chmod +x ~/.local/bin/buck2
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

BuckOS supports three toolchain modes:

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

Per-build with a platform flag:

```bash
buck2 build //packages/linux/editors/entr:entr --target-platforms //platforms:linux-target-host
```

**Benefits:**
- Faster builds (no toolchain compilation)
- Useful for rapid iteration

#### Pre-built Toolchain Mode (For CI/CD and Repeat Builds)

Uses a previously-built bootstrap toolchain exported as a tarball, avoiding recompilation on subsequent builds.

First, build and export the bootstrap toolchain:

```bash
# Build the bootstrap toolchain and Export it as a tarball
scripts/export-toolchain.sh /path/to/toolchain.tar.zst
```

Then configure `.buckconfig` to use it:

```ini
[buckos]
prebuilt_toolchain_path = /path/to/toolchain.tar.zst
```

You can now empty the cache, kill buck2 and start again using the toolchain:

```bash
buck2 clean
buck2 kill
```

The next build will be using the pre-compiled toolchain.


**Benefits:**
- Reproducible builds without re-compiling the toolchain every time
- Significantly faster CI/CD pipelines
- Same binary output as full bootstrap mode

| Use Case | Recommended Mode |
|----------|------------------|
| First bootstrap build | Bootstrap |
| Production builds | Bootstrap or Pre-built |
| Subsequent builds after first bootstrap | Pre-built |
| Development/testing | Host |
| Creating distributable binaries | Bootstrap or Pre-built |
| Quick prototyping | Host |
| CI/CD builds | Pre-built |

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
load("//defs:package.bzl", "package")

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

## Target Labels

BuckOS uses Buck2's `labels` attribute to tag targets with structured metadata.
Labels follow the `buckos:<category>:<value>` convention and are queryable with
`buck2 cquery 'attrfilter(labels, "buckos:compile", //packages/...)'`.

### Auto-injected Labels

These labels are applied automatically by the build macros:

| Label | Applied To |
|-------|-----------|
| `buckos:compile` | All ebuild-based packages |
| `buckos:download` | Source download and extract targets |
| `buckos:prebuilt` | `binary_package` and `precompiled_package` targets |
| `buckos:image` | `rootfs`, `initramfs`, `iso_image`, `raw_disk_image`, `stage3_tarball` |
| `buckos:bootscript` | `qemu_boot_script`, `ch_boot_script` |
| `buckos:config` | `kernel_config` targets |
| `buckos:build:<type>` | Build system type: cmake, meson, autotools, make, cargo, go, etc. |
| `buckos:stage:<N>` | Bootstrap stage (1, 2, 3) |
| `buckos:arch:<arch>` | Architecture: x86_64, aarch64 |

### Manual Labels

These labels are set per-target in BUCK files:

| Label | Description |
|-------|-------------|
| `buckos:hw:cuda` | Requires NVIDIA CUDA |
| `buckos:hw:rocm` | Requires AMD ROCm |
| `buckos:hw:vulkan` | Requires Vulkan |
| `buckos:hw:opencl` | Requires OpenCL |
| `buckos:hw:gpu` | General GPU drivers/tools |
| `buckos:hw:dpdk` | Requires DPDK |
| `buckos:hw:rdma` | Requires RDMA/InfiniBand |
| `buckos:firmware` | Firmware blobs or microcode |
| `buckos:ci:skip` | Skip in CI |
| `buckos:ci:long` | Long build, sample in CI |

### Query Examples

```bash
# All CMake packages
buck2 cquery 'attrfilter(labels, "buckos:build:cmake", //packages/...)'

# All CUDA-dependent targets
buck2 cquery 'attrfilter(labels, "buckos:hw:cuda", //packages/...)'

# All firmware targets
buck2 cquery 'attrfilter(labels, "buckos:firmware", //packages/...)'

# Prebuilt packages (no compilation needed)
buck2 cquery 'attrfilter(labels, "buckos:prebuilt", //packages/...)'
```

### Adding Labels to New Packages

Auto-labels are injected by the macros — no action needed. For hardware or
firmware labels, add `labels = [...]` to your target:

```python
cmake_package(
    name = "my-cuda-lib",
    ...
    labels = ["buckos:hw:cuda"],
)
```

User-provided labels are merged with auto-injected labels.

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
buck2 build //packages/linux/system:buckos-minimal-iso --show-output
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

### IMA Binary Signing

Optional IMA (Integrity Measurement Architecture) signing sets the `security.ima`
extended attribute on every ELF binary and shared library. Kernels with IMA
appraisal enabled use this to verify binaries at exec time.

Signing is two-phase so package builds need no privilege:

1. **Build time** (unprivileged): `evmctl ima_sign --sigfile` writes `.sig`
   sidecar files alongside each ELF binary. No `CAP_SYS_ADMIN` needed.
2. **Image assembly** (root): `.sig` files are applied as `security.ima`
   xattrs via `evmctl ima_setxattr --sigfile`, then cleaned up.

Enable in `.buckconfig`:
```ini
[use]
  ima = true
```

Or per-build: `buck2 build --config use.ima=true //packages/...`

To use a custom signing key, override the default target:
```ini
[use]
  ima_key = //path/to:your-key
```

Requires `ima-evm-utils` (provides `evmctl`). IMA signing runs as part of
provenance stamping after `.note.package` injection.

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

