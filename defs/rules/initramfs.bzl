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

    compression = ctx.attrs.compression
    if compression == "gz":
        compress_cmd = "gzip -9"
    elif compression == "xz":
        compress_cmd = "xz -9 --check=crc32"
    elif compression == "lz4":
        compress_cmd = "lz4 -l -9"
    elif compression == "zstd":
        compress_cmd = "zstd -19"
    else:
        compress_cmd = "gzip -9"

    init_path = ctx.attrs.init if ctx.attrs.init else "/sbin/init"

    init_script_src = None
    if ctx.attrs.init_script:
        init_script_src = ctx.attrs.init_script[DefaultInfo].default_outputs[0]

    script = ctx.actions.write(
        "create_initramfs.sh",
        """#!/bin/bash
set -e

ROOTFS="$1"
OUTPUT="$(realpath -m "$2")"
INIT_PATH="{init_path}"
INIT_SCRIPT="$3"
mkdir -p "$(dirname "$OUTPUT")"

WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT

cp -a "$ROOTFS"/* "$WORK"/

# Fix aarch64 library paths
if [ -d "$WORK/lib64" ] && [ ! -L "$WORK/lib64" ]; then
    mkdir -p "$WORK/lib"
    cp -a "$WORK/lib64/"* "$WORK/lib/" 2>/dev/null || true
    rm -rf "$WORK/lib64"
    ln -sf lib "$WORK/lib64"
fi
if [ -d "$WORK/usr/lib64" ] && [ ! -L "$WORK/usr/lib64" ]; then
    mkdir -p "$WORK/usr/lib"
    cp -a "$WORK/usr/lib64/"* "$WORK/usr/lib/" 2>/dev/null || true
    rm -rf "$WORK/usr/lib64"
    ln -sf lib "$WORK/usr/lib64"
fi

# Install custom init script if provided
if [ -n "$INIT_SCRIPT" ] && [ -f "$INIT_SCRIPT" ]; then
    mkdir -p "$(dirname "$WORK$INIT_PATH")"
    cp "$INIT_SCRIPT" "$WORK$INIT_PATH"
    chmod +x "$WORK$INIT_PATH"
elif [ ! -e "$WORK$INIT_PATH" ]; then
    if [ -x "$WORK/bin/busybox" ]; then
        mkdir -p "$WORK/sbin"
        ln -sf /bin/busybox "$WORK/sbin/init"
    elif [ -x "$WORK/bin/sh" ]; then
        cat > "$WORK/sbin/init" << 'INIT_EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
[ -x /etc/init.d/rcS ] && /etc/init.d/rcS
exec /bin/sh
INIT_EOF
        chmod +x "$WORK/sbin/init"
    fi
fi

# Create /init at root for kernel to find
if [ ! -e "$WORK/init" ]; then
    if [ -e "$WORK$INIT_PATH" ]; then
        ln -sf "$INIT_PATH" "$WORK/init"
    elif [ -x "$WORK/sbin/init" ]; then
        ln -sf /sbin/init "$WORK/init"
    elif [ -x "$WORK/bin/sh" ]; then
        cat > "$WORK/init" << 'INIT_EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
[ -x /etc/init.d/rcS ] && /etc/init.d/rcS
exec /bin/sh
INIT_EOF
        chmod +x "$WORK/init"
    fi
fi

cd "$WORK"
find . -print0 | cpio --null -o -H newc | {compress_cmd} > "$OUTPUT"

echo "Created initramfs: $OUTPUT"
""".format(init_path = init_path, compress_cmd = compress_cmd),
        is_executable = True,
    )

    cmd = cmd_args([
        "bash",
        script,
        rootfs_dir,
        initramfs_file.as_output(),
        init_script_src if init_script_src else "",
    ])

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

    cmd = cmd_args([
        create_script,
        kernel_image,
        dracut_dir,
        rootfs_dir,
        initramfs_file.as_output(),
        kver,
        compress,
    ])
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
    },
)

def dracut_initramfs(labels = [], **kwargs):
    _dracut_initramfs_rule(labels = labels, **kwargs)
