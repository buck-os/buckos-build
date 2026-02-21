"""
meson_package rule: meson setup build && ninja -C build && ninja -C build install.

Five discrete cacheable actions — Buck2 can skip any phase whose
inputs haven't changed.

1. src_unpack  — obtain source artifact from source dep
2. src_prepare — apply patches (zero-cost passthrough when no patches)
3. meson_setup — run meson setup via meson_helper.py
4. src_compile — run ninja via build_helper.py
5. src_install — run ninja install via install_helper.py
   (post_install_cmds run in the prefix dir after install)
"""

load("//defs:providers.bzl", "PackageInfo")
load("//defs:toolchain_helpers.bzl", "TOOLCHAIN_ATTRS", "toolchain_env_args", "toolchain_extra_cflags", "toolchain_extra_ldflags")

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

    # Support source subdirectory (e.g. zstd keeps meson.build in build/meson/)
    if ctx.attrs.source_subdir:
        cmd.add("--source-dir", cmd_args(source, "/", ctx.attrs.source_subdir, delimiter = ""))
    else:
        cmd.add("--source-dir", source)
    cmd.add("--build-dir", output.as_output())

    # Inject toolchain CC/CXX/AR
    for env_arg in toolchain_env_args(ctx):
        cmd.add("--env", env_arg)

    # Inject user-specified environment variables
    for key, value in ctx.attrs.env.items():
        cmd.add("--env", "{}={}".format(key, value))

    # Pre-configure commands (run in the source dir before meson setup)
    for pre_cmd in ctx.attrs.pre_configure_cmds:
        cmd.add("--pre-cmd", pre_cmd)

    # Meson arguments (use = form so argparse doesn't treat -D... as a flag)
    for arg in ctx.attrs.meson_args:
        cmd.add(cmd_args("--meson-arg=", arg, delimiter = ""))

    # Meson defines (KEY=VALUE strings)
    for define in ctx.attrs.meson_defines:
        cmd.add(cmd_args("--meson-define=", define, delimiter = ""))

    # Extra CFLAGS / LDFLAGS — pass as environment-style flags via meson args
    cflags = list(toolchain_extra_cflags(ctx)) + list(ctx.attrs.extra_cflags)
    ldflags = list(toolchain_extra_ldflags(ctx)) + list(ctx.attrs.extra_ldflags)

    # Propagate flags and pkg-config paths from dependencies.
    # Note: dep libraries (-l flags) are NOT passed here — meson discovers
    # them via pkg-config.  Putting -l flags in LDFLAGS breaks meson's
    # C compiler sanity check (test binaries can't find .so files at runtime).
    pkg_config_paths = []
    for dep in ctx.attrs.deps:
        if PackageInfo in dep:
            pkg = dep[PackageInfo]
            prefix = pkg.prefix
            if pkg.pkg_config_path:
                pkg_config_paths.append(pkg.pkg_config_path)
            for f in pkg.cflags:
                cflags.append(f)
            for f in pkg.ldflags:
                ldflags.append(f)
        else:
            prefix = dep[DefaultInfo].default_outputs[0]

        # Derive standard include/lib/pkgconfig paths from dep prefix
        cflags.append(cmd_args(prefix, format = "-I{}/usr/include"))
        ldflags.append(cmd_args(prefix, format = "-L{}/usr/lib64"))
        ldflags.append(cmd_args(prefix, format = "-L{}/usr/lib"))
        # rpath-link lets the linker resolve transitive DT_NEEDED entries
        # (e.g. libsndfile.so → libFLAC.so) without adding runtime rpath.
        ldflags.append(cmd_args(prefix, format = "-Wl,-rpath-link,{}/usr/lib64"))
        ldflags.append(cmd_args(prefix, format = "-Wl,-rpath-link,{}/usr/lib"))
        pkg_config_paths.append(cmd_args(prefix, format = "{}/usr/lib64/pkgconfig"))
        pkg_config_paths.append(cmd_args(prefix, format = "{}/usr/lib/pkgconfig"))
        pkg_config_paths.append(cmd_args(prefix, format = "{}/usr/share/pkgconfig"))
        cmd.add("--path-prepend", cmd_args(prefix, format = "{}/usr/bin"))
        cmd.add("--path-prepend", cmd_args(prefix, format = "{}/usr/sbin"))

    if cflags:
        cmd.add("--env", cmd_args("CFLAGS=", cmd_args(cflags, delimiter = " "), delimiter = ""))
    if ldflags:
        cmd.add("--env", cmd_args("LDFLAGS=", cmd_args(ldflags, delimiter = " "), delimiter = ""))
    if pkg_config_paths:
        cmd.add("--env", cmd_args("PKG_CONFIG_PATH=", cmd_args(pkg_config_paths, delimiter = ":"), delimiter = ""))

    # Configure arguments from the common interface
    for arg in ctx.attrs.configure_args:
        cmd.add(cmd_args("--meson-arg=", arg, delimiter = ""))

    ctx.actions.run(cmd, category = "configure", identifier = ctx.attrs.name)
    return output

