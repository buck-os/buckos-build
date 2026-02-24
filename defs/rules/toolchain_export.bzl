"""
toolchain_export rule: pack a bootstrap stage into a distributable archive.

The archive contains compiler binaries, sysroot, GCC internal tools,
optionally host tools, and a metadata.json file for provenance tracking.

When host_tools is provided, the stage3 transition is applied so the
tools are built with the stage 2 toolchain (hermetic PATH from the
stage 2 host tools).  This ensures the seed contains hermetically-built
buckos-native host tools with no host library or path leakage.
"""

load("//defs:providers.bzl", "BootstrapStageInfo")

def _toolchain_export_impl(ctx):
    stage = ctx.attrs.stage[BootstrapStageInfo]
    stage_dir = ctx.attrs.stage[DefaultInfo].default_outputs[0]

    archive = ctx.actions.declare_output(
        "buckos-toolchain-{}.tar.zst".format(stage.target_triple),
    )

    cmd = cmd_args(ctx.attrs._pack_tool[RunInfo])
    cmd.add("--stage-dir", stage_dir)
    cmd.add("--output", archive.as_output())
    cmd.add("--target-triple", stage.target_triple)
    cmd.add("--gcc-version", ctx.attrs.gcc_version)
    cmd.add("--glibc-version", ctx.attrs.glibc_version)
    cmd.add("--compression", ctx.attrs.compression)

    # Include host tools in the seed archive when provided
    if ctx.attrs.host_tools != None:
        host_tools_dir = ctx.attrs.host_tools[DefaultInfo].default_outputs[0]
        cmd.add("--host-tools-dir", host_tools_dir)

    ctx.actions.run(cmd, category = "toolchain_export", identifier = ctx.attrs.name)

    return [DefaultInfo(default_output = archive)]

toolchain_export = rule(
    impl = _toolchain_export_impl,
    attrs = {
        "stage": attrs.dep(providers = [BootstrapStageInfo]),
        "host_tools": attrs.option(
            attrs.transition_dep(cfg = "//tc/exec:stage3-transition"),
            default = None,
        ),
        "gcc_version": attrs.string(default = "14.3.0"),
        "glibc_version": attrs.string(default = "2.42"),
        "compression": attrs.string(default = "zst"),
        "_pack_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:toolchain_pack"),
        ),
    },
)
