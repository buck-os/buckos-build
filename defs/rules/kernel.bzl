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
load("//defs:providers.bzl", "KernelBtfInfo", "KernelConfigInfo", "KernelHeadersInfo", "KernelInfo")
load("//defs:toolchain_helpers.bzl", "TOOLCHAIN_ATTRS", "toolchain_path_args")
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

    # Hermetic PATH from toolchain
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)

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

    # Hermetic PATH from toolchain
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)

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

    ctx.actions.run(cmd, category = "kernel_headers", identifier = ctx.attrs.name, allow_cache_upload = True)

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
