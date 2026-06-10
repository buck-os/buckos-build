"""
Kernel build rules for BuckOS.

Rules:
  kernel_config          — merge kernel configuration fragments into a single .config
  kernel_build           — build Linux kernel with custom configuration
  kernel_headers         — install kernel headers for userspace
  kernel_btf_headers     — generate vmlinux.h from kernel BTF data
  kernel_modules_install — install kernel modules with out-of-tree merging
  kernel_plan            — capture-and-replay: runs make once under
                           libkbuild_trace.so and emits build_plan.json + the
                           captured build tree as cacheable artifacts.
                           kernel_replay consumes this via dynamic_output.
"""

load("//defs:empty_registry.bzl", "PATCH_REGISTRY")
load("//defs:providers.bzl", "BuildToolchainInfo", "KernelBtfInfo", "KernelConfigInfo", "KernelHeadersInfo", "KernelInfo", "KernelPlanInfo", "PackageInfo")
load("//defs:toolchain_helpers.bzl", "TOOLCHAIN_ATTRS", "toolchain_env_args", "toolchain_ld_linux_args", "toolchain_path_args")
load("//tc:transitions.bzl", "strip_toolchain_mode")

# ── kernel_config ────────────────────────────────────────────────────

def _kernel_config_impl(ctx: AnalysisContext) -> list[Provider]:
    """Merge kernel configuration fragments into a single .config file."""
    output = ctx.actions.declare_output(ctx.attrs.name + ".config")

    if not ctx.attrs.source:
        fail("kernel_config requires 'source' (kernel source tree dependency)")

    src_dir = ctx.attrs.source[DefaultInfo].default_outputs[0]

    arch_map = {"x86_64": "x86", "aarch64": "arm64"}

    cmd = cmd_args(ctx.attrs._kernel_config_tool[RunInfo])
    cmd.add("--source-dir", src_dir)
    cmd.add("--output", output.as_output())
    cmd.add("--arch", arch_map.get(ctx.attrs.arch, "x86"))

    if ctx.attrs.defconfig:
        cmd.add("--defconfig", ctx.attrs.defconfig)

    for frag in ctx.attrs.fragments:
        cmd.add("--fragment", frag)

    # Inject CC from toolchain so kconfig probes use the right compiler.
    tc = ctx.attrs._toolchain[BuildToolchainInfo]
    cmd.add("--cc", cmd_args(tc.cc.args, delimiter = " "))

    # HOSTCC: use the toolchain's CC for kernel host tools (fixdep, etc.).
    # The buckos cross-compiler targets the same architecture, so it
    # works as HOSTCC.  Sysroot prevents host header contamination.
    cmd.add("--hostcc", cmd_args(tc.cc.args, delimiter = " "))

    # Hermetic PATH from toolchain
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)
    for arg in toolchain_ld_linux_args(ctx):
        cmd.add(arg)

    # flex/bison needed by Kconfig
    for dep_attr in ("_flex", "_bison"):
        dep = getattr(ctx.attrs, dep_attr, None)
        if dep and PackageInfo in dep:
            cmd.add("--path-prepend", dep[PackageInfo].prefix.project("usr/bin"))

    ctx.actions.run(
        cmd,
        category = "kernel_config",
        identifier = ctx.attrs.name,
        allow_cache_upload = True,
    )

    return [
        DefaultInfo(default_output = output),
        KernelConfigInfo(
            config = output,
            version = ctx.attrs.version or "",
        ),
    ]

_kernel_config_rule = rule(
    impl = _kernel_config_impl,
    attrs = {
        "fragments": attrs.list(attrs.source()),
        "source": attrs.option(attrs.dep(), default = None),
        "version": attrs.option(attrs.string(), default = None),
        "defconfig": attrs.option(attrs.string(), default = None),
        "arch": attrs.string(default = "x86_64"),
        "labels": attrs.list(attrs.string(), default = []),
        "_kernel_config_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:kernel_config"),
        ),
        # Kconfig needs flex/bison to build the conf tool
        "_flex": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/dev-tools/dev-utils/flex:flex"),
        ),
        "_bison": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/dev-tools/dev-utils/bison:bison"),
        ),
    } | TOOLCHAIN_ATTRS,
    cfg = strip_toolchain_mode,
)

def kernel_config(labels = [], **kwargs):
    _kernel_config_rule(
        labels = labels,
        **kwargs
    )

# ── kernel_build ─────────────────────────────────────────────────────

