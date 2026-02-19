"""
Tooling Integration for BuckOs Package Customization.

This module provides utilities for external tools to:
- Generate package configurations based on system detection
- Export configuration in various formats (JSON, TOML, shell)
- Query available USE flags and their states
- Generate Buck build files with customizations

External tools (like a `buckos` CLI) can use these functions to:
1. Detect system capabilities and generate appropriate USE flags
2. Create profile configurations for different target systems
3. Export package metadata for package managers
4. Generate configuration files from templates

Example workflow:
    1. Tool detects system has AMD GPU -> adds "amdgpu" to USE
    2. Tool detects no sound card -> removes audio USE flags
    3. Tool generates configuration and writes to build config
    4. Buck2 builds packages with the generated configuration
"""

load("//defs:use_flags.bzl",
     "GLOBAL_USE_FLAGS",
     "USE_PROFILES",
     "get_effective_use",
     "use_configure_args",
     "describe_use_flags",
     "format_use_string",
)
load("//defs:package_customize.bzl",
     "package_config",
     "ENV_PRESETS",
     "generate_make_conf",
     "generate_package_use",
)

# =============================================================================
# SYSTEM DETECTION FLAGS
# =============================================================================

# Hardware-related USE flags for system detection
HARDWARE_USE_FLAGS = {
    # CPU features
    "cpu_flags_x86_aes": "AES-NI instruction support",
    "cpu_flags_x86_avx": "AVX instruction support",
    "cpu_flags_x86_avx2": "AVX2 instruction support",
    "cpu_flags_x86_avx512": "AVX-512 instruction support",
    "cpu_flags_x86_sse4_2": "SSE4.2 instruction support",

    # GPU
    "nvidia": "NVIDIA GPU support",
    "amdgpu": "AMD GPU support",
    "intel": "Intel GPU support",
    "nouveau": "Nouveau (open-source NVIDIA) support",

    # Audio
    "audio": "Audio hardware present",
    "bluetooth-audio": "Bluetooth audio support",

    # Network
    "wifi": "WiFi hardware present",
    "bluetooth": "Bluetooth hardware present",

    # Storage
    "nvme": "NVMe storage present",
    "ssd": "SSD storage optimization",

    # Virtualization
    "kvm": "KVM virtualization support",
    "xen": "Xen virtualization support",
    "container": "Container runtime support",
}

# =============================================================================
# CONFIGURATION GENERATION
# =============================================================================

def generate_system_config(
        profile = "default",
        detected_hardware = [],
        detected_features = [],
        user_use_flags = [],
        package_overrides = {},
        env_preset = None,
        target_arch = "x86_64"):
    """Generate a complete system configuration.

    This is the main entry point for tooling to create configurations.

    Args:
        profile: Base profile (minimal, server, desktop, etc.)
        detected_hardware: List of detected hardware USE flags
        detected_features: List of detected system features
        user_use_flags: User-specified USE flags
        package_overrides: Per-package USE flag overrides
        env_preset: Environment preset name
        target_arch: Target architecture

    Returns:
        Complete configuration dict for package_config()

    Example (tooling would call this):
        config = generate_system_config(
            profile = "desktop",
            detected_hardware = ["nvidia", "nvme", "audio", "wifi"],
            detected_features = ["systemd", "pipewire"],
            user_use_flags = ["http2", "-ldap"],
            target_arch = "x86_64",
        )
    """
    # Start with all detected flags
    all_use_flags = list(detected_hardware)
    all_use_flags.extend(detected_features)
    all_use_flags.extend(user_use_flags)

    # Get environment based on preset or defaults
    cflags = ""
    cxxflags = ""
    ldflags = ""

    if env_preset and env_preset in ENV_PRESETS:
        env = ENV_PRESETS[env_preset]
        cflags = env.get("CFLAGS", "")
        cxxflags = env.get("CXXFLAGS", "")
        ldflags = env.get("LDFLAGS", "")
    else:
        # Default optimization based on target
        if target_arch == "x86_64":
            cflags = "-O2 -pipe -march=x86-64"
            cxxflags = "-O2 -pipe -march=x86-64"
        elif target_arch == "aarch64":
            cflags = "-O2 -pipe -march=armv8-a"
            cxxflags = "-O2 -pipe -march=armv8-a"

    return package_config(
        profile = profile,
        use_flags = all_use_flags,
        package_use = package_overrides,
        cflags = cflags,
        cxxflags = cxxflags,
        ldflags = ldflags,
        makeopts = "-j$(nproc)",
    )

