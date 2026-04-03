"""
Image rules: iso_image, raw_disk_image, stage3_tarball.

Assembly rules that take rootfs/kernel/initramfs deps and produce images.
"""

load("//defs:providers.bzl", "IsoImageInfo", "KernelInfo", "PackageInfo", "Stage3Info", "get_kernel_image")
load("//defs:host_tools.bzl", "host_tool_path_args")
load("//defs:toolchain_helpers.bzl", "TOOLCHAIN_ATTRS", "toolchain_ld_linux_args", "toolchain_path_args")

# =============================================================================
# RAW DISK IMAGE
# =============================================================================

def _raw_disk_image_impl(ctx: AnalysisContext) -> list[Provider]:
    """Create a raw disk image from a rootfs (for Cloud Hypervisor)."""
    image_file = ctx.actions.declare_output(ctx.attrs.name + ".raw")
    rootfs_dir = ctx.attrs.rootfs[DefaultInfo].default_outputs[0]

    label = ctx.attrs.label if ctx.attrs.label else ctx.attrs.name

    cmd = cmd_args(ctx.attrs._disk_image_tool[RunInfo])
    cmd.add("--rootfs", rootfs_dir)
    cmd.add("--output", image_file.as_output())
    cmd.add("--size", ctx.attrs.size)
    cmd.add("--filesystem", ctx.attrs.filesystem)
    cmd.add("--label", label)
    if ctx.attrs.partition_table:
        cmd.add("--partition-table")
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)
    for arg in toolchain_ld_linux_args(ctx):
        cmd.add(arg)

    ctx.actions.run(
        cmd,
        category = "disk_image",
        identifier = ctx.attrs.name,
        allow_cache_upload = True,
    )

    return [DefaultInfo(default_output = image_file)]

_raw_disk_image_rule = rule(
    impl = _raw_disk_image_impl,
    attrs = {
        "rootfs": attrs.dep(),
        "size": attrs.string(default = "2G"),
        "filesystem": attrs.string(default = "ext4"),  # ext4, xfs, btrfs
        "label": attrs.option(attrs.string(), default = None),
        "partition_table": attrs.bool(default = False),  # True for GPT with EFI
        "labels": attrs.list(attrs.string(), default = []),
        "_disk_image_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:disk_image_helper"),
        ),
    } | TOOLCHAIN_ATTRS,
)

def raw_disk_image(labels = [], **kwargs):
    _raw_disk_image_rule(
        labels = labels,
        **kwargs
    )

# =============================================================================
# ISO IMAGE
# =============================================================================

