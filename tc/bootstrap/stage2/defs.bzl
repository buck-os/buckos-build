"""Stage 2 aggregator rule — forwards BootstrapStageInfo from native-gcc."""

load("//defs:providers.bzl", "BootstrapStageInfo")

def _stage2_impl(ctx):
    gcc = ctx.attrs.native_gcc
    if BootstrapStageInfo in gcc:
        return [
            DefaultInfo(default_output = gcc[DefaultInfo].default_outputs[0]),
            gcc[BootstrapStageInfo],
        ]
    fail("native-gcc must provide BootstrapStageInfo")

stage2_aggregator = rule(
    impl = _stage2_impl,
    attrs = {
        "native_gcc": attrs.dep(providers = [BootstrapStageInfo]),
        # These deps ensure all native tools are built before stage2 completes.
        # They don't affect the BootstrapStageInfo, just force materialization.
        "native_tools": attrs.list(attrs.dep(), default = []),
    },
)
