"""
USE Flag system for BuckOs.

Per-package feature flags resolved from .buckconfig at analysis time.

Configuration sections:
  [use]            - global flag defaults (ssl = true, debug = false, etc.)
  [use.PKGNAME]   - per-package overrides

Resolution order (later overrides earlier):
  1. Package use_defaults (from macro param)
  2. Global .buckconfig [use] section
  3. Per-package .buckconfig [use.PKGNAME] section

"unset" (absent key) means fall through to the previous layer.
"true"/"1"/"yes" enables; "false"/"0"/"no" disables.

Example:
    autotools_package(
        name = "curl",
        iuse = ["ssl", "gnutls", "http2", "zstd", "brotli", "ipv6", "ldap"],
        use_defaults = ["ssl", "http2", "ipv6"],
        use_deps = {
            "ssl": ["//packages/linux/dev-libs/openssl"],
            "gnutls": ["//packages/linux/system/libs/crypto/gnutls"],
        },
        use_configure = {
            "ssl": "--with-ssl",
            "-ssl": "--without-ssl",
            "ipv6": "--enable-ipv6",
            "-ipv6": "--disable-ipv6",
        },
        ...
    )

    # .buckconfig
    # [use]
    # ssl = true
    #
    # [use.curl]
    # gnutls = true
    # ssl = false
"""

# =============================================================================
# USE FLAG PROFILES
# =============================================================================

# Predefined profiles for common use cases.
# Used by package_sets.bzl to map set names to recommended flags.
USE_PROFILES = {
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
        Sorted list of enabled USE flags
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

    # Layer 3: per-package buckconfig [use.PKGNAME] section
    for flag in iuse:
        val = read_config("use." + package_name, flag, "")
        if val.lower() in _TRUTHY:
            effective[flag] = True
        elif val.lower() in _FALSY:
            effective.pop(flag, None)

    return sorted(effective.keys())

# =============================================================================
# DEPENDENCY RESOLUTION
# =============================================================================

def use_dep(deps_map, enabled_flags):
    """Resolve USE-flag conditional dependencies.

    Args:
        deps_map: Dict mapping USE flag to dependency list
        enabled_flags: List of enabled USE flags

    Returns:
        Flattened list of resolved dependencies
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

# =============================================================================
# CONFIGURE ARGUMENT GENERATION
# =============================================================================

def use_configure_args(use_configure, enabled_flags):
    """Generate configure arguments based on USE flags.

    Args:
        use_configure: Dict mapping USE flag (or "-flag") to configure arg
        enabled_flags: List of enabled USE flags

    Returns:
        List of configure arguments
    """
    result = []
    enabled_set = {f: True for f in enabled_flags}

    for flag, arg in use_configure.items():
        if flag.startswith("-"):
            actual_flag = flag[1:]
            if actual_flag not in enabled_set:
                result.append(arg)
        else:
            if flag in enabled_set:
                result.append(arg)

    return result

def use_enable(flag, option = None, enabled_flags = None):
    """Generate --enable-X or --disable-X based on USE flag."""
    opt = option if option else flag
    if enabled_flags and flag in enabled_flags:
        return "--enable-{}".format(opt)
    return "--disable-{}".format(opt)

def use_with(flag, option = None, enabled_flags = None):
    """Generate --with-X or --without-X based on USE flag."""
    opt = option if option else flag
    if enabled_flags and flag in enabled_flags:
        return "--with-{}".format(opt)
    return "--without-{}".format(opt)

# =============================================================================
# CARGO/RUST
# =============================================================================

def use_cargo_features(use_features, enabled_flags):
    """Map USE flags to Cargo features.

    Args:
        use_features: Dict mapping USE flag to Cargo feature name(s)
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
    """Generate Cargo build arguments based on USE flags."""
    args = list(extra_args)
    features = use_cargo_features(use_features, enabled_flags)

    if features:
        args.append("--features={}".format(",".join(features)))
    else:
        args.append("--no-default-features")

    return args

# =============================================================================
# CMAKE
# =============================================================================

def use_cmake_options(use_options, enabled_flags):
    """Map USE flags to CMake -D options (ON/OFF)."""
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
# MESON
# =============================================================================

def use_meson_options(use_options, enabled_flags):
    """Map USE flags to Meson -D options (enabled/disabled)."""
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
# GO
# =============================================================================

def use_go_tags(use_tags, enabled_flags):
    """Map USE flags to Go build tags."""
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
    """Generate Go build arguments based on USE flags."""
    args = list(extra_args)
    tags = use_go_tags(use_tags, enabled_flags)

    if tags:
        args.append("-tags={}".format(",".join(tags)))

    return args
