"""
Template for package(build_rule = "cargo") with USE flags
Based on PACKAGE-SPEC-003: Rust/Cargo Packages
"""

load("//defs:package.bzl", "package")

package(
    build_rule = "cargo",
    name = "PACKAGE_NAME",
    version = "VERSION",
    url = "SOURCE_URL",
    sha256 = "SHA256_CHECKSUM",

    # Binary names to install (if different from package name)
    bins = [
        # Example: "my-binary",
    ],

    # USE flags this package supports
    iuse = [
        # Example: "pcre2", "simd", "jemalloc"
    ],

    # Map USE flags to Cargo features
    use_features = {
        # Format: "flag": "feature-name" or ["feature1", "feature2"]
        # Example:
        # "pcre2": "pcre2",
        # "simd": "simd-accel",
        # "compression": ["zstd", "brotli"],  # Multiple features
    },

    # Conditional dependencies based on USE flags
    use_deps = {
        # Format: "flag": ["//dependency/target"]
        # Example:
        # "pcre2": ["//packages/linux/dev-libs:pcre2"],
    },

    # Additional cargo build arguments
    cargo_args = [
        # Example: "--release", "--locked"
    ],

    # Runtime dependencies (always required)
    deps = [
        # Example: "//packages/linux/core:glibc",
    ],

    # Build-time only dependencies
    build_deps = [
        # Example: "//packages/linux/dev-lang:rust",
    ],

    # Patches
    patches = [
        # Example: ":fix-cargo-toml.patch",
    ],

    # Metadata
    maintainers = [
        # Example: "rust@buckos.org",
    ],

    # Optional: GPG verification
    # signature_sha256 = "SIGNATURE_SHA256",
    # gpg_key = "GPG_KEY_ID",
    # gpg_keyring = "//path/to:keyring",

    # Optional: Environment variables
    # env = {
    #     "RUSTFLAGS": "-C target-feature=+crt-static",
    # },
)
