# BuckOS Kernel Configuration System

This document describes the BuckOS kernel build system and how to configure and customize kernel builds using Buck2.

## Overview

BuckOS uses a modular kernel configuration system that allows:

- **Pre-built kernel packages** for common use cases
- **Configuration fragments** that can be combined to create custom configs
- **Easy customization** without managing entire kernel configs
- **Reproducible builds** through Buck2's hermetic build system

## Kernel Version

BuckOS uses the **Linux 6.12 LTS** kernel (released November 2024), which is supported until December 2026. This provides:

- Long-term stability and security updates
- Real-time `PREEMPT_RT` support
- New `sched_ext` scheduler
- Improved hardware support

## Available Kernel Packages

### Default Kernel

```bash
buck2 build //packages/linux/kernel/buckos-kernel
```

The default BuckOS kernel with comprehensive hardware support. Includes:
- All common filesystems (ext4, XFS, Btrfs, NTFS, etc.)
- Full networking stack with BBR congestion control
- Virtualization (KVM host and VirtIO guest)
- Container support (cgroups v2, namespaces)
- Security features (AppArmor, SELinux, TPM)

### Kernel Variants

| Package | Description | Use Case |
|---------|-------------|----------|
| `buckos-kernel` | Full featured default kernel | General purpose, most users |
| `buckos-kernel-minimal` | Essential drivers only | Small footprint, embedded |
| `buckos-kernel-server` | Server optimized | Servers, headless systems |
| `buckos-kernel-vm` | VM guest optimized | Virtual machines |
| `buckos-kernel-defconfig` | Kernel defconfig | Development/testing |

Build examples:
```bash
buck2 build //packages/linux/kernel/buckos-kernel:buckos-kernel-minimal
buck2 build //packages/linux/kernel/buckos-kernel:buckos-kernel-server
buck2 build //packages/linux/kernel/buckos-kernel:buckos-kernel-vm
```

## Configuration Fragments

BuckOS provides modular configuration fragments that can be combined to create custom kernel configurations.

### Available Fragments

| Fragment | Description |
|----------|-------------|
| `base.config` | Core settings (64-bit, SMP, modules, power management) |
| `filesystem.config` | Filesystem support (ext4, XFS, Btrfs, FUSE, NFS, etc.) |
| `network.config` | Networking (TCP/IP, IPv6, netfilter, drivers) |
| `hardware.config` | Hardware drivers (USB, SCSI, SATA, NVMe, input, audio) |
| `virtualization.config` | KVM, VirtIO, containers, VFIO |
| `security.config` | Crypto, LSM, TPM, integrity |

### Pre-built Configurations

```bash
# View available configs
buck2 build //packages/linux/kernel/configs:buckos-default
buck2 build //packages/linux/kernel/configs:buckos-minimal
buck2 build //packages/linux/kernel/configs:buckos-server
buck2 build //packages/linux/kernel/configs:buckos-vm-guest
```

## Creating Custom Kernels

### Method 1: Combine Fragments

Create a custom kernel by combining existing fragments with your own overrides.

1. Create a custom fragment file:

```bash
# my-custom.config
CONFIG_PREEMPT=y
CONFIG_HZ_1000=y
CONFIG_DRM_I915=y
```

2. Create a BUCK file with `kernel_config`:

```python
load("//defs/rules:kernel.bzl", "kernel_build", "kernel_config")

# Merge fragments into a final config
kernel_config(
    name = "my-kernel-config",
    fragments = [
        "//packages/linux/kernel/configs:base.config",
        "//packages/linux/kernel/configs:filesystem.config",
        "//packages/linux/kernel/configs:network.config",
        "//packages/linux/kernel/configs:hardware.config",
        "my-custom.config",  # Your custom fragment (last to override)
    ],
)

# Build kernel with merged config
kernel_build(
    name = "my-kernel",
    source = "//packages/linux/kernel/src:linux-src",
    version = "6.12.6",
    config_dep = ":my-kernel-config",
    visibility = ["PUBLIC"],
)
```

