# BuckOS

[![CI](https://github.com/buck-os/buckos-build/actions/workflows/ci.yml/badge.svg)](https://github.com/buck-os/buckos-build/actions/workflows/ci.yml)

> **Early stage** — the toolchain bootstraps, packages build, ISOs boot,
> and IMA enforcement works end-to-end. Rough edges everywhere.

A from-source Linux distribution built with Buck2, inspired by the
flexibility of Gentoo and the reliability of Fedora Atomic. Compose capabilities,
target any platform, and produce purpose-built images — with features
like kernel-enforced integrity that traditionally require complex
infrastructure, but here are just build flags.

## Why

- **Source-first** — building everything from source means patching any
  package is a file in `patches/`, combining non-standard compiler flags
  or build options is a one-line change, and nothing is a black box.
  Maximum flexibility with no binary constraints.
- **Composable capabilities** — features like integrity measurement,
  virtualization support, or hardware-specific optimizations are build
  flags. Combine them to produce images tailored to a specific role —
  a hardened cloud server, a kiosk appliance, or a gaming handheld
  optimized for its hardware — from the same source tree, without
  maintaining separate forks.
- **Pick your platform** — choose the architecture, the hardware
  profile, and the output format. The same source tree produces a
  bootable ISO, a cloud image, a liveCD, or a device-specific installer
  for an ARM board or an exotic handheld.
- **Immutability without the complexity** — no signing infrastructure,
  no image-based update schemes, no merged-usr gymnastics. IMA
  signatures are applied at build time and the kernel enforces them at
  runtime — only signed binaries execute and only signed files are read.
  The security of an immutable OS on a conventionally mutable filesystem.
- **Built for hackers** — planned support for submoduling your own
  projects directly into the build tree. Hack on your code and leverage
  high-level capabilities like USE flags — enable Wayland support or GPU
  acceleration without having to untangle the dependency graph yourself.
- **One repo, one command** — no chroot managers, no image builder
  pipelines, no CI-specific scripts. The entire distro — toolchain,
  packages, kernel, bootable image — builds with `buck2 build`.

## Example

Cloud Hypervisor is built from source as a package, the kernel is
compiled with IMA support, a VM image is assembled with signed workload
binaries, and the whole thing boots in a test — all from one command:

```sh
# boot a Cloud Hypervisor VM with IMA enforcement:
# signed workloads run, unsigned workloads are rejected by the kernel
buck2 test //tests:test-ch-ima-enforce-signed
buck2 test //tests:test-ch-ima-enforce-unsigned  # verified: kernel rejects it
```

## Quick start

```sh
bash setup.sh          # install host deps, buck2, download seed toolchain
buck2 build //packages/linux/system:buckos-minimal-iso
buck2 test //tests:
```

## Layout

```
tc/              toolchain — bootstrap stages, seed, cross-compiler
packages/        all distro packages (autotools, cmake, meson, cargo, ...)
defs/            build rules and package macro
use/             USE flag constraints, profiles, and modifier aliases
config/          local configuration (local_modifiers.bzl — gitignored)
tools/           build-time helpers (Python)
tests/           integration and VM tests
platforms/       target platform definitions
patches/         private patch registry
```

### USE flag configuration

USE flags use Buck2's native constraint/modifier system. Configure them with
the `buckos` CLI or edit `config/local_modifiers.bzl` directly:

```sh
buckos use profile desktop           # apply a profile (desktop, server, minimal, ...)
buckos use +wayland -gtk             # toggle individual flags
buckos use package vim +python +lua  # per-package overrides
```

Or use Buck2 modifiers directly:

```sh
buck2 build //packages/linux/core:curl -m desktop           # profile alias
buck2 build //packages/linux/core:curl -m ssl_on -m http2_on  # individual flags
```
