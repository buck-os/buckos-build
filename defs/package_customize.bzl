"""
Package Customization System for BuckOs Linux Distribution.

Similar to Gentoo's /etc/portage/ configuration system, this provides:
- Global package configuration overrides
- Per-package USE flag settings
- Build environment customization
- Patch overlays
- Custom ebuild phases

This allows users and tools to customize package builds without modifying
the original package definitions.

Example usage:
    # Load customization system
    load("//defs:package_customize.bzl", "package_config", "apply_customizations")

    # Define global customizations
    CUSTOMIZATIONS = package_config(
        # Global USE flags
        use_flags = ["ssl", "http2", "-debug", "ipv6"],

        # Profile selection
        profile = "server",

        # Per-package USE flags (like /etc/portage/package.use)
        package_use = {
            "curl": ["gnutls", "-ssl", "brotli"],
            "nginx": ["http2", "ssl", "pcre2"],
            "python": ["sqlite", "ssl", "readline"],
        },

        # Per-package environment (like /etc/portage/package.env)
        package_env = {
            "ffmpeg": {"CFLAGS": "-O3 -march=native"},
            "gcc": {"MAKEOPTS": "-j4"},
        },

        # Package-specific patches
        package_patches = {
            "glibc": ["//patches:glibc-fix.patch"],
        },

        # Package masks (prevent installation)
        package_mask = [
            "//packages/linux/dev-libs/openssl:1.1",  # Mask old OpenSSL
        ],

        # Package unmasks (allow masked packages)
        package_unmask = [
            "//packages/linux/lang/rust",  # Allow unstable Rust
        ],

        # Accept specific keywords
        accept_keywords = {
            "rust": ["~amd64"],  # Accept testing for Rust
        },
    )
"""

load("//defs:use_flags.bzl",
     "USE_PROFILES",
     "get_effective_use",
     "use_configure_args",
     "use_dep",
)
load("//defs:package_defs.bzl", "download_source", "ebuild_package", "inherit")

# =============================================================================
# CUSTOMIZATION CONFIGURATION
# =============================================================================

def package_config(
        use_flags = [],
        profile = "default",
        package_use = {},
        package_env = {},
        package_patches = {},
        package_mask = [],
        package_unmask = [],
        accept_keywords = {},
        cflags = "",
        cxxflags = "",
        ldflags = "",
        makeopts = "",
        features = []):
    """Create a package customization configuration.

    This is similar to Gentoo's make.conf + /etc/portage/ system.

    Note: USE flag resolution now happens via .buckconfig [use] / [use.PKGNAME]
    sections at analysis time. This function records intent for tooling and
    config generation; actual flag resolution uses get_effective_use().

    Args:
        use_flags: Global USE flags (like USE in make.conf)
        profile: Profile name (minimal, server, desktop, etc.)
        package_use: Per-package USE flags (like package.use)
        package_env: Per-package environment variables (like package.env)
        package_patches: Per-package patches to apply
        package_mask: Packages to mask (prevent building)
        package_unmask: Packages to unmask
        accept_keywords: Accept specific keywords per package
        cflags: Global CFLAGS
        cxxflags: Global CXXFLAGS
        ldflags: Global LDFLAGS
        makeopts: Global make options (e.g., "-j8")
        features: Build features to enable

    Returns:
        Customization configuration dict
    """
    # Parse profile
    profile_config = USE_PROFILES.get(profile, USE_PROFILES["default"])

    # Merge profile USE with explicit USE flags for tooling output
    merged_enabled = list(profile_config["enabled"])
    merged_disabled = list(profile_config["disabled"])

    for flag in use_flags:
        if flag.startswith("-"):
            actual = flag[1:]
            if actual not in merged_disabled:
                merged_disabled.append(actual)
            if actual in merged_enabled:
                merged_enabled.remove(actual)
        else:
            if flag not in merged_enabled:
                merged_enabled.append(flag)
            if flag in merged_disabled:
                merged_disabled.remove(flag)

    # Parse per-package USE flags
    parsed_package_use = {}
    for pkg, flags in package_use.items():
        parsed_package_use[pkg] = package_use_config(pkg, flags)

    return {
        "profile": profile,
        "use_flags": {
            "enabled": merged_enabled,
            "disabled": merged_disabled,
        },
        "package_use": parsed_package_use,
        "package_env": package_env,
        "package_patches": package_patches,
        "package_mask": package_mask,
        "package_unmask": package_unmask,
        "accept_keywords": accept_keywords,
        "cflags": cflags,
        "cxxflags": cxxflags,
        "ldflags": ldflags,
        "makeopts": makeopts,
        "features": features,
    }

