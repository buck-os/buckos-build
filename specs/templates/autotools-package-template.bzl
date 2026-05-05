"""
Template for package(build_rule = "autotools") with USE flags
Based on PACKAGE-SPEC-001: Simple and Autotools Packages
"""

load("//defs:package.bzl", "package")

package(
    build_rule = "autotools",
    name = "PACKAGE_NAME",
    version = "VERSION",
    url = "SOURCE_URL",
    sha256 = "SHA256_CHECKSUM",

    # USE flags this package supports
    iuse = [
        # Example: "ssl", "ipv6", "doc", "examples"
    ],

    # Map USE flags to configure arguments
    use_configure = {
        # Format: "flag": ("--enable-flag", "--disable-flag")
        # Example:
        # "ssl": ("--with-ssl", "--without-ssl"),
        # "ipv6": ("--enable-ipv6", "--disable-ipv6"),
    },

    # Conditional dependencies based on USE flags
    use_deps = {
        # Format: "flag": ["//dependency/target"]
        # Example:
        # "ssl": ["//packages/linux/network:openssl"],
    },

    # Static configure arguments (always applied)
    configure_args = [
        # Example: "--disable-static",
    ],

    # Static make arguments
    make_args = [
        # Example: "V=1",  # Verbose build
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
        # Example: ":fix-configure.patch",
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
