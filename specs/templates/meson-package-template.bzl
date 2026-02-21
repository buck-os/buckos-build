"""
Template for package(build_rule = "meson") with USE flags
Based on PACKAGE-SPEC-002: Build System Packages (Meson)
"""

load("//defs:package.bzl", "package")

package(
    build_rule = "meson",
    name = "PACKAGE_NAME",
    version = "VERSION",
    url = "SOURCE_URL",
    sha256 = "SHA256_CHECKSUM",

    # USE flags this package supports
    iuse = [
        # Example: "systemd", "doc", "test", "introspection"
    ],

    # Map USE flags to Meson options
    use_options = {
        # Format: "flag": ("-Doption=enabled", "-Doption=disabled")
        # Example:
        # "systemd": ("-Dsystemd=enabled", "-Dsystemd=disabled"),
        # "doc": ("-Ddocs=true", "-Ddocs=false"),
    },

    # Conditional dependencies based on USE flags
    use_deps = {
        # Format: "flag": ["//dependency/target"]
        # Example:
        # "systemd": ["//packages/linux/sys-apps:systemd"],
    },

    # Static Meson arguments (always applied)
    configure_args = [
        # Example: "-Dselinux=disabled",
        # Note: --prefix=/usr is automatic
        # Note: --buildtype=release is automatic
    ],

    # Runtime dependencies (always required)
    deps = [
        # Example: "//packages/linux/core:glibc",
    ],

    # Build-time only dependencies
    build_deps = [
        # Example: "//packages/linux/dev-util:pkg-config",
    ],

    # Patches
    patches = [
        # Example: ":fix-meson-build.patch",
    ],

    # Metadata
    maintainers = [
        # Example: "category@buckos.org",
    ],

    # Optional: GPG verification
    # signature_sha256 = "SIGNATURE_SHA256",
    # gpg_key = "GPG_KEY_ID",
    # gpg_keyring = "//path/to:keyring",
)