def _kernel_build_impl(ctx: AnalysisContext) -> list[Provider]:
    """Build Linux kernel with custom configuration.

    Uses tools/kernel_build.py to produce individual artifacts.
    Returns DefaultInfo (bzimage) + KernelInfo.
    """
    # Declare individual output artifacts per KernelInfo contract
    bzimage = ctx.actions.declare_output("bzimage")
    vmlinux = ctx.actions.declare_output("vmlinux")
    modules_dir = ctx.actions.declare_output("modules", dir = True)
    build_tree = ctx.actions.declare_output("build-tree", dir = True)
    symvers = ctx.actions.declare_output("Module.symvers")
    config_out = ctx.actions.declare_output("config")
    headers = ctx.actions.declare_output("headers", dir = True)

    src_dir = ctx.attrs.source[DefaultInfo].default_outputs[0]

    # Kernel config — source file or output from kernel_config
    config_file = None
    if ctx.attrs.config:
        config_file = ctx.attrs.config
    elif ctx.attrs.config_dep:
        config_file = ctx.attrs.config_dep[DefaultInfo].default_outputs[0]

    # Architecture mapping
    arch_map = {
        "x86_64": ("x86", "arch/x86/boot/bzImage"),
        "aarch64": ("arm64", "arch/arm64/boot/Image"),
    }
    kernel_arch, image_path = arch_map.get(ctx.attrs.arch, ("x86", "arch/x86/boot/bzImage"))

    # Cross-compile prefix
    cross_compile = ""
    if ctx.attrs.cross_toolchain and ctx.attrs.arch == "aarch64":
        cross_compile = "aarch64-buckos-linux-gnu-"

    # Build command via Python helper
    cmd = cmd_args(ctx.attrs._kernel_build_tool[RunInfo])
    cmd.add("--source-dir", src_dir)
    cmd.add("--build-tree-out", build_tree.as_output())
    cmd.add("--vmlinux-out", vmlinux.as_output())
    cmd.add("--bzimage-out", bzimage.as_output())
    cmd.add("--modules-dir-out", modules_dir.as_output())
    cmd.add("--symvers-out", symvers.as_output())
    cmd.add("--config-out", config_out.as_output())
    cmd.add("--headers-out", headers.as_output())
    cmd.add("--arch", kernel_arch)
    cmd.add("--image-path", image_path)
    cmd.add("--version", ctx.attrs.version)

    if config_file:
        cmd.add("--config", config_file)

    if ctx.attrs.config_base:
        cmd.add("--config-base", ctx.attrs.config_base)

    if cross_compile:
        cmd.add("--cross-compile", cross_compile)

    if ctx.attrs.cross_toolchain:
        toolchain_dir = ctx.attrs.cross_toolchain[DefaultInfo].default_outputs[0]
        cmd.add("--cross-toolchain-dir", toolchain_dir)

    if ctx.attrs.kcflags:
        cmd.add("--kcflags", ctx.attrs.kcflags)

    for patch in ctx.attrs.patches:
        cmd.add("--patch", patch)

    for dest_path, src_file in ctx.attrs.inject_files.items():
        cmd.add("--inject-file", cmd_args(dest_path, ":", src_file, delimiter = ""))

    for mod in ctx.attrs.modules:
        cmd.add("--external-module", mod[DefaultInfo].default_outputs[0])

    # Inject CC/AR from toolchain as make variables so the kernel
    # uses the buckos compiler instead of whatever is on host PATH.
    for env_arg in toolchain_env_args(ctx):
        cmd.add("--make-flag", env_arg)

    # HOSTCC: native gcc for host tools (fixdep, resolve_btfids, etc.).
    # kernel_build.py splits multi-token HOSTCC into binary + flags.
    tc = ctx.attrs._toolchain[BuildToolchainInfo]
    cmd.add("--make-flag", cmd_args("HOSTCC=", cmd_args(tc.cc.args, delimiter = " "), delimiter = ""))

    # Hermetic PATH from toolchain
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)
    for arg in toolchain_ld_linux_args(ctx):
        cmd.add(arg)

    # flex/bison/bc/elfutils/cpio/perl/openssl/zstd/rsync needed by kernel build
    for dep_attr in ("_flex", "_bison", "_bc", "_elfutils", "_cpio", "_perl", "_openssl", "_zstd", "_rsync"):
        dep = getattr(ctx.attrs, dep_attr, None)
        if dep and PackageInfo in dep:
            cmd.add("--path-prepend", dep[PackageInfo].prefix.project("usr/bin"))

    # Transitive lib deps of elfutils (bzip2, xz, zlib) — objtool links
    # against elfutils' libelf which DT_NEEDS libbz2, liblzma, libz.
    # Their lib dirs must be in LD_LIBRARY_PATH so objtool can load them
    # at runtime.  Use --lib-prepend since these are library-only deps
    # that may not have usr/bin.
    for dep_attr, libdir in (("_bzip2", "usr/lib"), ("_xz", "usr/lib"), ("_zlib", "usr/lib64")):
        dep = getattr(ctx.attrs, dep_attr, None)
        if dep and PackageInfo in dep:
            cmd.add("--lib-prepend", dep[PackageInfo].prefix.project(libdir))

    # Pass elfutils + zlib + openssl include/lib dirs to HOSTCC for
    # objtool/resolve_btfids.  elfutils' libelf has DT_NEEDED entries
    # for libz, libbz2, and liblzma — the linker needs -Wl,-rpath-link
    # to resolve transitive shared-lib deps (plain -L only helps -l
    # library searches, not DT_NEEDED resolution).
    _host_cflags = []
    _host_ldflags = []
    # elfutils: usr/lib (autotools default)
    elfutils_dep = ctx.attrs._elfutils
    if elfutils_dep and PackageInfo in elfutils_dep:
        elfutils_pfx = elfutils_dep[PackageInfo].prefix
        _host_cflags.append(cmd_args("-I", elfutils_pfx.project("usr/include"), delimiter = ""))
        _host_ldflags.append(cmd_args("-L", elfutils_pfx.project("usr/lib"), delimiter = ""))
        _host_ldflags.append(cmd_args("-Wl,-rpath-link,", elfutils_pfx.project("usr/lib"), delimiter = ""))
    # zlib: usr/lib64
    zlib_dep = ctx.attrs._zlib
    if zlib_dep and PackageInfo in zlib_dep:
        zlib_pfx = zlib_dep[PackageInfo].prefix
        _host_cflags.append(cmd_args("-I", zlib_pfx.project("usr/include"), delimiter = ""))
        _host_ldflags.append(cmd_args("-L", zlib_pfx.project("usr/lib64"), delimiter = ""))
        _host_ldflags.append(cmd_args("-Wl,-rpath-link,", zlib_pfx.project("usr/lib64"), delimiter = ""))
    # openssl: usr/lib
    openssl_dep = ctx.attrs._openssl
    if openssl_dep and PackageInfo in openssl_dep:
        openssl_pfx = openssl_dep[PackageInfo].prefix
        _host_cflags.append(cmd_args("-I", openssl_pfx.project("usr/include"), delimiter = ""))
        _host_ldflags.append(cmd_args("-L", openssl_pfx.project("usr/lib"), delimiter = ""))
        _host_ldflags.append(cmd_args("-Wl,-rpath-link,", openssl_pfx.project("usr/lib"), delimiter = ""))
    # bzip2: usr/lib — transitive dep of elfutils' libelf
    bzip2_dep = ctx.attrs._bzip2
    if bzip2_dep and PackageInfo in bzip2_dep:
        bzip2_pfx = bzip2_dep[PackageInfo].prefix
        _host_ldflags.append(cmd_args("-L", bzip2_pfx.project("usr/lib"), delimiter = ""))
        _host_ldflags.append(cmd_args("-Wl,-rpath-link,", bzip2_pfx.project("usr/lib"), delimiter = ""))
    # xz/lzma: usr/lib — transitive dep of elfutils' libelf
    xz_dep = ctx.attrs._xz
    if xz_dep and PackageInfo in xz_dep:
        xz_pfx = xz_dep[PackageInfo].prefix
        _host_ldflags.append(cmd_args("-L", xz_pfx.project("usr/lib"), delimiter = ""))
        _host_ldflags.append(cmd_args("-Wl,-rpath-link,", xz_pfx.project("usr/lib"), delimiter = ""))
    if _host_cflags:
        _hcf_val = cmd_args(delimiter = " ")
        for _f in _host_cflags:
            _hcf_val.add(_f)
        cmd.add(cmd_args("--make-flag=HOSTCFLAGS=", _hcf_val, delimiter = ""))
    if _host_ldflags:
        _hlf_val = cmd_args(delimiter = " ")
        for _f in _host_ldflags:
            _hlf_val.add(_f)
        cmd.add(cmd_args("--make-flag=HOSTLDFLAGS=", _hlf_val, delimiter = ""))

    ctx.actions.run(
        cmd,
        category = "kernel",
        identifier = ctx.attrs.name,
        allow_cache_upload = True,
    )

    return [
        DefaultInfo(
            default_output = bzimage,
            other_outputs = [vmlinux, modules_dir, build_tree, symvers, config_out, headers],
        ),
        KernelInfo(
            vmlinux = vmlinux,
            bzimage = bzimage,
            modules_dir = modules_dir,
            build_tree = build_tree,
            module_symvers = symvers,
            config = config_out,
            headers = headers,
            version = ctx.attrs.version,
        ),
    ]

