"""
Image rules: iso_image, raw_disk_image, stage3_tarball.

Assembly rules that take rootfs/kernel/initramfs deps and produce images.
"""

load("//defs:host_tools.bzl", "host_tool_path_args")
load("//defs:providers.bzl", "IsoImageInfo", "KernelInfo", "PackageInfo", "Stage3Info", "get_kernel_image")
load("//defs:toolchain_helpers.bzl", "TOOLCHAIN_ATTRS", "toolchain_ld_linux_args", "toolchain_path_args")
load("//defs:tsets.bzl", "PathInfoTSet")
load("//defs/rules:_common.bzl", "add_flag_file", "write_lib_dirs")

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
        "filesystem": attrs.string(default = "ext4"),  # ext4, xfs, btrfs
        "label": attrs.option(attrs.string(), default = None),
        "labels": attrs.list(attrs.string(), default = []),
        "partition_table": attrs.bool(default = False),  # True for GPT with EFI
        "rootfs": attrs.dep(),
        "size": attrs.string(default = "2G"),
        "_disk_image_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:disk_image_helper"),
        ),
    }
    | TOOLCHAIN_ATTRS,
)

def raw_disk_image(labels = [], **kwargs):
    _raw_disk_image_rule(labels = labels, **kwargs)

# =============================================================================
# DM-VERITY MEASURED IMAGE
# =============================================================================
# Build a dm-verity bound image set from a rootfs, in the hatch-image style:
# a measured root filesystem image, its verity hash tree, the root hash, and a
# kernel cmdline carrying `roothash=<hex>`.  The root hash binds every byte of
# the rootfs to the boot measurement — the anchor of the attestation / verified
# boot story.  Plays to buckos's strength: the rootfs is built hermetically
# from source, so the measured image is reproducible by third parties.
#
# mkfs comes from the toolchain host PATH (like raw_disk_image); veritysetup is
# a buckos-built PIE launched through the seed loader with its dep lib closure
# (like ostree_commit).  `veritysetup format` is pure userspace — no root.

def _verity_image_impl(ctx: AnalysisContext) -> list[Provider]:
    rootfs_dir = ctx.attrs.rootfs[DefaultInfo].default_outputs[0]
    cryptsetup = ctx.attrs.cryptsetup[PackageInfo]

    name = ctx.attrs.name
    root_img = ctx.actions.declare_output(name + ".root.img")
    hash_img = ctx.actions.declare_output(name + ".hash.img")
    roothash = ctx.actions.declare_output(name + ".roothash")
    cmdline = ctx.actions.declare_output(name + ".cmdline")

    label = ctx.attrs.label if ctx.attrs.label else name

    cmd = cmd_args(ctx.attrs._verity_tool[RunInfo])
    cmd.add("--rootfs", rootfs_dir)
    cmd.add("--root-output", root_img.as_output())
    cmd.add("--hash-output", hash_img.as_output())
    cmd.add("--roothash-output", roothash.as_output())
    cmd.add("--cmdline-output", cmdline.as_output())
    cmd.add("--filesystem", ctx.attrs.filesystem)
    cmd.add("--label", label)
    cmd.add("--size", ctx.attrs.size)
    cmd.add("--base-cmdline", ctx.attrs.base_cmdline)

    # mkfs is a buckos PIE too (not on the toolchain host PATH), so it is
    # launched like veritysetup: pick the package + binary for the filesystem.
    if ctx.attrs.filesystem == "btrfs":
        mkfs_pkg = ctx.attrs.btrfs_progs[PackageInfo]
        mkfs_bin = mkfs_pkg.prefix.project("usr/bin/mkfs.btrfs")
    elif ctx.attrs.filesystem == "ext4":
        mkfs_pkg = ctx.attrs.e2fsprogs[PackageInfo]
        mkfs_bin = mkfs_pkg.prefix.project("usr/sbin/mke2fs")
    else:
        fail("verity_image: unsupported filesystem {}".format(ctx.attrs.filesystem))

    # Both mkfs and veritysetup are buckos PIEs launched via the seed loader
    # with a dep lib closure on --library-path.  Merge both packages' closures
    # into one tset and write it once (two write_lib_dirs calls would collide on
    # the same output name); extra dirs on a --library-path are harmless.
    combined = ctx.actions.tset(
        PathInfoTSet,
        children = [cryptsetup.path_info, mkfs_pkg.path_info],
    )
    libs = write_lib_dirs(ctx, combined)

    cmd.add("--veritysetup", cryptsetup.prefix.project("usr/sbin/veritysetup"))
    add_flag_file(cmd, "--lib-dirs-file", libs)
    cmd.add("--mkfs", mkfs_bin)
    add_flag_file(cmd, "--mkfs-lib-dirs-file", libs)
    cmd.add(cmd_args(hidden = [cryptsetup.prefix, mkfs_pkg.prefix]))

    # PATH (mke2fs/mkfs.btrfs from toolchain) + ld-linux for the PIE.
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)
    for arg in toolchain_ld_linux_args(ctx):
        cmd.add(arg)

    ctx.actions.run(
        cmd,
        category = "verity_image",
        identifier = name,
        allow_cache_upload = True,
    )

    return [
        DefaultInfo(
            default_output = root_img,
            other_outputs = [hash_img, roothash, cmdline],
            sub_targets = {
                "cmdline": [DefaultInfo(default_output = cmdline)],
                "hash": [DefaultInfo(default_output = hash_img)],
                "roothash": [DefaultInfo(default_output = roothash)],
            },
        )
    ]

