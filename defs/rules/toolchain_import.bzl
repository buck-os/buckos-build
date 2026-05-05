"""
toolchain_import rule: unpack a prebuilt toolchain archive and provide
BuildToolchainInfo.

The archive is expected to have been produced by toolchain_export and
contains metadata.json with provenance information.  If the archive
includes host-tools/, those are wired as the hermetic PATH directory.
"""

load("//defs:providers.bzl", "BuildToolchainInfo")

def _lib_subdir(triple):
    """Return the GCC runtime lib subdirectory name for a given triple.

    GCC installs runtime libs to lib64/ on both x86_64 and aarch64.
    """
    return "lib64"

def _sysroot_lib_subdir(triple):
    """Return the sysroot lib subdirectory name for a given triple."""
    if triple.startswith("aarch64"):
        return "lib"
    return "lib64"

def _toolchain_import_impl(ctx):
    unpacked = ctx.actions.declare_output("toolchain", dir = True)

    cmd = cmd_args(ctx.attrs._unpack_tool[RunInfo])
    cmd.add("--archive", ctx.attrs.archive)
    cmd.add("--output", unpacked.as_output())

    ctx.actions.run(cmd, category = "toolchain_import", identifier = ctx.attrs.name, allow_cache_upload = False)

    triple = ctx.attrs.target_triple
    libdir = _lib_subdir(triple)

    # Wire host tools from the seed archive when present.
    # The archive layout is: host-tools/bin/{make,sed,...}
    host_bin = unpacked.project("host-tools/bin") if ctx.attrs.has_host_tools else None

    make_cmd = cmd_args(host_bin.project("make")) if host_bin else cmd_args("make")
    pkg_config_cmd = cmd_args(host_bin.project("pkg-config")) if host_bin else cmd_args("pkg-config")

    # Don't project python3 from host_bin — the binary may have a
    # build-machine ELF interpreter.  Python rules find python3 on
    # the hermetic PATH (host-tools/bin) at runtime instead.
    python_cmd = None

    if ctx.attrs.exec_mode:
        # Exec mode: cross-compiler for building exec deps (tools
        # that run on the host).  Same arch (x86_64 → x86_64) so
        # cross-compiled binaries execute on the host.  Uses the
        # cross-compiler from tools/ rather than requiring gcc-native
        # in host-tools — keeps the seed small (no gcc-native needed).
        sysroot = unpacked.project("tools/" + triple + "/sys-root")
        cc = unpacked.project("tools/bin/" + triple + "-gcc")
        cxx = unpacked.project("tools/bin/" + triple + "-g++")
        ar = unpacked.project("tools/bin/" + triple + "-ar")
        strip_bin = unpacked.project("tools/bin/" + triple + "-strip")

        cc_args = cmd_args(cc)
        cc_args.add(cmd_args("--sysroot=", sysroot, delimiter = ""))
        cxx_args = cmd_args(cxx)
        cxx_args.add(cmd_args("--sysroot=", sysroot, delimiter = ""))

        gcc_lib_dir = unpacked.project("tools/" + triple + "/" + libdir)
        ldflags = list(ctx.attrs.extra_ldflags)
        ldflags.append(cmd_args("-Wl,-rpath-link,", gcc_lib_dir, delimiter = ""))
        ldflags.append(cmd_args("-L", sysroot.project("usr/lib64"), delimiter = ""))
        ldflags.append(cmd_args("-L", sysroot.project("usr/lib"), delimiter = ""))
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
        gcc_lib_dir = unpacked.project("tools/" + triple + "/" + libdir)
        sysroot_libdir = _sysroot_lib_subdir(triple)
        ldflags = list(ctx.attrs.extra_ldflags)
        ldflags.append(cmd_args("-Wl,-rpath-link,", gcc_lib_dir, delimiter = ""))
        # Explicit -L for sysroot lib dirs — see toolchain_rules.bzl comment.
        ldflags.append(cmd_args("-L", sysroot.project("usr/" + sysroot_libdir), delimiter = ""))
        ldflags.append(cmd_args("-L", sysroot.project("usr/lib"), delimiter = ""))

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
