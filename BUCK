# BuckOs Linux Distribution - Root Build File
# A Buck2-based Linux distribution similar to Gentoo's ebuild system

load("//defs:package_defs.bzl", "rootfs")

# =============================================================================
# Main build targets
# =============================================================================

# Minimal bootable system
alias(
    name = "minimal",
    actual = "//packages/linux/system:buckos-rootfs",
    visibility = ["PUBLIC"],
)

# Complete system with kernel - points to the minimal profile with kernel
alias(
    name = "complete",
    actual = "//:core-packages",
    visibility = ["PUBLIC"],
)

# Individual component aliases
alias(
    name = "kernel",
    actual = "//packages/linux/kernel:default",
    visibility = ["PUBLIC"],
)

alias(
    name = "bootloader",
    actual = "//packages/linux/boot/grub:grub",
    visibility = ["PUBLIC"],
)

# Default shell
alias(
    name = "shell",
    actual = "//packages/linux/core/bash:bash",
    visibility = ["PUBLIC"],
)

# Default terminal
alias(
    name = "terminal",
    actual = "//packages/linux/terminals/foot:foot",
    visibility = ["PUBLIC"],
)

# Default cron
alias(
    name = "cron",
    actual = "//packages/linux/system/apps/cronie:cronie",
    visibility = ["PUBLIC"],
)

# Essential utilities from sys-apps
alias(
    name = "tar",
    actual = "//packages/linux/system/apps/tar:tar",
    visibility = ["PUBLIC"],
)

alias(
    name = "gzip",
    actual = "//packages/linux/system/libs/compression/gzip:gzip",
    visibility = ["PUBLIC"],
)

alias(
    name = "shadow",
    actual = "//packages/linux/system/apps/shadow:shadow",
    visibility = ["PUBLIC"],
)

alias(
    name = "man-db",
    actual = "//packages/linux/system/docs:man-db",
    visibility = ["PUBLIC"],
)

alias(
    name = "texinfo",
    actual = "//packages/linux/system/docs:texinfo",
    visibility = ["PUBLIC"],
)

alias(
    name = "gettext",
    actual = "//packages/linux/dev-libs/misc/gettext:gettext",
    visibility = ["PUBLIC"],
)

# Default privilege escalation
alias(
    name = "sudo",
    actual = "//packages/linux/system/apps/sudo:sudo",
    visibility = ["PUBLIC"],
)

# Default terminal multiplexer
alias(
    name = "multiplexer",
    actual = "//packages/linux/system/apps/tmux:tmux",
    visibility = ["PUBLIC"],
)

# VPN solutions
alias(
    name = "wireguard",
    actual = "//packages/linux/network/vpn/wireguard-tools:wireguard-tools",
    visibility = ["PUBLIC"],
)

alias(
    name = "openvpn",
    actual = "//packages/linux/network/vpn/openvpn:openvpn",
    visibility = ["PUBLIC"],
)

alias(
    name = "strongswan",
    actual = "//packages/linux/network/vpn/strongswan:strongswan",
    visibility = ["PUBLIC"],
)

# Benchmarking tools
alias(
    name = "benchmarks",
    actual = "//packages/linux/benchmarks:all-benchmarks",
    visibility = ["PUBLIC"],
)

# Default init system
alias(
    name = "init",
    actual = "//packages/linux/system/init:systemd",
    visibility = ["PUBLIC"],
)

alias(
    name = "init-s6",
    actual = "//packages/linux/system/init:s6",
    visibility = ["PUBLIC"],
)

# =============================================================================
# Package groups for convenience
# =============================================================================

filegroup(
    name = "core-packages",
    srcs = [
        "//packages/linux/core/musl:musl",
        "//packages/linux/core/cpio:cpio",
        "//packages/linux/core/util-linux:util-linux",
        "//packages/linux/core/zlib:zlib",
    ],
    visibility = ["PUBLIC"],
)

filegroup(
    name = "filesystem-packages",
    srcs = [
        "//packages/linux/core/e2fsprogs:e2fsprogs",
    ],
    visibility = ["PUBLIC"],
)