# =============================================================================
# CONFIGURATION EXPORT FORMATS
# =============================================================================

def export_config_json(config):
    """Export configuration as JSON string.

    Args:
        config: Configuration from package_config() or generate_system_config()

    Returns:
        JSON-formatted configuration string
    """
    # Build JSON manually (Starlark doesn't have json module)
    lines = ["{"]

    # Profile
    lines.append('  "profile": "{}",'.format(config["profile"]))

    # USE flags
    lines.append('  "use_flags": {')
    lines.append('    "enabled": [{}],'.format(
        ", ".join(['"{}"'.format(f) for f in config["use_flags"]["enabled"]])))
    lines.append('    "disabled": [{}]'.format(
        ", ".join(['"{}"'.format(f) for f in config["use_flags"]["disabled"]])))
    lines.append('  },')

    # Compiler flags
    lines.append('  "cflags": "{}",'.format(config["cflags"]))
    lines.append('  "cxxflags": "{}",'.format(config["cxxflags"]))
    lines.append('  "ldflags": "{}",'.format(config["ldflags"]))
    lines.append('  "makeopts": "{}",'.format(config["makeopts"]))

    # Package USE
    lines.append('  "package_use": {')
    pkg_lines = []
    for pkg, flags in config["package_use"].items():
        enabled = ", ".join(['"{}"'.format(f) for f in flags.get("enabled", [])])
        disabled = ", ".join(['"{}"'.format(f) for f in flags.get("disabled", [])])
        pkg_lines.append('    "{}": {{"enabled": [{}], "disabled": [{}]}}'.format(
            pkg, enabled, disabled))
    lines.append(",\n".join(pkg_lines))
    lines.append('  },')

    # Features
    lines.append('  "features": [{}]'.format(
        ", ".join(['"{}"'.format(f) for f in config["features"]])))

    lines.append("}")
    return "\n".join(lines)

def export_config_toml(config):
    """Export configuration as TOML string.

    Args:
        config: Configuration dict

    Returns:
        TOML-formatted configuration string
    """
    lines = [
        "# BuckOs System Configuration",
        "# Generated by buckos tooling",
        "",
        "[system]",
        'profile = "{}"'.format(config["profile"]),
        "",
        "[build]",
        'cflags = "{}"'.format(config["cflags"]),
        'cxxflags = "{}"'.format(config["cxxflags"]),
        'ldflags = "{}"'.format(config["ldflags"]),
        'makeopts = "{}"'.format(config["makeopts"]),
        "",
        "[use_flags]",
        "enabled = [{}]".format(
            ", ".join(['"{}"'.format(f) for f in config["use_flags"]["enabled"]])),
        "disabled = [{}]".format(
            ", ".join(['"{}"'.format(f) for f in config["use_flags"]["disabled"]])),
        "",
    ]

    # Package USE
    if config["package_use"]:
        lines.append("[package_use]")
        for pkg, flags in config["package_use"].items():
            all_flags = list(flags.get("enabled", []))
            all_flags.extend(["-" + f for f in flags.get("disabled", [])])
            lines.append('{} = [{}]'.format(
                pkg, ", ".join(['"{}"'.format(f) for f in all_flags])))
        lines.append("")

    return "\n".join(lines)

def export_config_shell(config):
    """Export configuration as shell environment variables.

    This can be sourced by build scripts.

    Args:
        config: Configuration dict

    Returns:
        Shell script string
    """
    lines = [
        "#!/bin/bash",
        "# BuckOs Build Configuration",
        "# Source this file to set build environment",
        "",
        "# Profile",
        'export BUCKOS_PROFILE="{}"'.format(config["profile"]),
        "",
        "# Compiler flags",
        'export CFLAGS="{}"'.format(config["cflags"]),
        'export CXXFLAGS="{}"'.format(config["cxxflags"]),
        'export LDFLAGS="{}"'.format(config["ldflags"]),
        'export MAKEOPTS="{}"'.format(config["makeopts"]),
        "",
        "# USE flags",
        'export USE="{}"'.format(
            " ".join(config["use_flags"]["enabled"] +
                    ["-" + f for f in config["use_flags"]["disabled"]])),
        "",
    ]

    return "\n".join(lines)

