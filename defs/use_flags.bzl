"""
USE Flag system for BuckOs Linux Distribution.

Similar to Gentoo's USE flags, this provides:
- Global USE flag definitions with descriptions
- Per-package USE flag customization via .buckconfig
- Conditional dependencies based on USE flags
- Build configuration profiles (minimal, default, full)
- USE flag expansion and inheritance

Configuration is read from .buckconfig sections:
  [use]            — global flag defaults (ssl = true, debug = false, etc.)
  [use.PKGNAME]    — per-package overrides

Resolution order (later overrides earlier):
  1. Package use_defaults (from macro param)
  2. Global .buckconfig [use] section
  3. Per-package .buckconfig [use.PKGNAME] section

"unset" (absent key) means fall through to the previous layer.
"true"/"1"/"yes" enables; "false"/"0"/"no" disables.

Example usage:
    autotools_package(
        name = "curl",
        version = "8.5.0",
        src_uri = "https://curl.se/download/curl-8.5.0.tar.xz",
        sha256 = "...",
        iuse = ["ssl", "gnutls", "http2", "zstd", "brotli", "ipv6", "ldap"],
        use_defaults = ["ssl", "http2", "ipv6"],
        use_deps = {
            "ssl": ["//packages/linux/dev-libs/openssl"],
            "gnutls": ["//packages/linux/system/libs/crypto/gnutls"],
            "http2": ["//packages/linux/system/libs/network/nghttp2"],
            "zstd": ["//packages/linux/system/libs/compression/zstd"],
            "brotli": ["//packages/linux/system/libs/compression/brotli"],
        },
        use_configure = {
            "ssl": "--with-ssl",
            "-ssl": "--without-ssl",
            "gnutls": "--with-gnutls",
            "http2": "--with-nghttp2",
            "zstd": "--with-zstd",
            "brotli": "--with-brotli",
            "ipv6": "--enable-ipv6",
            "-ipv6": "--disable-ipv6",
            "ldap": "--enable-ldap",
            "-ldap": "--disable-ldap",
        },
    )

    # .buckconfig
    # [use]
    # ssl = true
    # ipv6 = true
    #
    # [use.curl]
    # gnutls = true
    # ssl = false
"""

# =============================================================================
# GLOBAL USE FLAG REGISTRY
# =============================================================================