# Networking packages
filegroup(
    name = "net-packages",
    srcs = [
        "//packages/linux/system/libs/crypto/openssl:openssl",
        "//packages/linux/network/curl:curl",
        "//packages/linux/network/openssh:openssh",
        "//packages/linux/network/iproute2:iproute2",
        "//packages/linux/network/dhcpcd:dhcpcd",
    ],
    visibility = ["PUBLIC"],
)

# VPN packages
filegroup(
    name = "vpn-packages",
    srcs = [
        "//packages/linux/network/vpn/wireguard-tools:wireguard-tools",
        "//packages/linux/network/vpn/openvpn:openvpn",
        "//packages/linux/network/vpn/strongswan:strongswan",
        "//packages/linux/network/vpn/libreswan:libreswan",
        "//packages/linux/network/vpn/openconnect:openconnect",
        "//packages/linux/network/vpn/tinc:tinc",
        "//packages/linux/network/vpn/zerotier:zerotier",
        "//packages/linux/network/vpn/nebula:nebula",
    ],
    visibility = ["PUBLIC"],
)

# Modern VPN solutions
filegroup(
    name = "vpn-modern",
    srcs = [
        "//packages/linux/network/vpn/wireguard-tools:wireguard-tools",
        "//packages/linux/network/vpn/openvpn:openvpn",
        "//packages/linux/network/vpn/strongswan:strongswan",
    ],
    visibility = ["PUBLIC"],
)

# Mesh VPN solutions
filegroup(
    name = "vpn-mesh",
    srcs = [
        "//packages/linux/network/vpn/tinc:tinc",
        "//packages/linux/network/vpn/zerotier:zerotier",
        "//packages/linux/network/vpn/nebula:nebula",
        "//packages/linux/network/vpn/tailscale:tailscale",
    ],
    visibility = ["PUBLIC"],
)

# Editor packages
filegroup(
    name = "editor-packages",
    srcs = [
        "//packages/linux/editors/vim:vim",
        "//packages/linux/editors/neovim:neovim",
        "//packages/linux/editors/emacs:emacs",
    ],
    visibility = ["PUBLIC"],
)

filegroup(
    name = "shell-packages",
    srcs = [
        "//packages/linux/core/bash:bash",
        "//packages/linux/shells/zsh:zsh",
    ],
    visibility = ["PUBLIC"],
)

# Terminal packages
filegroup(
    name = "terminal-packages",
    srcs = [
        "//packages/linux/terminals/alacritty:alacritty",
        "//packages/linux/terminals/foot:foot",
    ],
    visibility = ["PUBLIC"],
)

filegroup(
    name = "sys-apps-packages",
    srcs = [
        "//packages/linux/system/apps/coreutils:coreutils",
        "//packages/linux/system/apps/findutils:findutils",
        "//packages/linux/system/apps/cronie:cronie",
        "//packages/linux/system/apps/sudo:sudo",
        "//packages/linux/system/apps/tmux:tmux",
        "//packages/linux/system/apps/htop:htop",
        "//packages/linux/system/apps/rsync:rsync",
        "//packages/linux/system/apps/logrotate:logrotate",
        "//packages/linux/system/apps/tar:tar",
        "//packages/linux/system/apps/shadow:shadow",
    ],
    visibility = ["PUBLIC"],
)

filegroup(
    name = "benchmark-packages",
    srcs = [
        "//packages/linux/benchmarks/stress-ng:stress-ng",
        "//packages/linux/benchmarks/fio:fio",
        "//packages/linux/benchmarks/iperf3:iperf3",
        "//packages/linux/benchmarks/hackbench:hackbench",
        "//packages/linux/benchmarks/memtester:memtester",
    ],
    visibility = ["PUBLIC"],
)

# Terminal/shell libraries
filegroup(
    name = "shell-libs",
    srcs = [
        "//packages/linux/core/readline:readline",
        "//packages/linux/core/ncurses:ncurses",
        "//packages/linux/core/less:less",
    ],
    visibility = ["PUBLIC"],
)

