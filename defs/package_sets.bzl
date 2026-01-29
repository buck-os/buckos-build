"""
Package Set system for BuckOs Linux Distribution.

Similar to Gentoo's system profiles and package sets, this provides:
- Predefined package collections for common use cases
- System profiles (minimal, server, desktop, developer, embedded)
- Hierarchical set inheritance
- Integration with USE flag profiles
- Package set operations (union, intersection, difference)

Example usage:
    # Use a predefined system profile
    system_set(
        name = "my-server",
        profile = "server",
        additions = ["//packages/linux/network/vpn/wireguard-tools:wireguard-tools"],
        removals = ["//packages/linux/editors/emacs:emacs"],
    )

    # Create a custom package set
    package_set(
        name = "web-development",
        packages = [
            "//packages/linux/lang/nodejs:nodejs",
            "//packages/linux/lang/python:python",
            "//packages/linux/editors/neovim:neovim",
        ],
        inherits = ["@base"],
    )

    # Combine sets
    combined_set(
        name = "full-stack",
        sets = ["@web-development", "@database-tools"],
    )
"""

load("//defs:use_flags.bzl", "USE_PROFILES")

# =============================================================================
# SET OPERATION HELPERS (Starlark doesn't have native sets)
# =============================================================================

def _make_set(items):
    """Create a dict-based set from a list."""
    return {item: True for item in items}

def _set_to_list(s):
    """Convert a dict-based set to a sorted list."""
    return sorted(s.keys())

def _set_intersection(set1, set2):
    """Return intersection of two dict-based sets."""
    return {k: True for k in set1 if k in set2}

def _set_difference(set1, set2):
    """Return difference of two dict-based sets (set1 - set2)."""
    return {k: True for k in set1 if k not in set2}

def _set_union(set1, set2):
    """Return union of two dict-based sets."""
    result = dict(set1)
    result.update(set2)
    return result

# =============================================================================
# CORE SYSTEM PACKAGES (@system equivalent)
# =============================================================================

# Absolute minimum for a bootable system
# These are the essential @system packages required for a functioning Linux system

# System packages with musl (lightweight C library)
SYSTEM_PACKAGES_MUSL = [
    # Core C library
    "//packages/linux/core/musl:musl",              # lightweight C library

    # Essential system utilities
    "//packages/linux/system/apps/coreutils:coreutils",  # ls, cp, mv, rm, etc
    "//packages/linux/core/util-linux:util-linux",        # mount, fdisk, etc
    "//packages/linux/core/procps-ng:procps-ng",         # ps, top, etc
    "//packages/linux/system/apps/shadow:shadow",  # user/group management
    "//packages/linux/core/file:file",              # file type detection

    # Shell
    "//packages/linux/core/bash:bash",              # default shell

    # Basic libraries needed by most packages
    "//packages/linux/core/zlib:zlib",              # compression library
]

# System packages with glibc (GNU C library - broader compatibility)
SYSTEM_PACKAGES_GLIBC = [
    # Core C library
    "//packages/linux/core/glibc:glibc",             # GNU C library (broader compatibility)

    # Essential system utilities
    "//packages/linux/system/apps/coreutils:coreutils",  # ls, cp, mv, rm, etc
    "//packages/linux/core/util-linux:util-linux",        # mount, fdisk, etc
    "//packages/linux/core/procps-ng:procps-ng",         # ps, top, etc
    "//packages/linux/system/apps/shadow:shadow",  # user/group management
    "//packages/linux/core/file:file",              # file type detection

    # Shell
    "//packages/linux/core/bash:bash",              # default shell

    # Basic libraries needed by most packages
    "//packages/linux/core/zlib:zlib",              # compression library
]

# Default to glibc for maximum compatibility
SYSTEM_PACKAGES = SYSTEM_PACKAGES_GLIBC

# Base packages that should be in almost every installation
BASE_PACKAGES = SYSTEM_PACKAGES + [
    # Core libraries
    "//packages/linux/core/readline:readline",
    "//packages/linux/core/ncurses:ncurses",
    "//packages/linux/core/less:less",
    "//packages/linux/core/libffi:libffi",
    "//packages/linux/core/expat:expat",

    # Shell and terminal
    "//packages/linux/core/bash:bash",

    # Compression
    "//packages/linux/system/libs/compression/bzip2:bzip2",
    "//packages/linux/system/libs/compression/xz:xz",
    "//packages/linux/system/libs/compression/gzip:gzip",
    "//packages/linux/system/apps/tar:tar",

    # System utilities
    "//packages/linux/system/apps/coreutils:coreutils",
    "//packages/linux/system/apps/findutils:findutils",
    "//packages/linux/core/procps-ng:procps-ng",
    "//packages/linux/core/file:file",
    "//packages/linux/system/apps/shadow:shadow",

    # Networking basics
    "//packages/linux/system/libs/crypto/openssl:openssl",
    "//packages/linux/network/curl:curl",
    "//packages/linux/network/iproute2:iproute2",
    "//packages/linux/network/dhcpcd:dhcpcd",
]

