"""
BuckOS Rust toolchain rule.

Wraps an existing rust-toolchain ebuild_package output in a first-class
Buck2 toolchain rule returning RustToolchainInfo.
"""

load("@buckos//defs:toolchain_providers.bzl", "RustToolchainInfo")

def _rust_toolchain_impl(ctx):
    output = ctx.attrs.toolchain_package[DefaultInfo].default_outputs[0]
    return [
        DefaultInfo(default_output = output),
        RustToolchainInfo(
            rust_root = output,
            version = ctx.attrs.version,
        ),
    ]

buckos_rust_toolchain = rule(
    impl = _rust_toolchain_impl,
    attrs = {
        "toolchain_package": attrs.dep(doc = "The rust-toolchain ebuild_package target"),
        "version": attrs.string(doc = "Rust version string"),
    },
)
