"""
Template for package(build_rule = "python") with USE flags
Based on PACKAGE-SPEC-005: Python Packages
"""

load("//defs:package.bzl", "package")

package(
    build_rule = "python",
    name = "PACKAGE_NAME",
    version = "VERSION",
    url = "SOURCE_URL",
    sha256 = "SHA256_CHECKSUM",

    # Python interpreter (default is python3)
    python = "python3",

    # USE flags this package supports
    iuse = [
        # Example: "socks", "security", "http2"
    ],

    # Map USE flags to Python extras
    use_extras = {
        # Format: "flag": "extra-name"
        # Example:
        # "socks": "socks",
        # "security": "security",
        # "http2": "http2",
    },

    # Conditional dependencies based on USE flags
    use_deps = {
        # Format: "flag": ["//dependency/target"]
        # Example:
        # "socks": ["//packages/linux/dev-python:pysocks"],
    },

    # Runtime dependencies (always required)
    deps = [
        # Python packages: //packages/linux/dev-python:package-name
        # System libraries (for C extensions): //packages/linux/dev-libs:library
        # Example:
        # "//packages/linux/dev-python:urllib3",
        # "//packages/linux/dev-python:certifi",
    ],

    # Build-time only dependencies
    build_deps = [
        # Example: "//packages/linux/dev-libs:libffi",  # For C extensions
    ],

    # Patches
    patches = [
        # Example: ":fix-setup-py.patch",
    ],

    # Metadata
    maintainers = [
        # Example: "python@buckos.org",
    ],

    # Optional: GPG verification
    # signature_sha256 = "SIGNATURE_SHA256",
    # gpg_key = "GPG_KEY_ID",
    # gpg_keyring = "//path/to:keyring",
)