# Compression utilities
filegroup(
    name = "compression-packages",
    srcs = [
        "//packages/linux/core/zlib:zlib",
        "//packages/linux/core/bzip2:bzip2",
        "//packages/linux/core/xz:xz",
        "//packages/linux/system/libs/compression/gzip:gzip",
        "//packages/linux/system/apps/tar:tar",
    ],
    visibility = ["PUBLIC"],
)

# Documentation packages
filegroup(
    name = "docs-packages",
    srcs = [
        "//packages/linux/system/docs:man-db",
        "//packages/linux/system/docs:texinfo",
        "//packages/linux/system/docs:man-pages",
        "//packages/linux/system/docs:groff",
    ],
    visibility = ["PUBLIC"],
)

# Internationalization packages
filegroup(
    name = "i18n-packages",
    srcs = [
        "//packages/linux/dev-libs/misc/gettext:gettext",
    ],
    visibility = ["PUBLIC"],
)

# System monitoring utilities
filegroup(
    name = "system-packages",
    srcs = [
        "//packages/linux/core/procps-ng:procps-ng",
        "//packages/linux/core/file:file",
    ],
    visibility = ["PUBLIC"],
)

# Development libraries
filegroup(
    name = "dev-libraries",
    srcs = [
        "//packages/linux/core/libffi:libffi",
        "//packages/linux/core/expat:expat",
        "//packages/linux/core/libnl:libnl",
    ],
    visibility = ["PUBLIC"],
)

# Init system packages
filegroup(
    name = "init-packages",
    srcs = [
        "//packages/linux/system/init:systemd",
    ],
    visibility = ["PUBLIC"],
)

filegroup(
    name = "init-lightweight",
    srcs = [
    ],
    visibility = ["PUBLIC"],
)

# =============================================================================
# Desktop environment aliases
# =============================================================================

# Full desktop environments
alias(
    name = "kde-plasma",
    actual = "//packages/linux/desktop/kde:kde-plasma",
    visibility = ["PUBLIC"],
)

alias(
    name = "xfce",
    actual = "//packages/linux/desktop/xfce:xfce",
    visibility = ["PUBLIC"],
)

alias(
    name = "lxqt",
    actual = "//packages/linux/desktop/lxqt:lxqt",
    visibility = ["PUBLIC"],
)

alias(
    name = "cinnamon",
    actual = "//packages/linux/desktop/cinnamon:cinnamon-desktop",
    visibility = ["PUBLIC"],
)

alias(
    name = "mate",
    actual = "//packages/linux/desktop/mate:mate",
    visibility = ["PUBLIC"],
)

alias(
    name = "budgie",
    actual = "//packages/linux/desktop/budgie:budgie",
    visibility = ["PUBLIC"],
)

# Wayland compositors
alias(
    name = "sway",
    actual = "//packages/linux/desktop/sway:sway-desktop",
    visibility = ["PUBLIC"],
)

alias(
    name = "hyprland",
    actual = "//packages/linux/desktop/hyprland:hyprland-desktop",
    visibility = ["PUBLIC"],
)

alias(
    name = "wayfire",
    actual = "//packages/linux/desktop/wayfire:wayfire-desktop",
    visibility = ["PUBLIC"],
)

# X11 window managers
alias(
    name = "i3",
    actual = "//packages/linux/desktop/i3:i3-desktop",
    visibility = ["PUBLIC"],
)

alias(
    name = "bspwm",
    actual = "//packages/linux/desktop/bspwm:bspwm-desktop",
    visibility = ["PUBLIC"],
)

alias(
    name = "awesome",
    actual = "//packages/linux/desktop/awesome:awesome-desktop",
    visibility = ["PUBLIC"],
)

# =============================================================================
# Desktop package groups
# =============================================================================

filegroup(
    name = "desktop-foundation",
    srcs = [
        "//packages/linux/desktop:desktop-foundation",
    ],
    visibility = ["PUBLIC"],
)