# Global USE flag definitions - maps flag name to description
GLOBAL_USE_FLAGS = {
    # Build options
    "debug": "Enable debugging symbols and assertions",
    "doc": "Build and install documentation",
    "examples": "Install example files",
    "static": "Build static libraries",
    "static-libs": "Build static libraries instead of shared",
    "test": "Enable test suite during build",
    "verify-signatures": "Verify GPG signatures on source downloads",

    # Optimization
    "lto": "Enable Link Time Optimization",
    "pgo": "Enable Profile Guided Optimization",
    "native": "Optimize for the current CPU architecture",

    # Security
    "caps": "Use Linux capabilities library",
    "hardened": "Enable security hardening features",
    "pie": "Build position independent executables",
    "seccomp": "Enable seccomp sandboxing",
    "selinux": "Enable SELinux support",
    "ssp": "Enable stack smashing protection",

    # Networking
    "ipv6": "Enable IPv6 support",
    "ssl": "Enable SSL/TLS support (typically OpenSSL)",
    "gnutls": "Enable GnuTLS support",
    "libressl": "Use LibreSSL instead of OpenSSL",
    "nss": "Use Mozilla NSS for crypto",
    "http2": "Enable HTTP/2 support",
    "curl": "Use libcurl for HTTP operations",

    # Compression
    "brotli": "Enable Brotli compression support",
    "bzip2": "Enable bzip2 compression support",
    "lz4": "Enable LZ4 compression support",
    "lzma": "Enable LZMA compression support",
    "zlib": "Enable zlib compression support",
    "zstd": "Enable Zstandard compression support",

    # Graphics & Display
    "X": "Enable X11 support",
    "wayland": "Enable Wayland support",
    "opengl": "Enable OpenGL support",
    "vulkan": "Enable Vulkan support",
    "egl": "Enable EGL support",
    "gtk": "Enable GTK+ toolkit support",
    "qt5": "Enable Qt5 toolkit support",
    "qt6": "Enable Qt6 toolkit support",
    "cairo": "Enable Cairo graphics library",
    "pango": "Enable Pango text rendering",
    "splash": "Enable boot splash screen generation",

    # Audio & Video
    "alsa": "Enable ALSA audio support",
    "pulseaudio": "Enable PulseAudio support",
    "pipewire": "Enable PipeWire support",
    "ffmpeg": "Enable FFmpeg support",
    "gstreamer": "Enable GStreamer support",
    "v4l": "Enable Video4Linux support",

    # Language bindings
    "python": "Build Python bindings",
    "perl": "Build Perl bindings",
    "ruby": "Build Ruby bindings",
    "lua": "Build Lua bindings",
    "tcl": "Build Tcl bindings",
    "java": "Build Java bindings",

    # Database
    "mysql": "Enable MySQL/MariaDB support",
    "postgres": "Enable PostgreSQL support",
    "sqlite": "Enable SQLite support",
    "berkdb": "Enable Berkeley DB support",
    "ldap": "Enable LDAP support",

    # Authentication & Security Extensions
    "kerberos": "Enable Kerberos authentication support",
    "libedit": "Use libedit for line editing",
    "dnssec": "Enable DNSSEC validation support",
    "gssapi": "Enable GSSAPI authentication",

    # System features
    "acl": "Enable Access Control Lists support",
    "attr": "Enable extended attributes support",
    "dbus": "Enable D-Bus message bus support",
    "fam": "Enable FAM/Gamin file monitoring",
    "inotify": "Enable inotify file monitoring",
    "pam": "Enable PAM authentication support",
    "systemd": "Enable systemd integration",
    "udev": "Enable udev device management",

    # Distribution compatibility
    "fedora": "Enable Fedora compatibility mode (FHS layout, RPM support, Fedora build flags)",

    # Text & Localization
    "icu": "Enable ICU library for Unicode",
    "idn": "Enable IDN (internationalized domain names)",
    "nls": "Enable native language support",
    "unicode": "Enable Unicode support",
    "pcre": "Use PCRE for regular expressions",
    "pcre2": "Use PCRE2 for regular expressions",

    # Misc
    "ncurses": "Enable ncurses TUI support",
    "readline": "Enable readline support",
    "threads": "Enable multi-threading support",
    "xml": "Enable XML support",
    "json": "Enable JSON support",
    "yaml": "Enable YAML support",

    # Provenance & Supply Chain
    "provenance": "Embed source provenance metadata in build artifacts",
    "slsa": "Generate SLSA provenance attestations",
}

# =============================================================================
# USE FLAG PROFILES
# =============================================================================