def _src_compile(ctx, configured, source):
    """Run ninja in the meson build tree."""
    output = ctx.actions.declare_output("built", dir = True)
    cmd = cmd_args(ctx.attrs._build_tool[RunInfo])
    cmd.add("--build-dir", configured)
    cmd.add("--output-dir", output.as_output())
    cmd.add("--build-system", "ninja")

    # Ensure source dir and dep artifacts are available — meson
    # out-of-tree builds reference them in build.ninja.
    cmd.add(cmd_args(hidden = source))
    for dep in ctx.attrs.deps:
        cmd.add(cmd_args(hidden = dep[DefaultInfo].default_outputs))
        if PackageInfo in dep:
            prefix = dep[PackageInfo].prefix
        else:
            prefix = dep[DefaultInfo].default_outputs[0]
        cmd.add("--path-prepend", cmd_args(prefix, format = "{}/usr/bin"))
        cmd.add("--path-prepend", cmd_args(prefix, format = "{}/usr/sbin"))

    # Inject toolchain CC/CXX/AR
    for env_arg in toolchain_env_args(ctx):
        cmd.add("--env", env_arg)

    # Inject user-specified environment variables
    for key, value in ctx.attrs.env.items():
        cmd.add("--env", "{}={}".format(key, value))

    for arg in ctx.attrs.make_args:
        cmd.add("--make-arg", arg)

    ctx.actions.run(cmd, category = "compile", identifier = ctx.attrs.name)
    return output

def _src_install(ctx, built, source):
    """Run ninja install into the output prefix."""
    output = ctx.actions.declare_output("installed", dir = True)
    cmd = cmd_args(ctx.attrs._install_tool[RunInfo])
    cmd.add("--build-dir", built)
    cmd.add("--prefix", output.as_output())
    cmd.add("--build-system", "ninja")

    # Ensure source dir is available for meson install rules
    cmd.add(cmd_args(hidden = source))

    # Inject toolchain CC/CXX/AR
    for env_arg in toolchain_env_args(ctx):
        cmd.add("--env", env_arg)

    # Inject user-specified environment variables
    for key, value in ctx.attrs.env.items():
        cmd.add("--env", "{}={}".format(key, value))

    for arg in ctx.attrs.make_args:
        cmd.add("--make-arg", arg)

    # Post-install commands (run in the prefix dir after install)
    for post_cmd in ctx.attrs.post_install_cmds:
        cmd.add("--post-cmd", post_cmd)

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

    # Phase 4: src_compile (source passed as hidden input for out-of-tree builds)
    built = _src_compile(ctx, configured, prepared)

    # Phase 5: src_install
    installed = _src_install(ctx, built, prepared)

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
        "pre_configure_cmds": attrs.list(attrs.string(), default = []),
        "meson_args": attrs.list(attrs.string(), default = []),
        "meson_defines": attrs.list(attrs.string(), default = []),
        "source_subdir": attrs.string(default = ""),
        "make_args": attrs.list(attrs.string(), default = []),
        "post_install_cmds": attrs.list(attrs.string(), default = []),
        "env": attrs.dict(attrs.string(), attrs.string(), default = {}),
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
