"""
Decomposed kernel build rules for BuckOS.

Five separate rules, each producing a single cacheable action with typed
providers.  kbuild owns compilation internally; Buck2 owns the phases
and their typed I/O.

Rules:
  kernel_config          — produce a finalized .config from defconfig + fragments
  kernel_headers         — produce installed kernel headers (make headers_install)
  kernel_build           — compile vmlinux, bzImage, modules
  kernel_btf_headers     — generate vmlinux.h from BTF data (for BPF CO-RE)
  kernel_modules_install — run modules_install and merge out-of-tree modules

Dependency graph:
  source + fragments → kernel_config → kernel_headers (early, glibc depends on this)
                                     → kernel_build → kernel_btf_headers
                                                    → kernel_modules_install
"""

load("//defs:providers.bzl", "KernelBtfInfo", "KernelConfigInfo", "KernelHeadersInfo", "KernelInfo")

# ── Architecture helpers ─────────────────────────────────────────────

_ARCH_MAP = {
    "x86_64": struct(
        kernel_arch = "x86",
        image_target = "bzImage",
        image_path = "arch/x86/boot/bzImage",
        cross_compile = "",
    ),
    "aarch64": struct(
        kernel_arch = "arm64",
        image_target = "Image",
        image_path = "arch/arm64/boot/Image",
        cross_compile = "aarch64-linux-gnu-",
    ),
}

def _arch_info(arch):
    return _ARCH_MAP.get(arch, _ARCH_MAP["x86_64"])

# ── Rule 1: kernel_config ────────────────────────────────────────────

def _kernel_config_impl(ctx):
    """Produce a finalized .config from defconfig + composable fragments."""
    arch = _arch_info(ctx.attrs.arch)
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]
    output = ctx.actions.declare_output(ctx.attrs.name + ".config")

    cmd = cmd_args(ctx.attrs._config_tool[RunInfo])
    cmd.add("--source-dir", source)
    cmd.add("--output", output.as_output())
    cmd.add("--arch", arch.kernel_arch)

    if ctx.attrs.defconfig:
        cmd.add("--defconfig", ctx.attrs.defconfig)

    if ctx.attrs.localversion:
        cmd.add("--localversion=" + ctx.attrs.localversion)

    if arch.cross_compile:
        cmd.add("--cross-compile", arch.cross_compile)

    for frag in ctx.attrs.fragments:
        cmd.add("--fragment", frag)

    ctx.actions.run(
        cmd,
        category = "kernel_config",
        identifier = ctx.attrs.name,
    )

    return [
        DefaultInfo(default_output = output),
        KernelConfigInfo(
            config = output,
            version = ctx.attrs.version,
        ),
    ]

kernel_config = rule(
    impl = _kernel_config_impl,
    attrs = {
        "source": attrs.dep(),
        "version": attrs.string(),
        "defconfig": attrs.string(default = ""),
        "fragments": attrs.list(attrs.source(), default = []),
        "arch": attrs.string(default = "x86_64"),
        "localversion": attrs.string(default = "-buckos"),
        "labels": attrs.list(attrs.string(), default = []),
        "_config_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:kernel_config"),
        ),
    },
)

# ── Rule 2: kernel_headers ───────────────────────────────────────────

def _kernel_headers_impl(ctx):
    """Produce installed kernel headers.  Earliest kernel output —
    glibc/musl/BPF depend on this, not on the full build."""
    arch = _arch_info(ctx.attrs.arch)
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]
    config = ctx.attrs.config[KernelConfigInfo].config
    output = ctx.actions.declare_output("headers", dir = True)

    cmd = cmd_args(ctx.attrs._headers_tool[RunInfo])
    cmd.add("--source-dir", source)
    cmd.add("--config", config)
    cmd.add("--output-dir", output.as_output())
    cmd.add("--arch", arch.kernel_arch)

    if arch.cross_compile:
        cmd.add("--cross-compile", arch.cross_compile)

    ctx.actions.run(
        cmd,
        category = "kernel_headers",
        identifier = ctx.attrs.name,
    )

    return [
        DefaultInfo(default_output = output),
        KernelHeadersInfo(
            headers = output,
            version = ctx.attrs.version,
        ),
    ]

kernel_headers = rule(
    impl = _kernel_headers_impl,
    attrs = {
        "source": attrs.dep(),
        "config": attrs.dep(providers = [KernelConfigInfo]),
        "version": attrs.string(),
        "arch": attrs.string(default = "x86_64"),
        "labels": attrs.list(attrs.string(), default = []),
        "_headers_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:kernel_headers"),
        ),
    },
)

# ── Rule 3: kernel_build ─────────────────────────────────────────────