def export_buck_config(config, output_file = ".buckconfig.local"):
    """Generate a .buckconfig snippet for USE flag configuration.

    Args:
        config: Configuration dict
        output_file: Output filename

    Returns:
        INI-format buckconfig string
    """
    lines = [
        "# Auto-generated BuckOs USE flag configuration",
        "# Generated by buckos tooling based on system detection",
        "# Profile: {}".format(config["profile"]),
        "",
        "[use]",
    ]

    # USE flags
    for flag in sorted(config["use_flags"]["enabled"]):
        lines.append("  {} = true".format(flag))
    for flag in sorted(config["use_flags"]["disabled"]):
        lines.append("  {} = false".format(flag))

    # Package USE
    if config["package_use"]:
        lines.append("")
        for pkg, flags in sorted(config["package_use"].items()):
            lines.append("[use.{}]".format(pkg))
            for f in sorted(flags.get("enabled", [])):
                lines.append("  {} = true".format(f))
            for f in sorted(flags.get("disabled", [])):
                lines.append("  {} = false".format(f))

    lines.append("")

    return "\n".join(lines)

# =============================================================================
# PACKAGE METADATA QUERIES
# =============================================================================

def get_available_use_flags():
    """Get all available global USE flags.

    Returns:
        Dict of flag name to description
    """
    all_flags = dict(GLOBAL_USE_FLAGS)
    all_flags.update(HARDWARE_USE_FLAGS)
    return all_flags

def get_available_profiles():
    """Get all available profiles with descriptions.

    Returns:
        Dict of profile name to profile info
    """
    result = {}
    for name, profile in USE_PROFILES.items():
        result[name] = {
            "description": profile["description"],
            "enabled_count": len(profile["enabled"]),
            "disabled_count": len(profile["disabled"]),
        }
    return result

def get_env_presets():
    """Get all available environment presets.

    Returns:
        Dict of preset names to their configurations
    """
    return ENV_PRESETS

def query_package_use(package_name, iuse, config = None):
    """Query effective USE flags for a package.

    Reads flags from .buckconfig [use] and [use.PKGNAME] sections.

    Args:
        package_name: Package name
        iuse: Package's supported USE flags
        config: Unused (kept for API compatibility)

    Returns:
        Dict with USE flag information for the package
    """
    effective = get_effective_use(
        package_name,
        iuse,
        [],  # No package defaults in query
    )

    return {
        "package": package_name,
        "effective_use": effective,
        "formatted": format_use_string(iuse, effective),
    }

# =============================================================================
# SYSTEM DETECTION HELPERS
# =============================================================================

def detect_cpu_flags_x86():
    """Generate shell script to detect CPU flags.

    Returns:
        Shell script that outputs detected CPU USE flags
    """
    return '''#!/bin/bash
# Detect x86 CPU flags and output as USE flags
flags=""

if grep -q "aes" /proc/cpuinfo; then
    flags="$flags cpu_flags_x86_aes"
fi

if grep -q "avx2" /proc/cpuinfo; then
    flags="$flags cpu_flags_x86_avx2"
elif grep -q "avx " /proc/cpuinfo; then
    flags="$flags cpu_flags_x86_avx"
fi

if grep -q "avx512" /proc/cpuinfo; then
    flags="$flags cpu_flags_x86_avx512"
fi

if grep -q "sse4_2" /proc/cpuinfo; then
    flags="$flags cpu_flags_x86_sse4_2"
fi

echo $flags
'''

def detect_gpu():
    """Generate shell script to detect GPU.

    Returns:
        Shell script that outputs detected GPU USE flags
    """
    return '''#!/bin/bash
# Detect GPU and output as USE flags
flags=""

if lspci | grep -qi nvidia; then
    flags="$flags nvidia"
fi

if lspci | grep -qi "AMD.*VGA\|Radeon"; then
    flags="$flags amdgpu"
fi

if lspci | grep -qi "Intel.*Graphics"; then
    flags="$flags intel"
fi

echo $flags
'''

def detect_audio():
    """Generate shell script to detect audio hardware.

    Returns:
        Shell script that outputs detected audio USE flags
    """
    return '''#!/bin/bash
# Detect audio hardware
flags=""

if [ -d /proc/asound ] || aplay -l 2>/dev/null | grep -q card; then
    flags="$flags audio alsa"

    # Check for PulseAudio or PipeWire
    if command -v pipewire &>/dev/null; then
        flags="$flags pipewire"
    elif command -v pulseaudio &>/dev/null; then
        flags="$flags pulseaudio"
    fi
fi

echo $flags
'''