def _iso_image_impl(ctx: AnalysisContext) -> list[Provider]:
    """Create a bootable ISO image from kernel, initramfs, and optional rootfs."""
    iso_file = ctx.actions.declare_output(ctx.attrs.name + ".iso")

    cmd = cmd_args(ctx.attrs._iso_tool[RunInfo])
    cmd.add("--kernel", get_kernel_image(ctx.attrs.kernel))
    cmd.add("--initramfs", ctx.attrs.initramfs[DefaultInfo].default_outputs[0])
    cmd.add("--output", iso_file.as_output())

    if ctx.attrs.rootfs:
        cmd.add("--rootfs", ctx.attrs.rootfs[DefaultInfo].default_outputs[0])

    if ctx.attrs.modules:
        cmd.add("--modules", ctx.attrs.modules[DefaultInfo].default_outputs[0])
    elif KernelInfo in ctx.attrs.kernel:
        cmd.add("--modules", ctx.attrs.kernel[KernelInfo].modules_dir)

    cmd.add("--boot-mode", ctx.attrs.boot_mode)
    cmd.add("--volume-label", ctx.attrs.volume_label)
    cmd.add("--kernel-args", ctx.attrs.kernel_args)
    cmd.add("--arch", ctx.attrs.arch)

    if ctx.attrs.syslinux:
        syslinux_dir = ctx.attrs.syslinux[DefaultInfo].default_outputs[0]
        cmd.add("--syslinux-dir", syslinux_dir)

    # Hermetic PATH from toolchain
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)
    for arg in toolchain_ld_linux_args(ctx):
        cmd.add(arg)
    for arg in host_tool_path_args(ctx):
        cmd.add(arg)

    # xorriso binary from libisoburn
    xorriso_dep = ctx.attrs._xorriso
    if xorriso_dep and PackageInfo in xorriso_dep:
        cmd.add("--path-prepend", xorriso_dep[PackageInfo].prefix.project("usr/bin"))
    # Runtime shared libs (libisofs, libburn) — project usr/lib for
    # LD_LIBRARY_PATH derivation so xorriso finds them at runtime.
    for _iso_lib_attr in ("_libisofs", "_libburn"):
        _dep = getattr(ctx.attrs, _iso_lib_attr, None)
        if _dep and PackageInfo in _dep:
            cmd.add("--path-prepend", _dep[PackageInfo].prefix.project("usr/lib"))

    # GRUB EFI for grub-mkimage (creates EFI boot image)
    grub_dep = ctx.attrs._grub
    if grub_dep and PackageInfo in grub_dep:
        cmd.add("--path-prepend", grub_dep[PackageInfo].prefix.project("usr/bin"))
        # grub-mkimage needs the module directory (lib64/grub/x86_64-efi)
        cmd.add("--path-prepend", grub_dep[PackageInfo].prefix.project("usr/lib64/grub"))

    # dosfstools for mkfs.vfat (creates FAT EFI system partition)
    dosfstools_dep = ctx.attrs._dosfstools
    if dosfstools_dep and PackageInfo in dosfstools_dep:
        cmd.add("--path-prepend", dosfstools_dep[PackageInfo].prefix.project("usr/sbin"))

    # mtools for mmd/mcopy (populates FAT EFI image)
    mtools_dep = ctx.attrs._mtools
    if mtools_dep and PackageInfo in mtools_dep:
        cmd.add("--path-prepend", mtools_dep[PackageInfo].prefix.project("usr/bin"))

    ctx.actions.run(cmd, category = "iso", identifier = ctx.attrs.name, allow_cache_upload = True)

    return [
        DefaultInfo(default_output = iso_file),
        IsoImageInfo(
            iso = iso_file,
            boot_mode = ctx.attrs.boot_mode,
            volume_label = ctx.attrs.volume_label,
            arch = ctx.attrs.arch,
        ),
    ]

_iso_image_rule = rule(
    impl = _iso_image_impl,
    attrs = {
        "kernel": attrs.dep(),
        "initramfs": attrs.dep(),
        "modules": attrs.option(attrs.dep(), default = None),
        "rootfs": attrs.option(attrs.dep(), default = None),
        "boot_mode": attrs.string(default = "hybrid"),  # bios, efi, or hybrid
        "volume_label": attrs.string(default = "BUCKOS"),
        "kernel_args": attrs.string(default = "quiet"),
        "arch": attrs.string(default = "x86_64"),  # x86_64 or aarch64
        "syslinux": attrs.option(attrs.dep(), default = None),
        "host_deps": attrs.list(attrs.dep(), default = []),
        "labels": attrs.list(attrs.string(), default = []),
        "_iso_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:iso_helper"),
        ),
        # xorriso (from libisoburn) is required for ISO creation.
        # libisofs and libburn are transitive deps whose shared libs
        # xorriso loads at runtime — they need their lib dirs on
        # LD_LIBRARY_PATH via --path-prepend derivation.
        "_xorriso": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/dev-libs/iso/libisoburn:libisoburn"),
        ),
        "_libisofs": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/dev-libs/iso/libisofs:libisofs"),
        ),
        "_libburn": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/dev-libs/iso/libburn:libburn"),
        ),
        # GRUB EFI for grub-mkimage (creates UEFI boot image)
        "_grub": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/boot/grub:grub"),
        ),
        # dosfstools for mkfs.vfat (creates FAT EFI system partition image)
        "_dosfstools": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/system/filesystem/native/dosfstools:dosfstools"),
        ),
        # mtools for mmd/mcopy (populates FAT image with EFI bootloader)
        "_mtools": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/system/apps/mtools:mtools"),
        ),
    } | TOOLCHAIN_ATTRS,
)