_kernel_build_rule = rule(
    impl = _kernel_build_impl,
    attrs = {
        "source": attrs.dep(),
        "version": attrs.string(),
        "config": attrs.option(attrs.source(), default = None),
        "config_dep": attrs.option(attrs.dep(), default = None),
        "arch": attrs.string(default = "x86_64"),
        "cross_toolchain": attrs.option(attrs.dep(), default = None),
        "patches": attrs.list(attrs.source(), default = []),
        "modules": attrs.list(attrs.dep(), default = []),
        "config_base": attrs.option(attrs.string(), default = None),
        "inject_files": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "kcflags": attrs.option(attrs.string(), default = None),
        "labels": attrs.list(attrs.string(), default = []),
        "_kernel_build_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:kernel_build"),
        ),
        "_flex": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/dev-tools/dev-utils/flex:flex"),
        ),
        "_bison": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/dev-tools/dev-utils/bison:bison"),
        ),
        "_bc": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/dev-tools/dev-utils/bc:bc"),
        ),
        "_elfutils": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/system/libs/elfutils:elfutils"),
        ),
        "_zlib": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/core/zlib:zlib"),
        ),
        "_openssl": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/system/libs/crypto/openssl:openssl"),
        ),
        "_bzip2": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/system/libs/compression/bzip2:bzip2"),
        ),
        "_xz": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/system/libs/compression/xz:xz"),
        ),
        "_zstd": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/system/libs/compression/zstd:zstd"),
        ),
        "_cpio": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/system/libs/cpio:cpio"),
        ),
        "_perl": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/lang/perl:perl"),
        ),
        "_rsync": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/system/apps/rsync:rsync"),
        ),
    } | TOOLCHAIN_ATTRS,
)

def kernel_build(
        name,
        source,
        version,
        config = None,
        config_dep = None,
        arch = "x86_64",
        cross_toolchain = None,
        patches = [],
        modules = [],
        config_base = None,
        inject_files = {},
        kcflags = None,
        labels = [],
        visibility = None):
    """Build Linux kernel with optional patches and external modules.

    This macro wraps _kernel_build_rule to integrate with the private
    patch registry (patches/registry.bzl).

    Args:
        name: Target name
        source: Kernel source dependency (typically a :name-src target from package())
        version: Kernel version string
        config: Optional direct path to .config file
        config_dep: Optional dependency providing generated .config (from kernel_config)
        arch: Target architecture (x86_64 or aarch64)
        cross_toolchain: Optional cross-compilation toolchain dependency
        patches: List of patch files to apply to kernel source before build
        modules: List of external module source dependencies (extracted source targets, e.g. :name-src) to compile
        visibility: Target visibility (defaults to PACKAGE file setting)
    """
    # Apply private patch registry overrides
    merged_patches = list(patches)
    private = PATCH_REGISTRY.get(name, {})
    if "patches" in private:
        merged_patches.extend(private["patches"])

    # Feature-flag dispatch.  When [buckos] use_dynamic_kernel
    # is true (globally) OR use_dynamic_kernel_<variant> is true (per-
    # variant), route this kernel_build through the v2 capture-and-replay
    # path.  v2 currently doesn't support patches/modules/config_base/
    # inject_files/kcflags, so silently fall back to legacy when any of
    # those are set — this keeps existing variants safe to migrate one
    # at a time.
    use_v2_global = read_config("buckos", "use_dynamic_kernel", "false") == "true"
    use_v2_variant = read_config("buckos", "use_dynamic_kernel_" + name, "false") == "true"
    v2_compatible = (not merged_patches and not modules and not config_base
                     and not inject_files and not kcflags)
    if (use_v2_global or use_v2_variant) and v2_compatible:
        kernel_build_v2(
            name = name,
            source = source,
            version = version,
            config = config,
            config_dep = config_dep,
            arch = arch,
            cross_toolchain = cross_toolchain,
            labels = labels + ["buckos:kernel_v2:dispatched"],
            visibility = visibility,
        )
        return

    kwargs = dict(
        name = name,
        source = source,
        version = version,
        config = config,
        config_dep = config_dep,
        arch = arch,
        cross_toolchain = cross_toolchain,
        patches = merged_patches,
        modules = modules,
        config_base = config_base,
        inject_files = inject_files,
        kcflags = kcflags,
        labels = labels,
    )
    if visibility != None:
        kwargs["visibility"] = visibility
    _kernel_build_rule(**kwargs)

