"""
Account user and group package rules.

These rules generate passwd/group/shadow file entries for system
accounts.  They don't download or build anything — they simply
produce files that the rootfs rule merges into the system databases.

Usage in BUCK files:

    load("//defs/rules:acct.bzl", "acct_user_package", "acct_group_package")

    acct_group_package(
        name = "messagebus",
        gid = 101,
        description = "System group for D-Bus",
    )

    acct_user_package(
        name = "messagebus",
        uid = 101,
        primary_group = "messagebus",
        home = "/nonexistent",
        shell = "/usr/sbin/nologin",
        description = "System user for D-Bus",
        deps = ["//packages/acct-group/messagebus:messagebus"],
    )
"""

load("//defs:providers.bzl", "PackageInfo")

# ── acct_group_package ────────────────────────────────────────────────

def _acct_group_impl(ctx):
    """Generate /etc/group and /etc/gshadow entries."""
    prefix = ctx.actions.declare_output("installed", dir = True)

    cmd = cmd_args(ctx.attrs._acct_tool[RunInfo])
    cmd.add("--mode", "group")
    cmd.add("--name", ctx.attrs.name)
    cmd.add("--id", str(ctx.attrs.gid))
    cmd.add("--output-dir", prefix.as_output())

    ctx.actions.run(
        cmd,
        category = "acct_group",
        identifier = ctx.attrs.name,
    )

    pkg_info = PackageInfo(
        name = ctx.attrs.name,
        version = "0",
        prefix = prefix,
        include_dirs = [],
        lib_dirs = [],
        bin_dirs = [],
        libraries = [],
        runtime_lib_dirs = [],
        pkg_config_path = None,
        cflags = [],
        ldflags = [],
        license = "metapackage",
        src_uri = "",
        src_sha256 = "",
        homepage = None,
        supplier = "Organization: BuckOS",
        description = ctx.attrs.description,
        cpe = None,
    )

    return [DefaultInfo(default_output = prefix), pkg_info]

acct_group_package = rule(
    impl = _acct_group_impl,
    attrs = {
        "gid": attrs.int(),
        "description": attrs.string(default = ""),
        "deps": attrs.list(attrs.dep(), default = []),
        "_acct_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:acct_helper"),
        ),
    },
)

# ── acct_user_package ─────────────────────────────────────────────────

def _acct_user_impl(ctx):
    """Generate /etc/passwd and /etc/shadow entries."""
    prefix = ctx.actions.declare_output("installed", dir = True)

    cmd = cmd_args(ctx.attrs._acct_tool[RunInfo])
    cmd.add("--mode", "user")
    cmd.add("--name", ctx.attrs.name)
    cmd.add("--id", str(ctx.attrs.uid))
    cmd.add("--output-dir", prefix.as_output())
    cmd.add("--home", ctx.attrs.home)
    cmd.add("--shell", ctx.attrs.shell)
    cmd.add("--description", ctx.attrs.description)

    ctx.actions.run(
        cmd,
        category = "acct_user",
        identifier = ctx.attrs.name,
    )

    pkg_info = PackageInfo(
        name = ctx.attrs.name,
        version = "0",
        prefix = prefix,
        include_dirs = [],
        lib_dirs = [],
        bin_dirs = [],
        libraries = [],
        runtime_lib_dirs = [],
        pkg_config_path = None,
        cflags = [],
        ldflags = [],
        license = "metapackage",
        src_uri = "",
        src_sha256 = "",
        homepage = None,
        supplier = "Organization: BuckOS",
        description = ctx.attrs.description,
        cpe = None,
    )

    return [DefaultInfo(default_output = prefix), pkg_info]

acct_user_package = rule(
    impl = _acct_user_impl,
    attrs = {
        "uid": attrs.int(),
        "home": attrs.string(default = "/nonexistent"),
        "shell": attrs.string(default = "/usr/sbin/nologin"),
        "primary_group": attrs.string(default = ""),
        "groups": attrs.list(attrs.string(), default = []),
        "description": attrs.string(default = ""),
        "deps": attrs.list(attrs.dep(), default = []),
        "_acct_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:acct_helper"),
        ),
    },
)