3. Build your kernel:

```bash
buck2 build //path/to/your:my-kernel
```

### Method 2: Complete Custom Config

Use when you have a complete kernel configuration from another source:

```python
kernel_build(
    name = "my-kernel",
    source = "//packages/linux/kernel/src:linux-src",
    version = "6.12.6",
    config = "my-complete.config",  # Your full config file
    visibility = ["PUBLIC"],
)
```

You can generate a config using:
```bash
# From kernel source
make menuconfig
make savedefconfig

# Or copy from another distribution
cp /boot/config-$(uname -r) my-complete.config
```

### Method 3: Using Defconfig

For development or minimal builds:

```python
kernel_build(
    name = "dev-kernel",
    source = "//packages/linux/kernel/src:linux-src",
    version = "6.12.6",
    # No config = uses make defconfig
    visibility = ["PUBLIC"],
)
```

## How Configuration Merging Works

The `kernel_config` rule merges fragments in order, with later fragments overriding earlier ones:

1. Each fragment is processed line by line
2. When a CONFIG option is set, any previous setting is removed
3. The final merged config is passed to `make olddefconfig` to fill in defaults

This allows you to:
- Start with base fragments for common settings
- Add specialized fragments (like `virtualization.config`)
- Override specific options with your custom fragment last

## Fragment Customization Examples

### Desktop/Workstation

```python
kernel_config(
    name = "desktop-config",
    fragments = [
        "//packages/linux/kernel/configs:base.config",
        "//packages/linux/kernel/configs:filesystem.config",
        "//packages/linux/kernel/configs:network.config",
        "//packages/linux/kernel/configs:hardware.config",
        "//packages/linux/kernel/configs:security.config",
        "desktop.config",  # Add graphics drivers, preemption
    ],
)
```

### Embedded/IoT

```python
kernel_config(
    name = "embedded-config",
    fragments = [
        "//packages/linux/kernel/configs:base.config",
        "//packages/linux/kernel/configs:filesystem.config",
        "embedded-hw.config",  # Specific hardware only
    ],
)
```

### Cloud/Container Host

```python
kernel_config(
    name = "cloud-config",
    fragments = [
        "//packages/linux/kernel/configs:base.config",
        "//packages/linux/kernel/configs:filesystem.config",
        "//packages/linux/kernel/configs:network.config",
        "//packages/linux/kernel/configs:virtualization.config",
        "//packages/linux/kernel/configs:security.config",
        "cloud-tweaks.config",  # Disable unnecessary drivers
    ],
)
```

### DPU (Data Processing Unit)

DPU images are typically stripped-down, immutable systems focused on networking,
storage offload, and infrastructure services. The kernel config should enable
the DPU's NIC/SmartNIC drivers and RDMA stack while disabling desktop hardware
(graphics, sound, USB HID).

Create a `dpu.config` fragment with options relevant to your hardware:

```
# dpu.config — example for Mellanox/NVIDIA BlueField-style DPUs

# Core networking drivers
CONFIG_MLX5_CORE=y
CONFIG_MLX5_CORE_EN=y
CONFIG_MLX5_EN_IPSEC=y
CONFIG_MLX5_ESWITCH=y
CONFIG_MLX5_MPFS=y
CONFIG_MLX5_VDPA_NET=y

# RDMA / RoCE
CONFIG_INFINIBAND=y
CONFIG_MLX5_INFINIBAND=y
CONFIG_INFINIBAND_USER_ACCESS=y
CONFIG_INFINIBAND_ADDR_TRANS=y

# VirtIO for host-DPU communication
CONFIG_VIRTIO=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_BLK=y
CONFIG_VHOST_NET=y
CONFIG_VHOST_VDPA=y

# NVMe for storage offload
CONFIG_NVME_CORE=y
CONFIG_BLK_DEV_NVME=y
CONFIG_NVME_TARGET=y

# Disable desktop hardware
# CONFIG_DRM is not set
# CONFIG_SOUND is not set
# CONFIG_USB_HID is not set
# CONFIG_INPUT_JOYSTICK is not set
```