_verity_image_rule = rule(
    impl = _verity_image_impl,
    attrs = {
        "base_cmdline": attrs.string(default = "noresume"),
        # mkfs providers; only the one matching `filesystem` is actually built.
        "btrfs_progs": attrs.dep(
            providers = [PackageInfo],
            default = "//packages/linux/system/filesystem/native/btrfs-progs:btrfs-progs",
        ),
        "cryptsetup": attrs.dep(
            providers = [PackageInfo],
            default = "//packages/linux/system/filesystem/management/cryptsetup:cryptsetup",
        ),
        "e2fsprogs": attrs.dep(
            providers = [PackageInfo],
            default = "//packages/linux/system/filesystem/native/e2fsprogs:e2fsprogs",
        ),
        "filesystem": attrs.string(default = "btrfs"),  # btrfs (hatch parity) or ext4
        "label": attrs.option(attrs.string(), default = None),
        "labels": attrs.list(attrs.string(), default = []),
        "rootfs": attrs.dep(),
        "size": attrs.string(default = "4G"),
        "_verity_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:verity_image_helper"),
        ),
    }
    | TOOLCHAIN_ATTRS,
)

def verity_image(labels = [], **kwargs):
    _verity_image_rule(labels = labels, **kwargs)

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

    ctx.actions.run(
        cmd,
        category = "iso",
        identifier = ctx.attrs.name,
        allow_cache_upload = True,
        # Bump this whenever iso_helper.py changes semantically -- Buck2
        # keys action results on inputs + env, so a fresh env var here
        # forces re-execution even when iso_helper.par's digest change
        # somehow doesn't propagate through the DICE cache.
        env = {"_ISO_HELPER_SEMANTIC_TAG": "appended-part-as-gpt-2026-07-13"},
    )

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
        "arch": attrs.string(default = "x86_64"),  # x86_64 or aarch64
        "boot_mode": attrs.string(default = "hybrid"),  # bios, efi, or hybrid
        "host_deps": attrs.list(attrs.dep(), default = []),
        "initramfs": attrs.dep(),
        "kernel": attrs.dep(),
        "kernel_args": attrs.string(default = "quiet"),
        "labels": attrs.list(attrs.string(), default = []),
        "modules": attrs.option(attrs.dep(), default = None),
        "rootfs": attrs.option(attrs.dep(), default = None),
        "syslinux": attrs.option(attrs.dep(), default = None),
        "volume_label": attrs.string(default = "BUCKOS"),
        # dosfstools for mkfs.vfat (creates FAT EFI system partition image)
        "_dosfstools": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/system/filesystem/native/dosfstools:dosfstools"),
        ),
        # GRUB EFI for grub-mkimage (creates UEFI boot image)
        "_grub": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/boot/grub:grub"),
        ),
        "_iso_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:iso_helper"),
        ),
        "_libburn": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/dev-libs/iso/libburn:libburn"),
        ),
        "_libisofs": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/dev-libs/iso/libisofs:libisofs"),
        ),
        # mtools for mmd/mcopy (populates FAT image with EFI bootloader)
        "_mtools": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/system/apps/mtools:mtools"),
        ),
        # xorriso (from libisoburn) is required for ISO creation.
        # libisofs and libburn are transitive deps whose shared libs
        # xorriso loads at runtime — they need their lib dirs on
        # LD_LIBRARY_PATH via --path-prepend derivation.
        "_xorriso": attrs.default_only(
            attrs.exec_dep(default = "//packages/linux/dev-libs/iso/libisoburn:libisoburn"),
        ),
    }
    | TOOLCHAIN_ATTRS,
)

def iso_image(labels = [], **kwargs):
    _iso_image_rule(labels = labels, **kwargs)

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
        "gz": ".tar.gz",
        "xz": ".tar.xz",
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
        "arch": attrs.string(default = "amd64"),  # amd64, arm64
        "compression": attrs.string(default = "xz"),  # xz, gz, zstd
        "labels": attrs.list(attrs.string(), default = []),
        "libc": attrs.string(default = "glibc"),  # glibc, musl
        "rootfs": attrs.dep(),
        "variant": attrs.string(default = "base"),  # minimal, base, developer, complete
        "version": attrs.string(default = ""),  # Optional version string
        "_stage3_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:stage3_helper"),
        ),
    }
    | TOOLCHAIN_ATTRS,
)

def stage3_tarball(labels = [], **kwargs):
    _stage3_tarball_rule(labels = labels, **kwargs)