def package_use_config(package_name, flags):
    """Parse package USE flag configuration.

    Args:
        package_name: Package name
        flags: List of USE flags (prefix with - to disable)

    Returns:
        Package USE configuration dict
    """
    enabled = []
    disabled = []

    for flag in flags:
        if flag.startswith("-"):
            disabled.append(flag[1:])
        else:
            enabled.append(flag)

    return {
        "enabled": enabled,
        "disabled": disabled,
    }

# =============================================================================
# CUSTOMIZATION APPLICATION
# =============================================================================

def apply_customizations(
        name,
        config,
        iuse = [],
        use_defaults = [],
        use_deps = {},
        use_configure = {},
        configure_args = [],
        deps = [],
        env = {},
        pre_configure = "",
        **kwargs):
    """Apply customizations to package build parameters.

    This takes the customization config and original package parameters,
    returning modified parameters with customizations applied.

    Args:
        name: Package name
        config: Customization config from package_config()
        iuse: Package's supported USE flags
        use_defaults: Package's default USE flags
        use_deps: USE-conditional dependencies
        use_configure: USE-conditional configure args
        configure_args: Base configure arguments
        deps: Base dependencies
        env: Base environment variables
        pre_configure: Base pre-configure script
        **kwargs: Additional parameters

    Returns:
        Dict with customized parameters
    """
    # Check if package is masked
    if is_masked(name, config):
        fail("Package {} is masked".format(name))

    # Calculate effective USE flags (reads from .buckconfig)
    effective_use = get_effective_use(
        name,
        iuse,
        use_defaults,
    )

    # Resolve dependencies
    resolved_deps = list(deps)
    resolved_deps.extend(use_dep(use_deps, effective_use))

    # Resolve configure arguments
    resolved_configure = list(configure_args)
    resolved_configure.extend(use_configure_args(use_configure, effective_use))

    # Build environment
    resolved_env = dict(env)

    # Apply global environment
    if config["cflags"]:
        resolved_env["CFLAGS"] = config["cflags"]
    if config["cxxflags"]:
        resolved_env["CXXFLAGS"] = config["cxxflags"]
    if config["ldflags"]:
        resolved_env["LDFLAGS"] = config["ldflags"]
    if config["makeopts"]:
        resolved_env["MAKEOPTS"] = config["makeopts"]

    # Apply package-specific environment
    if name in config["package_env"]:
        resolved_env.update(config["package_env"][name])

    # Apply patches
    resolved_pre_configure = pre_configure
    if name in config["package_patches"]:
        for patch in config["package_patches"][name]:
            resolved_pre_configure += '\npatch -p1 < "{}"'.format(patch)

    return {
        "effective_use": effective_use,
        "deps": resolved_deps,
        "configure_args": resolved_configure,
        "env": resolved_env,
        "pre_configure": resolved_pre_configure,
    }

def is_masked(package_name, config):
    """Check if a package is masked.

    Args:
        package_name: Package name or target path
        config: Customization config

    Returns:
        True if package is masked and not unmasked
    """
    masked = False
    unmasked = False

    for mask in config["package_mask"]:
        if package_name in mask or mask.endswith("/" + package_name):
            masked = True
            break

    for unmask in config["package_unmask"]:
        if package_name in unmask or unmask.endswith("/" + package_name):
            unmasked = True
            break

    return masked and not unmasked

# =============================================================================
# CUSTOMIZATION-AWARE PACKAGE MACROS
# =============================================================================

