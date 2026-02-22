"""
python_package rule: pip install for Python packages.

Four discrete cacheable actions:

1. src_unpack  — obtain source artifact from source dep
2. src_prepare — apply patches (zero-cost passthrough when no patches)
3. python_install — run pip install via python_helper.py
"""

load("//defs:providers.bzl", "BuildToolchainInfo", "PackageInfo")
load("//defs:toolchain_helpers.bzl", "TOOLCHAIN_ATTRS", "toolchain_env_args")

# ── Phase helpers ─────────────────────────────────────────────────────

def _src_prepare(ctx, source):
    """Apply patches and pre_configure_cmds.  Separate action so unpatched source stays cached."""
    if not ctx.attrs.patches and not ctx.attrs.pre_configure_cmds:
        return source  # No patches or cmds — zero-cost passthrough

    output = ctx.actions.declare_output("prepared", dir = True)
    cmd = cmd_args(ctx.attrs._patch_tool[RunInfo])
    cmd.add("--source-dir", source)
    cmd.add("--output-dir", output.as_output())
    for p in ctx.attrs.patches:
        cmd.add("--patch", p)
    for c in ctx.attrs.pre_configure_cmds:
        cmd.add("--cmd", c)

    ctx.actions.run(cmd, category = "prepare", identifier = ctx.attrs.name)
    return output

def _python_install(ctx, source):
    """Run pip install via python_helper.py."""
    output = ctx.actions.declare_output("installed", dir = True)
    cmd = cmd_args(ctx.attrs._python_tool[RunInfo])
    cmd.add("--source-dir", source)
    cmd.add("--output-dir", output.as_output())

    # Inject bootstrap Python if available from toolchain
    tc = ctx.attrs._toolchain[BuildToolchainInfo]
    if tc.python:
        cmd.add("--python", tc.python.args)

    # Inject toolchain CC/CXX/AR (for C extensions)
    for env_arg in toolchain_env_args(ctx):
        cmd.add("--env", env_arg)

    # Inject user-specified environment variables
    for key, value in ctx.attrs.env.items():
        cmd.add("--env", "{}={}".format(key, value))

    for arg in ctx.attrs.pip_args:
        cmd.add("--pip-arg", arg)

    ctx.actions.run(cmd, category = "python_install", identifier = ctx.attrs.name)
    return output

# ── Rule implementation ───────────────────────────────────────────────

def _python_package_impl(ctx):
    # Phase 1: src_unpack — obtain source from dep
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]

    # Phase 2: src_prepare — apply patches
    prepared = _src_prepare(ctx, source)

    # Phase 3: python_install
    installed = _python_install(ctx, prepared)

    pkg_info = PackageInfo(
        name = ctx.attrs.name,
        version = ctx.attrs.version,
        prefix = installed,
        include_dirs = [],
        lib_dirs = [],
        bin_dirs = [],
        libraries = [],
        pkg_config_path = None,
        cflags = [],
        ldflags = [],
        license = ctx.attrs.license,
        src_uri = ctx.attrs.src_uri,
        src_sha256 = ctx.attrs.src_sha256,
        homepage = ctx.attrs.homepage,
        supplier = "Organization: BuckOS",
        description = ctx.attrs.description,
        cpe = ctx.attrs.cpe,
    )

    return [DefaultInfo(default_output = installed), pkg_info]

# ── Rule definition ───────────────────────────────────────────────────

python_package = rule(
    impl = _python_package_impl,
    attrs = {
        # Source and identity
        "source": attrs.dep(),
        "version": attrs.string(),

        # Build configuration
        "pip_args": attrs.list(attrs.string(), default = []),
        "pre_configure_cmds": attrs.list(attrs.string(), default = []),
        "env": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "deps": attrs.list(attrs.dep(), default = []),
        "patches": attrs.list(attrs.source(), default = []),

        # Unused by python but accepted by the package() macro interface
        "configure_args": attrs.list(attrs.string(), default = []),
        "extra_cflags": attrs.list(attrs.string(), default = []),
        "extra_ldflags": attrs.list(attrs.string(), default = []),
        "libraries": attrs.list(attrs.string(), default = []),
        "post_install_cmds": attrs.list(attrs.string(), default = []),

        # Labels (metadata-only, for BXL queries)
        "labels": attrs.list(attrs.string(), default = []),

        # SBOM metadata
        "license": attrs.string(default = "UNKNOWN"),
        "src_uri": attrs.string(default = ""),
        "src_sha256": attrs.string(default = ""),
        "homepage": attrs.option(attrs.string(), default = None),
        "description": attrs.string(default = ""),
        "cpe": attrs.option(attrs.string(), default = None),

        # Tool deps (hidden — resolved automatically)
        "_patch_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:patch_helper"),
        ),
        "_python_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:python_helper"),
        ),
    } | TOOLCHAIN_ATTRS,
)
