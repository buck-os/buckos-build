"""
go_package rule: go build for Go packages.

Four discrete cacheable actions:

1. src_unpack  — obtain source artifact from source dep
2. src_prepare — apply patches (zero-cost passthrough when no patches)
3. go_build    — run go build via go_helper.py
4. install     — binaries placed into prefix/usr/bin/ by go_helper.py
"""

load("//defs:providers.bzl", "PackageInfo")
load("//defs/rules:_common.bzl", "COMMON_PACKAGE_ATTRS", "build_package_tsets", "src_prepare")
load("//defs:toolchain_helpers.bzl", "toolchain_env_args", "toolchain_path_args")
load("//defs:host_tools.bzl", "host_tool_path_args")

# ── Phase helpers ─────────────────────────────────────────────────────

def _go_build(ctx, source):
    """Run go build via go_helper.py."""
    output = ctx.actions.declare_output("built", dir = True)
    cmd = cmd_args(ctx.attrs._go_tool[RunInfo])
    cmd.add("--source-dir", source)
    cmd.add("--output-dir", output.as_output())

    # Hermetic PATH from toolchain
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)

    # Add host_deps bin dirs to PATH
    for arg in host_tool_path_args(ctx):
        cmd.add(arg)

    # Inject toolchain CC/CXX/AR
    for env_arg in toolchain_env_args(ctx):
        cmd.add("--env", env_arg)

    # Inject user-specified environment variables
    for key, value in ctx.attrs.env.items():
        cmd.add("--env", "{}={}".format(key, value))

    if ctx.attrs.ldflags:
        cmd.add("--ldflags", ctx.attrs.ldflags)
    for arg in ctx.attrs.go_args:
        cmd.add("--go-arg", arg)

    # Explicit binary names to install
    for b in ctx.attrs.bins:
        cmd.add("--bin", b)

    # Go packages to build (default: ./...)
    for pkg in ctx.attrs.packages:
        cmd.add("--package", pkg)

    # Vendor deps directory
    if ctx.attrs.vendor_deps:
        cmd.add("--vendor-dir", ctx.attrs.vendor_deps[DefaultInfo].default_outputs[0])

    ctx.actions.run(cmd, category = "go_build", identifier = ctx.attrs.name, allow_cache_upload = True)
    return output

# ── Rule implementation ───────────────────────────────────────────────

def _go_package_impl(ctx):
    # Phase 1: src_unpack — obtain source from dep
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]

    # Phase 2: src_prepare — apply patches
    prepared = src_prepare(ctx, source, "go_prepare")

    # Phase 3: go_build (also handles install into prefix/usr/bin/)
    installed = _go_build(ctx, prepared)

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

go_package = rule(
    impl = _go_package_impl,
    attrs = COMMON_PACKAGE_ATTRS | {
        # Go-specific
        "go_args": attrs.list(attrs.string(), default = []),
        "ldflags": attrs.string(default = ""),
        "bins": attrs.list(attrs.string(), default = []),
        "packages": attrs.list(attrs.string(), default = []),
        "vendor_deps": attrs.option(attrs.dep(), default = None),
        "_go_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:go_helper"),
        ),
    },
)