def detect_init_system():
    """Generate shell script to detect init system.

    Returns:
        Shell script that outputs init system USE flags
    """
    return '''#!/bin/bash
# Detect init system
flags=""

if command -v systemctl &>/dev/null && systemctl --version &>/dev/null; then
    flags="$flags systemd"
elif [ -f /sbin/openrc ]; then
    flags="$flags openrc"
fi

echo $flags
'''

def generate_detection_script():
    """Generate a complete system detection script.

    This script can be run by tooling to detect all system features.

    Returns:
        Complete shell script for system detection
    """
    return '''#!/bin/bash
# BuckOs System Detection Script
# Run this to detect system capabilities for USE flag configuration

echo "# BuckOs System Detection"
echo "# Run: buckos configure --auto"
echo ""

# CPU flags
echo "CPU_FLAGS=$({})".format(detect_cpu_flags_x86().replace("\n", " "))

# GPU
echo "GPU_FLAGS=$({})".format(detect_gpu().replace("\n", " "))

# Audio
echo "AUDIO_FLAGS=$({})".format(detect_audio().replace("\n", " "))

# Init system
echo "INIT_FLAGS=$({})".format(detect_init_system().replace("\n", " "))

# Combine all
echo ""
echo "DETECTED_USE=\"$CPU_FLAGS $GPU_FLAGS $AUDIO_FLAGS $INIT_FLAGS\""
'''

# =============================================================================
# TOOLING COMMAND HELPERS
# =============================================================================

def cmd_list_use_flags(category = None):
    """Generate output for 'buckos use-flags list' command.

    Args:
        category: Optional category filter

    Returns:
        Formatted string listing USE flags
    """
    flags = get_available_use_flags()
    lines = ["Available USE flags:", ""]

    # Group by category
    categories = {
        "build": ["debug", "doc", "examples", "static", "static-libs", "test", "lto", "pgo", "native"],
        "security": ["caps", "hardened", "pie", "seccomp", "selinux", "ssp"],
        "network": ["ipv6", "ssl", "gnutls", "libressl", "nss", "http2", "curl"],
        "compression": ["brotli", "bzip2", "lz4", "lzma", "zlib", "zstd"],
        "graphics": ["X", "wayland", "opengl", "vulkan", "egl", "gtk", "qt5", "qt6", "cairo", "pango"],
        "audio": ["alsa", "pulseaudio", "pipewire", "ffmpeg", "gstreamer", "v4l"],
        "language": ["python", "perl", "ruby", "lua", "tcl", "java"],
        "database": ["mysql", "postgres", "sqlite", "berkdb", "ldap"],
        "system": ["acl", "attr", "dbus", "fam", "inotify", "pam", "systemd", "udev"],
    }

    for cat_name, cat_flags in sorted(categories.items()):
        if category and cat_name != category:
            continue

        lines.append("{}:".format(cat_name.upper()))
        for flag in cat_flags:
            if flag in flags:
                lines.append("  {:20} {}".format(flag, flags[flag]))
        lines.append("")

    return "\n".join(lines)

def cmd_show_profile(profile_name):
    """Generate output for 'buckos profile show' command.

    Args:
        profile_name: Profile to show

    Returns:
        Formatted string with profile information
    """
    if profile_name not in USE_PROFILES:
        return "Unknown profile: {}".format(profile_name)

    profile = USE_PROFILES[profile_name]
    lines = [
        "Profile: {}".format(profile_name),
        "",
        "Description: {}".format(profile["description"]),
        "",
        "Enabled USE flags:",
        "  {}".format(" ".join(sorted(profile["enabled"]))),
        "",
        "Disabled USE flags:",
        "  {}".format(" ".join(sorted(profile["disabled"]))),
    ]

    return "\n".join(lines)

def cmd_generate_config(profile, use_flags, output_format = "buckconfig"):
    """Generate output for 'buckos configure' command.

    Args:
        profile: Base profile
        use_flags: Additional USE flags
        output_format: Output format (buckconfig, json, toml, shell)

    Returns:
        Configuration in requested format
    """
    config = generate_system_config(
        profile = profile,
        user_use_flags = use_flags,
    )

    if output_format == "json":
        return export_config_json(config)
    elif output_format == "toml":
        return export_config_toml(config)
    elif output_format == "shell":
        return export_config_shell(config)
    else:  # buckconfig
        return export_buck_config(config)