# =============================================================================
# PROFILE-BASED PACKAGE SETS
# =============================================================================

# Maps profile names to their package sets
PROFILE_PACKAGE_SETS = {
    # Minimal - Bare essentials only
    "minimal": {
        "description": "Absolute minimum packages for a bootable system",
        "packages": SYSTEM_PACKAGES + [
            "//packages/linux/core/bash:bash",
            "//packages/linux/core/readline:readline",
            "//packages/linux/core/ncurses:ncurses",
        ],
        "inherits": [],
        "use_profile": "minimal",
    },

    # Server - Headless server configuration
    "server": {
        "description": "Server-optimized package set without GUI",
        "packages": BASE_PACKAGES + [
            # Remote access
            "//packages/linux/network/openssh:openssh",

            # Editors
            "//packages/linux/editors/vim:vim",

            # System administration
            "//packages/linux/system/apps/sudo:sudo",
            "//packages/linux/system/apps/tmux:tmux",
            "//packages/linux/system/apps/htop:htop",
            "//packages/linux/system/apps/rsync:rsync",
            "//packages/linux/system/apps/logrotate:logrotate",
            "//packages/linux/system/apps/cronie:cronie",
            "//packages/linux/system/apps/lsof:lsof",
            "//packages/linux/system/apps/strace:strace",

            # Documentation
            "//packages/linux/system/docs:man-db",
            "//packages/linux/system/docs:man-pages",
        ],
        "inherits": [],
        "use_profile": "server",
    },

    # Desktop - Full desktop environment
    "desktop": {
        "description": "Full desktop environment with multimedia support",
        "packages": BASE_PACKAGES + [
            # Remote access
            "//packages/linux/network/openssh:openssh",

            # Editors
            "//packages/linux/editors/vim:vim",
            "//packages/linux/editors/neovim:neovim",

            # System administration
            "//packages/linux/system/apps/sudo:sudo",
            "//packages/linux/system/apps/tmux:tmux",
            "//packages/linux/system/apps/htop:htop",
            "//packages/linux/system/apps/rsync:rsync",
            "//packages/linux/system/apps/logrotate:logrotate",
            "//packages/linux/system/apps/cronie:cronie",

            # Shells
            "//packages/linux/shells/zsh:zsh",

            # Terminals
            "//packages/linux/terminals/alacritty:alacritty",
            "//packages/linux/terminals/foot:foot",

            # Documentation
            "//packages/linux/system/docs:man-db",
            "//packages/linux/system/docs:man-pages",
            "//packages/linux/system/docs:texinfo",

            # Internationalization
            "//packages/linux/dev-libs/misc/gettext:gettext",
        ],
        "inherits": [],
        "use_profile": "desktop",
    },

    # Developer - Development tools and languages
    "developer": {
        "description": "Development-focused with languages, tools, and documentation",
        "packages": BASE_PACKAGES + [
            # Remote access
            "//packages/linux/network/openssh:openssh",

            # Editors
            "//packages/linux/editors/vim:vim",
            "//packages/linux/editors/neovim:neovim",
            "//packages/linux/editors/emacs:emacs",

            # Shells
            "//packages/linux/shells/zsh:zsh",

            # System administration
            "//packages/linux/system/apps/sudo:sudo",
            "//packages/linux/system/apps/tmux:tmux",
            "//packages/linux/system/apps/htop:htop",
            "//packages/linux/system/apps/rsync:rsync",
            "//packages/linux/system/apps/strace:strace",
            "//packages/linux/system/apps/lsof:lsof",

            # Documentation
            "//packages/linux/system/docs:man-db",
            "//packages/linux/system/docs:man-pages",
            "//packages/linux/system/docs:texinfo",
            "//packages/linux/system/docs:groff",
        ],
        "inherits": [],
        "use_profile": "developer",
    },

    # Hardened - Security-focused system
    "hardened": {
        "description": "Security-hardened configuration with minimal attack surface",
        "packages": BASE_PACKAGES + [
            # Remote access (required for server management)
            "//packages/linux/network/openssh:openssh",

            # Minimal editor
            "//packages/linux/editors/vim:vim",

            # System administration
            "//packages/linux/system/apps/sudo:sudo",
            "//packages/linux/system/apps/htop:htop",
            "//packages/linux/system/apps/rsync:rsync",
            "//packages/linux/system/apps/logrotate:logrotate",

            # VPN for secure communications
            "//packages/linux/network/vpn/wireguard-tools:wireguard-tools",
        ],
        "inherits": [],
        "use_profile": "hardened",
    },

    # Embedded - Minimal footprint for embedded systems
    "embedded": {
        "description": "Minimal footprint for embedded and IoT systems",
        "packages": SYSTEM_PACKAGES + [
            "//packages/linux/core/readline:readline",
            # "//packages/linux/network/dropbear:dropbear",  # TODO: Smaller SSH - not packaged yet
        ],
        "inherits": [],
        "use_profile": "minimal",
    },

    # Container - Optimized for container base images
    "container": {
        "description": "Minimal base for container images",
        "packages": SYSTEM_PACKAGES + [
            "//packages/linux/core/bash:bash",
            "//packages/linux/core/readline:readline",
            "//packages/linux/core/ncurses:ncurses",
            "//packages/linux/network/curl:curl",
        ],
        "inherits": [],
        "use_profile": "minimal",
    },
}