Compose with base fragments and build:

```python
load("//defs/rules:kernel.bzl", "kernel_build", "kernel_config")

kernel_config(
    name = "dpu-config",
    fragments = [
        "//packages/linux/kernel/configs:base.config",
        "//packages/linux/kernel/configs:network.config",
        "//packages/linux/kernel/configs:security.config",
        "dpu.config",  # DPU-specific hardware and features
    ],
)

# Optional: download external module sources
download_source(
    name = "custom-driver-src",
    src_uri = "https://example.com/custom-driver-1.0.tar.gz",
    sha256 = "...",
)

kernel_build(
    name = "dpu-kernel",
    source = "//packages/linux/kernel/src:linux-src",
    version = "6.17.10",
    config_dep = ":dpu-config",
    modules = [
        ":custom-driver-src",  # External modules built against this kernel
    ],
    arch = "aarch64",  # Most DPUs are ARM64
    cross_toolchain = "//tc/bootstrap/aarch64:cross-toolchain-aarch64",
    visibility = ["PUBLIC"],
)
```

The resulting kernel output includes in-tree modules, external modules in
`lib/modules/$KRELEASE/extra/`, and pre-generated `modules.dep` from depmod.

#### Building a DPU image

DPU images can be assembled using existing BuckOS image rules:

```python
load("//defs/rules:rootfs.bzl", "rootfs")
load("//defs/rules:initramfs.bzl", "initramfs")
load("//defs/rules:image.bzl", "raw_disk_image")

# Minimal rootfs for DPU
rootfs(
    name = "dpu-rootfs",
    packages = [
        "//packages/linux/core:musl",
        "//packages/linux/core:busybox",
        "//packages/linux/core:iproute2",
        # Add DPU management packages as needed
    ],
)

# For PXE / network boot
initramfs(
    name = "dpu-initramfs",
    rootfs = ":dpu-rootfs",
    compression = "xz",
)

# For eMMC / flash storage
raw_disk_image(
    name = "dpu-disk-image",
    rootfs = ":dpu-rootfs",
    size = "2G",
    filesystem = "ext4",
    label = "BUCKOS-DPU",
    partition_table = True,
)
```

## Build Rules Reference

### `kernel_config`

Merges multiple configuration fragments into a single .config file.

```python
kernel_config(
    name = "config-name",
    fragments = [
        "fragment1.config",
        "fragment2.config",
        # Later fragments override earlier ones
    ],
)
```

### `kernel_build`

Builds a Linux kernel with the specified configuration, optional patches, and external modules.

```python
kernel_build(
    name = "kernel-name",
    source = "//packages/linux/kernel/src:linux-src",
    version = "6.12.6",

    # Use ONE of these config options:
    config = "path/to/config.file",  # Direct config file
    config_dep = ":config-target",   # Output from kernel_config
    # Or neither for defconfig

    # Optional: patches to apply before building
    patches = [
        "fix-driver-bug.patch",         # Local patch file
        "//patches:custom-fix.patch",   # Patch from another target
    ],

    # Optional: external module sources to compile against this kernel
    modules = [
        ":my-driver-src",              # download_source target
        "//packages/linux/kernel/modules/custom:src",
    ],

    visibility = ["PUBLIC"],
)
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `name` | string | required | Target name |
| `source` | dep | required | Kernel source (download_source target) |
| `version` | string | required | Kernel version string |
| `config` | source | None | Direct path to .config file |
| `config_dep` | dep | None | Config from kernel_config rule |
| `arch` | string | "x86_64" | Target architecture (x86_64 or aarch64) |
| `cross_toolchain` | dep | None | Cross-compilation toolchain |
| `patches` | list[source] | [] | Patch files applied with `patch -p1` before build |
| `modules` | list[dep] | [] | External module sources to compile |
| `visibility` | list | [] | Target visibility |

**Patches** are applied after the kernel source is copied to the build directory
but before configuration and compilation. They use `patch -p1` and the build fails
if any patch fails to apply. Patches from the private patch registry
(`patches/registry.bzl`) are automatically appended.

**Modules** are compiled after the kernel build completes using
`make -C $KERNEL_BUILD M=$MODULE_SRC modules`. Each module source is a
`download_source` target whose extracted directory contains a Makefile/Kbuild
file. Built `.ko` files are installed to `lib/modules/$KRELEASE/extra/` and
`depmod` runs automatically to generate module dependency metadata.

### External Kernel Modules

There are two ways to build external kernel modules:

#### Method 1: `modules` attribute (recommended)

The simplest approach — declare module sources directly on the `kernel_build` target:

```python
load("//defs/rules:kernel.bzl", "kernel_build")

