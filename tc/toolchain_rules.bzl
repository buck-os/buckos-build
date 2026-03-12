"""
Toolchain rule definitions for BuckOS.

Four rules:

  buckos_toolchain           -- wraps PATH tools, no sysroot (bootstrap fallback)
  buckos_cross_toolchain     -- wraps PATH tools + buckos-built sysroot (monorepo integration)
  buckos_bootstrap_toolchain -- wraps BootstrapStageInfo artifacts (seed bootstrap)
  buckos_prebuilt_toolchain  -- wraps an unpacked prebuilt toolchain dir (legacy compat)

All return BuildToolchainInfo from defs/providers.bzl.

At analysis time we can't inspect PATH or run executables, so tool
paths are string attrs with sensible defaults ("cc", "c++", etc.)
that resolve at action time through the shell.  When build rules
consume BuildToolchainInfo, they pass these values to their Python
helper scripts which invoke the tools.
"""

load("//defs:providers.bzl", "BootstrapStageInfo", "BuildToolchainInfo", "PackageInfo")

# ── Host toolchain ───────────────────────────────────────────────────

def _buckos_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    """Host toolchain: PATH tools, host sysroot."""
    info = BuildToolchainInfo(
        cc = RunInfo(args = cmd_args(ctx.attrs.cc)),
        cxx = RunInfo(args = cmd_args(ctx.attrs.cxx)),
        ar = RunInfo(args = cmd_args(ctx.attrs.ar)),
        strip = RunInfo(args = cmd_args(ctx.attrs.strip_bin)),
        make = RunInfo(args = cmd_args(ctx.attrs.make)),
        pkg_config = RunInfo(args = cmd_args(ctx.attrs.pkg_config)),
        target_triple = ctx.attrs.target_triple,
        sysroot = None,
        python = None,
        host_bin_dir = None,
        allows_host_path = True,
        extra_cflags = ctx.attrs.extra_cflags,
        extra_ldflags = ctx.attrs.extra_ldflags,
    )
    return [DefaultInfo(), info]

buckos_toolchain = rule(
    impl = _buckos_toolchain_impl,
    is_toolchain_rule = True,
    attrs = {
        "cc": attrs.string(default = "cc"),
        "cxx": attrs.string(default = "c++"),
        "ar": attrs.string(default = "ar"),
        "strip_bin": attrs.string(default = "strip"),
        "make": attrs.string(default = "make"),
        "pkg_config": attrs.string(default = "pkg-config"),
        "target_triple": attrs.string(default = "x86_64-linux-gnu"),
        "extra_cflags": attrs.list(attrs.string(), default = []),
        "extra_ldflags": attrs.list(attrs.string(), default = []),
    },
)

# ── Cross toolchain ──────────────────────────────────────────────────

def _buckos_cross_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    """Cross toolchain: PATH compiler + buckos-built sysroot.

    The sysroot dep must provide PackageInfo (from the musl or glibc
    package).  Its prefix artifact becomes the sysroot path that gets
    injected as --sysroot into cc/cxx invocations.
    """
    sysroot_pkg = ctx.attrs.sysroot[PackageInfo]
    sysroot_dir = sysroot_pkg.prefix

    # Wrap cc/cxx with --sysroot so every compile and link sees the
    # buckos libc headers and libraries instead of the host's.
    sysroot_flag = cmd_args("--sysroot=", sysroot_dir, delimiter = "")

    cc_args = cmd_args(ctx.attrs.cc)
    cc_args.add(sysroot_flag)

    cxx_args = cmd_args(ctx.attrs.cxx)
    cxx_args.add(sysroot_flag)

    info = BuildToolchainInfo(
        cc = RunInfo(args = cc_args),
        cxx = RunInfo(args = cxx_args),
        ar = RunInfo(args = cmd_args(ctx.attrs.ar)),
        strip = RunInfo(args = cmd_args(ctx.attrs.strip_bin)),
        make = RunInfo(args = cmd_args(ctx.attrs.make)),
        pkg_config = RunInfo(args = cmd_args(ctx.attrs.pkg_config)),
        target_triple = ctx.attrs.target_triple,
        sysroot = sysroot_dir,
        python = None,
        host_bin_dir = None,
        allows_host_path = True,
        extra_cflags = ctx.attrs.extra_cflags,
        extra_ldflags = ctx.attrs.extra_ldflags,
    )
    return [DefaultInfo(), info]