# =============================================================================
# TASK-SPECIFIC PACKAGE SETS
# =============================================================================

TASK_PACKAGE_SETS = {
    # Web server
    "web-server": {
        "description": "Packages for running a web server",
        "packages": [
            "//packages/linux/www/servers/nginx:nginx",
        ],
        "inherits": ["server"],
    },

    # Database server
    "database-server": {
        "description": "Database server packages",
        "packages": [
            "//packages/linux/system/libs/database/sqlite:sqlite",
        ],
        "inherits": ["server"],
    },

    # Container host
    "container-host": {
        "description": "Host system for running containers",
        "packages": [
            "//packages/linux/emulation/containers:podman-full",
            "//packages/linux/emulation/containers/podman:buildah",
            "//packages/linux/emulation/containers/podman:skopeo",
        ],
        "inherits": ["server"],
    },

    # Virtualization host
    "virtualization-host": {
        "description": "Host system for virtual machines",
        "packages": [
            "//packages/linux/emulation/hypervisors/qemu:qemu",
            "//packages/linux/emulation/virtualization/libvirt:libvirt",
        ],
        "inherits": ["server"],
    },

    # VPN server
    "vpn-server": {
        "description": "VPN server packages",
        "packages": [
            "//packages/linux/network/vpn/wireguard-tools:wireguard-tools",
            "//packages/linux/network/vpn/openvpn:openvpn",
            "//packages/linux/network/vpn/strongswan:strongswan",
        ],
        "inherits": ["server"],
    },

    # Monitoring
    "monitoring": {
        "description": "System monitoring and observability tools",
        "packages": [
            "//packages/linux/system/apps/htop:htop",
            "//packages/linux/system/apps/lsof:lsof",
            "//packages/linux/system/apps/strace:strace",
        ],
        "inherits": ["server"],
    },

    # Benchmarking
    "benchmarking": {
        "description": "Performance testing and benchmarking tools",
        "packages": [
            "//packages/linux/benchmarks/stress-ng:stress-ng",
            "//packages/linux/benchmarks/fio:fio",
            "//packages/linux/benchmarks/iperf3:iperf3",
            "//packages/linux/benchmarks/hackbench:hackbench",
            "//packages/linux/benchmarks/memtester:memtester",
        ],
        "inherits": ["server"],
    },
}

# =============================================================================
# INIT SYSTEM SETS
# =============================================================================

INIT_SYSTEM_SETS = {
    # systemd - Modern init system and service manager
    "systemd": {
        "description": "systemd init system and service manager",
        "packages": [
            "//packages/linux/system/init:systemd",
        ],
        "inherits": [],
    },

    # OpenRC - Dependency-based init system
    "openrc": {
        "description": "OpenRC dependency-based init system",
        "packages": [
            "//packages/linux/system/init:openrc",
        ],
        "inherits": [],
    },

    # runit - Simple init system with service supervision
    "runit": {
        "description": "runit init system with service supervision",
        "packages": [
            "//packages/linux/system/init:runit",
        ],
        "inherits": [],
    },

    # s6 - Small and secure init system
    "s6": {
        "description": "s6 init system with supervision suite",
        "packages": [
            "//packages/linux/system/init:s6",
            "//packages/linux/system/init:s6-linux-init",
            "//packages/linux/system/init:s6-rc",
            "//packages/linux/system/init:skalibs",
        ],
        "inherits": [],
    },

    # SysVinit - Traditional init system
    "sysvinit": {
        "description": "Traditional SysV init system",
        "packages": [
            "//packages/linux/system/init:sysvinit",
        ],
        "inherits": [],
    },

    # dinit - Service manager and init system
    "dinit": {
        "description": "dinit service manager and init system",
        "packages": [
            "//packages/linux/system/init:dinit",
        ],
        "inherits": [],
    },

    # BusyBox init - Minimal init from BusyBox
    "busybox-init": {
        "description": "BusyBox built-in init system (minimal)",
        "packages": [
            # BusyBox init is part of BusyBox itself, which is in @system
            # This set is empty but defined for consistency
        ],
        "inherits": [],
    },
}

# =============================================================================
# DESKTOP ENVIRONMENT SETS
# =============================================================================

