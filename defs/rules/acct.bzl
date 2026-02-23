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

    # group(5): group_name:password:GID:user_list
    group_line = "{}:x:{}:".format(ctx.attrs.name, ctx.attrs.gid)

    # gshadow(5): group_name:encrypted_password:admins:members
    gshadow_line = "{}:!::".format(ctx.attrs.name)

    script = ctx.actions.write("gen_group.sh", """\
#!/bin/bash
set -e
mkdir -p "$1/etc"
echo '{group}' >> "$1/etc/group"
echo '{gshadow}' >> "$1/etc/gshadow"
""".format(group = group_line, gshadow = gshadow_line), is_executable = True)

    ctx.actions.run(
        cmd_args("bash", script, prefix.as_output()),
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
    },
)

# ── acct_user_package ─────────────────────────────────────────────────

def _acct_user_impl(ctx):
    """Generate /etc/passwd and /etc/shadow entries."""
    prefix = ctx.actions.declare_output("installed", dir = True)

    # passwd(5): username:password:UID:GID:GECOS:home_dir:shell
    # GID is set to UID by default (matching primary_group convention)
    passwd_line = "{}:x:{}:{}:{}:{}:{}".format(
        ctx.attrs.name,
        ctx.attrs.uid,
        ctx.attrs.uid,  # GID = UID (resolved via primary_group at rootfs merge)
        ctx.attrs.description,
        ctx.attrs.home,
        ctx.attrs.shell,
    )

    # shadow(5): username:encrypted_password:last_changed:min:max:warn:inactive:expire:reserved
    shadow_line = "{}:!:0:0:99999:7:::".format(ctx.attrs.name)

    script = ctx.actions.write("gen_user.sh", """\
#!/bin/bash
set -e
mkdir -p "$1/etc"
echo '{passwd}' >> "$1/etc/passwd"
echo '{shadow}' >> "$1/etc/shadow"
chmod 640 "$1/etc/shadow"
""".format(passwd = passwd_line, shadow = shadow_line), is_executable = True)

    ctx.actions.run(
        cmd_args("bash", script, prefix.as_output()),
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
    },
)