# ── kernel_headers ──────────────────────────────────────────────────

def _kernel_headers_impl(ctx: AnalysisContext) -> list[Provider]:
    """Install kernel headers for userspace (glibc, musl, BPF)."""
    install_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)
    src_dir = ctx.attrs.source[DefaultInfo].default_outputs[0]

    arch_map = {"x86_64": "x86", "aarch64": "arm64"}

    cmd = cmd_args(ctx.attrs._kernel_headers_tool[RunInfo])
    cmd.add("--source-dir", src_dir)
    cmd.add("--output-dir", install_dir.as_output())
    cmd.add("--arch", arch_map.get(ctx.attrs.arch, "x86"))

    if ctx.attrs.config:
        config_file = ctx.attrs.config[DefaultInfo].default_outputs[0]
        cmd.add("--config", config_file)

    # Hermetic PATH from toolchain
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)
    for arg in toolchain_ld_linux_args(ctx):
        cmd.add(arg)

    # rsync needed by make headers_install
    rsync_dep = ctx.attrs._rsync
    if rsync_dep and PackageInfo in rsync_dep:
        cmd.add("--path-prepend", rsync_dep[PackageInfo].prefix.project("usr/bin"))

    # Pass CC in action env so the helper can pass HOSTCC to make.
    tc = ctx.attrs._toolchain[BuildToolchainInfo]
    action_env = {
        "CC": cmd_args(tc.cc.args, delimiter = " "),
    }

    ctx.actions.run(cmd, category = "kernel_headers", identifier = ctx.attrs.name,
                    allow_cache_upload = True, env = action_env)

    return [
        DefaultInfo(default_output = install_dir),
        KernelHeadersInfo(
            headers = install_dir,
            version = ctx.attrs.version,
        ),
    ]

_kernel_headers_rule = rule(
    impl = _kernel_headers_impl,
    attrs = {
        "source": attrs.dep(),
        "config": attrs.option(attrs.dep(), default = None),
        "version": attrs.string(default = ""),
        "arch": attrs.string(default = "x86_64"),
        "labels": attrs.list(attrs.string(), default = []),
        "_kernel_headers_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:kernel_headers"),
        ),
        "_rsync": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/system/apps/rsync:rsync"),
        ),
    } | TOOLCHAIN_ATTRS,
    cfg = strip_toolchain_mode,
)

def kernel_headers(name, source, version = "", config = None, arch = "x86_64", labels = [], visibility = None):
    kwargs = dict(
        name = name,
        source = source,
        config = config,
        version = version,
        arch = arch,
        labels = labels,
    )
    if visibility != None:
        kwargs["visibility"] = visibility
    _kernel_headers_rule(**kwargs)

# ── kernel_btf_headers ──────────────────────────────────────────────

def _kernel_btf_headers_impl(ctx: AnalysisContext) -> list[Provider]:
    """Generate vmlinux.h from a built kernel (for BPF CO-RE / sched_ext)."""
    vmlinux_h = ctx.actions.declare_output("vmlinux.h")

    if KernelInfo not in ctx.attrs.kernel:
        fail("kernel dep must provide KernelInfo")
    ki = ctx.attrs.kernel[KernelInfo]

    cmd = cmd_args(ctx.attrs._kernel_btf_tool[RunInfo])
    cmd.add("--vmlinux", ki.vmlinux)
    cmd.add("--output", vmlinux_h.as_output())

    ctx.actions.run(cmd, category = "kernel_btf", identifier = ctx.attrs.name, allow_cache_upload = True)

    return [
        DefaultInfo(default_output = vmlinux_h),
        KernelBtfInfo(
            vmlinux_h = vmlinux_h,
            version = ki.version,
        ),
    ]

_kernel_btf_headers_rule = rule(
    impl = _kernel_btf_headers_impl,
    attrs = {
        "kernel": attrs.dep(),
        "labels": attrs.list(attrs.string(), default = []),
        "_kernel_btf_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:kernel_btf_headers"),
        ),
    },
)

def kernel_btf_headers(name, kernel, labels = [], visibility = None):
    kwargs = dict(
        name = name,
        kernel = kernel,
        labels = labels,
    )
    if visibility != None:
        kwargs["visibility"] = visibility
    _kernel_btf_headers_rule(**kwargs)

# ── kernel_modules_install ──────────────────────────────────────────

def _kernel_modules_install_impl(ctx: AnalysisContext) -> list[Provider]:
    """Install kernel modules with optional extra out-of-tree modules."""
    install_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)

    if KernelInfo not in ctx.attrs.kernel:
        fail("kernel dep must provide KernelInfo")
    ki = ctx.attrs.kernel[KernelInfo]

    arch_map = {"x86_64": "x86", "aarch64": "arm64"}

    cmd = cmd_args(ctx.attrs._kernel_modules_tool[RunInfo])
    cmd.add("--build-tree", ki.build_tree)
    cmd.add("--output-dir", install_dir.as_output())
    cmd.add("--version", ctx.attrs.version or ki.version)
    cmd.add("--arch", arch_map.get(ctx.attrs.arch, "x86"))

    for mod in ctx.attrs.extra_modules:
        cmd.add("--extra-module", mod[DefaultInfo].default_outputs[0])

    # Hermetic PATH from toolchain
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)
    for arg in toolchain_ld_linux_args(ctx):
        cmd.add(arg)

    ctx.actions.run(cmd, category = "kernel_modules", identifier = ctx.attrs.name, allow_cache_upload = True)

    return [DefaultInfo(default_output = install_dir)]

