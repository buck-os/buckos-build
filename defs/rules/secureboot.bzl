"""efi_sign rule: Authenticode-sign an EFI PE binary for UEFI Secure Boot.

SPEC-007 Tier 2: a deployed system's boot chain should be verifiable by firmware
Secure Boot. This rule signs an EFI binary (the kernel's EFI stub, or a
bootloader) with the Secure Boot `db` key using the buckos-built osslsigncode,
and self-verifies against the db certificate (the same Authenticode check the
firmware does against the enrolled db at boot).

It runs the osslsigncode PIE in a buck2 action via the seed ld-linux loader +
the package's path_info lib closure (the same mechanism as ostree_commit).
"""

load("//defs:providers.bzl", "BuildToolchainInfo", "PackageInfo")
load(
    "//defs:toolchain_helpers.bzl",
    "TOOLCHAIN_ATTRS",
    "toolchain_ld_linux_args",
    "toolchain_path_args",
)
load("//defs/rules:_common.bzl", "add_flag_file", "write_lib_dirs")

def _ld_linux(ctx):
    """The seed dynamic loader used to launch the buckos osslsigncode PIE."""
    tc = ctx.attrs._toolchain[BuildToolchainInfo]
    if not tc.sysroot:
        fail("efi_sign requires a toolchain sysroot (the ld-linux loader)")
    sub = "lib/ld-linux-aarch64.so.1" if tc.target_triple.startswith("aarch64") else "lib64/ld-linux-x86-64.so.2"
    return tc.sysroot.project(sub)

def _efi_sign_impl(ctx):
    ossl = ctx.attrs.osslsigncode[PackageInfo]
    src = ctx.attrs.efi[DefaultInfo].default_outputs[0]
    signed = ctx.actions.declare_output(ctx.attrs.name + ".efi")

    cmd = cmd_args(ctx.attrs._sign_tool[RunInfo])
    cmd.add("--ld-linux", _ld_linux(ctx))
    cmd.add("--osslsigncode", ossl.prefix.project("usr/bin/osslsigncode"))
    cmd.add("--in", src)
    cmd.add("--cert", ctx.attrs.cert)
    cmd.add("--key", ctx.attrs.key)
    cmd.add("--out", signed.as_output())

    add_flag_file(cmd, "--lib-dirs-file", write_lib_dirs(ctx, ossl.path_info))
    cmd.add(cmd_args(hidden = ossl.prefix))

    ctx.actions.run(cmd, category = "efi_sign", identifier = ctx.attrs.name)
    return [DefaultInfo(default_output = signed)]

efi_sign = rule(
    impl = _efi_sign_impl,
    attrs = {
        "efi": attrs.dep(),
        "cert": attrs.source(),
        "key": attrs.source(),
        "osslsigncode": attrs.dep(
            providers = [PackageInfo],
            default = "//packages/linux/system/security/osslsigncode:osslsigncode",
        ),
        "_sign_tool": attrs.exec_dep(default = "//tools:efi_sign_helper"),
    } | TOOLCHAIN_ATTRS,
)

# ── uki: assemble a Unified Kernel Image ──────────────────────────────────────

def _uki_impl(ctx):
    """Assemble a systemd-stub UKI: kernel + initramfs + cmdline + os-release in
    one PE/COFF EFI binary. Signing the result (efi_sign) covers all of them with
    a single Secure Boot signature, so the whole boot artifact is verified by
    firmware LoadImage and still reaches init (the cmdline + initrd ride along).
    """
    tc = ctx.attrs._toolchain[BuildToolchainInfo]
    stub = ctx.attrs.stub[DefaultInfo].default_outputs[0]
    kernel = ctx.attrs.linux[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.attrs.name + ".efi")

    osrel = ctx.actions.write("os-release", ctx.attrs.os_release)

    cmd = cmd_args(ctx.attrs._assemble_tool[RunInfo])
    cmd.add("--objcopy", tc.objcopy.args)
    cmd.add("--objdump", tc.objdump.args)
    cmd.add("--stub", stub)
    cmd.add("--linux", kernel)
    cmd.add("--osrel", osrel)
    cmd.add("--cmdline-str", ctx.attrs.cmdline)
    if ctx.attrs.initrd != None:
        cmd.add("--initrd", ctx.attrs.initrd[DefaultInfo].default_outputs[0])
    if ctx.attrs.uname:
        cmd.add("--uname", ctx.actions.write("uname", ctx.attrs.uname))
    cmd.add("--output", out.as_output())

    # The toolchain objcopy/objdump are dynamically linked; give them the
    # hermetic PATH + ld-linux so they find their shared libs (as strip does).
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)
    for arg in toolchain_ld_linux_args(ctx):
        cmd.add(arg)

    ctx.actions.run(cmd, category = "uki", identifier = ctx.attrs.name)
    return [DefaultInfo(default_output = out)]

uki = rule(
    impl = _uki_impl,
    attrs = {
        "linux": attrs.dep(),
        "initrd": attrs.option(attrs.dep(), default = None),
        "cmdline": attrs.string(default = "console=ttyS0"),
        "os_release": attrs.string(default = "ID=buckos\nNAME=BuckOS\n"),
        "uname": attrs.string(default = ""),
        "stub": attrs.dep(default = "//packages/linux/boot/systemd-boot:stub"),
        "_assemble_tool": attrs.exec_dep(default = "//tools:assemble_uki"),
    } | TOOLCHAIN_ATTRS,
)