buckos_cross_toolchain = rule(
    impl = _buckos_cross_toolchain_impl,
    is_toolchain_rule = True,
    attrs = {
        "cc": attrs.string(default = "cc"),
        "cxx": attrs.string(default = "c++"),
        "ar": attrs.string(default = "ar"),
        "strip_bin": attrs.string(default = "strip"),
        "make": attrs.string(default = "make"),
        "pkg_config": attrs.string(default = "pkg-config"),
        "sysroot": attrs.dep(providers = [PackageInfo]),
        "target_triple": attrs.string(default = "x86_64-buckos-linux-musl"),
        "extra_cflags": attrs.list(attrs.string(), default = []),
        "extra_ldflags": attrs.list(attrs.string(), default = []),
    },
)

# ── Bootstrap toolchain ─────────────────────────────────────────────

def _buckos_bootstrap_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    """Bootstrap toolchain: bridges BootstrapStageInfo -> BuildToolchainInfo.

    Uses the bootstrap-built compiler and sysroot artifacts directly.
    When host_tools is provided, its bin/ dir becomes the hermetic PATH
    and its make/pkg-config are used instead of host PATH lookups.
    """
    stage = ctx.attrs.bootstrap_stage[BootstrapStageInfo]

    cc_args = cmd_args(stage.cc)
    cc_args.add(cmd_args("--sysroot=", stage.sysroot, delimiter = ""))

    cxx_args = cmd_args(stage.cxx)
    cxx_args.add(cmd_args("--sysroot=", stage.sysroot, delimiter = ""))

    # Expose Python from bootstrap stage if available
    python_run_info = None
    if stage.python:
        python_run_info = RunInfo(args = cmd_args(stage.python))

    # Wire host tools when provided (stage 3 toolchain for hermetic rebuild)
    host_bin = None
    make_cmd = cmd_args(ctx.attrs.make)
    pkg_config_cmd = cmd_args(ctx.attrs.pkg_config)
    if ctx.attrs.host_tools:
        ht_dir = ctx.attrs.host_tools[DefaultInfo].default_outputs[0]
        host_bin = ht_dir.project("bin")
        make_cmd = cmd_args(host_bin.project("make"))
        pkg_config_cmd = cmd_args(host_bin.project("pkg-config"))
        if not python_run_info:
            python_run_info = RunInfo(args = cmd_args(host_bin.project("python3")))

    # Generate GCC link specs that inject the sysroot dynamic linker
    # and RPATH unconditionally at link time.  Uses the actual sysroot
    # ld-linux path (not a padded host path) so build-time binaries
    # execute with buckos glibc — no host glibc version dependency.
    # The path is left-padded with '/' so stale_root rewriting can
    # replace it in-place across machines.
    #
    # Extract RPATH from extra_ldflags (still passed as a string).
    rpath_val = None
    remaining_ldflags = []
    for flag in ctx.attrs.extra_ldflags:
        if "-rpath," in flag and "rpath-link" not in flag:
            rpath_val = flag.split("-rpath,", 1)[1]
        elif "--dynamic-linker," in flag:
            pass  # Ignored — interpreter comes from sysroot directly
        else:
            remaining_ldflags.append(flag)

    sysroot_ld = stage.sysroot.project("lib64/ld-linux-x86-64.so.2")
    specs_file = ctx.actions.declare_output("gcc-link.specs")
    gen_cmd = cmd_args(ctx.attrs._gen_specs_tool[RunInfo])
    gen_cmd.add("--ld-linux", sysroot_ld)
    if stage.gcc_lib_dir:
        gen_cmd.add("--gcc-lib-dir", stage.gcc_lib_dir)
    if rpath_val:
        gen_cmd.add("--rpath", rpath_val)
    gen_cmd.add("--output", specs_file.as_output())
    ctx.actions.run(gen_cmd, category = "gen_specs",
                    identifier = ctx.label.name)

    cc_args.add(cmd_args("-specs=", specs_file, delimiter = ""))
    cxx_args.add(cmd_args("-specs=", specs_file, delimiter = ""))

    # ld.bfd resolves DT_NEEDED chains and needs to find libstdc++.so
    # when linking C programs against C++ shared libraries.  The GCC
    # runtime libs live outside the sysroot — add them as rpath-link.
    ldflags = list(remaining_ldflags)
    if stage.gcc_lib_dir:
        ldflags.append(cmd_args("-Wl,-rpath-link,", stage.gcc_lib_dir, delimiter = ""))

    info = BuildToolchainInfo(
        cc = RunInfo(args = cc_args),
        cxx = RunInfo(args = cxx_args),
        ar = RunInfo(args = cmd_args(stage.ar)),
        strip = RunInfo(args = cmd_args(ctx.attrs.strip_bin)),
        make = RunInfo(args = make_cmd),
        pkg_config = RunInfo(args = pkg_config_cmd),
        target_triple = stage.target_triple,
        sysroot = stage.sysroot,
        python = python_run_info,
        host_bin_dir = host_bin,
        allows_host_path = ctx.attrs.host_tools == None,
        extra_cflags = ctx.attrs.extra_cflags,
        extra_ldflags = ldflags,
    )
    return [DefaultInfo(), info]

