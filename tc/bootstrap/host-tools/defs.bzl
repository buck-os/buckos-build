"""
host_tools_aggregator: merge package bin dirs into a single directory.

Collects all binaries from each package's usr/bin/ into one flat
directory that becomes host_bin_dir in the seed toolchain.

Packages are built through bootstrap_transition so they use the
host-PATH toolchain (allows host sed/make/bash during their build).
This breaks the cycle: seed-toolchain → host-tools → packages →
seed-toolchain.  After aggregation, the merged tools are patched
by host_tools_exec to use sysroot ld-linux.
"""

load("//defs:providers.bzl", "PackageInfo")

def _host_tools_aggregator_impl(ctx):
    output = ctx.actions.declare_output("host-tools", dir = True)

    cmd = cmd_args(ctx.attrs._merge_tool[RunInfo])
    cmd.add("--output", output.as_output())

    for pkg in ctx.attrs.packages:
        if PackageInfo in pkg:
            prefix = pkg[PackageInfo].prefix
        else:
            prefix = pkg[DefaultInfo].default_outputs[0]
        cmd.add("--prefix", prefix)

    ctx.actions.run(cmd, category = "aggregate_host_tools", identifier = ctx.attrs.name)

    return [DefaultInfo(default_output = output)]

host_tools_aggregator = rule(
    impl = _host_tools_aggregator_impl,
    attrs = {
        "packages": attrs.list(
            attrs.transition_dep(cfg = "//tc/exec:host-tools-transition"),
            default = [],
        ),
        "_merge_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:merge_host_tools"),
        ),
    },
)