def _kernel_build_impl(ctx):
    """Compile the kernel: vmlinux, bzImage, modules.  The expensive step."""
    arch = _arch_info(ctx.attrs.arch)
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]
    config = ctx.attrs.config[KernelConfigInfo].config
    version = ctx.attrs.version

    # Declare all outputs
    build_tree = ctx.actions.declare_output("build-tree", dir = True)
    vmlinux = ctx.actions.declare_output("vmlinux")
    bzimage = ctx.actions.declare_output("bzImage")
    modules_dir = ctx.actions.declare_output("modules", dir = True)
    module_symvers = ctx.actions.declare_output("Module.symvers")
    config_out = ctx.actions.declare_output("dot-config")
    install_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)

    cmd = cmd_args(ctx.attrs._build_tool[RunInfo])
    cmd.add("--source-dir", source)
    cmd.add("--config", config)
    cmd.add("--build-tree-out", build_tree.as_output())
    cmd.add("--vmlinux-out", vmlinux.as_output())
    cmd.add("--bzimage-out", bzimage.as_output())
    cmd.add("--modules-dir-out", modules_dir.as_output())
    cmd.add("--symvers-out", module_symvers.as_output())
    cmd.add("--config-out", config_out.as_output())
    cmd.add("--arch", arch.kernel_arch)
    cmd.add("--image-path", arch.image_path)
    cmd.add("--install-dir-out", install_dir.as_output())
    cmd.add("--version", version)

    if arch.cross_compile:
        cmd.add("--cross-compile", arch.cross_compile)

    if ctx.attrs.kcflags:
        cmd.add("--kcflags", ctx.attrs.kcflags)

    for flag in ctx.attrs.make_flags:
        cmd.add("--make-flag", flag)

    for target in ctx.attrs.targets:
        cmd.add("--target", target)

    # Apply patches
    for patch in ctx.attrs.patches:
        cmd.add("--patch", patch)

    # Cross-toolchain support
    if ctx.attrs.cross_toolchain:
        toolchain_dir = ctx.attrs.cross_toolchain[DefaultInfo].default_outputs[0]
        cmd.add(cmd_args(hidden = [toolchain_dir]))

    ctx.actions.run(
        cmd,
        category = "kernel_compile",
        identifier = ctx.attrs.name,
    )

    # Also produce headers inline (since build tree has everything)
    headers = ctx.actions.declare_output("installed-headers", dir = True)
    hdr_cmd = cmd_args(ctx.attrs._headers_tool[RunInfo])
    hdr_cmd.add("--source-dir", source)
    hdr_cmd.add("--config", config_out)
    hdr_cmd.add("--output-dir", headers.as_output())
    hdr_cmd.add("--arch", arch.kernel_arch)
    if arch.cross_compile:
        hdr_cmd.add("--cross-compile", arch.cross_compile)

    ctx.actions.run(
        hdr_cmd,
        category = "kernel_headers",
        identifier = ctx.attrs.name,
    )

    kernel_info = KernelInfo(
        vmlinux = vmlinux,
        bzimage = bzimage,
        modules_dir = modules_dir,
        build_tree = build_tree,
        module_symvers = module_symvers,
        config = config_out,
        headers = headers,
        version = version,
    )

    return [
        DefaultInfo(
            default_output = install_dir,
            other_outputs = [vmlinux, bzimage, modules_dir, build_tree, module_symvers, config_out, headers],
        ),
        kernel_info,
    ]

kernel_build = rule(
    impl = _kernel_build_impl,
    attrs = {
        "source": attrs.dep(),
        "config": attrs.dep(providers = [KernelConfigInfo]),
        "version": attrs.string(),
        "targets": attrs.list(attrs.string(), default = ["vmlinux", "bzImage", "modules"]),
        "kcflags": attrs.string(default = ""),
        "make_flags": attrs.list(attrs.string(), default = []),
        "arch": attrs.string(default = "x86_64"),
        "cross_toolchain": attrs.option(attrs.dep(), default = None),
        "patches": attrs.list(attrs.source(), default = []),
        "labels": attrs.list(attrs.string(), default = []),
        "_build_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:kernel_build"),
        ),
        "_headers_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:kernel_headers"),
        ),
    },
)

# ── Rule 4: kernel_btf_headers ───────────────────────────────────────

def _kernel_btf_headers_impl(ctx):
    """Generate vmlinux.h from kernel BTF data for BPF CO-RE programs."""
    kernel_info = ctx.attrs.kernel[KernelInfo]
    vmlinux = kernel_info.vmlinux
    output = ctx.actions.declare_output("vmlinux.h")

    cmd = cmd_args(ctx.attrs._btf_tool[RunInfo])
    cmd.add("--vmlinux", vmlinux)
    cmd.add("--output", output.as_output())

    ctx.actions.run(
        cmd,
        category = "kernel_btf",
        identifier = ctx.attrs.name,
    )

    return [
        DefaultInfo(default_output = output),
        KernelBtfInfo(
            vmlinux_h = output,
            version = kernel_info.version,
        ),
    ]

kernel_btf_headers = rule(
    impl = _kernel_btf_headers_impl,
    attrs = {
        "kernel": attrs.dep(providers = [KernelInfo]),
        "labels": attrs.list(attrs.string(), default = []),
        "_btf_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:kernel_btf_headers"),
        ),
    },
)

# ── Rule 5: kernel_modules_install ───────────────────────────────────

def _kernel_modules_install_impl(ctx):
    """Run modules_install and merge out-of-tree modules."""
    kernel_info = ctx.attrs.kernel[KernelInfo]
    build_tree = kernel_info.build_tree
    output = ctx.actions.declare_output("modules-installed", dir = True)

    arch = _arch_info(ctx.attrs.arch)

    cmd = cmd_args(ctx.attrs._install_tool[RunInfo])
    cmd.add("--build-tree", build_tree)
    cmd.add("--output-dir", output.as_output())
    cmd.add("--version", ctx.attrs.version)
    cmd.add("--arch", arch.kernel_arch)

    if arch.cross_compile:
        cmd.add("--cross-compile", arch.cross_compile)

    for mod in ctx.attrs.extra_modules:
        mod_dir = mod[DefaultInfo].default_outputs[0]
        cmd.add("--extra-module", mod_dir)

    ctx.actions.run(
        cmd,
        category = "kernel_modules_install",
        identifier = ctx.attrs.name,
    )

    return [DefaultInfo(default_output = output)]

kernel_modules_install = rule(
    impl = _kernel_modules_install_impl,
    attrs = {
        "kernel": attrs.dep(providers = [KernelInfo]),
        "extra_modules": attrs.list(attrs.dep(), default = []),
        "version": attrs.string(),
        "arch": attrs.string(default = "x86_64"),
        "labels": attrs.list(attrs.string(), default = []),
        "_install_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:kernel_modules_install"),
        ),
    },
)
