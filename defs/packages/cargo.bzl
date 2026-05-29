"""cargo_package: Rust/Cargo builds.

Thin wrapper that delegates to the package() macro with build_rule = "cargo".
See defs/packages/autotools.bzl for the rationale.

Rule-specific kwargs (forwarded to defs/rules:cargo.bzl::cargo_build):
    features, cargo_args, bins, vendor_deps

vendor_deps semantics (handled by package() macro in defs/package.bzl:308-364):
    True       -- source tarball ships a vendor/ dir; package() drops the kwarg.
    <64 hex>   -- mirror-hosted vendor tarball; package() auto-creates
                  :name-vendor-archive + :name-vendor-src.
    unset      -- in mirror.mode=vendor, package() auto-wires from the local
                  vendor dir.
"""

load("//defs:package.bzl", "package")

def cargo_package(name, **kwargs):
    package(name = name, build_rule = "cargo", **kwargs)
