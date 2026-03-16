"""
Kernel build rules for BuckOS.

Rules:
  kernel_config          — merge kernel configuration fragments into a single .config
  kernel_build           — build Linux kernel with custom configuration
  kernel_headers         — install kernel headers for userspace
  kernel_btf_headers     — generate vmlinux.h from kernel BTF data
  kernel_modules_install — install kernel modules with out-of-tree merging
"""

load("//defs:empty_registry.bzl", "PATCH_REGISTRY")
load("//defs:providers.bzl", "BuildToolchainInfo", "KernelBtfInfo", "KernelConfigInfo", "KernelHeadersInfo", "KernelInfo", "PackageInfo")
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
        source: Kernel source dependency (download_source target)
        version: Kernel version string
        config: Optional direct path to .config file
        config_dep: Optional dependency providing generated .config (from kernel_config)
        arch: Target architecture (x86_64 or aarch64)
        cross_toolchain: Optional cross-compilation toolchain dependency
        patches: List of patch files to apply to kernel source before build
        modules: List of external module source dependencies (download_source targets) to compile
        visibility: Target visibility (defaults to PACKAGE file setting)
    """
    # Apply private patch registry overrides
    merged_patches = list(patches)
    private = PATCH_REGISTRY.get(name, {})
    if "patches" in private:
        merged_patches.extend(private["patches"])

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