filegroup(
    name = "all-desktops",
    srcs = [
        "//packages/linux/desktop:all-desktops",
    ],
    visibility = ["PUBLIC"],
)

filegroup(
    name = "wayland-compositors",
    srcs = [
        "//packages/linux/desktop:wayland-compositors",
    ],
    visibility = ["PUBLIC"],
)

filegroup(
    name = "tiling-desktops",
    srcs = [
        "//packages/linux/desktop:tiling-desktops",
    ],
    visibility = ["PUBLIC"],
)

filegroup(
    name = "monitoring-packages",
    srcs = [
        "//packages/linux/system/apps/htop:htop",
        "//packages/linux/system/apps/lsof:lsof",
        "//packages/linux/system/apps/strace:strace",
        "//packages/linux/core/procps-ng:procps-ng",
    ],
    visibility = ["PUBLIC"],
)

filegroup(
    name = "lightweight-desktops",
    srcs = [
        "//packages/linux/desktop:lightweight-desktops",
    ],
    visibility = ["PUBLIC"],
)

# =============================================================================
# Emulation and Virtualization aliases
# =============================================================================

# QEMU - Full system emulator
alias(
    name = "qemu",
    actual = "//packages/linux/emulation/hypervisors/qemu:qemu",
    visibility = ["PUBLIC"],
)

# libvirt - Virtualization API
alias(
    name = "libvirt",
    actual = "//packages/linux/emulation/virtualization/libvirt:libvirt",
    visibility = ["PUBLIC"],
)

# virt-manager - VM management GUI
alias(
    name = "virt-manager",
    actual = "//packages/linux/emulation/virtualization/virt-manager:virt-manager",
    visibility = ["PUBLIC"],
)


# Docker
alias(
    name = "docker",
    actual = "//packages/linux/emulation/containers:docker-full",
    visibility = ["PUBLIC"],
)

# Podman
alias(
    name = "podman",
    actual = "//packages/linux/emulation/containers:podman-full",
    visibility = ["PUBLIC"],
)

# containerd
alias(
    name = "containerd",
    actual = "//packages/linux/emulation/containers/containerd:containerd",
    visibility = ["PUBLIC"],
)

# Firecracker - Secure microVMs
alias(
    name = "firecracker",
    actual = "//packages/linux/emulation/utilities/firecracker:firecracker",
    visibility = ["PUBLIC"],
)

# Cloud Hypervisor
alias(
    name = "cloud-hypervisor",
    actual = "//packages/linux/emulation/utilities/cloud-hypervisor:cloud-hypervisor",
    visibility = ["PUBLIC"],
)

# crosvm - Chrome OS VMM
alias(
    name = "crosvm",
    actual = "//packages/linux/emulation/utilities/crosvm:crosvm",
    visibility = ["PUBLIC"],
)

# virtme-ng - Fast kernel testing
alias(
    name = "virtme-ng",
    actual = "//packages/linux/emulation/kernel/virtme-ng:virtme-ng",
    visibility = ["PUBLIC"],
)

# =============================================================================
# Cloud Hypervisor Integration
# =============================================================================

# Cloud Hypervisor full stack (CH + virtiofsd + firmware)
alias(
    name = "ch-full",
    actual = "//packages/linux/emulation:cloud-hypervisor-full",
    visibility = ["PUBLIC"],
)

# Cloud Hypervisor minimal (CH + virtiofsd)
alias(
    name = "ch-minimal",
    actual = "//packages/linux/emulation:cloud-hypervisor-minimal",
    visibility = ["PUBLIC"],
)

# Cloud Hypervisor optimized kernel
alias(
    name = "kernel-ch",
    actual = "//packages/linux/kernel/buckos-kernel:buckos-kernel-ch",
    visibility = ["PUBLIC"],
)

# Cloud Hypervisor firmware
alias(
    name = "hypervisor-fw",
    actual = "//packages/linux/boot/rust-hypervisor-firmware:rust-hypervisor-firmware",
    visibility = ["PUBLIC"],
)

