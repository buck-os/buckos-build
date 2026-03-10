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

    ctx.actions.run(cmd, category = "toolchain_import", identifier = ctx.attrs.name, allow_cache_upload = False)

    triple = ctx.attrs.target_triple

    # Wire host tools from the seed archive when present.
    # The archive layout is: host-tools/bin/{make,sed,...}
    host_bin = unpacked.project("host-tools/bin") if ctx.attrs.has_host_tools else None

    make_cmd = cmd_args(host_bin.project("make")) if host_bin else cmd_args("make")
    pkg_config_cmd = cmd_args(host_bin.project("pkg-config")) if host_bin else cmd_args("pkg-config")

    python_cmd = None
    if host_bin:
        python_cmd = RunInfo(args = cmd_args(host_bin.project("python3")))

    if ctx.attrs.exec_mode:
        # Exec mode: native compiler from host-tools for building
        # exec deps (tools that run on the host during builds).
        # Uses gcc-native from host-tools/bin with the cross-toolchain's
        # sysroot.  The sysroot is needed because gcc-native has
        # --prefix=/usr baked in and would otherwise find incompatible
        # host headers (e.g. Ubuntu multiarch glibc) at /usr/include.
        sysroot = unpacked.project("tools/" + triple + "/sys-root")
        cc_args = cmd_args(host_bin.project("gcc"))
        cc_args.add(cmd_args("--sysroot=", sysroot, delimiter = ""))
        cxx_args = cmd_args(host_bin.project("g++"))
        cxx_args.add(cmd_args("--sysroot=", sysroot, delimiter = ""))
        ar = host_bin.project("ar")
        strip_bin = host_bin.project("strip")
        gcc_lib_dir = unpacked.project("tools/" + triple + "/lib64")
        host_lib_dir = unpacked.project("host-tools/lib64")
        ldflags = list(ctx.attrs.extra_ldflags)
        # Native gcc with --sysroot can't find its own runtime libs
        # (libgcc_s.so, libstdc++.so) because the sysroot prefix
        # redirects /usr/lib64 to sysroot/usr/lib64.  Add explicit
        # -L for host-tools/lib64 where the native runtime lives.
        ldflags.append(cmd_args("-L", host_lib_dir, delimiter = ""))
        ldflags.append(cmd_args("-Wl,-rpath-link,", gcc_lib_dir, delimiter = ""))
    else:
        # Cross mode: cross-compiler for building target packages.
        sysroot = unpacked.project("tools/" + triple + "/sys-root")
        cc = unpacked.project("tools/bin/" + triple + "-gcc")
        cxx = unpacked.project("tools/bin/" + triple + "-g++")
        ar = unpacked.project("tools/bin/" + triple + "-ar")
        strip_bin = unpacked.project("tools/bin/" + triple + "-strip")

        cc_args = cmd_args(cc)
        cc_args.add(cmd_args("--sysroot=", sysroot, delimiter = ""))

        cxx_args = cmd_args(cxx)
        cxx_args.add(cmd_args("--sysroot=", sysroot, delimiter = ""))

        # ld.bfd resolves DT_NEEDED chains and needs to find libstdc++.so
        # when linking C programs against C++ shared libraries.  The GCC
        # runtime libs live outside the sysroot — add them as rpath-link.
        gcc_lib_dir = unpacked.project("tools/" + triple + "/lib64")
        ldflags = list(ctx.attrs.extra_ldflags)
        ldflags.append(cmd_args("-Wl,-rpath-link,", gcc_lib_dir, delimiter = ""))

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
        allows_host_path = False,
        extra_cflags = ctx.attrs.extra_cflags,
        extra_ldflags = ldflags,
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
        "exec_mode": attrs.bool(default = False),
        "extra_cflags": attrs.list(attrs.string(), default = []),
        "extra_ldflags": attrs.list(attrs.string(), default = []),
        "labels": attrs.list(attrs.string(), default = []),
        "_unpack_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:toolchain_unpack"),
        ),
    },
)
