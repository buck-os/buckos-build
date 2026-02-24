"""
initramfs rules: create initramfs cpio archives.

Two variants:
- initramfs: simple cpio archive from a rootfs directory
- dracut_initramfs: dracut-based initramfs with live boot support
"""

load("//defs:providers.bzl", "KernelInfo")

def _get_kernel_image(dep):
    """Extract boot image from KernelInfo provider."""
    if KernelInfo not in dep:
        fail("kernel dep must provide KernelInfo")
    return dep[KernelInfo].bzimage

def _initramfs_impl(ctx):
    """Create an initramfs cpio archive from a rootfs."""
    initramfs_file = ctx.actions.declare_output(ctx.attrs.name + ".cpio.gz")

    rootfs_dir = ctx.attrs.rootfs[DefaultInfo].default_outputs[0]
    init_path = ctx.attrs.init if ctx.attrs.init else "/sbin/init"

    cmd = cmd_args(ctx.attrs._initramfs_tool[RunInfo])
    cmd.add("--rootfs-dir", rootfs_dir)
    cmd.add("--output", initramfs_file.as_output())
    cmd.add("--init-path", init_path)
    cmd.add("--compression", ctx.attrs.compression)

    if ctx.attrs.init_script:
        init_script_src = ctx.attrs.init_script[DefaultInfo].default_outputs[0]
        cmd.add("--init-script", init_script_src)

    ctx.actions.run(cmd, category = "initramfs", identifier = ctx.attrs.name)

    return [DefaultInfo(default_output = initramfs_file)]

_initramfs_rule = rule(
    impl = _initramfs_impl,
    attrs = {
        "rootfs": attrs.dep(),
        "compression": attrs.string(default = "gz"),
        "init": attrs.string(default = "/sbin/init"),
        "init_script": attrs.option(attrs.dep(), default = None),
        "labels": attrs.list(attrs.string(), default = []),
        "_initramfs_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:initramfs_builder"),
        ),
    },
)

def initramfs(labels = [], **kwargs):
    _initramfs_rule(labels = labels, **kwargs)


def _dracut_initramfs_impl(ctx):
    """Create an initramfs using dracut with dmsquash-live module for live boot."""
    initramfs_file = ctx.actions.declare_output(ctx.attrs.name + ".img")

    kernel_image = _get_kernel_image(ctx.attrs.kernel)

    if ctx.attrs.modules:
        modules_dir = ctx.attrs.modules[DefaultInfo].default_outputs[0]
    elif KernelInfo in ctx.attrs.kernel:
        modules_dir = ctx.attrs.kernel[KernelInfo].modules_dir
    else:
        modules_dir = None

    dracut_dir = ctx.attrs.dracut[DefaultInfo].default_outputs[0]
    rootfs_dir = ctx.attrs.rootfs[DefaultInfo].default_outputs[0]
    create_script = ctx.attrs.create_script[DefaultInfo].default_outputs[0]

    kver = ctx.attrs.kernel_version
    compress = ctx.attrs.compression

    cmd = cmd_args(ctx.attrs._dracut_tool[RunInfo])
    cmd.add(create_script)
    cmd.add(kernel_image)
    cmd.add(dracut_dir)
    cmd.add(rootfs_dir)
    cmd.add(initramfs_file.as_output())
    cmd.add(kver)
    cmd.add(compress)
    if modules_dir:
        cmd.add(modules_dir)

    ctx.actions.run(cmd, category = "dracut_initramfs", identifier = ctx.attrs.name)

    return [DefaultInfo(default_output = initramfs_file)]

_dracut_initramfs_rule = rule(
    impl = _dracut_initramfs_impl,
    attrs = {
        "kernel": attrs.dep(),
        "modules": attrs.option(attrs.dep(), default = None),
        "dracut": attrs.dep(),
        "rootfs": attrs.dep(),
        "create_script": attrs.dep(default = "//defs/scripts:create-dracut-initramfs"),
        "kernel_version": attrs.string(default = ""),
        "add_modules": attrs.list(attrs.string(), default = ["dmsquash-live", "livenet"]),
        "compression": attrs.string(default = "gzip"),
        "labels": attrs.list(attrs.string(), default = []),
        "_dracut_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:dracut_initramfs_helper"),
        ),
    },
)

def dracut_initramfs(labels = [], **kwargs):
    _dracut_initramfs_rule(labels = labels, **kwargs)