# Predefined profiles for common use cases
USE_PROFILES = {
    # Minimal system - bare essentials
    "minimal": {
        "enabled": [
            "ipv6",
            "ssl",
            "zlib",
        ],
        "disabled": [
            "X", "wayland", "gtk", "qt5", "qt6",
            "debug", "doc", "examples", "test",
            "pulseaudio", "pipewire", "alsa",
            "python", "perl", "ruby", "lua",
        ],
        "description": "Minimal system with essential features only",
    },

    # Server profile - headless server optimizations
    "server": {
        "enabled": [
            "ipv6", "ssl", "http2",
            "zlib", "zstd", "lz4",
            "acl", "attr", "caps",
            "hardened", "pie", "ssp",
            "threads", "pam",
            "postgres", "mysql", "sqlite",
        ],
        "disabled": [
            "X", "wayland", "gtk", "qt5", "qt6",
            "opengl", "vulkan",
            "pulseaudio", "pipewire", "alsa",
            "debug",
        ],
        "description": "Server-optimized profile without GUI",
    },

    # Desktop profile - full desktop experience
    "desktop": {
        "enabled": [
            "X", "wayland",
            "opengl", "vulkan", "egl",
            "gtk", "qt5",
            "pulseaudio", "pipewire",
            "ipv6", "ssl", "http2",
            "zlib", "zstd", "brotli",
            "unicode", "icu", "nls",
            "dbus", "udev",
            "ffmpeg", "gstreamer",
            "cairo", "pango",
        ],
        "disabled": [
            "debug", "static",
            "minimal",
        ],
        "description": "Full desktop environment with multimedia",
    },

    # Developer profile - development tools enabled
    "developer": {
        "enabled": [
            "debug", "doc", "examples", "test",
            "python", "perl", "ruby",
            "git", "subversion",
            "xml", "json", "yaml",
        ],
        "disabled": [],
        "description": "Development-focused with documentation and tests",
    },

    # Hardened profile - security focus
    "hardened": {
        "enabled": [
            "hardened", "pie", "ssp",
            "caps", "seccomp", "selinux",
            "acl", "attr",
            "ssl",
        ],
        "disabled": [
            "debug",
        ],
        "description": "Security-hardened configuration",
    },

    # Default profile - reasonable defaults
    "default": {
        "enabled": [
            "ipv6", "ssl", "http2",
            "zlib", "bzip2",
            "unicode", "nls",
            "readline", "ncurses",
            "threads",
            "pcre2",
        ],
        "disabled": [
            "debug",
            "static",
        ],
        "description": "Balanced default configuration",
    },
}

# =============================================================================
# USE FLAG RESOLUTION (reads .buckconfig)
# =============================================================================

_TRUTHY = ["true", "1", "yes"]
_FALSY = ["false", "0", "no"]

def get_effective_use(package_name, iuse, use_defaults):
    """Calculate effective USE flags for a package.

    Resolution order (later overrides earlier):
    1. Package use_defaults (from macro param)
    2. Global .buckconfig [use] section
    3. Per-package .buckconfig [use.PKGNAME] section

    Args:
        package_name: Package name
        iuse: List of USE flags the package supports
        use_defaults: Default USE flags for this package

    Returns:
        List of enabled USE flags for this package
    """
    # Layer 1: package defaults
    effective = {flag: True for flag in use_defaults} if use_defaults else {}

    # Layer 2: global buckconfig [use] section
    for flag in iuse:
        val = read_config("use", flag, "")
        if val.lower() in _TRUTHY:
            effective[flag] = True
        elif val.lower() in _FALSY:
            effective.pop(flag, None)
        # "" (unset) = no override, keep use_defaults

    # Layer 3: per-package buckconfig [use.PKGNAME] section
    for flag in iuse:
        val = read_config("use." + package_name, flag, "")
        if val.lower() in _TRUTHY:
            effective[flag] = True
        elif val.lower() in _FALSY:
            effective.pop(flag, None)

    return sorted(effective.keys())

# =============================================================================
# USE FLAG CONDITIONAL HELPERS
# =============================================================================

def use_conditional(flag, if_enabled, if_disabled = None):
    """Return value based on USE flag state.

    Args:
        flag: USE flag name
        if_enabled: Value if flag is enabled
        if_disabled: Value if flag is disabled (default: None)

    Returns:
        Dict with conditional information for build-time resolution
    """
    return {
        "type": "use_conditional",
        "flag": flag,
        "if_enabled": if_enabled,
        "if_disabled": if_disabled,
    }

def resolve_use_conditionals(items, enabled_flags):
    """Resolve USE flag conditionals to actual values.

    Args:
        items: List of items, some may be use_conditional dicts
        enabled_flags: Set of enabled USE flags

    Returns:
        Resolved list of items
    """
    result = []

    for item in items:
        if isinstance(item, dict) and item.get("type") == "use_conditional":
            flag = item["flag"]
            if flag in enabled_flags:
                if item["if_enabled"]:
                    if isinstance(item["if_enabled"], list):
                        result.extend(item["if_enabled"])
                    else:
                        result.append(item["if_enabled"])
            else:
                if item.get("if_disabled"):
                    if isinstance(item["if_disabled"], list):
                        result.extend(item["if_disabled"])
                    else:
                        result.append(item["if_disabled"])
        else:
            result.append(item)

    return result