DESKTOP_ENVIRONMENT_SETS = {
    # KDE Plasma
    "kde-desktop": {
        "description": "KDE Plasma desktop environment",
        "packages": [
            "//packages/linux/desktop/kde:kde-plasma",
        ],
        "inherits": ["desktop"],
    },

    # XFCE
    "xfce-desktop": {
        "description": "XFCE lightweight desktop environment",
        "packages": [
            "//packages/linux/desktop/xfce:xfce",
        ],
        "inherits": ["desktop"],
    },

    # Sway (Wayland tiling)
    "sway-desktop": {
        "description": "Sway Wayland compositor with tiling",
        "packages": [
            "//packages/linux/desktop/sway:sway-desktop",
        ],
        "inherits": ["desktop"],
    },

    # Hyprland (Wayland tiling)
    "hyprland-desktop": {
        "description": "Hyprland Wayland compositor",
        "packages": [
            "//packages/linux/desktop/hyprland:hyprland-desktop",
        ],
        "inherits": ["desktop"],
    },

    # i3 (X11 tiling)
    "i3-desktop": {
        "description": "i3 X11 tiling window manager",
        "packages": [
            "//packages/linux/desktop/i3:i3-desktop",
        ],
        "inherits": ["desktop"],
    },
}

# =============================================================================
# LANGUAGE DEVELOPMENT SETS
# =============================================================================

LANGUAGE_DEVELOPMENT_SETS = {
    # Python development
    "python-dev": {
        "description": "Python development environment with tooling",
        "packages": [
            "//packages/linux/lang/python:python:python",
        ],
        "inherits": ["developer"],
    },

    # Node.js development
    "nodejs-dev": {
        "description": "Node.js development environment with npm",
        "packages": [
            "//packages/linux/lang/nodejs:nodejs:nodejs",
        ],
        "inherits": ["developer"],
    },

    # Rust development
    "rust-dev": {
        "description": "Rust development environment with cargo",
        "packages": [
            "//packages/linux/lang/rust:rust",
        ],
        "inherits": ["developer"],
    },

    # Go development
    "go-dev": {
        "description": "Go development environment with tooling",
        "packages": [
            "//packages/linux/lang/go:go",
        ],
        "inherits": ["developer"],
    },

    # C/C++ development
    "cpp-dev": {
        "description": "C/C++ development with GCC/Clang toolchain",
        "packages": [
            "//packages/linux/lang/gcc:gcc",
            "//packages/linux/lang/clang:clang",
            "//packages/linux/lang/binutils:binutils",
            "//packages/linux/dev-tools/build-systems/cmake:cmake",
            "//packages/linux/dev-tools/build-systems/make:make",
            "//packages/linux/dev-tools/build-systems/autoconf:autoconf",
            "//packages/linux/dev-tools/build-systems/automake:automake",
            "//packages/linux/dev-tools/debuggers/gdb:gdb",
            "//packages/linux/dev-tools/build-systems/pkg-config:pkg-config",
        ],
        "inherits": ["developer"],
    },

    # Ruby development
    "ruby-dev": {
        "description": "Ruby development environment with gems",
        "packages": [
            "//packages/linux/lang/ruby:ruby",
        ],
        "inherits": ["developer"],
    },

    # PHP development
    "php-dev": {
        "description": "PHP development environment",
        "packages": [
            "//packages/linux/lang/php:php",
        ],
        "inherits": ["developer"],
    },

    # Zig development
    "zig-dev": {
        "description": "Zig development environment",
        "packages": [
            "//packages/linux/lang/zig:zig",
        ],
        "inherits": ["developer"],
    },

    # Julia development
    "julia-dev": {
        "description": "Julia development for scientific computing",
        "packages": [
            "//packages/linux/lang/julia:julia",
        ],
        "inherits": ["developer"],
    },
}

# =============================================================================
# STAGE3 PACKAGE SETS
# =============================================================================
# Stage3 tarball package sets for bootstrapping new systems.
# Each stage3 variant builds on the previous one:
#   minimal -> base -> developer -> complete

