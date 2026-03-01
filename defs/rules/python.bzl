"""
python_package rule: pip install for Python packages.

Four discrete cacheable actions:

1. src_unpack  — obtain source artifact from source dep
2. src_prepare — apply patches (zero-cost passthrough when no patches)
3. python_install — run pip install via python_helper.py
"""

load("//defs:providers.bzl", "BuildToolchainInfo", "PackageInfo")
load("//defs/rules:_common.bzl", "COMMON_PACKAGE_ATTRS", "build_package_tsets", "src_prepare")
load("//defs:toolchain_helpers.bzl", "toolchain_env_args", "toolchain_path_args")
load("//defs:host_tools.bzl", "host_tool_path_args")

# ── Phase helpers ─────────────────────────────────────────────────────

def _python_install(ctx, source):
    """Run pip install via python_helper.py."""
    output = ctx.actions.declare_output("installed", dir = True)
    cmd = cmd_args(ctx.attrs._python_tool[RunInfo])
    cmd.add("--source-dir", source)
    cmd.add("--output-dir", output.as_output())

    # Hermetic PATH from toolchain
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)

    # Add host_deps bin dirs to PATH
    for arg in host_tool_path_args(ctx):
        cmd.add(arg)

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

    # Propagate dependency prefixes so build deps (setuptools, etc.)
    # are on PYTHONPATH during pip install --no-build-isolation.
    for dep in ctx.attrs.deps:
        if PackageInfo in dep:
            prefix = dep[PackageInfo].prefix
        else:
            prefix = dep[DefaultInfo].default_outputs[0]
        cmd.add("--dep-prefix", prefix)

    for arg in ctx.attrs.pip_args:
        cmd.add("--pip-arg", arg)

    ctx.actions.run(cmd, category = "python_install", identifier = ctx.attrs.name, allow_cache_upload = True)
    return output

# ── Rule implementation ───────────────────────────────────────────────

def _python_package_impl(ctx):
    # Phase 1: src_unpack — obtain source from dep
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]

    # Phase 2: src_prepare — apply patches
    prepared = src_prepare(ctx, source, "python_prepare")

    # Phase 3: python_install
    installed = _python_install(ctx, prepared)

    # Build transitive sets
    compile_tset, link_tset, path_tset, runtime_tset = build_package_tsets(ctx, installed)

    pkg_info = PackageInfo(
        name = ctx.attrs.name,
        version = ctx.attrs.version,
        prefix = installed,
        libraries = [],
        cflags = [],
        ldflags = [],
        compile_info = compile_tset,
        link_info = link_tset,
        path_info = path_tset,
        runtime_deps = runtime_tset,
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
    attrs = COMMON_PACKAGE_ATTRS | {
        # Python-specific
        "pip_args": attrs.list(attrs.string(), default = []),
        "_python_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:python_helper"),
        ),
    },
)