# =============================================================================
# USE FLAG DEPENDENCY RESOLUTION
# =============================================================================

def use_dep(deps_map, enabled_flags):
    """Resolve USE-flag conditional dependencies.

    Args:
        deps_map: Dict mapping USE flag to dependencies
                  Example: {"ssl": ["//pkg/openssl"], "gnutls": ["//pkg/gnutls"]}
        enabled_flags: List of enabled USE flags

    Returns:
        List of resolved dependencies
    """
    result = []
    enabled_set = {f: True for f in enabled_flags}

    for flag, deps in deps_map.items():
        if flag in enabled_set:
            if isinstance(deps, list):
                result.extend(deps)
            else:
                result.append(deps)

    return result

def use_required_deps(deps_map, enabled_flags):
    """Get dependencies with USE flag requirements.

    Used for dependencies that require specific USE flags on the dep.

    Args:
        deps_map: Dict mapping dep to required USE flags
                  Example: {"//pkg/openssl": ["ssl"], "//pkg/curl": ["ssl", "http2"]}
        enabled_flags: List of enabled USE flags

    Returns:
        List of dependency targets with USE requirements
    """
    result = []
    enabled_set = {f: True for f in enabled_flags}

    for dep, required_flags in deps_map.items():
        # Check if all required flags are enabled
        all_present = True
        for f in required_flags:
            if f not in enabled_set:
                all_present = False
                break
        if all_present:
            result.append(dep)

    return result

# =============================================================================
# USE FLAG CONFIGURE ARGUMENT GENERATION
# =============================================================================

def use_configure_args(use_configure, enabled_flags):
    """Generate configure arguments based on USE flags.

    Args:
        use_configure: Dict mapping USE flag to configure arg
                       Use "-flag" for disabled state
                       Example: {
                           "ssl": "--with-ssl",
                           "-ssl": "--without-ssl",
                           "debug": "--enable-debug",
                       }
        enabled_flags: List of enabled USE flags

    Returns:
        List of configure arguments
    """
    result = []
    enabled_set = {f: True for f in enabled_flags}

    for flag, arg in use_configure.items():
        if flag.startswith("-"):
            # This is a disabled flag config
            actual_flag = flag[1:]
            if actual_flag not in enabled_set:
                result.append(arg)
        else:
            # This is an enabled flag config
            if flag in enabled_set:
                result.append(arg)

    return result

def use_enable(flag, option = None, enabled_flags = None):
    """Generate --enable-X or --disable-X based on USE flag.

    Args:
        flag: USE flag name
        option: Configure option name (defaults to flag name)
        enabled_flags: List of enabled USE flags

    Returns:
        Configure argument string
    """
    opt = option if option else flag
    if enabled_flags and flag in enabled_flags:
        return "--enable-{}".format(opt)
    return "--disable-{}".format(opt)

def use_with(flag, option = None, enabled_flags = None):
    """Generate --with-X or --without-X based on USE flag.

    Args:
        flag: USE flag name
        option: Configure option name (defaults to flag name)
        enabled_flags: List of enabled USE flags

    Returns:
        Configure argument string
    """
    opt = option if option else flag
    if enabled_flags and flag in enabled_flags:
        return "--with-{}".format(opt)
    return "--without-{}".format(opt)

# =============================================================================
# CARGO/RUST USE FLAG SUPPORT
# =============================================================================

