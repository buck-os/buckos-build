"""
Stage 2 wrapper rule: creates wrapper scripts to run Stage 2 native binaries on the host.

Stage 2 builds native binaries that are linked against the BuckOS sysroot's glibc.
These can't run directly on the host (wrong libc). This rule creates wrapper scripts
that invoke the sysroot's dynamic linker (ld-linux-x86-64.so.2) explicitly with
LD_LIBRARY_PATH pointing to sysroot libs.

Wrapper pattern:
    #!/bin/bash
    SYSROOT="<path-to-stage2-sysroot>"
    LD_LIBRARY_PATH="$SYSROOT/usr/lib64:$SYSROOT/lib64" \
      exec "$SYSROOT/lib64/ld-linux-x86-64.so.2" \
      --library-path "$LD_LIBRARY_PATH" \
      "<stage2-binary>" "$@"
"""

load("//defs:providers.bzl", "BootstrapStageInfo")

TARGET_TRIPLE = "x86_64-buckos-linux-gnu"

def _stage2_wrapper_impl(ctx):
    stage2 = ctx.attrs.stage2[BootstrapStageInfo]
    stage2_output = ctx.attrs.stage2[DefaultInfo].default_outputs[0]

    # Output directory for wrapper scripts
    output = ctx.actions.declare_output("wrappers", dir = True)

    cmd = cmd_args(ctx.attrs._wrapper_tool[RunInfo])
    cmd.add("--stage2-dir", stage2_output)
    cmd.add("--output-dir", output.as_output())
    cmd.add("--target-triple", TARGET_TRIPLE)
    ctx.actions.run(cmd, category = "create_wrappers", identifier = ctx.attrs.name, allow_cache_upload = True)

    # Return BootstrapStageInfo with wrapper paths
    return [
        DefaultInfo(default_output = output),
        BootstrapStageInfo(
            stage = 2,
            cc = output.project("tools/bin/" + TARGET_TRIPLE + "-gcc"),
            cxx = output.project("tools/bin/" + TARGET_TRIPLE + "-g++"),
            ar = output.project("tools/bin/" + TARGET_TRIPLE + "-ar"),
            sysroot = output.project("tools/" + TARGET_TRIPLE + "/sys-root"),
            gcc_lib_dir = output.project("tools/" + TARGET_TRIPLE + "/lib64"),
            target_triple = TARGET_TRIPLE,
            python = None,
            python_version = None,
        ),
    ]

stage2_wrapper = rule(
    impl = _stage2_wrapper_impl,
    attrs = {
        "stage2": attrs.dep(providers = [BootstrapStageInfo]),
        "_wrapper_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:stage2_wrapper_helper"),
        ),
    },
)
