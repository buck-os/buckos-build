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

def _ld_linux_subpath(triple):
    """Return the sysroot-relative path to the dynamic linker for a given triple."""
    if triple.startswith("aarch64"):
        return "lib/ld-linux-aarch64.so.1"
    return "lib64/ld-linux-x86-64.so.2"

def _gcc_lib_subdir(triple):
    """Return the GCC runtime lib subdirectory name for a given triple.

    GCC installs runtime libs (libstdc++, libgcc_s) to lib64/ on both
    x86_64 and aarch64 targets.
    """
    return "lib64"

def _sysroot_lib_subdir(triple):
    """Return the sysroot lib subdirectory name for a given triple.

    glibc installs to lib/ on aarch64, lib64/ on x86_64.
    """
    if triple.startswith("aarch64"):
        return "lib"
    return "lib64"

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
    stage_dir = ctx.attrs.bootstrap_stage[DefaultInfo].default_outputs[0]
    triple = stage.target_triple

    # Patch compiler binary ELF interpreters to the sysroot ld-linux
    # and install GCC auto-loaded specs with padded dynamic linker + RPATH.
    # This makes CC a single binary path (no --sysroot= or -specs= needed),
    # fixing Makefiles that do `type $(CC)` or `test -x $(CC)`.
    ld_subpath = _ld_linux_subpath(triple)
    lib_subdir = _gcc_lib_subdir(triple)
    patched = ctx.actions.declare_output("patched-compiler", dir = True)
    sysroot_ld = stage.sysroot.project(ld_subpath)
    patchelf_bin = ctx.attrs._patchelf[DefaultInfo].default_outputs[0]

    # Extract RPATH from extra_ldflags for specs generation.
    rpath_val = None
    remaining_ldflags = []
    for flag in ctx.attrs.extra_ldflags:
        if "-rpath," in flag and "rpath-link" not in flag:
            rpath_val = flag.split("-rpath,", 1)[1]
        elif "--dynamic-linker," in flag:
            pass  # Ignored — interpreter comes from specs
        else:
            remaining_ldflags.append(flag)

    rewrite_cmd = cmd_args(ctx.attrs._rewrite_tool[RunInfo])
    rewrite_cmd.add("--tools-dir", stage_dir)
    rewrite_cmd.add("--ld-linux", sysroot_ld)
    rewrite_cmd.add("--patch-standard")
    rewrite_cmd.add("--patchelf", patchelf_bin)
    rewrite_cmd.add("--specs-gcc-triple", triple)
    rewrite_cmd.add("--specs-ld-subpath", ld_subpath)
    if rpath_val:
        rewrite_cmd.add("--specs-rpath", rpath_val)
    rewrite_cmd.add("--output-dir", patched.as_output())
    ctx.actions.run(
        rewrite_cmd,
        category = "patch_compiler",
        identifier = ctx.label.name,
        local_only = True,
        allow_cache_upload = False,
    )

    # Use patched compiler binaries.  GCC finds sysroot via built-in
    # --with-sysroot (relative to exec prefix) and loads specs from
    # lib/gcc/<triple>/<version>/specs automatically.
    patched_sysroot = patched.project("tools/" + triple + "/sys-root")
    patched_ld = patched_sysroot.project(ld_subpath)

    cc_args = cmd_args(patched.project("tools/bin/" + triple + "-gcc"))
    cxx_args = cmd_args(patched.project("tools/bin/" + triple + "-g++"))

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
        # Python comes from auto_tool_deps (python-host exec_dep)
        # when not in the base host tools.

    # GCC runtime libs (libstdc++, libgcc_s) live outside the sysroot.
    # Add them as both -rpath (runtime discovery) and -rpath-link
    # (link-time DT_NEEDED chain resolution).  Uses --disable-new-dtags
    # so RPATH entries use DT_RPATH (propagates to loaded shared libs).
    # These are buck2 cmd_args with artifacts, resolved to local paths
    # at analysis time — no remote cache portability issues.
    patched_gcc_lib_dir = patched.project("tools/" + triple + "/" + lib_subdir) if stage.gcc_lib_dir else None
    ldflags = list(remaining_ldflags)
    if patched_gcc_lib_dir:
        ldflags.append("-Wl,--disable-new-dtags")
        ldflags.append(cmd_args("-Wl,-rpath,", patched_gcc_lib_dir, delimiter = ""))
        ldflags.append(cmd_args("-Wl,-rpath-link,", patched_gcc_lib_dir, delimiter = ""))

    # Explicit -L for sysroot lib dirs so the linker finds sysroot libc
    # before any stray host paths (-L/usr/lib64) injected by pkg-config
    # or meson.  --sysroot only affects default search paths, not explicit
    # -L flags — a stray -L/usr/lib64 makes ld find the host's older libc
    # instead of the sysroot glibc, causing undefined __isoc23_* symbols.
    sysroot_libdir = _sysroot_lib_subdir(triple)
    ldflags.append(cmd_args("-L", patched_sysroot.project("usr/" + sysroot_libdir), delimiter = ""))
    ldflags.append(cmd_args("-L", patched_sysroot.project("usr/lib"), delimiter = ""))

    info = BuildToolchainInfo(
        cc = RunInfo(args = cc_args),
        cxx = RunInfo(args = cxx_args),
        ar = RunInfo(args = cmd_args(patched.project("tools/bin/" + triple + "-ar"))),
        strip = RunInfo(args = cmd_args(patched.project("tools/bin/" + triple + "-strip"))),
        make = RunInfo(args = make_cmd),
        pkg_config = RunInfo(args = pkg_config_cmd),
        target_triple = triple,
        sysroot = patched_sysroot,
        python = python_run_info,
        host_bin_dir = host_bin,
        # Host PATH fallback only when no host_tools provided (bootstrap
        # cycle-breaker for base tool builds).  When host_tools is set
        # (seed toolchains), PATH is fully hermetic from host_bin_dir.
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
        "_rewrite_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:rewrite_interps"),
        ),
        "_patchelf": attrs.default_only(
            attrs.dep(default = "//tc/bootstrap:patchelf-host"),
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