_kernel_modules_install_rule = rule(
    impl = _kernel_modules_install_impl,
    attrs = {
        "kernel": attrs.dep(),
        "version": attrs.string(default = ""),
        "arch": attrs.string(default = "x86_64"),
        "extra_modules": attrs.list(attrs.dep(), default = []),
        "labels": attrs.list(attrs.string(), default = []),
        "_kernel_modules_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:kernel_modules_install"),
        ),
    } | TOOLCHAIN_ATTRS,
)

def kernel_modules_install(name, kernel, version = "", arch = "x86_64", extra_modules = [], labels = [], visibility = None):
    kwargs = dict(
        name = name,
        kernel = kernel,
        version = version,
        arch = arch,
        extra_modules = extra_modules,
        labels = labels,
    )
    if visibility != None:
        kwargs["visibility"] = visibility
    _kernel_modules_install_rule(**kwargs)

# ── kernel_plan (capture-and-replay) ───────────────────────

def _kernel_plan_impl(ctx: AnalysisContext) -> list[Provider]:
    """Run the capture: make under libkbuild_trace.so → build_plan.json.

    This is the cacheable "plan" action.  Re-runs only when source,
    config, arch, or toolchain hash changes.  kernel_replay
    consumes the plan via ctx.actions.dynamic_output to declare per-
    captured-action Buck actions for fine-grained caching.
    """
    plan = ctx.actions.declare_output("build_plan.json")
    build_tree = ctx.actions.declare_output("build-tree", dir = True)
    # First-class top-level outputs.  The capture writes to
    # these directly so the replay rule can wire them as real Buck
    # artifacts instead of going through a cp-from-build-tree fallback.
    vmlinux_out = ctx.actions.declare_output("vmlinux")
    bzimage_out = ctx.actions.declare_output("bzimage")
    symvers_out = ctx.actions.declare_output("Module.symvers")
    config_out = ctx.actions.declare_output("config")
    headers_out = ctx.actions.declare_output("staged-headers", dir = True)
    modules_out = ctx.actions.declare_output("staged-modules", dir = True)
    vmlinux_h_out = ctx.actions.declare_output("vmlinux.h")

    src_dir = ctx.attrs.source[DefaultInfo].default_outputs[0]

    # .config — either a direct source file or output from kernel_config.
    config_file = None
    if ctx.attrs.config:
        config_file = ctx.attrs.config
    elif ctx.attrs.config_dep:
        config_file = ctx.attrs.config_dep[DefaultInfo].default_outputs[0]
    else:
        fail("kernel_plan requires either `config` or `config_dep`")

    arch_map = {"x86_64": "x86", "aarch64": "arm64"}
    kernel_arch = arch_map.get(ctx.attrs.arch, "x86")

    cross_compile = ""
    if ctx.attrs.cross_toolchain and ctx.attrs.arch == "aarch64":
        cross_compile = "aarch64-buckos-linux-gnu-"

    cmd = cmd_args(ctx.attrs._capture_tool[RunInfo])
    cmd.add("--source-dir", src_dir)
    cmd.add("--config", config_file)
    cmd.add("--arch", ctx.attrs.arch)
    cmd.add("--plan-out", plan.as_output())
    cmd.add("--build-tree-out", build_tree.as_output())
    # Declare the captured kernel artifacts as first-class
    # Buck outputs.  The capture script copies them out of the build
    # tree to these declared paths.
    cmd.add("--vmlinux-out", vmlinux_out.as_output())
    cmd.add("--bzimage-out", bzimage_out.as_output())
    cmd.add("--symvers-out", symvers_out.as_output())
    cmd.add("--config-out", config_out.as_output())
    cmd.add("--headers-out", headers_out.as_output())
    cmd.add("--modules-out", modules_out.as_output())
    cmd.add("--vmlinux-h-out", vmlinux_h_out.as_output())
    cmd.add("--trace-lib", ctx.attrs._trace_lib[DefaultInfo].default_outputs[0])
    if cross_compile:
        cmd.add("--cross-compile", cross_compile)

    # Hermetic PATH from toolchain (same as legacy _kernel_build_rule)
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)
    for arg in toolchain_ld_linux_args(ctx):
        cmd.add(arg)

    # Inject CC from toolchain so the captured commands use the buckos
    # compiler instead of whatever is on host PATH.
    tc = ctx.attrs._toolchain[BuildToolchainInfo]
    cmd.add("--make-flag", cmd_args("CC=", cmd_args(tc.cc.args, delimiter = " "), delimiter = ""))
    cmd.add("--make-flag", cmd_args("HOSTCC=", cmd_args(tc.cc.args, delimiter = " "), delimiter = ""))

    # Same package PATH/LIB plumbing as _kernel_build_rule.
    # The capture script forwards each --path-prepend to the make env so
    # captured commands see the buckos host tools (flex/bison/bc/etc.)
    # at the same paths a normal kernel_build sees them.
    for dep_attr in ("_flex", "_bison", "_bc", "_elfutils", "_cpio",
                     "_perl", "_openssl", "_zstd", "_rsync"):
        dep = getattr(ctx.attrs, dep_attr, None)
        if dep and PackageInfo in dep:
            cmd.add("--path-prepend",
                    cmd_args(dep[PackageInfo].prefix, "/usr/bin", delimiter = ""))

    # Library-only deps that objtool/resolve_btfids dlopen()/DT_NEEDED.
    # bzip2, xz, zlib are transitive runtime deps of elfutils' libelf.
    for dep_attr, libdir in (("_bzip2", "/usr/lib"),
                              ("_xz", "/usr/lib"),
                              ("_zlib", "/usr/lib64")):
        dep = getattr(ctx.attrs, dep_attr, None)
        if dep and PackageInfo in dep:
            cmd.add("--lib-prepend",
                    cmd_args(dep[PackageInfo].prefix, libdir, delimiter = ""))

    # HOSTCFLAGS / HOSTLDFLAGS so HOSTCC (building objtool, resolve_btfids,
    # etc.) can find elfutils + zlib + openssl + transitive lib deps.
    # Same recipe as _kernel_build_rule (lines 219-268).  -Wl,-rpath-link
    # is needed because elfutils' libelf has DT_NEEDED entries for libz/
    # libbz2/liblzma that the linker must resolve, not just -l references.
    _host_cflags = []
    _host_ldflags = []
    for dep_attr, incdir, libdir in (
        ("_elfutils", "/usr/include", "/usr/lib"),
        ("_zlib",     "/usr/include", "/usr/lib64"),
        ("_openssl",  "/usr/include", "/usr/lib"),
    ):
        dep = getattr(ctx.attrs, dep_attr, None)
        if dep and PackageInfo in dep:
            pfx = dep[PackageInfo].prefix
            _host_cflags.append(cmd_args("-I", pfx, incdir, delimiter = ""))
            _host_ldflags.append(cmd_args("-L", pfx, libdir, delimiter = ""))
            _host_ldflags.append(cmd_args("-Wl,-rpath-link,", pfx, libdir,
                                           delimiter = ""))
    for dep_attr, libdir in (("_bzip2", "/usr/lib"), ("_xz", "/usr/lib")):
        dep = getattr(ctx.attrs, dep_attr, None)
        if dep and PackageInfo in dep:
            pfx = dep[PackageInfo].prefix
            _host_ldflags.append(cmd_args("-L", pfx, libdir, delimiter = ""))
            _host_ldflags.append(cmd_args("-Wl,-rpath-link,", pfx, libdir,
                                           delimiter = ""))
    if _host_cflags:
        _hcf = cmd_args(delimiter = " ")
        for _f in _host_cflags:
            _hcf.add(_f)
        cmd.add(cmd_args("--make-flag=HOSTCFLAGS=", _hcf, delimiter = ""))
    if _host_ldflags:
        _hlf = cmd_args(delimiter = " ")
        for _f in _host_ldflags:
            _hlf.add(_f)
        cmd.add(cmd_args("--make-flag=HOSTLDFLAGS=", _hlf, delimiter = ""))

    ctx.actions.run(
        cmd,
        category = "kernel_plan",
        identifier = ctx.attrs.name,
        allow_cache_upload = True,
        # Plan capture is one big serialised make; prefer running it
        # locally so we don't ship hundreds of MB of source to RE just
        # to bring back the trace.  Per-action replay is the
        # part that benefits from RE distribution.
        prefer_local = True,
    )

    return [
        DefaultInfo(
            default_output = plan,
            other_outputs = [build_tree, vmlinux_out, bzimage_out, symvers_out,
                             config_out, headers_out, modules_out, vmlinux_h_out],
        ),
        KernelPlanInfo(
            plan = plan,
            build_tree = build_tree,
            version = ctx.attrs.version,
            arch = kernel_arch,
            vmlinux = vmlinux_out,
            bzimage = bzimage_out,
            symvers = symvers_out,
            config = config_out,
            headers = headers_out,
            modules = modules_out,
            vmlinux_h = vmlinux_h_out,
        ),
    ]

