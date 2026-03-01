"""
boot script rules: generate QEMU and Cloud Hypervisor boot scripts.
"""

load("//defs:providers.bzl", "KernelInfo")

def _get_kernel_image(dep):
    """Extract boot image from KernelInfo provider."""
    if KernelInfo not in dep:
        fail("kernel dep must provide KernelInfo")
    return dep[KernelInfo].bzimage

def _qemu_boot_script_impl(ctx):
    """Generate a QEMU boot script for testing."""
    boot_script = ctx.actions.declare_output(ctx.attrs.name + ".sh")

    kernel_image = _get_kernel_image(ctx.attrs.kernel)
    initramfs_file = ctx.attrs.initramfs[DefaultInfo].default_outputs[0]

    arch = ctx.attrs.arch
    extra_args = " ".join(ctx.attrs.extra_args) if ctx.attrs.extra_args else ""

    if arch == "x86_64":
        qemu_bin = "qemu-system-x86_64"
        machine = "q35"
    elif arch == "aarch64":
        qemu_bin = "qemu-system-aarch64"
        machine = "virt"
    elif arch == "riscv64":
        qemu_bin = "qemu-system-riscv64"
        machine = "virt"
    else:
        qemu_bin = "qemu-system-x86_64"
        machine = "q35"

    cmd = cmd_args(ctx.attrs._boot_script_tool[RunInfo])
    cmd.add("--kernel", kernel_image)
    cmd.add("--initramfs", initramfs_file)
    cmd.add("--output", boot_script.as_output())
    cmd.add("--qemu-bin", qemu_bin)
    cmd.add("--machine", machine)
    cmd.add("--memory", ctx.attrs.memory)
    cmd.add("--cpus", ctx.attrs.cpus)
    cmd.add("--kernel-args", ctx.attrs.kernel_args)
    if extra_args:
        cmd.add("--extra-args", extra_args)

    ctx.actions.run(cmd, category = "qemu_boot_script", identifier = ctx.attrs.name, allow_cache_upload = True)

    return [DefaultInfo(default_output = boot_script)]

_qemu_boot_script_rule = rule(
    impl = _qemu_boot_script_impl,
    attrs = {
        "kernel": attrs.dep(),
        "initramfs": attrs.dep(),
        "arch": attrs.string(default = "x86_64"),
        "memory": attrs.string(default = "512M"),
        "cpus": attrs.string(default = "2"),
        "kernel_args": attrs.string(default = "console=ttyS0 quiet"),
        "extra_args": attrs.list(attrs.string(), default = []),
        "labels": attrs.list(attrs.string(), default = []),
        "_boot_script_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:boot_script_helper"),
        ),
    },
)

def qemu_boot_script(labels = [], **kwargs):
    _qemu_boot_script_rule(labels = labels, **kwargs)