STAGE3_PACKAGE_SETS = {
    # Minimal stage3 - absolute minimum for chroot bootstrap
    "stage3-minimal": {
        "description": "Minimal stage3 for chroot bootstrap (no toolchain)",
        "packages": [
            # Core C library
            "//packages/linux/core/glibc:glibc",
            # Essential utilities
            "//packages/linux/system/apps/coreutils:coreutils",
            "//packages/linux/core/util-linux:util-linux",
            "//packages/linux/core/procps-ng:procps-ng",
            "//packages/linux/system/apps/shadow:shadow",
            "//packages/linux/core/file:file",
            # Shell
            "//packages/linux/core/bash:bash",
            # Terminal
            "//packages/linux/core/readline:readline",
            "//packages/linux/core/ncurses:ncurses",
            "//packages/linux/core/less:less",
            # Compression (required for package management)
            "//packages/linux/system/libs/compression/bzip2:bzip2",
            "//packages/linux/system/libs/compression/xz:xz",
            "//packages/linux/system/libs/compression/gzip:gzip",
            "//packages/linux/system/apps/tar:tar",
            # Basic libraries
            "//packages/linux/core/zlib:zlib",
        ],
        "inherits": [],
        "use_profile": "minimal",
    },

    # Base stage3 - includes GCC toolchain for building packages
    "stage3-base": {
        "description": "Standard stage3 with GCC toolchain for building packages",
        "packages": [
            # Additional core libraries
            "//packages/linux/core/libffi:libffi",
            "//packages/linux/core/expat:expat",
            # Networking basics
            "//packages/linux/system/libs/crypto/openssl:openssl",
            "//packages/linux/network/curl:curl",
            "//packages/linux/network/iproute2:iproute2",
            # Toolchain
            "//packages/linux/lang/gcc:gcc",
            "//packages/linux/lang/binutils:binutils",
            # Build systems
            "//packages/linux/dev-tools/build-systems/make:make",
            "//packages/linux/dev-tools/build-systems/pkg-config:pkg-config",
            "//packages/linux/dev-tools/build-systems/m4:m4",
            "//packages/linux/dev-tools/build-systems/autoconf:autoconf",
            "//packages/linux/dev-tools/build-systems/automake:automake",
            "//packages/linux/dev-tools/build-systems/libtool:libtool",
            # Essential for building (patch, sed, awk, grep)
            "//packages/linux/system/apps/patch:patch",
            "//packages/linux/system/apps/sed:sed",
            "//packages/linux/system/apps/gawk:gawk",
            "//packages/linux/system/apps/grep:grep",
            "//packages/linux/system/apps/diffutils:diffutils",
            "//packages/linux/system/apps/findutils:findutils",
            # Scripting languages (needed for many build systems)
            "//packages/linux/lang/perl:perl",
            "//packages/linux/lang/python:python:python",
        ],
        "inherits": ["stage3-minimal"],
        "use_profile": "server",
    },

    # Developer stage3 - modern build systems and dev tools
    "stage3-developer": {
        "description": "Developer stage3 with modern build systems (cmake, meson)",
        "packages": [
            # Modern build systems
            "//packages/linux/dev-tools/build-systems/cmake:cmake",
            "//packages/linux/dev-tools/build-systems/meson:meson",
            "//packages/linux/dev-tools/build-systems/ninja:ninja",
            # VCS
            "//packages/linux/dev-tools/vcs/git:git",
            # Editors
            "//packages/linux/editors/vim:vim",
            # Debugging
            "//packages/linux/dev-tools/debugging/gdb:gdb",
            # SSH for remote development
            "//packages/linux/network/openssh:openssh",
            # System administration
            "//packages/linux/system/apps/sudo:sudo",
        ],
        "inherits": ["stage3-base"],
        "use_profile": "developer",
    },

    # Complete stage3 - all development tools including Rust/Go/LLVM
    "stage3-complete": {
        "description": "Complete stage3 with all development tools (Rust, Go, LLVM)",
        "packages": [
            # Additional languages
            "//packages/linux/lang/rust:rust",
            "//packages/linux/lang/go:go",
            # LLVM toolchain
            "//packages/linux/dev-tools/compilers/llvm:llvm",
            "//packages/linux/dev-tools/compilers/clang:clang",
            # Additional editors
            "//packages/linux/editors/neovim:neovim:neovim",
        ],
        "inherits": ["stage3-developer"],
        "use_profile": "developer",
    },

    # Musl variants for smaller/static binaries
    "stage3-minimal-musl": {
        "description": "Minimal stage3 with musl libc (smaller, static-friendly)",
        "packages": [
            # Core C library (musl instead of glibc)
            "//packages/linux/core/musl:musl",
            # Essential utilities
            "//packages/linux/system/apps/coreutils:coreutils",
            "//packages/linux/core/util-linux:util-linux",
            "//packages/linux/core/procps-ng:procps-ng",
            "//packages/linux/system/apps/shadow:shadow",
            "//packages/linux/core/file:file",
            # Shell
            "//packages/linux/core/bash:bash",
            # Terminal
            "//packages/linux/core/readline:readline",
            "//packages/linux/core/ncurses:ncurses",
            "//packages/linux/core/less:less",
            # Compression
            "//packages/linux/system/libs/compression/bzip2:bzip2",
            "//packages/linux/system/libs/compression/xz:xz",
            "//packages/linux/system/libs/compression/gzip:gzip",
            "//packages/linux/system/apps/tar:tar",
            # Basic libraries
            "//packages/linux/core/zlib:zlib",
        ],
        "inherits": [],
        "use_profile": "minimal",
    },
}

# =============================================================================
# COMBINED REGISTRY
# =============================================================================