def use_cargo_features(use_features, enabled_flags):
    """Map USE flags to Cargo features.

    Args:
        use_features: Dict mapping USE flag to Cargo feature name(s)
                      Example: {"ssl": "tls", "http2": ["http2", "h2"]}
        enabled_flags: List of enabled USE flags

    Returns:
        List of Cargo features to enable
    """
    features = []
    enabled_set = {f: True for f in enabled_flags}

    for flag, cargo_features in use_features.items():
        if flag in enabled_set:
            if isinstance(cargo_features, list):
                features.extend(cargo_features)
            else:
                features.append(cargo_features)

    return features

def use_cargo_args(use_features, enabled_flags, extra_args = []):
    """Generate Cargo build arguments based on USE flags.

    Args:
        use_features: Dict mapping USE flag to Cargo feature
        enabled_flags: List of enabled USE flags
        extra_args: Additional Cargo arguments

    Returns:
        List of Cargo arguments
    """
    args = list(extra_args)
    features = use_cargo_features(use_features, enabled_flags)

    if features:
        args.append("--features={}".format(",".join(features)))
    else:
        # If no features, build with no default features
        args.append("--no-default-features")

    return args

# =============================================================================
# CMAKE USE FLAG SUPPORT
# =============================================================================

def use_cmake_options(use_options, enabled_flags):
    """Map USE flags to CMake options.

    Args:
        use_options: Dict mapping USE flag to CMake option name(s)
                     Example: {"ssl": "ENABLE_SSL", "tests": "BUILD_TESTING"}
        enabled_flags: List of enabled USE flags

    Returns:
        List of CMake options (-DENABLE_SSL=ON, etc.)
    """
    options = []
    enabled_set = {f: True for f in enabled_flags}

    for flag, cmake_opt in use_options.items():
        if isinstance(cmake_opt, list):
            for opt in cmake_opt:
                if flag in enabled_set:
                    options.append("-D{}=ON".format(opt))
                else:
                    options.append("-D{}=OFF".format(opt))
        else:
            if flag in enabled_set:
                options.append("-D{}=ON".format(cmake_opt))
            else:
                options.append("-D{}=OFF".format(cmake_opt))

    return options

# =============================================================================
# MESON USE FLAG SUPPORT
# =============================================================================

def use_meson_options(use_options, enabled_flags):
    """Map USE flags to Meson options.

    Args:
        use_options: Dict mapping USE flag to Meson option name(s)
                     Example: {"ssl": "ssl", "tests": "tests"}
        enabled_flags: List of enabled USE flags

    Returns:
        List of Meson options (-Dssl=enabled, etc.)
    """
    options = []
    enabled_set = {f: True for f in enabled_flags}

    for flag, meson_opt in use_options.items():
        if isinstance(meson_opt, list):
            for opt in meson_opt:
                if flag in enabled_set:
                    options.append("-D{}=enabled".format(opt))
                else:
                    options.append("-D{}=disabled".format(opt))
        else:
            if flag in enabled_set:
                options.append("-D{}=enabled".format(meson_opt))
            else:
                options.append("-D{}=disabled".format(meson_opt))

    return options

# =============================================================================
# GO USE FLAG SUPPORT
# =============================================================================

def use_go_tags(use_tags, enabled_flags):
    """Map USE flags to Go build tags.

    Args:
        use_tags: Dict mapping USE flag to Go build tag(s)
                  Example: {"ssl": "openssl", "sqlite": "sqlite"}
        enabled_flags: List of enabled USE flags

    Returns:
        List of Go build tags
    """
    tags = []
    enabled_set = {f: True for f in enabled_flags}

    for flag, go_tags_value in use_tags.items():
        if flag in enabled_set:
            if isinstance(go_tags_value, list):
                tags.extend(go_tags_value)
            else:
                tags.append(go_tags_value)

    return tags

def use_go_build_args(use_tags, enabled_flags, extra_args = []):
    """Generate Go build arguments based on USE flags.

    Args:
        use_tags: Dict mapping USE flag to Go build tag
        enabled_flags: List of enabled USE flags
        extra_args: Additional Go build arguments

    Returns:
        List of Go build arguments
    """
    args = list(extra_args)
    tags = use_go_tags(use_tags, enabled_flags)

    if tags:
        args.append("-tags={}".format(",".join(tags)))

    return args

