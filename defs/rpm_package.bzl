"""
RPM package support for Fedora compatibility.

Provides rules for downloading, extracting, and integrating RPM packages
into BuckOS. This enables hybrid systems where some packages come from
Fedora's RPM ecosystem while others are built natively.

Features:
- Download and verify RPM packages via native http_file
- Extract RPM contents with automatic FHS mapping
- Handle RPM dependencies (translation to Buck targets)
- Support for multiple Fedora versions
- Filesystem layout conversion

Example usage:
    rpm_package(
        name = "firefox",
        rpm_uri = "https://download.fedoraproject.org/.../firefox-*.rpm",
        sha256 = "...",
        fedora_version = "40",
        rpm_deps = {
            "gtk3": "//packages/linux/desktop/gtk:gtk3",
            "dbus-libs": "//packages/linux/core/dbus:dbus",
        },
    )
"""

load("//defs:fhs_mapping.bzl",
     "extract_rpm_to_layout",
     "get_configure_args_for_layout",
     "fhs_to_buckos")
load("//defs:distro_constraints.bzl",
     "DISTRO_FEDORA",
     "get_distro_constraints")
load("//defs:use_flags.bzl", "get_effective_use")

# =============================================================================
# RPM EXTRACTION
# =============================================================================

def _rpm_extract_impl(ctx):
    """Extract RPM package contents."""
    rpm_file = ctx.attrs.rpm_file[DefaultInfo].default_outputs[0]
    output_dir = ctx.actions.declare_output("extracted", dir = True)

    # Determine target layout from USE flags
    use_flags = get_effective_use(
        ctx.attrs.name,
        ctx.attrs.iuse,
        ctx.attrs.use_defaults,
    )

    target_layout = "fhs" if "fedora" in use_flags else "buckos"

    ctx.actions.run(
        [
            "sh", "-c",
            """
            set -e
            mkdir -p {output}
            cd {output}

            # Extract RPM using rpm2cpio and cpio
            rpm2cpio {rpm} | cpio -idmv

            # Record extracted files
            find . -type f > {output}/FILES.txt
            find . -type l >> {output}/FILES.txt
            """.format(
                output = output_dir.as_output(),
                rpm = rpm_file,
            ),
        ],
        category = "rpm_extract",
    )

    return [DefaultInfo(default_output = output_dir)]

rpm_extract = rule(
    impl = _rpm_extract_impl,
    attrs = {
        "rpm_file": attrs.dep(providers = [DefaultInfo]),
        "target_layout": attrs.string(default = "buckos"),
        "iuse": attrs.list(attrs.string(), default = []),
        "use_defaults": attrs.list(attrs.string(), default = []),
    },
)

# =============================================================================
# RPM PACKAGE RULE
# =============================================================================

def rpm_package(
    name,
    rpm_uri,
    sha256 = None,
    fedora_version = "40",
    rpm_deps = {},
    deps = [],
    compat_tags = None,
    description = "",
    homepage = "",
    license = "",
    visibility = None,
    **kwargs):
    """Define an RPM package for Fedora compatibility.

    Args:
        name: Package name
        rpm_uri: URL to download RPM package
        sha256: Expected SHA256 checksum
        fedora_version: Fedora version (39, 40, 41, etc.)
        rpm_deps: Dict mapping RPM dependency names to Buck targets
                 Example: {"gtk3": "//packages/linux/desktop/gtk:gtk3"}
        deps: Additional Buck dependencies
        compat_tags: Distribution compatibility tags (defaults to ["fedora"])
        description: Package description
        homepage: Package homepage URL
        license: Package license
        visibility: Target visibility
        **kwargs: Additional arguments
    """

    # Default compat tags for RPM packages
    if compat_tags == None:
        compat_tags = [DISTRO_FEDORA]

    # Download RPM via native http_file
    download_target = "{}-download".format(name)
    rpm_filename = rpm_uri.split("/")[-1]
    native.http_file(
        name = download_target,
        urls = [rpm_uri],
        sha256 = sha256 or "",
        out = rpm_filename,
        visibility = ["//{}:".format(native.package_name())],
    )

    # Extract RPM
    extract_target = "{}-extract".format(name)
    rpm_extract(
        name = extract_target,
        rpm_file = ":{}".format(download_target),
        iuse = ["fedora"],  # RPM packages imply Fedora USE flag
        use_defaults = ["fedora"],
        visibility = ["//{}:".format(native.package_name())],
    )

    # Resolve RPM dependencies to Buck targets
    all_deps = list(deps)
    for rpm_dep, buck_target in rpm_deps.items():
        all_deps.append(buck_target)

    # Create main target (filegroup of extracted contents)
    # NOTE: Buck2's filegroup doesn't support deps parameter.
    # Dependencies from all_deps need to be handled differently.
    # TODO: Implement proper dependency handling for RPM packages
    native.filegroup(
        name = name,
        srcs = [":{}".format(extract_target)],
        visibility = visibility or ["PUBLIC"],
        metadata = {
            "type": "rpm_package",
            "fedora_version": fedora_version,
            "compat_tags": compat_tags,
            "description": description,
            "homepage": homepage,
            "license": license,
            "rpm_uri": rpm_uri,
        },
    )