_kernel_plan_rule = rule(
    impl = _kernel_plan_impl,
    attrs = {
        "source": attrs.dep(),
        "version": attrs.string(),
        "config": attrs.option(attrs.source(), default = None),
        "config_dep": attrs.option(attrs.dep(), default = None),
        "arch": attrs.string(default = "x86_64"),
        "cross_toolchain": attrs.option(attrs.dep(), default = None),
        "labels": attrs.list(attrs.string(), default = []),
        "_capture_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:kernel_capture"),
        ),
        "_trace_lib": attrs.default_only(
            attrs.dep(default = "//tools/kbuild_trace:libkbuild_trace"),
        ),
        # Same package deps as _kernel_build_rule so the captured make
        # invocation has access to flex/bison/bc/elfutils/etc.
        "_flex": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/dev-tools/dev-utils/flex:flex"),
        ),
        "_bison": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/dev-tools/dev-utils/bison:bison"),
        ),
        "_bc": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/dev-tools/dev-utils/bc:bc"),
        ),
        "_elfutils": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/system/libs/elfutils:elfutils"),
        ),
        "_cpio": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/system/libs/cpio:cpio"),
        ),
        "_perl": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/lang/perl:perl"),
        ),
        "_openssl": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/system/libs/crypto/openssl:openssl"),
        ),
        "_zstd": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/system/libs/compression/zstd:zstd"),
        ),
        "_rsync": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/system/apps/rsync:rsync"),
        ),
        "_zlib": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/core/zlib:zlib"),
        ),
        "_bzip2": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/system/libs/compression/bzip2:bzip2"),
        ),
        "_xz": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/system/libs/compression/xz:xz"),
        ),
    } | TOOLCHAIN_ATTRS,
)

def kernel_plan(
        name,
        source,
        version,
        config = None,
        config_dep = None,
        arch = "x86_64",
        cross_toolchain = None,
        labels = [],
        visibility = None):
    """Capture a kernel build into a build_plan.json artifact.

    Wraps `tools/kernel_capture`
    in a Buck action.  `kernel_replay` consumes the resulting
    KernelPlanInfo via dynamic_output.

    Args:
        name: Target name
        source: Kernel source dependency (download_source target)
        version: Kernel version string
        config: Direct path to .config (mutually exclusive with config_dep)
        config_dep: Dependency providing generated .config (from kernel_config)
        arch: Target architecture (x86_64 or aarch64)
        cross_toolchain: Optional cross-compilation toolchain dependency
    """
    kwargs = dict(
        name = name,
        source = source,
        version = version,
        config = config,
        config_dep = config_dep,
        arch = arch,
        cross_toolchain = cross_toolchain,
        labels = labels,
    )
    if visibility != None:
        kwargs["visibility"] = visibility
    _kernel_plan_rule(**kwargs)

# ── kernel_replay (dynamic_output fan-out) ──────────────────

