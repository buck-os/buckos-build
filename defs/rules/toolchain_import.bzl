"""
toolchain_import rule: unpack a prebuilt toolchain archive and provide
BuildToolchainInfo.

The archive is expected to have been produced by toolchain_export and
contains metadata.json with provenance information.
"""

load("//defs:providers.bzl", "BuildToolchainInfo")

def _toolchain_import_impl(ctx):
    unpacked = ctx.actions.declare_output("toolchain", dir = True)

    cmd = cmd_args(ctx.attrs._unpack_tool[RunInfo])
    cmd.add("--archive", ctx.attrs.archive)
    cmd.add("--output", unpacked.as_output())

    ctx.actions.run(cmd, category = "toolchain_import", identifier = ctx.attrs.name)

    triple = ctx.attrs.target_triple

    # Build paths into the unpacked toolchain
    sysroot = unpacked.project("tools/" + triple + "/sys-root")
    cc = unpacked.project("tools/bin/" + triple + "-gcc")
    cxx = unpacked.project("tools/bin/" + triple + "-g++")
    ar = unpacked.project("tools/bin/" + triple + "-ar")
    strip_bin = unpacked.project("tools/bin/" + triple + "-strip")

    cc_args = cmd_args(cc)
    cc_args.add(cmd_args("--sysroot=", sysroot, delimiter = ""))

    cxx_args = cmd_args(cxx)
    cxx_args.add(cmd_args("--sysroot=", sysroot, delimiter = ""))

    info = BuildToolchainInfo(
        cc = RunInfo(args = cc_args),
        cxx = RunInfo(args = cxx_args),
        ar = RunInfo(args = cmd_args(ar)),
        strip = RunInfo(args = cmd_args(strip_bin)),
        make = RunInfo(args = cmd_args("make")),
        pkg_config = RunInfo(args = cmd_args("pkg-config")),
        target_triple = triple,
        sysroot = sysroot,
    )

    return [
        DefaultInfo(default_output = unpacked),
        info,
    ]

toolchain_import = rule(
    impl = _toolchain_import_impl,
    attrs = {
        "archive": attrs.source(),
        "target_triple": attrs.string(default = "x86_64-buckos-linux-gnu"),
        "_unpack_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:toolchain_unpack"),
        ),
    },
)