def customized_package(
        name,
        version,
        src_uri,
        sha256,
        config,
        iuse = [],
        use_defaults = [],
        use_deps = {},
        use_configure = {},
        configure_args = [],
        make_args = [],
        deps = [],
        build_deps = [],
        maintainers = [],
        **kwargs):
    """Create a package with customizations applied.

    This combines use_package with the customization system.

    Args:
        name: Package name
        version: Package version
        src_uri: Source download URL
        sha256: Source checksum
        config: Customization config from package_config()
        iuse: Supported USE flags
        use_defaults: Default USE flags
        use_deps: USE-conditional dependencies
        use_configure: USE-conditional configure args
        configure_args: Base configure arguments
        make_args: Make arguments
        deps: Base dependencies
        build_deps: Build dependencies
        maintainers: Package maintainers
        **kwargs: Additional arguments

    Returns:
        Effective USE flags that were applied
    """
    # Apply customizations
    customized = apply_customizations(
        name = name,
        config = config,
        iuse = iuse,
        use_defaults = use_defaults,
        use_deps = use_deps,
        use_configure = use_configure,
        configure_args = configure_args,
        deps = deps,
        env = kwargs.get("env", {}),
        pre_configure = kwargs.get("pre_configure", ""),
    )

    # Download source
    src_name = name + "-src"
    download_source(
        name = src_name,
        src_uri = src_uri,
        sha256 = sha256,
    )

    # Use autotools eclass for build
    eclass_config = inherit(["autotools"])

    # Set environment variables for autotools eclass
    env = dict(customized["env"])
    if customized["configure_args"]:
        env["EXTRA_ECONF"] = " ".join(customized["configure_args"])
    if make_args:
        env["EXTRA_EMAKE"] = " ".join(make_args)

    # Create the package with customizations using ebuild_package
    ebuild_package(
        name = name,
        source = ":" + src_name,
        version = version,
        src_configure = eclass_config["src_configure"],
        src_compile = eclass_config["src_compile"],
        src_install = eclass_config["src_install"],
        use_flags = customized["effective_use"],
        rdepend = customized["deps"],
        bdepend = build_deps,
        maintainers = maintainers,
        env = env,
        src_prepare = customized["pre_configure"],
        post_install = kwargs.get("post_install", ""),
        description = kwargs.get("description", ""),
        homepage = kwargs.get("homepage", ""),
        license = kwargs.get("license", ""),
        visibility = kwargs.get("visibility", ["PUBLIC"]),
    )

    return customized["effective_use"]

# =============================================================================
# OVERRIDE TEMPLATES
# =============================================================================

def package_override(
        name,
        configure_args = None,
        make_args = None,
        env = None,
        patches = None,
        pre_configure = None,
        post_install = None,
        deps_add = None,
        deps_remove = None):
    """Define an override for a specific package.

    This creates a reusable override that can be applied to packages.

    Args:
        name: Override name (for reference)
        configure_args: Additional configure arguments
        make_args: Additional make arguments
        env: Environment variable overrides
        patches: Patches to apply
        pre_configure: Additional pre-configure script
        post_install: Additional post-install script
        deps_add: Dependencies to add
        deps_remove: Dependencies to remove

    Returns:
        Override configuration dict
    """
    return {
        "name": name,
        "configure_args": configure_args or [],
        "make_args": make_args or [],
        "env": env or {},
        "patches": patches or [],
        "pre_configure": pre_configure or "",
        "post_install": post_install or "",
        "deps_add": deps_add or [],
        "deps_remove": deps_remove or [],
    }

def apply_override(base_args, override):
    """Apply an override to package arguments.

    Args:
        base_args: Base package arguments dict
        override: Override from package_override()

    Returns:
        Modified arguments dict
    """
    result = dict(base_args)

    # Extend list arguments
    if override["configure_args"]:
        result["configure_args"] = result.get("configure_args", []) + override["configure_args"]
    if override["make_args"]:
        result["make_args"] = result.get("make_args", []) + override["make_args"]

    # Merge environment
    if override["env"]:
        result_env = dict(result.get("env", {}))
        result_env.update(override["env"])
        result["env"] = result_env

    # Extend pre/post scripts
    if override["pre_configure"]:
        result["pre_configure"] = result.get("pre_configure", "") + "\n" + override["pre_configure"]
    if override["post_install"]:
        result["post_install"] = result.get("post_install", "") + "\n" + override["post_install"]

    # Handle dependencies
    if override["deps_add"] or override["deps_remove"]:
        current_deps = list(result.get("deps", []))
        for dep in override["deps_add"]:
            if dep not in current_deps:
                current_deps.append(dep)
        for dep in override["deps_remove"]:
            if dep in current_deps:
                current_deps.remove(dep)
        result["deps"] = current_deps

    return result