# Cloud Hypervisor UEFI firmware
alias(
    name = "edk2-cloudhv",
    actual = "//packages/linux/boot/edk2-cloudhv:edk2-cloudhv",
    visibility = ["PUBLIC"],
)

# Cloud Hypervisor boot scripts
alias(
    name = "ch-boot-direct",
    actual = "//packages/linux/boot/cloud-hypervisor-boot:ch-boot-direct",
    visibility = ["PUBLIC"],
)

alias(
    name = "ch-boot-virtiofs",
    actual = "//packages/linux/boot/cloud-hypervisor-boot:ch-boot-virtiofs",
    visibility = ["PUBLIC"],
)

alias(
    name = "ch-boot-network",
    actual = "//packages/linux/boot/cloud-hypervisor-boot:ch-boot-network",
    visibility = ["PUBLIC"],
)

# Cloud Hypervisor disk images
alias(
    name = "ch-disk-minimal",
    actual = "//packages/linux/system/cloud-hypervisor:ch-minimal-disk",
    visibility = ["PUBLIC"],
)

alias(
    name = "ch-disk-full",
    actual = "//packages/linux/system/cloud-hypervisor:ch-full-disk",
    visibility = ["PUBLIC"],
)

# =============================================================================
# Emulation package groups
# =============================================================================

# Essential virtualization (QEMU + libvirt + virt-manager)
filegroup(
    name = "emulation-essential",
    srcs = [
        "//packages/linux/emulation:essential",
    ],
    visibility = ["PUBLIC"],
)

# =============================================================================
# Container package groups
# =============================================================================

# Core container runtime
filegroup(
    name = "container-runtime",
    srcs = [
        "//packages/linux/system/containers:container-runtime",
    ],
    visibility = ["PUBLIC"],
)

# Server virtualization
filegroup(
    name = "emulation-server",
    srcs = [
        "//packages/linux/emulation:server",
    ],
    visibility = ["PUBLIC"],
)

# Container networking
filegroup(
    name = "container-networking",
    srcs = [
        "//packages/linux/system/containers:container-networking",
    ],
    visibility = ["PUBLIC"],
)

# Desktop virtualization (with GUI)
filegroup(
    name = "emulation-desktop",
    srcs = [
        "//packages/linux/emulation:desktop",
    ],
    visibility = ["PUBLIC"],
)

# Podman ecosystem tools
filegroup(
    name = "podman-tools",
    srcs = [
        "//packages/linux/system/containers:podman-tools",
    ],
    visibility = ["PUBLIC"],
)

# Cloud/microVM hypervisors
filegroup(
    name = "emulation-cloud",
    srcs = [
        "//packages/linux/emulation:cloud",
    ],
    visibility = ["PUBLIC"],
)

# Container utilities and monitoring
filegroup(
    name = "container-utilities",
    srcs = [
        "//packages/linux/system/containers:container-utilities",
    ],
    visibility = ["PUBLIC"],
)

# Development tools for kernel testing
filegroup(
    name = "emulation-development",
    srcs = [
        "//packages/linux/emulation:development",
    ],
    visibility = ["PUBLIC"],
)

# Container security tools
filegroup(
    name = "container-security",
    srcs = [
        "//packages/linux/system/containers:container-security",
    ],
    visibility = ["PUBLIC"],
)

# Container runtimes
filegroup(
    name = "container-packages",
    srcs = [
        "//packages/linux/emulation/containers:all-containers",
    ],
    visibility = ["PUBLIC"],
)

# All emulation packages
filegroup(
    name = "emulation-all",
    srcs = [
        "//packages/linux/emulation:all",
    ],
    visibility = ["PUBLIC"],
)

# Complete container stack
filegroup(
    name = "container-packages-complete",
    srcs = [
        "//packages/linux/system/containers:all-containers",
    ],
    visibility = ["PUBLIC"],
)

# =============================================================================
# System Profile Sets
# =============================================================================

load("//defs:package_sets.bzl", "system_set", "combined_set", "task_set", "desktop_set", "package_set")

