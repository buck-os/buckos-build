"""Stage 1 aggregator rule — forwards BootstrapStageInfo from gcc-pass2."""

load("//defs:providers.bzl", "BootstrapStageInfo")

def _stage1_impl(ctx):
    gcc = ctx.attrs.gcc_pass2
    if BootstrapStageInfo in gcc:
        return [
            DefaultInfo(default_output = gcc[DefaultInfo].default_outputs[0]),
            gcc[BootstrapStageInfo],
        ]
    fail("gcc-pass2 must provide BootstrapStageInfo")

stage1_aggregator = rule(
    impl = _stage1_impl,
    attrs = {
        "gcc_pass2": attrs.dep(providers = [BootstrapStageInfo]),
    },
)
