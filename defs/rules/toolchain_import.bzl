"""
toolchain_import rule: unpack a prebuilt toolchain archive and provide
BuildToolchainInfo.

The archive is expected to have been produced by toolchain_export and
contains metadata.json with provenance information.  If the archive
includes host-tools/, those are wired as the hermetic PATH directory.
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

    # Wire host tools from the seed archive when present.
    # The archive layout is: host-tools/bin/{make,sed,...}
    host_bin = unpacked.project("host-tools/bin") if ctx.attrs.has_host_tools else None

    make_cmd = cmd_args(host_bin.project("make")) if host_bin else cmd_args("make")
    pkg_config_cmd = cmd_args(host_bin.project("pkg-config")) if host_bin else cmd_args("pkg-config")

    python_cmd = None
    if host_bin:
        python_cmd = RunInfo(args = cmd_args(host_bin.project("python3")))

    info = BuildToolchainInfo(
        cc = RunInfo(args = cc_args),
        cxx = RunInfo(args = cxx_args),
        ar = RunInfo(args = cmd_args(ar)),
        strip = RunInfo(args = cmd_args(strip_bin)),
        make = RunInfo(args = make_cmd),
        pkg_config = RunInfo(args = pkg_config_cmd),
        target_triple = triple,
        sysroot = sysroot,
        python = python_cmd,
        host_bin_dir = host_bin,
        extra_cflags = ctx.attrs.extra_cflags,
        extra_ldflags = ctx.attrs.extra_ldflags,
    )

    return [
        DefaultInfo(default_output = unpacked),
        info,
    ]

toolchain_import = rule(
    impl = _toolchain_import_impl,
    is_toolchain_rule = True,
    attrs = {
        "archive": attrs.source(),
        "target_triple": attrs.string(default = "x86_64-buckos-linux-gnu"),
        "has_host_tools": attrs.bool(default = False),
        "extra_cflags": attrs.list(attrs.string(), default = []),
        "extra_ldflags": attrs.list(attrs.string(), default = []),
        "labels": attrs.list(attrs.string(), default = []),
        "_unpack_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:toolchain_unpack"),
        ),
    },
)