# =============================================================================
# RPM DEPENDENCY TRANSLATION
# =============================================================================

# Common RPM -> Buck dependency mappings
RPM_DEPENDENCY_MAP = {
    # Core libraries
    "glibc": "//packages/linux/core/glibc:glibc",
    "zlib": "//packages/linux/core/zlib:zlib",
    "bzip2-libs": "//packages/linux/system/libs/compression/bzip2:bzip2",
    "xz-libs": "//packages/linux/system/libs/compression/xz:xz",
    "openssl-libs": "//packages/linux/system/libs/crypto/openssl:openssl",

    # Desktop libraries
    "gtk3": "//packages/linux/desktop/gtk:gtk3",
    "gtk4": "//packages/linux/desktop/gtk:gtk4",
    "qt5-qtbase": "//packages/linux/desktop/qt:qt5",
    "qt6-qtbase": "//packages/linux/desktop/qt:qt6",

    # System libraries
    "dbus-libs": "//packages/linux/core/dbus:dbus",
    "systemd-libs": "//packages/linux/system/systemd:systemd",
    "libX11": "//packages/linux/graphics/xorg:libX11",
    "libwayland-client": "//packages/linux/graphics/wayland:wayland",

    # Multimedia
    "ffmpeg-libs": "//packages/linux/graphics/ffmpeg:ffmpeg",
    "pulseaudio-libs": "//packages/linux/audio/pulseaudio:pulseaudio",
    "pipewire-libs": "//packages/linux/audio/pipewire:pipewire",

    # Compression
    "libzstd": "//packages/linux/core/zstd:zstd",
    "lz4-libs": "//packages/linux/core/lz4:lz4",
    "brotli": "//packages/linux/core/brotli:brotli",
}

def translate_rpm_deps(rpm_dep_names):
    """Translate RPM dependency names to Buck targets.

    Args:
        rpm_dep_names: List of RPM package names

    Returns:
        List of Buck target paths
    """
    buck_targets = []
    unknown_deps = []

    for rpm_dep in rpm_dep_names:
        if rpm_dep in RPM_DEPENDENCY_MAP:
            buck_targets.append(RPM_DEPENDENCY_MAP[rpm_dep])
        else:
            unknown_deps.append(rpm_dep)

    if unknown_deps:
        # Warning: unknown dependencies
        print("Warning: Unknown RPM dependencies (need manual mapping): {}".format(
            ", ".join(unknown_deps)
        ))

    return buck_targets

# =============================================================================
# RPM REPOSITORY HELPERS
# =============================================================================

# Fedora mirror URLs
FEDORA_MIRRORS = {
    "39": "https://download.fedoraproject.org/pub/fedora/linux/releases/39/Everything/x86_64/os/Packages",
    "40": "https://download.fedoraproject.org/pub/fedora/linux/releases/40/Everything/x86_64/os/Packages",
    "41": "https://download.fedoraproject.org/pub/fedora/linux/development/rawhide/Everything/x86_64/os/Packages",
}

def fedora_rpm_url(package_name, version, fedora_version = "40"):
    """Generate Fedora RPM URL for a package.

    Args:
        package_name: RPM package name (e.g., "firefox")
        version: Package version (e.g., "120.0-1.fc40")
        fedora_version: Fedora release version

    Returns:
        Full URL to RPM package
    """
    if fedora_version not in FEDORA_MIRRORS:
        fail("Unknown Fedora version: {}. Supported: {}".format(
            fedora_version,
            ", ".join(FEDORA_MIRRORS.keys())
        ))

    base_url = FEDORA_MIRRORS[fedora_version]

    # Fedora organizes packages by first letter
    first_letter = package_name[0].lower()

    # Full package filename
    rpm_filename = "{}-{}.x86_64.rpm".format(package_name, version)

    return "{}/{}/{}/{}".format(base_url, first_letter, package_name, rpm_filename)

# =============================================================================
# HELPERS FOR PACKAGE DEFINITIONS
# =============================================================================

def is_rpm_available(use_flags):
    """Check if RPM packages should be used based on USE flags.

    Args:
        use_flags: List of enabled USE flags

    Returns:
        True if USE=fedora is enabled
    """
    return "fedora" in use_flags

def select_package_variant(native_target, rpm_target, use_flags):
    """Select between native and RPM package variants.

    Args:
        native_target: Buck target for native package
        rpm_target: Buck target for RPM package
        use_flags: List of enabled USE flags

    Returns:
        Selected target path
    """
    if is_rpm_available(use_flags):
        return rpm_target
    return native_target