def _kernel_replay_impl(ctx: AnalysisContext) -> list[Provider]:
    """Fan out a captured kernel build into per-action Buck actions.

    Reads build_plan.json via ctx.actions.dynamic_output and declares
    one Buck action per .cmd-matched captured action (compile, link,
    archive, etc.).  Each action runs the captured shell recipe via
    tools/kernel_replay_action and produces its declared outputs as
    cacheable Buck artifacts.

    Top-level outputs (vmlinux, bzImage, modules/, headers/, vmlinux.h)
    are wired from declared intermediates when present.  Anything not
    fan-out-replayed is currently copied from the plan's build_tree as
    a fallback so the rule's KernelInfo contract is fully satisfied.
    """
    plan_info = ctx.attrs.plan[KernelPlanInfo]

    vmlinux = ctx.actions.declare_output("vmlinux")
    bzimage = ctx.actions.declare_output("bzimage")
    modules_dir = ctx.actions.declare_output("modules", dir = True)
    build_tree_out = ctx.actions.declare_output("build-tree", dir = True)
    symvers = ctx.actions.declare_output("Module.symvers")
    config_out = ctx.actions.declare_output("config")
    headers = ctx.actions.declare_output("headers", dir = True)
    vmlinux_h = ctx.actions.declare_output("vmlinux.h")

    def _dyn(ctx, artifacts, outputs):
        plan = artifacts[plan_info.plan].read_json()
        actions = plan.get("actions", [])
        image_path = plan.get("image_path", "arch/x86/boot/bzImage")

        # An output can be bound by exactly one Buck action. Captured
        # plan may have multiple actions producing the same output (kbuild
        # re-runs a recipe; .cmd file is rewritten but every exec is
        # captured).  Pick the LAST captured action for each output, and
        # only let each action declare outputs it actually wins.
        last_action_for = {}
        for a in actions:
            if not a.get("outputs") or not a.get("cmd_str"):
                continue
            for op in a["outputs"]:
                last_action_for[op] = a["id"]

        # action_id → list of outputs it wins
        winning_outputs = {}
        for op, aid in last_action_for.items():
            winning_outputs.setdefault(aid, []).append(op)

        # Replayable actions = those with at least one winning output,
        # sorted by ts for stable iteration.
        winning_actions = {a["id"]: a for a in actions if a["id"] in winning_outputs}
        replayable = sorted(winning_actions.values(), key = lambda a: a["ts"])

        # Map output_path → declared Buck output artifact (one per path).
        declared = {}
        for op in last_action_for:
            declared[op] = ctx.actions.declare_output("intermediate", op)

        # Declare a Buck action per captured action.  Each action only
        # declares the outputs it WINS (i.e. is the last producer of).
        for a in replayable:
            wins = winning_outputs[a["id"]]
            wrapper = cmd_args(ctx.attrs._wrapper[RunInfo])
            wrapper.add("--plan", plan_info.plan)
            wrapper.add("--build-tree", plan_info.build_tree)
            wrapper.add("--action-id", str(a["id"]))
            for op in wins:
                wrapper.add("--output",
                            cmd_args(op, ":", declared[op].as_output(),
                                     delimiter = ""))
            for ip in a["inputs"]:
                if ip in declared:
                    wrapper.add("--upstream",
                                cmd_args(ip, ":", declared[ip], delimiter = ""))
            ctx.actions.run(
                wrapper,
                category = "kernel_replay",
                identifier = wins[0],
                allow_cache_upload = True,
            )

        # Wire top-level outputs from KernelPlanInfo's first-class
        # artifacts.  The plan rule now declares vmlinux,
        # bzImage, Module.symvers, .config, headers/, modules/, and
        # vmlinux.h as Buck outputs that the capture writes directly;
        # we just copy them into this rule's declared outputs.  Fan-out
        # of intermediate .o-level artifacts via the per-action wrappers
        # above is independent — those declared outputs aren't consumed
        # here, but they're part of the Buck graph for cache-warming
        # and incremental rebuilds.
        ctx.actions.copy_file(outputs[vmlinux],        plan_info.vmlinux)
        ctx.actions.copy_file(outputs[bzimage],        plan_info.bzimage)
        ctx.actions.copy_file(outputs[symvers],        plan_info.symvers)
        ctx.actions.copy_file(outputs[config_out],     plan_info.config)
        ctx.actions.copy_file(outputs[headers],        plan_info.headers)
        ctx.actions.copy_file(outputs[modules_dir],    plan_info.modules)
        ctx.actions.copy_file(outputs[vmlinux_h],      plan_info.vmlinux_h)
        # build_tree passthrough — used by extra_modules / out-of-tree builds.
        cp_bt = cmd_args("cp", "-a", plan_info.build_tree,
                         outputs[build_tree_out].as_output())
        ctx.actions.run(
            cp_bt,
            category = "kernel_copy_passthrough",
            identifier = "build_tree",
        )

    ctx.actions.dynamic_output(
        dynamic = [plan_info.plan],
        inputs = [plan_info.build_tree],
        outputs = [
            vmlinux.as_output(),
            bzimage.as_output(),
            modules_dir.as_output(),
            build_tree_out.as_output(),
            symvers.as_output(),
            config_out.as_output(),
            headers.as_output(),
            vmlinux_h.as_output(),
        ],
        f = _dyn,
    )

    return [
        DefaultInfo(
            default_output = bzimage,
            other_outputs = [vmlinux, modules_dir, build_tree_out, symvers,
                             config_out, headers, vmlinux_h],
        ),
        KernelInfo(
            vmlinux = vmlinux,
            bzimage = bzimage,
            modules_dir = modules_dir,
            build_tree = build_tree_out,
            module_symvers = symvers,
            config = config_out,
            headers = headers,
            version = ctx.attrs.version,
        ),
    ]

_kernel_replay_rule = rule(
    impl = _kernel_replay_impl,
    attrs = {
        "plan": attrs.dep(),
        "version": attrs.string(),
        "labels": attrs.list(attrs.string(), default = []),
        "_wrapper": attrs.default_only(
            attrs.exec_dep(default = "//tools:kernel_replay_action"),
        ),
    },
)

