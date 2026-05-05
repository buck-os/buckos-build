"""Stage 2 aggregator rule — forwards BootstrapStageInfo from gcc-pass2.

Stage 2 builds a cross-compiler with its own glibc (Gentoo stage 2):
  host GCC → cross-binutils → linux-headers → gcc-pass1 (C only)
  → glibc → gcc-pass2 (C/C++ with glibc sysroot)
"""

load("//defs:providers.bzl", "BootstrapStageInfo")
load("//tc:transitions.bzl", "strip_toolchain_mode")

def _stage2_impl(ctx):
    gcc = ctx.attrs.gcc_pass2
    if BootstrapStageInfo in gcc:
        return [
            DefaultInfo(default_output = gcc[DefaultInfo].default_outputs[0]),
            gcc[BootstrapStageInfo],
        ]
    fail("gcc-pass2 must provide BootstrapStageInfo")

stage2_aggregator = rule(
    impl = _stage2_impl,
    attrs = {
        "gcc_pass2": attrs.dep(providers = [BootstrapStageInfo]),
    },
    cfg = strip_toolchain_mode,
)