PACKAGE_SETS = {}
PACKAGE_SETS.update(PROFILE_PACKAGE_SETS)
PACKAGE_SETS.update(TASK_PACKAGE_SETS)
PACKAGE_SETS.update(INIT_SYSTEM_SETS)
PACKAGE_SETS.update(DESKTOP_ENVIRONMENT_SETS)
PACKAGE_SETS.update(LANGUAGE_DEVELOPMENT_SETS)
PACKAGE_SETS.update(STAGE3_PACKAGE_SETS)

# =============================================================================
# PACKAGE SET OPERATIONS
# =============================================================================

def _resolve_set_packages(set_name, visited = None):
    """Recursively resolve all packages in a set including inherited sets.

    Args:
        set_name: Name of the package set
        visited: Set of already visited sets (for cycle detection)

    Returns:
        List of all package targets in the set
    """
    if visited == None:
        visited = []

    # Cycle detection
    if set_name in visited:
        fail("Circular inheritance detected in package set: {}".format(set_name))

    # Handle @ prefix for set references
    actual_name = set_name[1:] if set_name.startswith("@") else set_name

    if actual_name not in PACKAGE_SETS:
        fail("Unknown package set: {}".format(actual_name))

    set_info = PACKAGE_SETS[actual_name]
    visited = visited + [set_name]

    # Start with inherited packages
    packages = []
    for inherited in set_info.get("inherits", []):
        packages.extend(_resolve_set_packages(inherited, visited))

    # Add this set's packages
    packages.extend(set_info.get("packages", []))

    # Remove duplicates while preserving order
    seen = {}
    result = []
    for pkg in packages:
        if pkg not in seen:
            seen[pkg] = True
            result.append(pkg)

    return result

def get_set_packages(set_name):
    """Get all packages in a set including inherited packages.

    Args:
        set_name: Name of the package set (with or without @ prefix)

    Returns:
        List of package targets
    """
    return _resolve_set_packages(set_name)

def get_set_info(set_name):
    """Get information about a package set.

    Args:
        set_name: Name of the package set

    Returns:
        Dict with set information or None
    """
    actual_name = set_name[1:] if set_name.startswith("@") else set_name
    return PACKAGE_SETS.get(actual_name)

def list_all_sets():
    """Get list of all available package sets.

    Returns:
        Sorted list of set names
    """
    return sorted(PACKAGE_SETS.keys())

def list_sets_by_type(set_type):
    """Get list of package sets by type.

    Args:
        set_type: "profile", "task", "init", "desktop", or "language"

    Returns:
        List of set names
    """
    if set_type == "profile":
        return sorted(PROFILE_PACKAGE_SETS.keys())
    elif set_type == "task":
        return sorted(TASK_PACKAGE_SETS.keys())
    elif set_type == "init":
        return sorted(INIT_SYSTEM_SETS.keys())
    elif set_type == "desktop":
        return sorted(DESKTOP_ENVIRONMENT_SETS.keys())
    elif set_type == "language":
        return sorted(LANGUAGE_DEVELOPMENT_SETS.keys())
    else:
        return []

# =============================================================================
# SET ARITHMETIC OPERATIONS
# =============================================================================

def union_sets(*set_names):
    """Compute union of multiple package sets.

    Args:
        *set_names: Names of package sets to union

    Returns:
        List of unique package targets
    """
    packages = []
    for name in set_names:
        packages.extend(get_set_packages(name))

    # Remove duplicates
    seen = {}
    result = []
    for pkg in packages:
        if pkg not in seen:
            seen[pkg] = True
            result.append(pkg)

    return result

def intersection_sets(*set_names):
    """Compute intersection of multiple package sets.

    Args:
        *set_names: Names of package sets to intersect

    Returns:
        List of package targets common to all sets
    """
    if not set_names:
        return []

    # Start with first set
    result_set = _make_set(get_set_packages(set_names[0]))

    # Intersect with remaining sets
    for name in set_names[1:]:
        result_set = _set_intersection(result_set, _make_set(get_set_packages(name)))

    return _set_to_list(result_set)

def difference_sets(base_set, *remove_sets):
    """Compute difference (base - others) of package sets.

    Args:
        base_set: Name of base package set
        *remove_sets: Names of sets to subtract

    Returns:
        List of package targets in base but not in remove sets
    """
    result_set = _make_set(get_set_packages(base_set))

    for name in remove_sets:
        result_set = _set_difference(result_set, _make_set(get_set_packages(name)))

    return _set_to_list(result_set)

# =============================================================================
# PACKAGE SET MACROS
# =============================================================================

