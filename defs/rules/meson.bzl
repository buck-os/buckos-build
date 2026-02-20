"""
meson_package rule: meson setup build && ninja -C build && ninja -C build install.

Five discrete cacheable actions — Buck2 can skip any phase whose
inputs haven't changed.

1. src_unpack  — obtain source artifact from source dep
2. src_prepare — apply patches (zero-cost passthrough when no patches)
3. meson_setup — run meson setup via meson_helper.py
4. src_compile — run ninja via build_helper.py
5. src_install — run ninja install via install_helper.py
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

def _meson_setup(ctx, source):
    """Run meson setup with toolchain env and dep flags."""
    output = ctx.actions.declare_output("configured", dir = True)
    cmd = cmd_args(ctx.attrs._meson_tool[RunInfo])
    cmd.add("--source-dir", source)
    cmd.add("--build-dir", output.as_output())

    # Inject toolchain CC/CXX/AR
    for env_arg in toolchain_env_args(ctx):
        cmd.add("--env", env_arg)

    # Meson arguments
    for arg in ctx.attrs.meson_args:
        cmd.add("--meson-arg", arg)

    # Meson defines (KEY=VALUE strings)
    for define in ctx.attrs.meson_defines:
        cmd.add("--meson-define", define)

    # Extra CFLAGS / LDFLAGS — pass as environment-style flags via meson args
    cflags = list(ctx.attrs.extra_cflags)
    ldflags = list(ctx.attrs.extra_ldflags)

    # Propagate include/lib dirs and library names from dependencies
    pkg_config_paths = []
    for dep in ctx.attrs.deps:
        if PackageInfo in dep:
            pkg = dep[PackageInfo]
            for d in pkg.include_dirs:
                cflags.append(cmd_args("-I", d, delimiter = ""))
            for d in pkg.lib_dirs:
                ldflags.append(cmd_args("-L", d, delimiter = ""))
            for lib in pkg.libraries:
                ldflags.append("-l" + lib)
            if pkg.pkg_config_path:
                pkg_config_paths.append(pkg.pkg_config_path)

            # Propagate any extra flags the dependency requires consumers to use
            for f in pkg.cflags:
                cflags.append(f)
            for f in pkg.ldflags:
                ldflags.append(f)

    if cflags:
        cmd.add("--meson-define", cmd_args("c_args=", cmd_args(cflags, delimiter = ","), delimiter = ""))
    if ldflags:
        cmd.add("--meson-define", cmd_args("c_link_args=", cmd_args(ldflags, delimiter = ","), delimiter = ""))

    # Configure arguments from the common interface
    for arg in ctx.attrs.configure_args:
        cmd.add("--meson-arg", arg)

    ctx.actions.run(cmd, category = "configure", identifier = ctx.attrs.name)
    return output

def _src_compile(ctx, configured):
    """Run ninja in the meson build tree."""
    output = ctx.actions.declare_output("built", dir = True)
    cmd = cmd_args(ctx.attrs._build_tool[RunInfo])
    cmd.add("--build-dir", configured)
    cmd.add("--output-dir", output.as_output())
    cmd.add("--build-system", "ninja")

    # Inject toolchain CC/CXX/AR
    for env_arg in toolchain_env_args(ctx):
        cmd.add("--env", env_arg)
    for arg in ctx.attrs.make_args:
        cmd.add("--make-arg", arg)

    ctx.actions.run(cmd, category = "compile", identifier = ctx.attrs.name)
    return output

def _src_install(ctx, built):
    """Run install into the output prefix."""
    output = ctx.actions.declare_output("installed", dir = True)
    cmd = cmd_args(ctx.attrs._install_tool[RunInfo])
    cmd.add("--build-dir", built)
    cmd.add("--prefix", output.as_output())

    # Inject toolchain CC/CXX/AR
    for env_arg in toolchain_env_args(ctx):
        cmd.add("--env", env_arg)

    for arg in ctx.attrs.make_args:
        cmd.add("--make-arg", arg)

    ctx.actions.run(cmd, category = "install", identifier = ctx.attrs.name)
    return output

# ── Rule implementation ───────────────────────────────────────────────

def _meson_package_impl(ctx):
    # Phase 1: src_unpack — obtain source from dep
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]

    # Phase 2: src_prepare — apply patches
    prepared = _src_prepare(ctx, source)

    # Phase 3: meson_setup
    configured = _meson_setup(ctx, prepared)

    # Phase 4: src_compile
    built = _src_compile(ctx, configured)

    # Phase 5: src_install
    installed = _src_install(ctx, built)

    pkg_info = PackageInfo(
        name = ctx.attrs.name,
        version = ctx.attrs.version,
        prefix = installed,
        include_dirs = [],
        lib_dirs = [],
        bin_dirs = [],
        libraries = ctx.attrs.libraries,
        pkg_config_path = None,
        cflags = ctx.attrs.extra_cflags,
        ldflags = ctx.attrs.extra_ldflags,
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

meson_package = rule(
    impl = _meson_package_impl,
    attrs = {
        # Source and identity
        "source": attrs.dep(),
        "version": attrs.string(),

        # Build configuration
        "configure_args": attrs.list(attrs.string(), default = []),
        "meson_args": attrs.list(attrs.string(), default = []),
        "meson_defines": attrs.list(attrs.string(), default = []),
        "make_args": attrs.list(attrs.string(), default = []),
        "deps": attrs.list(attrs.dep(), default = []),
        "patches": attrs.list(attrs.source(), default = []),
        "libraries": attrs.list(attrs.string(), default = []),
        "extra_cflags": attrs.list(attrs.string(), default = []),
        "extra_ldflags": attrs.list(attrs.string(), default = []),

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
        "_meson_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:meson_helper"),
        ),
        "_build_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:build_helper"),
        ),
        "_install_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:install_helper"),
        ),
    } | TOOLCHAIN_ATTRS,
)