def _ch_boot_script_impl(ctx):
    """Generate a Cloud Hypervisor boot script with multiple boot modes.

    Uses ctx.actions.write with allow_args=True so artifact paths resolve
    to actual filesystem paths instead of <build artifact ...> placeholders.
    """
    boot_script = ctx.actions.declare_output(ctx.attrs.name + ".sh")

    kernel_image = _get_kernel_image(ctx.attrs.kernel) if ctx.attrs.kernel else None
    firmware_file = ctx.attrs.firmware[DefaultInfo].default_outputs[0] if ctx.attrs.firmware else None
    disk_image_file = ctx.attrs.disk_image[DefaultInfo].default_outputs[0] if ctx.attrs.disk_image else None
    initramfs_file = ctx.attrs.initramfs[DefaultInfo].default_outputs[0] if ctx.attrs.initramfs else None

    boot_mode = ctx.attrs.boot_mode
    memory = ctx.attrs.memory
    cpus = ctx.attrs.cpus
    kernel_args = ctx.attrs.kernel_args
    extra_args = " ".join(ctx.attrs.extra_args) if ctx.attrs.extra_args else ""
    serial_console = ctx.attrs.serial_console
    network_mode = ctx.attrs.network_mode
    tap_name = ctx.attrs.tap_name
    virtiofs_socket = ctx.attrs.virtiofs_socket
    virtiofs_tag = ctx.attrs.virtiofs_tag
    virtiofs_path = ctx.attrs.virtiofs_path

    lines = [
        "#!/bin/bash",
        "# Cloud Hypervisor Boot Script for BuckOs",
        "# Boot mode: " + boot_mode,
        "",
        "set -e",
        "unset CDPATH",
        "",
    ]

    if kernel_image:
        lines.append(cmd_args("KERNEL=\"", kernel_image, "\"", delimiter = ""))
        lines.append("echo \"  Kernel: $KERNEL\"")

    if disk_image_file:
        lines.append(cmd_args("DISK_ARGS=\"--disk path=", disk_image_file, "\"", delimiter = ""))
    else:
        lines.append("DISK_ARGS=\"\"")

    if initramfs_file:
        lines.append(cmd_args("INITRAMFS_ARGS=\"--initramfs ", initramfs_file, "\"", delimiter = ""))
    else:
        lines.append("INITRAMFS_ARGS=\"\"")

    if firmware_file and boot_mode == "firmware":
        lines.append(cmd_args("FIRMWARE=\"", firmware_file, "\"", delimiter = ""))
        lines.append("if [ ! -f \"$FIRMWARE\" ]; then echo \"Error: Firmware not found\"; exit 1; fi")

    if network_mode == "tap":
        lines.append("NET_ARGS=\"--net tap={tap},mac=12:34:56:78:9a:bc\"".format(tap = tap_name))
    else:
        lines.append("NET_ARGS=\"\"")

    if boot_mode == "virtiofs":
        lines.append("VIRTIOFS_SOCKET=\"{socket}\"".format(socket = virtiofs_socket))
        lines.append("VIRTIOFS_PATH=\"${{VIRTIOFS_PATH:-{path}}}\"".format(path = virtiofs_path))
        lines.append("if [ ! -S \"$VIRTIOFS_SOCKET\" ]; then")
        lines.append("    mkdir -p \"$(dirname \"$VIRTIOFS_SOCKET\")\"")
        lines.append("    virtiofsd --socket-path=\"$VIRTIOFS_SOCKET\" --shared-dir=\"$VIRTIOFS_PATH\" --cache=auto --sandbox=chroot &")
        lines.append("    for i in $(seq 1 10); do [ -S \"$VIRTIOFS_SOCKET\" ] && break; sleep 0.5; done")
        lines.append("    [ -S \"$VIRTIOFS_SOCKET\" ] || { echo \"Error: virtiofsd failed\"; exit 1; }")
        lines.append("fi")
        lines.append("FS_ARGS=\"--fs tag={tag},socket=$VIRTIOFS_SOCKET\"".format(tag = virtiofs_tag))
        lines.append("MEMORY_ARGS=\"size={mem},shared=on\"".format(mem = memory))
    else:
        lines.append("FS_ARGS=\"\"")
        lines.append("MEMORY_ARGS=\"size={mem}\"".format(mem = memory))

    lines.append("")
    lines.append("echo \"Booting BuckOs with Cloud Hypervisor ({mode})...\"".format(mode = boot_mode))
    lines.append("")

    if boot_mode == "direct":
        lines.append("exec cloud-hypervisor \\")
        lines.append("    --cpus boot={cpus} --memory $MEMORY_ARGS \\".format(cpus = cpus))
        lines.append("    --kernel \"$KERNEL\" $INITRAMFS_ARGS \\")
        lines.append("    --cmdline \"{kargs}\" \\".format(kargs = kernel_args))
        lines.append("    $DISK_ARGS $NET_ARGS $FS_ARGS \\")
        lines.append("    --serial {serial} --console off {extra} \"$@\"".format(
            serial = serial_console, extra = extra_args))
    elif boot_mode == "firmware":
        lines.append("exec cloud-hypervisor \\")
        lines.append("    --cpus boot={cpus} --memory $MEMORY_ARGS \\".format(cpus = cpus))
        lines.append("    --kernel \"$FIRMWARE\" \\")
        lines.append("    $DISK_ARGS $NET_ARGS $FS_ARGS \\")
        lines.append("    --serial {serial} --console off {extra} \"$@\"".format(
            serial = serial_console, extra = extra_args))
    elif boot_mode == "virtiofs":
        lines.append("exec cloud-hypervisor \\")
        lines.append("    --cpus boot={cpus} --memory $MEMORY_ARGS \\".format(cpus = cpus))
        lines.append("    --kernel \"$KERNEL\" $INITRAMFS_ARGS \\")
        lines.append("    --cmdline \"{kargs} root={tag} rootfstype=virtiofs rw\" \\".format(
            kargs = kernel_args, tag = virtiofs_tag))
        lines.append("    $NET_ARGS $FS_ARGS \\")
        lines.append("    --serial {serial} --console off {extra} \"$@\"".format(
            serial = serial_console, extra = extra_args))
    else:
        lines.append("echo \"Error: Unknown boot mode: {mode}\"".format(mode = boot_mode))
        lines.append("exit 1")

    lines.append("")

    script, hidden = ctx.actions.write(
        boot_script.as_output(),
        lines,
        is_executable = True,
        allow_args = True,
    )

    return [DefaultInfo(default_output = script, other_outputs = hidden)]

_ch_boot_script_rule = rule(
    impl = _ch_boot_script_impl,
    attrs = {
        "kernel": attrs.option(attrs.dep(), default = None),
        "firmware": attrs.option(attrs.dep(), default = None),
        "disk_image": attrs.option(attrs.dep(), default = None),
        "initramfs": attrs.option(attrs.dep(), default = None),
        "boot_mode": attrs.string(default = "direct"),
        "memory": attrs.string(default = "512M"),
        "cpus": attrs.string(default = "2"),
        "kernel_args": attrs.string(default = "console=ttyS0 quiet"),
        "network_mode": attrs.string(default = "none"),
        "tap_name": attrs.string(default = "tap0"),
        "virtiofs_socket": attrs.string(default = "/tmp/virtiofs.sock"),
        "virtiofs_tag": attrs.string(default = "rootfs"),
        "virtiofs_path": attrs.string(default = "/tmp/rootfs"),
        "serial_console": attrs.string(default = "tty"),
        "extra_args": attrs.list(attrs.string(), default = []),
        "labels": attrs.list(attrs.string(), default = []),
    },
)

def ch_boot_script(labels = [], **kwargs):
    _ch_boot_script_rule(labels = labels, **kwargs)