def package_set(
        name,
        packages = [],
        inherits = [],
        description = "",
        visibility = ["PUBLIC"]):
    """Create a custom package set as a filegroup.

    Args:
        name: Name of the package set
        packages: List of package targets to include
        inherits: List of set names to inherit from (use @name format)
        description: Human-readable description
        visibility: Buck visibility specification

    Example:
        package_set(
            name = "my-tools",
            packages = [
                "//packages/linux/editors/vim:vim",
                "//packages/linux/system/apps/tmux:tmux",
            ],
            inherits = ["@base"],
            description = "My essential tools",
        )
    """
    # Resolve inherited packages
    all_packages = []
    for inherited in inherits:
        all_packages.extend(get_set_packages(inherited))

    # Add direct packages
    all_packages.extend(packages)

    # Remove duplicates
    seen = {}
    unique_packages = []
    for pkg in all_packages:
        if pkg not in seen:
            seen[pkg] = True
            unique_packages.append(pkg)

    native.filegroup(
        name = name,
        srcs = unique_packages,
        visibility = visibility,
    )

def system_set(
        name,
        profile,
        additions = [],
        removals = [],
        description = "",
        visibility = ["PUBLIC"]):
    """Create a system set based on a profile with customizations.

    This is the primary way to create a complete system configuration.

    Args:
        name: Name of the system set
        profile: Base profile (minimal, server, desktop, developer, hardened, embedded, container)
        additions: Additional packages to include
        removals: Packages to exclude from the profile
        description: Human-readable description
        visibility: Buck visibility specification

    Example:
        system_set(
            name = "my-server",
            profile = "server",
            additions = [
                "//packages/linux/network/vpn/wireguard-tools:wireguard-tools",
                "//packages/linux/www/servers/nginx:nginx",
            ],
            removals = [
                "//packages/linux/editors/emacs:emacs",
            ],
            description = "Custom web server configuration",
        )
    """
    if profile not in PROFILE_PACKAGE_SETS:
        fail("Unknown profile: {}. Available: {}".format(
            profile, ", ".join(PROFILE_PACKAGE_SETS.keys())))

    # Get base profile packages
    packages = get_set_packages(profile)

    # Remove unwanted packages
    if removals:
        removal_set = _make_set(removals)
        packages = [p for p in packages if p not in removal_set]

    # Add additional packages
    packages.extend(additions)

    # Remove duplicates
    seen = {}
    unique_packages = []
    for pkg in packages:
        if pkg not in seen:
            seen[pkg] = True
            unique_packages.append(pkg)

    native.filegroup(
        name = name,
        srcs = unique_packages,
        visibility = visibility,
    )

def combined_set(
        name,
        sets,
        additions = [],
        removals = [],
        description = "",
        visibility = ["PUBLIC"]):
    """Combine multiple package sets into one.

    Args:
        name: Name of the combined set
        sets: List of set names to combine (use @name format)
        additions: Additional packages to include
        removals: Packages to exclude
        description: Human-readable description
        visibility: Buck visibility specification

    Example:
        combined_set(
            name = "full-stack-server",
            sets = ["@web-server", "@database-server", "@container-host"],
            additions = ["//packages/linux/network/vpn/wireguard-tools:wireguard-tools"],
            description = "Complete server stack",
        )
    """
    # Union all sets
    packages = union_sets(*sets)

    # Remove unwanted packages
    if removals:
        removal_set = _make_set(removals)
        packages = [p for p in packages if p not in removal_set]

    # Add additional packages
    packages.extend(additions)

    # Remove duplicates
    seen = {}
    unique_packages = []
    for pkg in packages:
        if pkg not in seen:
            seen[pkg] = True
            unique_packages.append(pkg)

    native.filegroup(
        name = name,
        srcs = unique_packages,
        visibility = visibility,
    )

def task_set(
        name,
        task,
        additions = [],
        removals = [],
        description = "",
        visibility = ["PUBLIC"]):
    """Create a package set based on a predefined task.

    Args:
        name: Name of the task set
        task: Task name (web-server, database-server, container-host, etc.)
        additions: Additional packages to include
        removals: Packages to exclude
        description: Human-readable description
        visibility: Buck visibility specification

    Example:
        task_set(
            name = "my-web-server",
            task = "web-server",
            additions = ["//packages/linux/network/vpn/wireguard-tools:wireguard-tools"],
            description = "Web server with VPN",
        )
    """
    if task not in TASK_PACKAGE_SETS:
        fail("Unknown task: {}. Available: {}".format(
            task, ", ".join(TASK_PACKAGE_SETS.keys())))

    packages = get_set_packages(task)

    # Remove unwanted packages
    if removals:
        removal_set = _make_set(removals)
        packages = [p for p in packages if p not in removal_set]

    # Add additional packages
    packages.extend(additions)

    # Remove duplicates
    seen = {}
    unique_packages = []
    for pkg in packages:
        if pkg not in seen:
            seen[pkg] = True
            unique_packages.append(pkg)

    native.filegroup(
        name = name,
        srcs = unique_packages,
        visibility = visibility,
    )

