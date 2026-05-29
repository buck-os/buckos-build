"""
Template for cargo_package (Rust/Cargo builds).

Real-world example: packages/linux/dev-tools/dev-utils/ripgrep/BUCK  (minimal)
                    packages/linux/dev-tools/dev-utils/sccache/BUCK   (cargo_args)
                    packages/linux/emulation/utilities/cloud-hypervisor/BUCK
                                                                       (use_features)
Wrapper definition: defs/packages/cargo.bzl
Underlying rule:    defs/rules/cargo.bzl
Common kwargs:      defs/package.bzl (see the package() docstring)

Vendoring: package() auto-creates :name-vendor-* targets from the mirror.
Set vendor_deps = True if the source tarball already ships a vendor/ dir.
"""

load("//defs/packages:cargo.bzl", "cargo_package")

cargo_package(
    name = "PACKAGE_NAME",
    version = "VERSION",
    url = "https://github.com/EXAMPLE/PACKAGE_NAME/archive/refs/tags/vVERSION.tar.gz",
    sha256 = "REPLACE_WITH_SHA256",

    # ── SBOM metadata ────────────────────────────────────────────────
    description = "One-line description",
    homepage = "https://github.com/EXAMPLE/PACKAGE_NAME",
    license = "MIT OR Apache-2.0",

    # ── Binaries to install ──────────────────────────────────────────
    # Defaults to all [[bin]] targets defined in Cargo.toml.  Use this to
    # restrict installation to a subset:
    # bins = ["my-tool"],

    # ── Cargo build args ─────────────────────────────────────────────
    cargo_args = [
        # "--release",          # implicit, listed for clarity
        # "--locked",
        # "--no-default-features",
        # "--features", "gha",
    ],

    # ── USE flags ────────────────────────────────────────────────────
    use_features = {
        # "flag": "feature-name"            # single feature
        # "flag": ["feat-a", "feat-b"]      # multiple features
        # "io-uring": "io_uring",
        # "kvm": "kvm",
    },
    use_deps = {
        # "flag": "//pkg:dep"
        # "tls": "//packages/linux/system/libs/crypto/openssl:openssl",
    },

    # ── Patches ──────────────────────────────────────────────────────
    # patches = glob(["patches/*.patch"]),

    # ── Dependencies ─────────────────────────────────────────────────
    deps = [
        # Runtime libraries (linked into the produced binary):
        # "//packages/linux/system/libs/crypto/openssl:openssl",
    ],
    host_deps = [
        # Rust toolchain — required for any cargo build.  When
        # buckos.cache.mode = enabled, sccache is auto-injected too.
        "//packages/linux/lang/rust:rust",
    ],

    # ── Vendor deps ──────────────────────────────────────────────────
    # vendor_deps = True,  # tarball ships vendor/ — skip mirror auto-wire

    # ── Environment ──────────────────────────────────────────────────
    # env = {
    #     "RUSTFLAGS": "-C target-feature=+crt-static",
    # },
)
