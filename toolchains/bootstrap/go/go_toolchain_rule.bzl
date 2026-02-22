"""
BuckOS Go toolchain rule.

Wraps an existing go-toolchain ebuild_package output in a first-class
Buck2 toolchain rule returning GoToolchainInfo.
"""

load("@buckos//defs:providers.bzl", "GoToolchainInfo")

def _go_toolchain_impl(ctx):
    output = ctx.attrs.toolchain_package[DefaultInfo].default_outputs[0]
    return [
        DefaultInfo(default_output = output),
        GoToolchainInfo(
            goroot = output,
            version = ctx.attrs.version,
        ),
    ]

buckos_go_toolchain = rule(
    impl = _go_toolchain_impl,
    attrs = {
        "toolchain_package": attrs.dep(doc = "The go-toolchain ebuild_package target"),
        "version": attrs.string(doc = "Go version string"),
    },
)