def desktop_set(
        name,
        environment,
        additions = [],
        removals = [],
        description = "",
        visibility = ["PUBLIC"]):
    """Create a desktop package set.

    Args:
        name: Name of the desktop set
        environment: Desktop environment (gnome-desktop, kde-desktop, sway-desktop, etc.)
        additions: Additional packages to include
        removals: Packages to exclude
        description: Human-readable description
        visibility: Buck visibility specification

    Example:
        desktop_set(
            name = "my-gnome",
            environment = "gnome-desktop",
            additions = ["//packages/linux/editors/vscode"],
            description = "GNOME with VS Code",
        )
    """
    if environment not in DESKTOP_ENVIRONMENT_SETS:
        fail("Unknown desktop environment: {}. Available: {}".format(
            environment, ", ".join(DESKTOP_ENVIRONMENT_SETS.keys())))

    packages = get_set_packages(environment)

    # Remove unwanted packages
    if removals:
        removal_set = _make_set(removals)
        packages = [p for p in packages if p not in removal_set]

    # Add additional packages
    packages.extend(additions)

    # Remove duplicates
    seen = {}
    unique_packages = []
    for pkg in packages:
        if pkg not in seen:
            seen[pkg] = True
            unique_packages.append(pkg)

    native.filegroup(
        name = name,
        srcs = unique_packages,
        visibility = visibility,
    )

def language_set(
        name,
        language,
        additions = [],
        removals = [],
        description = "",
        visibility = ["PUBLIC"]):
    """Create a language development package set.

    Args:
        name: Name of the language set
        language: Language name (python-dev, nodejs-dev, rust-dev, go-dev, cpp-dev, etc.)
        additions: Additional packages to include
        removals: Packages to exclude
        description: Human-readable description
        visibility: Buck visibility specification

    Example:
        language_set(
            name = "my-python",
            language = "python-dev",
            additions = ["root//packages/linux/dev-python:pytest"],
            description = "Python with testing tools",
        )
    """
    if language not in LANGUAGE_DEVELOPMENT_SETS:
        fail("Unknown language: {}. Available: {}".format(
            language, ", ".join(LANGUAGE_DEVELOPMENT_SETS.keys())))

    packages = get_set_packages(language)

    # Remove unwanted packages
    if removals:
        removal_set = _make_set(removals)
        packages = [p for p in packages if p not in removal_set]

    # Add additional packages
    packages.extend(additions)

    # Remove duplicates
    seen = {}
    unique_packages = []
    for pkg in packages:
        if pkg not in seen:
            seen[pkg] = True
            unique_packages.append(pkg)

    native.filegroup(
        name = name,
        srcs = unique_packages,
        visibility = visibility,
    )

# =============================================================================
# QUERY HELPERS
# =============================================================================

def get_profile_use_flags(profile_name):
    """Get the USE flag profile associated with a package set profile.

    Args:
        profile_name: Name of the profile

    Returns:
        USE profile name or None
    """
    if profile_name not in PROFILE_PACKAGE_SETS:
        return None

    return PROFILE_PACKAGE_SETS[profile_name].get("use_profile")

def compare_sets(set1, set2):
    """Compare two package sets.

    Args:
        set1: First set name
        set2: Second set name

    Returns:
        Dict with 'only_in_first', 'only_in_second', 'common'
    """
    packages1 = _make_set(get_set_packages(set1))
    packages2 = _make_set(get_set_packages(set2))

    return {
        "only_in_first": _set_to_list(_set_difference(packages1, packages2)),
        "only_in_second": _set_to_list(_set_difference(packages2, packages1)),
        "common": _set_to_list(_set_intersection(packages1, packages2)),
    }

def set_stats():
    """Get statistics about package sets.

    Returns:
        Dict with set statistics
    """
    total_sets = len(PACKAGE_SETS)

    return {
        "total_sets": total_sets,
        "profile_sets": len(PROFILE_PACKAGE_SETS),
        "task_sets": len(TASK_PACKAGE_SETS),
        "init_sets": len(INIT_SYSTEM_SETS),
        "desktop_sets": len(DESKTOP_ENVIRONMENT_SETS),
        "language_sets": len(LANGUAGE_DEVELOPMENT_SETS),
    }

# =============================================================================
# INTEGRATION WITH USE FLAGS
# =============================================================================

def get_recommended_use_flags(set_name):
    """Get recommended USE flags for a package set.

    This returns the USE flags from the associated profile.

    Args:
        set_name: Name of the package set

    Returns:
        Dict with 'enabled' and 'disabled' USE flags
    """
    actual_name = set_name[1:] if set_name.startswith("@") else set_name

    if actual_name not in PACKAGE_SETS:
        return {"enabled": [], "disabled": []}

    use_profile = PACKAGE_SETS[actual_name].get("use_profile")
    if not use_profile or use_profile not in USE_PROFILES:
        return {"enabled": [], "disabled": []}

    profile = USE_PROFILES[use_profile]
    return {
        "enabled": profile.get("enabled", []),
        "disabled": profile.get("disabled", []),
    }