# Pre-configured system profiles
system_set(
    name = "system-minimal",
    profile = "minimal",
    description = "Minimal bootable system",
)

system_set(
    name = "system-server",
    profile = "server",
    description = "Standard server configuration",
)

system_set(
    name = "system-desktop",
    profile = "desktop",
    description = "Desktop system with GUI support",
)

system_set(
    name = "system-developer",
    profile = "developer",
    description = "Development workstation",
)

system_set(
    name = "system-hardened",
    profile = "hardened",
    description = "Security-hardened system",
)

system_set(
    name = "system-embedded",
    profile = "embedded",
    description = "Embedded/IoT system",
)

system_set(
    name = "system-container",
    profile = "container",
    description = "Container base image",
)

# =============================================================================
# Task-Specific Sets
# =============================================================================

task_set(
    name = "task-web-server",
    task = "web-server",
    description = "Web server configuration",
)

task_set(
    name = "task-database-server",
    task = "database-server",
    description = "Database server configuration",
)

task_set(
    name = "task-container-host",
    task = "container-host",
    description = "Container host system",
)

task_set(
    name = "task-virtualization-host",
    task = "virtualization-host",
    description = "Virtualization host system",
)

task_set(
    name = "task-vpn-server",
    task = "vpn-server",
    description = "VPN server configuration",
)

task_set(
    name = "task-monitoring",
    task = "monitoring",
    description = "System monitoring tools",
)

task_set(
    name = "task-benchmarking",
    task = "benchmarking",
    description = "Performance benchmarking tools",
)

# =============================================================================
# Desktop Environment Sets
# =============================================================================

desktop_set(
    name = "desktop-kde",
    environment = "kde-desktop",
    description = "KDE Plasma desktop environment",
)

desktop_set(
    name = "desktop-xfce",
    environment = "xfce-desktop",
    description = "XFCE desktop environment",
)

desktop_set(
    name = "desktop-sway",
    environment = "sway-desktop",
    description = "Sway Wayland compositor",
)

desktop_set(
    name = "desktop-hyprland",
    environment = "hyprland-desktop",
    description = "Hyprland Wayland compositor",
)

desktop_set(
    name = "desktop-i3",
    environment = "i3-desktop",
    description = "i3 tiling window manager",
)

# =============================================================================
# Combined Sets (Example Configurations)
# =============================================================================

# Full-stack web server with monitoring
combined_set(
    name = "full-stack-server",
    sets = ["@web-server", "@database-server", "@monitoring"],
    additions = [
        "//packages/linux/network/vpn/wireguard-tools:wireguard-tools",
    ],
    description = "Complete web application server stack",
)

# DevOps workstation
combined_set(
    name = "devops-workstation",
    sets = ["@developer", "@container-host", "@monitoring"],
    description = "DevOps development workstation",
)

# Secure server with VPN
system_set(
    name = "secure-server",
    profile = "hardened",
    additions = [
        "//packages/linux/network/vpn/wireguard-tools:wireguard-tools",
        "//packages/linux/network/vpn/openvpn:openvpn",
    ],
    description = "Hardened server with VPN support",
)

# CI/CD runner
combined_set(
    name = "ci-runner",
    sets = ["@container-host"],
    additions = [
        "//packages/linux/editors/vim:vim",
    ],
    removals = [
        "//packages/linux/system/docs:texinfo",
    ],
    description = "CI/CD runner with container support",
)

# Lightweight server (minimal + SSH)
system_set(
    name = "lightweight-server",
    profile = "minimal",
    additions = [
        "//packages/linux/network/openssh:openssh",
        "//packages/linux/editors/vim:vim",
        "//packages/linux/system/apps/sudo:sudo",
    ],
    description = "Lightweight server with SSH access",
)

# =============================================================================
# Validation Target
# =============================================================================
# Use this to validate all dependencies exist without building:
#   buck2 uquery 'deps("//...")' > /dev/null && echo "All deps valid"
#
# Note: Buck2 doesn't support //... as a dependency, so validation must be done
# via uquery. The command above will fail fast if any dependency doesn't exist.
