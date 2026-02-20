"""
Template for package(build_rule = "cmake") with USE flags
Based on PACKAGE-SPEC-002: Build System Packages (CMake)
"""

load("//defs:package.bzl", "package")

package(
    build_rule = "cmake",
    name = "PACKAGE_NAME",
    version = "VERSION",
    url = "SOURCE_URL",
    sha256 = "SHA256_CHECKSUM",

    # USE flags this package supports
    iuse = [
        # Example: "ssl", "cuda", "python", "test"
    ],

    # Map USE flags to CMake options
    use_options = {
        # Format: "flag": ("-DOPTION=ON", "-DOPTION=OFF")
        # Example:
        # "ssl": ("-DWITH_SSL=ON", "-DWITH_SSL=OFF"),
        # "python": ("-DBUILD_PYTHON=ON", "-DBUILD_PYTHON=OFF"),
    },

    # Conditional dependencies based on USE flags
    use_deps = {
        # Format: "flag": ["//dependency/target"]
        # Example:
        # "ssl": ["//packages/linux/dev-libs:openssl"],
    },

    # Static CMake arguments (always applied)
    configure_args = [
        # Example: "-DBUILD_EXAMPLES=OFF",
        # Note: -DCMAKE_INSTALL_PREFIX=/usr is automatic
        # Note: -DCMAKE_BUILD_TYPE=Release is automatic
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
        # Example: ":fix-cmakelists.patch",
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
