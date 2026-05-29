"""go_package: Go builds.

Thin wrapper that delegates to the package() macro with build_rule = "go".
See defs/packages/autotools.bzl for the rationale.

Rule-specific kwargs (forwarded to defs/rules:go.bzl::go_build):
    go_args, ldflags, bins, packages, vendor_deps, lib_only

Note: ldflags here is a single string passed to `go build -ldflags=`.
For C/C++ link flags use the common extra_ldflags (list) instead.

vendor_deps semantics (handled by package() macro):
    True       -- source tarball ships a vendor/ dir; package() drops the
                  kwarg and injects GOFLAGS=-mod=vendor.
    <64 hex>   -- mirror-hosted vendor tarball; auto-wired.
    unset      -- in mirror.mode=vendor, auto-wired from local vendor dir.
"""

load("//defs:package.bzl", "package")

def go_package(name, **kwargs):
    package(name = name, build_rule = "go", **kwargs)