download_source(
    name = "my-driver-src",
    src_uri = "https://example.com/my-driver-1.0.tar.gz",
    sha256 = "...",
)

kernel_build(
    name = "my-kernel",
    source = "//packages/linux/kernel/src:linux-src",
    version = "6.17.10",
    config_dep = "//packages/linux/kernel/configs:buckos-default",
    modules = [":my-driver-src"],
    visibility = ["PUBLIC"],
)
```

The kernel build will compile the module against the kernel tree and install the
`.ko` files alongside in-tree modules.

#### Method 2: Separate `ebuild_package` (for complex modules)

For modules that need custom build steps, non-standard source layouts, or
additional dependencies, use a separate `ebuild_package` with `bdepend` on the
kernel. See `packages/linux/laptop/battery/tp_smapi/BUCK` for an example.

### Private Patch Registry

Kernel targets integrate with the private patch registry (`patches/registry.bzl`).
Add entries keyed by the kernel target name to apply patches without modifying
the BUCK file:

```python
# patches/registry.bzl
PATCH_REGISTRY = {
    "buckos-kernel": {
        "patches": ["//patches:my-kernel-fix.patch"],
    },
}
```

See `defs/patch_registry.bzl` for the full registry format.

## Directory Structure

```
packages/linux/kernel/
├── BUCK                    # Main kernel targets
├── src/                    # Kernel source download
│   └── BUCK
├── configs/                # Configuration fragments
│   ├── BUCK
│   ├── base.config
│   ├── filesystem.config
│   ├── network.config
│   ├── hardware.config
│   ├── virtualization.config
│   └── security.config
├── buckos-kernel/          # Official BuckOS kernels
│   └── BUCK
├── modules/                # External kernel module sources
│   └── <module-name>/
│       └── BUCK            # download_source + optional ebuild_package
├── examples/               # Custom kernel examples
│   └── BUCK
├── linux/                  # Legacy (deprecated)
└── linux-defconfig/        # Legacy (deprecated)
```

## Migration from Legacy Targets

If you were using the old kernel targets, migrate as follows:

| Old Target | New Target |
|------------|------------|
| `//packages/linux/kernel/linux` | `//packages/linux/kernel/buckos-kernel` |
| `//packages/linux/kernel/linux-defconfig` | `//packages/linux/kernel/buckos-kernel:buckos-kernel-defconfig` |

The legacy targets still work but now use the 6.12 LTS kernel source.

## Tips

### Checking Configuration

To see what options are set in a merged config:
```bash
buck2 build //packages/linux/kernel/configs:buckos-default
cat buck-out/v2/gen/.../buckos-default.config | grep CONFIG_KVM
```

### Debugging Build Issues

If the kernel fails to build:
1. Check for conflicting options between fragments
2. Run `make olddefconfig` to resolve dependencies
3. Use the debug fragment for more verbose output

### Performance Tuning

For specific workloads, consider:
- `CONFIG_PREEMPT` levels for latency vs throughput
- `CONFIG_HZ` settings (100/250/300/1000)
- CPU frequency governors
- I/O schedulers

## See Also

- [USE_FLAGS.md](USE_FLAGS.md) - Package USE flags
- [PACKAGE_SETS.md](PACKAGE_SETS.md) - System profiles
- [packages/linux/kernel/examples/](../packages/linux/kernel/examples/) - Example custom kernels
