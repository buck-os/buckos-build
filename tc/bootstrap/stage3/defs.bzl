"""Stage 3 aggregator rule — forwards BootstrapStageInfo from self-hosted gcc.

Stage 3 rebuilds GCC using Stage 2's native toolchain in a chroot environment.
This produces a fully self-hosted, reproducible compiler that has no dependency
on the host system's toolchain.

The chroot contains Stage 2's native tools and is used to build Stage 3 GCC.
"""

load("//defs:providers.bzl", "BootstrapStageInfo")

def _stage3_impl(ctx):
    gcc = ctx.attrs.native_gcc
    if BootstrapStageInfo not in gcc:
        fail("native-gcc must provide BootstrapStageInfo")

    gcc_info = gcc[BootstrapStageInfo]

    # Get Python artifact if native_python is provided
    python_artifact = None
    python_version = None
    if ctx.attrs.native_python:
        python_output = ctx.attrs.native_python[DefaultInfo].default_outputs[0]
        python_artifact = python_output.project("usr/bin/python3")
        python_version = "3.12.1"

    # Create a new BootstrapStageInfo that includes Python
    return [
        DefaultInfo(default_output = gcc[DefaultInfo].default_outputs[0]),
        BootstrapStageInfo(
            stage = gcc_info.stage,
            cc = gcc_info.cc,
            cxx = gcc_info.cxx,
            ar = gcc_info.ar,
            sysroot = gcc_info.sysroot,
            gcc_lib_dir = gcc_info.gcc_lib_dir,
            target_triple = gcc_info.target_triple,
            python = python_artifact,
            python_version = python_version,
        ),
    ]

stage3_aggregator = rule(
    impl = _stage3_impl,
    attrs = {
        "native_gcc": attrs.dep(providers = [BootstrapStageInfo]),
        # Bootstrap Python interpreter
        "native_python": attrs.option(attrs.dep(), default = None),
        # Stage 2 toolchain used to build Stage 3
        "stage2": attrs.dep(),
        # These deps ensure all native tools are built before stage3 completes.
        "native_tools": attrs.list(attrs.dep(), default = []),
    },
)