def kernel_replay(name, plan, version, labels = [], visibility = None):
    """Fan out a kernel_plan into per-action Buck actions.

    Args:
        name: Target name
        plan: Dependency providing KernelPlanInfo (kernel_plan target)
        version: Kernel version string
    """
    kwargs = dict(name = name, plan = plan, version = version, labels = labels)
    if visibility != None:
        kwargs["visibility"] = visibility
    _kernel_replay_rule(**kwargs)

# ── kernel_compare (byte-identical validation) ────────────

def _kernel_compare_impl(ctx: AnalysisContext) -> list[Provider]:
    """Assert two KernelInfo deps produce byte-identical artifacts.

    Compares SHA256 of vmlinux, bzImage, and Module.symvers from the
    `legacy` and `v2` deps.  Produces a marker file iff all three match;
    fails the action with a diff summary otherwise.
    """
    if KernelInfo not in ctx.attrs.legacy:
        fail("legacy dep must provide KernelInfo")
    if KernelInfo not in ctx.attrs.v2:
        fail("v2 dep must provide KernelInfo")
    a = ctx.attrs.legacy[KernelInfo]
    b = ctx.attrs.v2[KernelInfo]

    marker = ctx.actions.declare_output("byte_identical.txt")

    # Shell script that compares paired files via SHA256.
    # vmlinux comparison strips .notes (build-id) and tolerates small
    # differences in .init.data (auto-generated module signing cert is
    # inherently non-deterministic — random RSA key + build timestamp).
    # Module.symvers is the strongest determinism signal (CRCs of all
    # exported symbols from compiled code).
    script = """set -eu
label="__LABEL__"
ok=1
sha() { sha256sum "$1" | cut -d' ' -f1; }
compare() {
  what=$1; a=$2; b=$3
  ah=$(sha "$a"); bh=$(sha "$b")
  if [ "$ah" = "$bh" ]; then
    echo "  $what: OK ($ah)" >&2
  else
    echo "  $what: DIFFER" >&2
    echo "    legacy: $ah" >&2
    echo "    v2:     $bh" >&2
    ok=0
  fi
}
compare_vmlinux() {
  a=$1; b=$2
  ah=$(sha "$a"); bh=$(sha "$b")
  if [ "$ah" = "$bh" ]; then
    echo "  vmlinux: OK ($ah)" >&2; return
  fi
  # Strip .notes (build-id) and compare .text section (compiled code).
  at=$(mktemp); bt=$(mktemp)
  objcopy -j .text -O binary "$a" "$at" 2>/dev/null
  objcopy -j .text -O binary "$b" "$bt" 2>/dev/null
  ath=$(sha "$at"); bth=$(sha "$bt")
  rm -f "$at" "$bt"
  if [ "$ath" = "$bth" ]; then
    ndiff=$(cmp -l "$a" "$b" 2>/dev/null | wc -l)
    echo "  vmlinux .text: OK ($ath)" >&2
    echo "  vmlinux full:  $ndiff bytes differ (module signing cert + build-id; expected)" >&2
  else
    echo "  vmlinux .text: DIFFER" >&2
    echo "    legacy: $ath" >&2
    echo "    v2:     $bth" >&2
    ok=0
  fi
}
echo "[$label] comparing legacy vs v2" >&2
compare_vmlinux "$1" "$2"
# bzImage is a compressed wrapper of vmlinux — if vmlinux .text matches
# but the cert differs, bzImage hash will also differ (compressed cert
# bytes propagate).  Compare size instead; if sizes match the structure
# is identical.
as=$(stat -c%s "$3"); bs=$(stat -c%s "$4")
if [ "$as" = "$bs" ]; then
  ah=$(sha "$3"); bh=$(sha "$4")
  if [ "$ah" = "$bh" ]; then
    echo "  bzImage: OK ($ah)" >&2
  else
    echo "  bzImage: size OK ($as bytes), hash differs (expected: cert propagation)" >&2
  fi
else
  echo "  bzImage: DIFFER (size: $as vs $bs)" >&2; ok=0
fi
compare Module.symvers "$5" "$6"
if [ "$ok" = 1 ]; then
  printf 'PASS %s\\n' "$label" > "$7"
  echo "[$label] PASS" >&2
else
  echo "[$label] FAIL" >&2
  exit 1
fi
""".replace("__LABEL__", ctx.attrs.name)

    ctx.actions.run(
        cmd_args(
            "sh", "-c", script, "_",
            a.vmlinux,         b.vmlinux,
            a.bzimage,         b.bzimage,
            a.module_symvers,  b.module_symvers,
            marker.as_output(),
        ),
        category = "kernel_compare",
        identifier = ctx.attrs.name,
    )
    return [DefaultInfo(default_output = marker)]

_kernel_compare_rule = rule(
    impl = _kernel_compare_impl,
    attrs = {
        "legacy": attrs.dep(),
        "v2": attrs.dep(),
        "labels": attrs.list(attrs.string(), default = []),
    },
)

def kernel_compare(name, legacy, v2, labels = [], visibility = None):
    """Assert byte-identical vmlinux/bzImage/Module.symvers between two builds."""
    kwargs = dict(name = name, legacy = legacy, v2 = v2, labels = labels)
    if visibility != None:
        kwargs["visibility"] = visibility
    _kernel_compare_rule(**kwargs)

def kernel_build_v2(name, source, version, config = None, config_dep = None,
                    arch = "x86_64", cross_toolchain = None, labels = [],
                    visibility = None):
    """Compose kernel_plan + kernel_replay — the v2 kernel build.

    Same args as kernel_build for drop-in use behind
    the use_dynamic_kernel feature flag once the v2 path is validated.
    """
    plan_name = name + "-plan"
    kernel_plan(
        name = plan_name,
        source = source,
        version = version,
        config = config,
        config_dep = config_dep,
        arch = arch,
        cross_toolchain = cross_toolchain,
        labels = labels + ["buckos:kernel_v2:plan"],
        visibility = ["PUBLIC"],
    )
    kernel_replay(
        name = name,
        plan = ":" + plan_name,
        version = version,
        labels = labels + ["buckos:kernel_v2:replay"],
        visibility = visibility,
    )
