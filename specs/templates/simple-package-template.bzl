"""
Template for package(build_rule = "simple")
Based on PACKAGE-SPEC-001: Simple and Autotools Packages
"""

load("//defs:package.bzl", "package")

package(
    build_rule = "simple",
    name = "PACKAGE_NAME",
    version = "VERSION",
    url = "SOURCE_URL",
    sha256 = "SHA256_CHECKSUM",

    # Optional: Build configuration
    configure_args = [
        # Add ./configure arguments here
        # Example: "--enable-feature",
    ],
    make_args = [
        # Add make arguments here
        # Example: "DESTDIR=",
    ],

    # Optional: Dependencies
    deps = [
        # Runtime dependencies
        # Example: "//packages/linux/core:glibc",
    ],

    # Optional: Patches
    patches = [
        # Patch files to apply
        # Example: ":fix-makefile.patch",
    ],

    # Optional: Metadata
    maintainers = [
        # Maintainer emails
        # Example: "category@buckos.org",
    ],

    # Optional: Security verification
    # signature_sha256 = "SIGNATURE_SHA256",
    # gpg_key = "GPG_KEY_ID",
)