buckos_bootstrap_toolchain = rule(
    impl = _buckos_bootstrap_toolchain_impl,
    is_toolchain_rule = True,
    attrs = {
        "bootstrap_stage": attrs.dep(providers = [BootstrapStageInfo]),
        "host_tools": attrs.option(attrs.dep(), default = None),
        "strip_bin": attrs.string(default = "strip"),
        "make": attrs.string(default = "make"),
        "pkg_config": attrs.string(default = "pkg-config"),
        "extra_cflags": attrs.list(attrs.string(), default = []),
        "extra_ldflags": attrs.list(attrs.string(), default = []),
        "_gen_specs_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:gen_specs"),
        ),
    },
)

# ── Prebuilt toolchain ──────────────────────────────────────────────

def _buckos_prebuilt_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    """Prebuilt toolchain: wraps an unpacked toolchain directory.

    The toolchain_dir dep should produce a directory containing
    tools/bin/{triple}-gcc, tools/{triple}/sys-root, etc.
    """
    toolchain_dir = ctx.attrs.toolchain_dir[DefaultInfo].default_outputs[0]
    triple = ctx.attrs.target_triple
    sysroot = toolchain_dir.project("tools/" + triple + "/sys-root")

    cc_args = cmd_args(toolchain_dir.project("tools/bin/" + triple + "-gcc"))
    cc_args.add(cmd_args("--sysroot=", sysroot, delimiter = ""))

    cxx_args = cmd_args(toolchain_dir.project("tools/bin/" + triple + "-g++"))
    cxx_args.add(cmd_args("--sysroot=", sysroot, delimiter = ""))

    # ld.bfd resolves DT_NEEDED chains and needs to find libstdc++.so
    # when linking C programs against C++ shared libraries.  The GCC
    # runtime libs live outside the sysroot — add them as rpath-link.
    gcc_lib_dir = toolchain_dir.project("tools/" + triple + "/lib64")
    ldflags = list(ctx.attrs.extra_ldflags)
    ldflags.append(cmd_args("-Wl,-rpath-link,", gcc_lib_dir, delimiter = ""))

    info = BuildToolchainInfo(
        cc = RunInfo(args = cc_args),
        cxx = RunInfo(args = cxx_args),
        ar = RunInfo(args = cmd_args(toolchain_dir.project("tools/bin/" + triple + "-ar"))),
        strip = RunInfo(args = cmd_args(toolchain_dir.project("tools/bin/" + triple + "-strip"))),
        make = RunInfo(args = cmd_args(ctx.attrs.make)),
        pkg_config = RunInfo(args = cmd_args(ctx.attrs.pkg_config)),
        target_triple = triple,
        sysroot = sysroot,
        python = None,
        host_bin_dir = None,
        allows_host_path = False,
        extra_cflags = ctx.attrs.extra_cflags,
        extra_ldflags = ldflags,
    )
    return [DefaultInfo(), info]

buckos_prebuilt_toolchain = rule(
    impl = _buckos_prebuilt_toolchain_impl,
    is_toolchain_rule = True,
    attrs = {
        "toolchain_dir": attrs.dep(),
        "target_triple": attrs.string(default = "x86_64-buckos-linux-gnu"),
        "make": attrs.string(default = "make"),
        "pkg_config": attrs.string(default = "pkg-config"),
        "extra_cflags": attrs.list(attrs.string(), default = []),
        "extra_ldflags": attrs.list(attrs.string(), default = []),
    },
)