# =============================================================================
# EBUILD-STYLE USE PACKAGE
# =============================================================================

# =============================================================================
# USE FLAG VALIDATION
# =============================================================================

def validate_use_flags(iuse, requested_flags):
    """Validate that requested USE flags are supported.

    Args:
        iuse: List of supported USE flags for the package
        requested_flags: List of requested USE flags

    Returns:
        List of warning messages for unknown flags
    """
    warnings = []
    iuse_set = {f: True for f in iuse}

    for flag in requested_flags:
        actual_flag = flag[1:] if flag.startswith("-") else flag
        if actual_flag not in iuse_set and actual_flag not in GLOBAL_USE_FLAGS:
            warnings.append("Unknown USE flag: {}".format(actual_flag))

    return warnings

def required_use_check(required_use, enabled_flags):
    """Check REQUIRED_USE constraints.

    Supports Gentoo-style REQUIRED_USE syntax:
    - "flag1? ( flag2 )" - if flag1 then flag2
    - "flag1? ( !flag2 )" - if flag1 then not flag2
    - "|| ( flag1 flag2 )" - at least one of
    - "^^ ( flag1 flag2 )" - exactly one of
    - "?? ( flag1 flag2 )" - at most one of

    Args:
        required_use: REQUIRED_USE specification string
        enabled_flags: List of enabled USE flags

    Returns:
        True if constraints satisfied, error message otherwise
    """
    enabled_set = {f: True for f in enabled_flags}

    # Simple implementation - parse basic patterns
    # Full implementation would need a proper parser

    # Check "at least one" - || ( flag1 flag2 )
    if "|| (" in required_use:
        start = required_use.find("|| (") + 4
        end = required_use.find(")", start)
        flags = required_use[start:end].split()
        found_any = False
        for f in flags:
            if f in enabled_set:
                found_any = True
                break
        if not found_any:
            return "At least one of {} must be enabled".format(flags)

    # Check "exactly one" - ^^ ( flag1 flag2 )
    if "^^ (" in required_use:
        start = required_use.find("^^ (") + 4
        end = required_use.find(")", start)
        flags = required_use[start:end].split()
        count = 0
        for f in flags:
            if f in enabled_set:
                count += 1
        if count != 1:
            return "Exactly one of {} must be enabled".format(flags)

    # Check "at most one" - ?? ( flag1 flag2 )
    if "?? (" in required_use:
        start = required_use.find("?? (") + 4
        end = required_use.find(")", start)
        flags = required_use[start:end].split()
        count = 0
        for f in flags:
            if f in enabled_set:
                count += 1
        if count > 1:
            return "At most one of {} can be enabled".format(flags)

    return True

# =============================================================================
# USE FLAG DESCRIPTION HELPERS
# =============================================================================

def describe_use_flags(iuse, custom_descriptions = {}):
    """Get descriptions for a list of USE flags.

    Args:
        iuse: List of USE flags
        custom_descriptions: Package-specific flag descriptions

    Returns:
        Dict mapping flag to description
    """
    result = {}

    for flag in iuse:
        if flag in custom_descriptions:
            result[flag] = custom_descriptions[flag]
        elif flag in GLOBAL_USE_FLAGS:
            result[flag] = GLOBAL_USE_FLAGS[flag]
        else:
            result[flag] = "Local USE flag"

    return result

def format_use_string(iuse, enabled_flags):
    """Format USE flags for display (like `emerge --info`).

    Args:
        iuse: List of supported USE flags
        enabled_flags: List of enabled USE flags

    Returns:
        Formatted string like "ssl http2 -debug -ldap"
    """
    enabled_set = {f: True for f in enabled_flags}
    parts = []

    for flag in sorted(iuse):
        if flag in enabled_set:
            parts.append(flag)
        else:
            parts.append("-" + flag)

    return " ".join(parts)

# =============================================================================
# PROFILE-BASED PACKAGE CREATION
# =============================================================================

