"""
Template for go_package (Go modules build).

Real-world example: packages/linux/dev-libs/cloud/finnhub-go/BUCK     (minimal)
                    packages/linux/dev-libs/go/go-fuse/BUCK           (cgo)
                    packages/linux/dev-libs/go/prometheus-common/BUCK (lib_only)
Wrapper definition: defs/packages/go.bzl
Underlying rule:    defs/rules/go.bzl
Common kwargs:      defs/package.bzl (see the package() docstring)

Vendoring: package() auto-creates :name-vendor-* targets from the mirror.
Set vendor_deps = True if the source tarball already ships a vendor/ dir
(GOFLAGS=-mod=vendor is then injected automatically).
"""

load("//defs/packages:go.bzl", "go_package")

go_package(
    name = "PACKAGE_NAME",
    version = "VERSION",
    url = "https://github.com/EXAMPLE/PACKAGE_NAME/archive/vVERSION.tar.gz",
    sha256 = "REPLACE_WITH_SHA256",

    # ── SBOM metadata ────────────────────────────────────────────────
    description = "One-line description",
    homepage = "https://github.com/EXAMPLE/PACKAGE_NAME",
    license = "Apache-2.0",

    # ── Library-only package (no binaries to install) ────────────────
    # Set when packaging a Go module that other packages import via
    # GOPATH but which has no `package main`:
    # lib_only = True,

    # ── Binaries to install ──────────────────────────────────────────
    # Defaults: all `package main` entries.  Restrict with bins / packages:
    # bins = ["my-tool"],
    # packages = [".", "./cmd/foo", "./cmd/bar"],

    # ── Build args ───────────────────────────────────────────────────
    # go_args = ["-trimpath", "-buildmode=pie"],
    # ldflags = "-s -w -X main.Version=VERSION",  # single string, not a list

    # ── USE flags ────────────────────────────────────────────────────
    # Go uses build tags via use_configure (the macro forwards them to
    # the go rule which translates them appropriately).  Pass a single
    # `-tags` arg via go_args for static tags.
    use_configure = {
        # "flag": ("--tags=flag", ""),
    },
    use_deps = {
        # "sqlite": "//packages/linux/dev-db/sqlite:sqlite",
    },

    # ── Patches ──────────────────────────────────────────────────────
    # patches = glob(["patches/*.patch"]),

    # ── Dependencies ─────────────────────────────────────────────────
    deps = [
        # Other Go module packages (compile-time and runtime):
        # "//packages/linux/dev-libs/cloud/golang-oauth2:golang-oauth2",
        # System libraries for cgo:
        # "//packages/linux/system/libs/libfuse:libfuse",
    ],
    # host_deps auto-injects the Go SDK; no manual entry needed unless
    # you need extra tools.
    # host_deps = ["//packages/linux/dev-tools/build-systems/protoc:protoc"],

    # ── Vendor deps ──────────────────────────────────────────────────
    # vendor_deps = True,  # tarball ships vendor/ — skip mirror auto-wire

    # ── Environment ──────────────────────────────────────────────────
    # env = {
    #     "CGO_ENABLED": "1",
    #     "GOFLAGS": "-trimpath",
    # },
)
