"""
binary_package rule: custom install script for pre-built packages.

Three discrete cacheable actions:

1. src_unpack   — obtain source artifact from source dep
2. src_prepare  — apply patches (zero-cost passthrough when no patches)
3. install      — run install_script in a shell with $SRC and $OUT set
"""

load("//defs:providers.bzl", "PackageInfo")
load("//defs:toolchain_helpers.bzl", "TOOLCHAIN_ATTRS", "toolchain_env_args")

# ── Phase helpers ─────────────────────────────────────────────────────

def _src_prepare(ctx, source):
    """Apply patches.  Separate action so unpatched source stays cached."""
    if not ctx.attrs.patches:
        return source  # No patches — zero-cost passthrough

    output = ctx.actions.declare_output("prepared", dir = True)
    cmd = cmd_args(ctx.attrs._patch_tool[RunInfo])
    cmd.add("--source-dir", source)
    cmd.add("--output-dir", output.as_output())
    for p in ctx.attrs.patches:
        cmd.add("--patch", p)

    ctx.actions.run(cmd, category = "prepare", identifier = ctx.attrs.name)
    return output

def _install(ctx, source):
    """Run install_script with SRC pointing to source and OUT to output prefix."""
    output = ctx.actions.declare_output("installed", dir = True)

    # Write a wrapper that sets SRCS/OUT from positional args then sources
    # the user script.  This ensures output.as_output() appears in cmd_args
    # so Buck2 can track the declared output.
    wrapper = ctx.actions.write("wrapper.sh", """\
#!/bin/bash
set -e
# Resolve to absolute paths so install scripts that cd still work.
_resolve() { [[ "$1" = /* ]] && echo "$1" || echo "$PWD/$1"; }
export SRCS="$(_resolve "$1")"; shift
export OUT="$(_resolve "$1")"; shift
export PV="$1"; shift
source "$1"
""", is_executable = True)

    script = ctx.actions.write("install.sh", ctx.attrs.install_script, is_executable = True)

    cmd = cmd_args("bash", "-e", wrapper, source, output.as_output(), ctx.attrs.version, script)

    env = {}

    # Inject toolchain CC/CXX/AR
    for env_arg in toolchain_env_args(ctx):
        parts = env_arg.split("=", 1) if type(env_arg) == "string" else []
        if len(parts) == 2:
            env[parts[0]] = parts[1]

    # Inject user-specified environment variables
    for key, value in ctx.attrs.env.items():
        env[key] = value

    ctx.actions.run(
        cmd,
        env = env,
        category = "install",
        identifier = ctx.attrs.name,
    )
    return output

# ── Rule implementation ───────────────────────────────────────────────

def _binary_package_impl(ctx):
    # Phase 1: src_unpack — obtain source from dep
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]

    # Phase 2: src_prepare — apply patches
    prepared = _src_prepare(ctx, source)

    # Phase 3: install
    installed = _install(ctx, prepared)

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

binary_package = rule(
    impl = _binary_package_impl,
    attrs = {
        # Source and identity
        "source": attrs.dep(),
        "version": attrs.string(),

        # Build configuration
        "install_script": attrs.string(default = "cp -a \"$SRCS\"/. \"$OUT/\""),
        "env": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "deps": attrs.list(attrs.dep(), default = []),
        "patches": attrs.list(attrs.source(), default = []),

        # Unused by binary but accepted by the package() macro interface
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
    } | TOOLCHAIN_ATTRS,
)