# =============================================================================
# ENVIRONMENT PRESETS
# =============================================================================

# Common environment presets
ENV_PRESETS = {
    # Optimization levels
    "optimize-size": {
        "CFLAGS": "-Os -ffunction-sections -fdata-sections",
        "CXXFLAGS": "-Os -ffunction-sections -fdata-sections",
        "LDFLAGS": "-Wl,--gc-sections",
    },
    "optimize-speed": {
        "CFLAGS": "-O3 -ffast-math",
        "CXXFLAGS": "-O3 -ffast-math",
    },
    "native": {
        "CFLAGS": "-O2 -march=native -mtune=native",
        "CXXFLAGS": "-O2 -march=native -mtune=native",
    },

    # Debug builds
    "debug": {
        "CFLAGS": "-O0 -g3 -ggdb",
        "CXXFLAGS": "-O0 -g3 -ggdb",
    },
    "debug-sanitize": {
        "CFLAGS": "-O0 -g3 -fsanitize=address,undefined",
        "CXXFLAGS": "-O0 -g3 -fsanitize=address,undefined",
        "LDFLAGS": "-fsanitize=address,undefined",
    },

    # Security hardening
    "hardened": {
        "CFLAGS": "-O2 -D_FORTIFY_SOURCE=2 -fstack-protector-strong -fPIE",
        "CXXFLAGS": "-O2 -D_FORTIFY_SOURCE=2 -fstack-protector-strong -fPIE",
        "LDFLAGS": "-Wl,-z,relro,-z,now -pie",
    },

    # LTO builds
    "lto": {
        "CFLAGS": "-O2 -flto=auto",
        "CXXFLAGS": "-O2 -flto=auto",
        "LDFLAGS": "-flto=auto",
    },

    # Cross-compilation
    "cross-aarch64": {
        "CC": "aarch64-linux-gnu-gcc",
        "CXX": "aarch64-linux-gnu-g++",
        "AR": "aarch64-linux-gnu-ar",
        "RANLIB": "aarch64-linux-gnu-ranlib",
        "CHOST": "aarch64-linux-gnu",
    },
    "cross-riscv64": {
        "CC": "riscv64-linux-gnu-gcc",
        "CXX": "riscv64-linux-gnu-g++",
        "AR": "riscv64-linux-gnu-ar",
        "RANLIB": "riscv64-linux-gnu-ranlib",
        "CHOST": "riscv64-linux-gnu",
    },
}

def get_env_preset(preset_name):
    """Get an environment preset.

    Args:
        preset_name: Name of preset (optimize-size, debug, hardened, etc.)

    Returns:
        Environment dict for the preset
    """
    if preset_name not in ENV_PRESETS:
        fail("Unknown environment preset: {}. Available: {}".format(
            preset_name, ", ".join(ENV_PRESETS.keys())))
    return ENV_PRESETS[preset_name]

def merge_env_presets(*preset_names):
    """Merge multiple environment presets.

    Later presets override earlier ones.

    Args:
        *preset_names: Names of presets to merge

    Returns:
        Merged environment dict
    """
    result = {}
    for name in preset_names:
        result.update(get_env_preset(name))
    return result

# =============================================================================
# FEATURE FLAGS
# =============================================================================

# Build features (like Gentoo's FEATURES)
AVAILABLE_FEATURES = {
    "sandbox": "Enable build sandboxing",
    "usersandbox": "Enable user-level sandboxing",
    "network-sandbox": "Disable network during build",
    "parallel-fetch": "Download sources in parallel",
    "parallel-install": "Install packages in parallel",
    "ccache": "Use ccache for compilation",
    "distcc": "Use distcc for distributed compilation",
    "test": "Run test suites",
    "splitdebug": "Split debug symbols into separate files",
    "strip": "Strip binaries",
    "nostrip": "Don't strip binaries",
    "keepwork": "Keep working directory after build",
    "fail-clean": "Remove build files on failure",
}

