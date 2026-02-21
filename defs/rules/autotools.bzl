"""
autotools_package rule: ./configure && make && make install.

Six discrete cacheable actions — Buck2 can skip any phase whose
inputs haven't changed.

1. src_unpack  — obtain source artifact from source dep
2. src_prepare — apply patches (zero-cost passthrough when no patches)
3. src_configure — run ./configure via configure_helper.py
   (skip_configure=True copies source without running ./configure,
   for Kconfig-based packages like busybox or the kernel)
   (pre_configure_cmds run in the source dir before ./configure,
   for autoreconf or other pre-configure setup)
4. src_compile — run make via build_helper.py
   (pre_build_cmds run in the build dir before the main make invocation,
   for Kconfig initialisation or other setup)
5. src_install — run make install via install_helper.py
   (post_install_cmds run in the prefix dir after make install)
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

def _src_configure(ctx, source):
    """Run ./configure with toolchain env and dep flags.

    When skip_configure is True, only copies the source tree without
    running ./configure.  Used for Kconfig-based packages where the
    configuration is handled by make targets in the build phase.
    """
    output = ctx.actions.declare_output("configured", dir = True)
    cmd = cmd_args(ctx.attrs._configure_tool[RunInfo])
    cmd.add("--source-dir", source)
    cmd.add("--output-dir", output.as_output())

    # Inject toolchain CC/CXX/AR
    for env_arg in toolchain_env_args(ctx):
        cmd.add("--env", env_arg)

    # Inject user-specified environment variables
    for key, value in ctx.attrs.env.items():
        cmd.add("--env", "{}={}".format(key, value))

    if ctx.attrs.configure_script:
        cmd.add("--configure-script", ctx.attrs.configure_script)

    # Pre-configure commands (run before ./configure in the source tree)
    for pre_cmd in ctx.attrs.pre_configure_cmds:
        cmd.add("--pre-cmd", pre_cmd)

    if ctx.attrs.skip_configure:
        cmd.add("--skip-configure")
    else:
        # Default prefix for FHS layout
        cmd.add("--configure-arg=--prefix=/usr")

        # Configure arguments (use = syntax so argparse handles --prefix=... values)
        for arg in ctx.attrs.configure_args:
            cmd.add(cmd_args("--configure-arg=", arg, delimiter = ""))

        # Toolchain-injected CFLAGS / LDFLAGS (e.g. -fuse-ld=mold)
        for flag in toolchain_extra_cflags(ctx):
            cmd.add(cmd_args("--cflags=", flag, delimiter = ""))
        for flag in toolchain_extra_ldflags(ctx):
            cmd.add(cmd_args("--ldflags=", flag, delimiter = ""))

        # Extra CFLAGS / LDFLAGS from this package's attrs
        for flag in ctx.attrs.extra_cflags:
            cmd.add(cmd_args("--cflags=", flag, delimiter = ""))
        for flag in ctx.attrs.extra_ldflags:
            cmd.add(cmd_args("--ldflags=", flag, delimiter = ""))

        # Propagate include/lib/pkgconfig paths from dependencies.
        # Works with both new-style PackageInfo deps and old-style
        # ebuild_package deps (DefaultInfo only).
        for dep in ctx.attrs.deps:
            if PackageInfo in dep:
                prefix = dep[PackageInfo].prefix
            else:
                prefix = dep[DefaultInfo].default_outputs[0]
            inc = cmd_args(prefix, format = "-I{}/usr/include")
            lib64 = cmd_args(prefix, format = "-L{}/usr/lib64")
            lib = cmd_args(prefix, format = "-L{}/usr/lib")
            cmd.add(cmd_args("--cppflags=", inc, delimiter = ""))
            cmd.add(cmd_args("--cflags=", inc, delimiter = ""))
            cmd.add(cmd_args("--ldflags=", lib64, delimiter = ""))
            cmd.add(cmd_args("--ldflags=", lib, delimiter = ""))
            cmd.add(cmd_args("--ldflags=", cmd_args(prefix, format = "-Wl,-rpath-link,{}/usr/lib64"), delimiter = ""))
            cmd.add(cmd_args("--ldflags=", cmd_args(prefix, format = "-Wl,-rpath-link,{}/usr/lib"), delimiter = ""))
            cmd.add("--pkg-config-path", cmd_args(prefix, format = "{}/usr/lib64/pkgconfig"))
            cmd.add("--pkg-config-path", cmd_args(prefix, format = "{}/usr/lib/pkgconfig"))
            cmd.add("--pkg-config-path", cmd_args(prefix, format = "{}/usr/share/pkgconfig"))
            cmd.add("--path-prepend", cmd_args(prefix, format = "{}/usr/bin"))
            cmd.add("--path-prepend", cmd_args(prefix, format = "{}/usr/sbin"))

            if PackageInfo in dep:
                for f in dep[PackageInfo].cflags:
                    cmd.add(cmd_args("--cflags=", f, delimiter = ""))
                for f in dep[PackageInfo].ldflags:
                    cmd.add(cmd_args("--ldflags=", f, delimiter = ""))

    ctx.actions.run(cmd, category = "configure", identifier = ctx.attrs.name)
    return output

def _dep_env_args(ctx):
    """Build --env and --path-prepend args from deps for build/install phases.

    Returns (env_args, path_args) tuples.  env_args are --env KEY=VALUE
    strings; path_args are --path-prepend directories.
    """
    pkg_config_paths = []
    path_dirs = []
    cppflags = []
    cflags = list(toolchain_extra_cflags(ctx)) + list(ctx.attrs.extra_cflags)
    ldflags = list(toolchain_extra_ldflags(ctx)) + list(ctx.attrs.extra_ldflags)
    libs = []
    for dep in ctx.attrs.deps:
        if PackageInfo in dep:
            prefix = dep[PackageInfo].prefix
            for libname in dep[PackageInfo].libraries:
                libs.append("-l" + libname)
            for f in dep[PackageInfo].cflags:
                cflags.append(f)
            for f in dep[PackageInfo].ldflags:
                ldflags.append(f)
        else:
            prefix = dep[DefaultInfo].default_outputs[0]
        inc = cmd_args(prefix, format = "-I{}/usr/include")
        cppflags.append(inc)
        cflags.append(inc)
        ldflags.append(cmd_args(prefix, format = "-L{}/usr/lib64"))
        ldflags.append(cmd_args(prefix, format = "-L{}/usr/lib"))
        ldflags.append(cmd_args(prefix, format = "-Wl,-rpath-link,{}/usr/lib64"))
        ldflags.append(cmd_args(prefix, format = "-Wl,-rpath-link,{}/usr/lib"))
        pkg_config_paths.append(cmd_args(prefix, format = "{}/usr/lib64/pkgconfig"))
        pkg_config_paths.append(cmd_args(prefix, format = "{}/usr/lib/pkgconfig"))
        pkg_config_paths.append(cmd_args(prefix, format = "{}/usr/share/pkgconfig"))
        path_dirs.append(cmd_args(prefix, format = "{}/usr/bin"))
        path_dirs.append(cmd_args(prefix, format = "{}/usr/sbin"))

    env_args = []
    if pkg_config_paths:
        env_args.append(cmd_args("PKG_CONFIG_PATH=", cmd_args(pkg_config_paths, delimiter = ":"), delimiter = ""))
    if cppflags:
        env_args.append(cmd_args("CPPFLAGS=", cmd_args(cppflags, delimiter = " "), delimiter = ""))
    if cflags:
        env_args.append(cmd_args("CFLAGS=", cmd_args(cflags, delimiter = " "), delimiter = ""))
    if ldflags:
        env_args.append(cmd_args("LDFLAGS=", cmd_args(ldflags, delimiter = " "), delimiter = ""))
    if libs:
        env_args.append(cmd_args("LIBS=", cmd_args(libs, delimiter = " "), delimiter = ""))
    return env_args, path_dirs

def _src_compile(ctx, configured):
    """Run make (or equivalent) in the configured source tree.

    When pre_build_cmds is non-empty, each command runs in the build
    directory before the main make invocation (e.g. Kconfig setup).
    """
    output = ctx.actions.declare_output("built", dir = True)
    cmd = cmd_args(ctx.attrs._build_tool[RunInfo])
    cmd.add("--build-dir", configured)
    cmd.add("--output-dir", output.as_output())
    # Inject toolchain CC/CXX/AR
    for env_arg in toolchain_env_args(ctx):
        cmd.add("--env", env_arg)

    # Propagate dep paths so make can find headers/libs/pkg-config/tools
    dep_env, dep_paths = _dep_env_args(ctx)
    for env_arg in dep_env:
        cmd.add("--env", env_arg)
    for path_dir in dep_paths:
        cmd.add("--path-prepend", path_dir)

    # Inject user-specified environment variables
    for key, value in ctx.attrs.env.items():
        cmd.add("--env", "{}={}".format(key, value))

    for pre_cmd in ctx.attrs.pre_build_cmds:
        cmd.add("--pre-cmd", pre_cmd)
    for arg in ctx.attrs.make_args:
        cmd.add(cmd_args("--make-arg=", arg, delimiter = ""))

    ctx.actions.run(cmd, category = "compile", identifier = ctx.attrs.name)
    return output

def _src_install(ctx, built):
    """Run make install DESTDIR=... into the output prefix.

    install_prefix_var overrides the make variable name for the install
    prefix (default: DESTDIR).  Busybox uses CONFIG_PREFIX instead.
    post_install_cmds run in the prefix directory after make install.
    """
    output = ctx.actions.declare_output("installed", dir = True)
    cmd = cmd_args(ctx.attrs._install_tool[RunInfo])
    cmd.add("--build-dir", built)
    cmd.add("--prefix", output.as_output())

    # Inject toolchain CC/CXX/AR
    for env_arg in toolchain_env_args(ctx):
        cmd.add("--env", env_arg)

    # Propagate dep paths so make install can find headers/libs/pkg-config/tools
    dep_env, dep_paths = _dep_env_args(ctx)
    for env_arg in dep_env:
        cmd.add("--env", env_arg)
    for path_dir in dep_paths:
        cmd.add("--path-prepend", path_dir)

    # Inject user-specified environment variables
    for key, value in ctx.attrs.env.items():
        cmd.add("--env", "{}={}".format(key, value))

    if ctx.attrs.install_prefix_var:
        cmd.add("--destdir-var", ctx.attrs.install_prefix_var)
    for arg in ctx.attrs.make_args:
        cmd.add(cmd_args("--make-arg=", arg, delimiter = ""))

    # Post-install commands (run in the prefix dir after make install)
    for post_cmd in ctx.attrs.post_install_cmds:
        cmd.add("--post-cmd", post_cmd)

    ctx.actions.run(cmd, category = "install", identifier = ctx.attrs.name)
    return output

# ── Rule implementation ───────────────────────────────────────────────

def _autotools_package_impl(ctx):
    # Phase 1: src_unpack — obtain source from dep
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]

    # Phase 2: src_prepare — apply patches
    prepared = _src_prepare(ctx, source)

    # Phase 3: src_configure
    configured = _src_configure(ctx, prepared)

    # Phase 4: src_compile
    built = _src_compile(ctx, configured)

    # Phase 5: src_install
    installed = _src_install(ctx, built)

    # Don't use project() for sub-paths — they may not exist in every
    # package (e.g. zlib has usr/lib64 but not usr/lib).  Store the
    # prefix only; consumers derive sub-paths from it.
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

autotools_package = rule(
    impl = _autotools_package_impl,
    attrs = {
        # Source and identity
        "source": attrs.dep(),
        "version": attrs.string(),

        # Build configuration
        "configure_args": attrs.list(attrs.string(), default = []),
        "configure_script": attrs.option(attrs.string(), default = None),
        "skip_configure": attrs.bool(default = False),
        "pre_configure_cmds": attrs.list(attrs.string(), default = []),
        "pre_build_cmds": attrs.list(attrs.string(), default = []),
        "post_install_cmds": attrs.list(attrs.string(), default = []),
        "make_args": attrs.list(attrs.string(), default = []),
        "install_prefix_var": attrs.option(attrs.string(), default = None),
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
        "_configure_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:configure_helper"),
        ),
        "_build_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:build_helper"),
        ),
        "_install_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:install_helper"),
        ),
    } | TOOLCHAIN_ATTRS,
)
