"""
Template for package(build_rule = "go") with USE flags
Based on PACKAGE-SPEC-004: Go Packages
"""

load("//defs:package.bzl", "package")

package(
    build_rule = "go",
    name = "PACKAGE_NAME",
    version = "VERSION",
    url = "SOURCE_URL",
    sha256 = "SHA256_CHECKSUM",

    # Go packages to build (import paths)
    packages = [
        # Example: ".", "./cmd/tool", "./cmd/other"
    ],

    # Binary names to install (if different from package name)
    bins = [
        # Example: "my-binary",
    ],

    # USE flags this package supports
    iuse = [
        # Example: "netgo", "sqlite", "postgres"
    ],

    # Map USE flags to Go build tags
    use_tags = {
        # Format: "flag": "tag-name"
        # Example:
        # "netgo": "netgo",
        # "sqlite": "sqlite",
        # "postgres": "postgres",
    },

    # Conditional dependencies based on USE flags
    use_deps = {
        # Format: "flag": ["//dependency/target"]
        # Example:
        # "sqlite": ["//packages/linux/dev-db:sqlite"],
    },

    # Additional go build arguments (ldflags, etc.)
    go_build_args = [
        # Example: "-ldflags", "-w -s -X main.version=VERSION"
    ],

    # Runtime dependencies (always required)
    deps = [
        # Example: "//packages/linux/core:glibc",
    ],

    # Build-time only dependencies
    build_deps = [
        # Example: "//packages/linux/dev-lang:go",
    ],

    # Patches
    patches = [
        # Example: ":fix-imports.patch",
    ],

    # Metadata
    maintainers = [
        # Example: "go@buckos.org",
    ],

    # Optional: GPG verification
    # signature_sha256 = "SIGNATURE_SHA256",
    # gpg_key = "GPG_KEY_ID",
    # gpg_keyring = "//path/to:keyring",

    # Optional: Environment variables
    # env = {
    #     "CGO_ENABLED": "0",
    #     "GOOS": "linux",
    #     "GOARCH": "amd64",
    # },
)
