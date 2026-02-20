"""
Transform rules: strip, stamp, IMA sign.

Each transform takes a dep with PackageInfo and returns DefaultInfo +
PackageInfo with a new prefix pointing at the transformed output.

When enabled=False the input PackageInfo is forwarded unchanged — no
action runs, no copy.  The target always exists in the graph regardless;
it is a zero-cost passthrough when the controlling USE flag is off.
"""

load("//defs:providers.bzl", "PackageInfo")

# ── Helpers ───────────────────────────────────────────────────────────

def _passthrough(pkg):
    """Return the input package unchanged."""
    return [DefaultInfo(default_output = pkg.prefix), pkg]

def _rebase_pkg(pkg, new_prefix):
    """Return a new PackageInfo with only the prefix swapped.

    The transform tools (strip, stamp, ima) copy the entire directory
    tree, preserving layout.  We only need to update the prefix artifact;
    downstream consumers that access sub-paths will use the prefix to
    locate files at runtime.  We don't re-project sub-paths because
    not all paths (e.g. usr/lib/pkgconfig) exist in every package.
    """
    return PackageInfo(
        name = pkg.name,
        version = pkg.version,
        prefix = new_prefix,
        include_dirs = pkg.include_dirs,
        lib_dirs = pkg.lib_dirs,
        bin_dirs = pkg.bin_dirs,
        libraries = pkg.libraries,
        pkg_config_path = pkg.pkg_config_path,
        cflags = pkg.cflags,
        ldflags = pkg.ldflags,
        license = pkg.license,
        src_uri = pkg.src_uri,
        src_sha256 = pkg.src_sha256,
        homepage = pkg.homepage,
        supplier = pkg.supplier,
        description = pkg.description,
        cpe = pkg.cpe,
    )

# ── strip_package ─────────────────────────────────────────────────────

def _strip_package_impl(ctx):
    pkg = ctx.attrs.package[PackageInfo]
    if not ctx.attrs.enabled:
        return _passthrough(pkg)

    output = ctx.actions.declare_output("stripped", dir = True)
    cmd = cmd_args(ctx.attrs._strip_tool[RunInfo])
    cmd.add("--input", pkg.prefix)
    cmd.add("--output", output.as_output())
    cmd.add("--strip", "strip")

    ctx.actions.run(cmd, category = "strip", identifier = pkg.name)
    return [DefaultInfo(default_output = output), _rebase_pkg(pkg, output)]

strip_package = rule(
    impl = _strip_package_impl,
    attrs = {
        "package": attrs.dep(),
        "enabled": attrs.bool(default = True),
        "_strip_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:strip_helper"),
        ),
    },
)

# ── stamp_package ─────────────────────────────────────────────────────

def _stamp_package_impl(ctx):
    pkg = ctx.attrs.package[PackageInfo]
    if not ctx.attrs.enabled:
        return _passthrough(pkg)

    output = ctx.actions.declare_output("stamped", dir = True)
    cmd = cmd_args(ctx.attrs._stamp_tool[RunInfo])
    cmd.add("--input", pkg.prefix)
    cmd.add("--output", output.as_output())
    cmd.add("--name", pkg.name)
    cmd.add("--version", pkg.version)
    cmd.add("--build-id", ctx.attrs.build_id)

    ctx.actions.run(cmd, category = "stamp", identifier = pkg.name)
    return [DefaultInfo(default_output = output), _rebase_pkg(pkg, output)]

stamp_package = rule(
    impl = _stamp_package_impl,
    attrs = {
        "package": attrs.dep(),
        "enabled": attrs.bool(default = True),
        "build_id": attrs.string(default = ""),
        "_stamp_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:stamp_helper"),
        ),
    },
)

# ── ima_sign_package ──────────────────────────────────────────────────

def _ima_sign_package_impl(ctx):
    pkg = ctx.attrs.package[PackageInfo]
    if not ctx.attrs.enabled:
        return _passthrough(pkg)

    output = ctx.actions.declare_output("signed", dir = True)
    cmd = cmd_args(ctx.attrs._ima_tool[RunInfo])
    cmd.add("--input", pkg.prefix)
    cmd.add("--output", output.as_output())
    cmd.add("--key", ctx.attrs.signing_key)

    ctx.actions.run(cmd, category = "ima_sign", identifier = pkg.name)
    return [DefaultInfo(default_output = output), _rebase_pkg(pkg, output)]

ima_sign_package = rule(
    impl = _ima_sign_package_impl,
    attrs = {
        "package": attrs.dep(),
        "enabled": attrs.bool(default = True),
        "signing_key": attrs.option(attrs.source(), default = None),
        "_ima_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:ima_helper"),
        ),
    },
)