def iso_image(labels = [], **kwargs):
    _iso_image_rule(
        labels = labels,
        **kwargs
    )

# =============================================================================
# STAGE3 TARBALL
# =============================================================================
# Creates a stage3 tarball from a rootfs for distribution.
# Stage3 tarballs are self-contained root filesystems with a complete
# toolchain that can be used to bootstrap new BuckOS installations.

def _stage3_tarball_impl(ctx: AnalysisContext) -> list[Provider]:
    """Create a stage3 tarball from a rootfs with metadata."""

    # Determine compression settings
    compression = ctx.attrs.compression
    compress_opts = {
        "xz": ".tar.xz",
        "gz": ".tar.gz",
        "zstd": ".tar.zst",
    }

    if compression not in compress_opts:
        fail("Unsupported compression: {}. Use xz, gz, or zstd".format(compression))

    suffix = compress_opts[compression]

    # Build tarball filename: stage3-{arch}-{variant}-{libc}-{date}.tar.{ext}
    arch = ctx.attrs.arch
    variant = ctx.attrs.variant
    libc = ctx.attrs.libc
    version = ctx.attrs.version

    tarball_basename = "stage3-{}-{}-{}".format(arch, variant, libc)
    if version:
        tarball_basename += "-" + version

    # Declare outputs
    tarball_file = ctx.actions.declare_output(tarball_basename + suffix)
    sha256_file = ctx.actions.declare_output(tarball_basename + suffix + ".sha256")
    contents_file = ctx.actions.declare_output(tarball_basename + ".CONTENTS.gz")

    rootfs_dir = ctx.attrs.rootfs[DefaultInfo].default_outputs[0]

    cmd = cmd_args(ctx.attrs._stage3_tool[RunInfo])
    cmd.add("--rootfs", rootfs_dir)
    cmd.add("--tarball-output", tarball_file.as_output())
    cmd.add("--sha256-output", sha256_file.as_output())
    cmd.add("--contents-output", contents_file.as_output())
    cmd.add("--arch", arch)
    cmd.add("--variant", variant)
    cmd.add("--libc", libc)
    cmd.add("--version", version if version else "0.1")
    cmd.add("--compression", compression)
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)
    for arg in toolchain_ld_linux_args(ctx):
        cmd.add(arg)

    ctx.actions.run(
        cmd,
        category = "stage3",
        identifier = ctx.attrs.name,
        allow_cache_upload = True,
    )

    return [
        DefaultInfo(default_outputs = [tarball_file, sha256_file, contents_file]),
        Stage3Info(
            tarball = tarball_file,
            checksum = sha256_file,
            contents = contents_file,
            arch = arch,
            variant = variant,
            libc = libc,
            version = version if version else "0.1",
        ),
    ]

_stage3_tarball_rule = rule(
    impl = _stage3_tarball_impl,
    attrs = {
        "rootfs": attrs.dep(),
        "variant": attrs.string(default = "base"),      # minimal, base, developer, complete
        "arch": attrs.string(default = "amd64"),        # amd64, arm64
        "libc": attrs.string(default = "glibc"),        # glibc, musl
        "compression": attrs.string(default = "xz"),    # xz, gz, zstd
        "version": attrs.string(default = ""),          # Optional version string
        "labels": attrs.list(attrs.string(), default = []),
        "_stage3_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:stage3_helper"),
        ),
    } | TOOLCHAIN_ATTRS,
)

def stage3_tarball(labels = [], **kwargs):
    _stage3_tarball_rule(
        labels = labels,
        **kwargs
    )