def validate_features(features):
    """Validate feature flags.

    Args:
        features: List of feature flags

    Returns:
        List of warning messages for unknown features
    """
    warnings = []
    for feature in features:
        actual = feature[1:] if feature.startswith("-") else feature
        if actual not in AVAILABLE_FEATURES:
            warnings.append("Unknown feature: {}".format(actual))
    return warnings

# =============================================================================
# CONFIGURATION FILE GENERATION
# =============================================================================

def generate_make_conf(config):
    """Generate a make.conf-style configuration file.

    Args:
        config: Customization config from package_config()

    Returns:
        String content for make.conf
    """
    lines = [
        "# Generated BuckOs configuration",
        "# Profile: {}".format(config["profile"]),
        "",
    ]

    # USE flags
    enabled = config["use_flags"]["enabled"]
    disabled = ["-" + f for f in config["use_flags"]["disabled"]]
    use_str = " ".join(sorted(enabled + disabled))
    lines.append('USE="{}"'.format(use_str))
    lines.append("")

    # Compiler flags
    if config["cflags"]:
        lines.append('CFLAGS="{}"'.format(config["cflags"]))
    if config["cxxflags"]:
        lines.append('CXXFLAGS="{}"'.format(config["cxxflags"]))
    if config["ldflags"]:
        lines.append('LDFLAGS="{}"'.format(config["ldflags"]))
    if config["makeopts"]:
        lines.append('MAKEOPTS="{}"'.format(config["makeopts"]))

    # Features
    if config["features"]:
        lines.append('FEATURES="{}"'.format(" ".join(config["features"])))

    return "\n".join(lines)

def generate_package_use(config):
    """Generate package.use-style configuration.

    Args:
        config: Customization config from package_config()

    Returns:
        String content for package.use
    """
    lines = ["# Per-package USE flag configuration", ""]

    for pkg, flags in sorted(config["package_use"].items()):
        enabled = flags.get("enabled", [])
        disabled = ["-" + f for f in flags.get("disabled", [])]
        flag_str = " ".join(sorted(enabled + disabled))
        lines.append("{} {}".format(pkg, flag_str))

    return "\n".join(lines)

# =============================================================================
# CONFIGURATION LOADING
# =============================================================================

def load_config_from_dict(config_dict):
    """Load configuration from a dictionary.

    This allows loading configuration from external sources like JSON.

    Args:
        config_dict: Configuration dictionary

    Returns:
        package_config() result
    """
    return package_config(
        use_flags = config_dict.get("use_flags", []),
        profile = config_dict.get("profile", "default"),
        package_use = config_dict.get("package_use", {}),
        package_env = config_dict.get("package_env", {}),
        package_patches = config_dict.get("package_patches", {}),
        package_mask = config_dict.get("package_mask", []),
        package_unmask = config_dict.get("package_unmask", []),
        accept_keywords = config_dict.get("accept_keywords", {}),
        cflags = config_dict.get("cflags", ""),
        cxxflags = config_dict.get("cxxflags", ""),
        ldflags = config_dict.get("ldflags", ""),
        makeopts = config_dict.get("makeopts", ""),
        features = config_dict.get("features", []),
    )

# =============================================================================
# QUICK CONFIGURATION HELPERS
# =============================================================================

def minimal_config(**kwargs):
    """Create a minimal configuration.

    Returns:
        Minimal profile configuration
    """
    return package_config(profile = "minimal", **kwargs)

def server_config(**kwargs):
    """Create a server configuration.

    Returns:
        Server profile configuration
    """
    return package_config(profile = "server", **kwargs)

def desktop_config(**kwargs):
    """Create a desktop configuration.

    Returns:
        Desktop profile configuration
    """
    return package_config(profile = "desktop", **kwargs)

def developer_config(**kwargs):
    """Create a developer configuration.

    Returns:
        Developer profile configuration
    """
    return package_config(profile = "developer", **kwargs)

def hardened_config(**kwargs):
    """Create a hardened configuration.

    Returns:
        Hardened profile configuration
    """
    return package_config(profile = "hardened", **kwargs)
