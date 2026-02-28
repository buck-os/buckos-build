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
load("//defs/rules:_common.bzl",
     "add_flag_file", "build_package_tsets", "collect_dep_tsets",
     "collect_runtime_lib_dirs",
     "write_bin_dirs", "write_compile_flags", "write_lib_dirs",
     "write_link_flags", "write_pkg_config_paths",
)
load("//defs:toolchain_helpers.bzl", "TOOLCHAIN_ATTRS", "toolchain_env_args", "toolchain_extra_cflags", "toolchain_extra_ldflags", "toolchain_path_args")
load("//defs:host_tools.bzl", "host_tool_path_args")

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

def _src_configure(ctx, source, cflags_file = None, ldflags_file = None,
                   pkg_config_file = None, path_file = None):
    """Run ./configure with toolchain env and dep flags.

    When skip_configure is True, only copies the source tree without
    running ./configure.  Used for Kconfig-based packages where the
    configuration is handled by make targets in the build phase.

    Dep flags are propagated via tset projection files (cflags_file etc.)
    instead of manual dep iteration — the Python helper reads one flag
    per line and merges them into CFLAGS, LDFLAGS, PKG_CONFIG_PATH, PATH.
    """
    output = ctx.actions.declare_output("configured", dir = True)
    cmd = cmd_args(ctx.attrs._configure_tool[RunInfo])
    cmd.add("--source-dir", source)
    cmd.add("--output-dir", output.as_output())

    # Inject toolchain CC/CXX/AR
    for env_arg in toolchain_env_args(ctx):
        cmd.add("--env", env_arg)

    # Hermetic PATH from seed toolchain
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)

    # Inject user-specified environment variables
    for key, value in ctx.attrs.env.items():
        cmd.add("--env", "{}={}".format(key, value))

    if ctx.attrs.configure_script:
        cmd.add("--configure-script", ctx.attrs.configure_script)

    # Pre-configure commands (run before ./configure in the source tree)
    for pre_cmd in ctx.attrs.pre_configure_cmds:
        cmd.add("--pre-cmd", pre_cmd)

    # Add host_deps bin dirs to PATH (build tools like cmake, m4, etc.)
    for arg in host_tool_path_args(ctx):
        cmd.add(arg)

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

        # --with-NAME=<prefix>/usr and --with-NAME-lib=<prefix>/usr/lib64
        # flags from configure_prefix_deps.
        # GCC needs both: --with-gmp for headers, --with-gmp-lib for the
        # library directory (defaults to <prefix>/lib which misses lib64).
        for flag_name, dep in ctx.attrs.configure_prefix_deps.items():
            if PackageInfo in dep:
                prefix = dep[PackageInfo].prefix
            else:
                prefix = dep[DefaultInfo].default_outputs[0]
            fmt = "--with-" + flag_name + "={}/usr"
            cmd.add(cmd_args("--configure-arg=", cmd_args(prefix, format = fmt), delimiter = ""))
            fmt_lib = "--with-" + flag_name + "-lib={}/usr/lib64"
            cmd.add(cmd_args("--configure-arg=", cmd_args(prefix, format = fmt_lib), delimiter = ""))

        # Dep flags via tset projection files (replaces manual dep iteration).
        # The helper reads flags from files and applies to CFLAGS, CPPFLAGS,
        # CXXFLAGS, LDFLAGS, PKG_CONFIG_PATH, and PATH.
        add_flag_file(cmd, "--cflags-file", cflags_file)
        add_flag_file(cmd, "--ldflags-file", ldflags_file)
        add_flag_file(cmd, "--pkg-config-file", pkg_config_file)
        add_flag_file(cmd, "--path-file", path_file)

    # Ensure dep artifacts are materialized — tset flag files reference
    # dep prefixes but don't register them as action inputs.
    for dep in ctx.attrs.deps:
        cmd.add(cmd_args(hidden = dep[DefaultInfo].default_outputs))

    ctx.actions.run(cmd, category = "configure", identifier = ctx.attrs.name)
    return output

def _src_compile(ctx, configured, cflags_file = None, ldflags_file = None,
                 pkg_config_file = None, path_file = None, lib_dirs_file = None):
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

    # Hermetic PATH from seed toolchain
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)

    # Toolchain-injected CFLAGS / LDFLAGS for build phase
    _tc_cflags = list(toolchain_extra_cflags(ctx)) + list(ctx.attrs.extra_cflags)
    _tc_ldflags = list(toolchain_extra_ldflags(ctx)) + list(ctx.attrs.extra_ldflags)
    if _tc_cflags:
        cmd.add("--env", cmd_args("CFLAGS=", cmd_args(_tc_cflags, delimiter = " "), delimiter = ""))
    if _tc_ldflags:
        cmd.add("--env", cmd_args("LDFLAGS=", cmd_args(_tc_ldflags, delimiter = " "), delimiter = ""))

    # Dep flags via tset projection files
    add_flag_file(cmd, "--cflags-file", cflags_file)
    add_flag_file(cmd, "--ldflags-file", ldflags_file)
    add_flag_file(cmd, "--pkg-config-file", pkg_config_file)
    add_flag_file(cmd, "--path-file", path_file)
    add_flag_file(cmd, "--lib-dirs-file", lib_dirs_file)

    # Add host_deps bin dirs to PATH
    for arg in host_tool_path_args(ctx):
        cmd.add(arg)

    # Inject user-specified environment variables
    for key, value in ctx.attrs.env.items():
        cmd.add("--env", "{}={}".format(key, value))

    # Suppress autotools regeneration — build_helper.py resets all timestamps
    # to epoch, so make thinks generated files (configure, Makefile.in) are stale.
    # Override the autotools tool variables so make uses `true` (no-op) instead
    # of trying to run aclocal/automake/autoconf which may not be available.
    for var in ["ACLOCAL=true", "AUTOMAKE=true", "AUTOCONF=true", "AUTOHEADER=true", "MAKEINFO=true"]:
        cmd.add(cmd_args("--make-arg=", var, delimiter = ""))
    for pre_cmd in ctx.attrs.pre_build_cmds:
        cmd.add("--pre-cmd", pre_cmd)
    for arg in ctx.attrs.make_args:
        cmd.add(cmd_args("--make-arg=", arg, delimiter = ""))

    # Ensure dep artifacts are materialized — tset flag files reference
    # dep prefixes but don't register them as action inputs.
    for dep in ctx.attrs.deps:
        cmd.add(cmd_args(hidden = dep[DefaultInfo].default_outputs))

    ctx.actions.run(cmd, category = "compile", identifier = ctx.attrs.name)
    return output

def _src_install(ctx, built, cflags_file = None, ldflags_file = None,
                 pkg_config_file = None, path_file = None, lib_dirs_file = None):
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

    # Hermetic PATH from seed toolchain
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)

    # Toolchain-injected CFLAGS / LDFLAGS for install phase
    _tc_cflags = list(toolchain_extra_cflags(ctx)) + list(ctx.attrs.extra_cflags)
    _tc_ldflags = list(toolchain_extra_ldflags(ctx)) + list(ctx.attrs.extra_ldflags)
    if _tc_cflags:
        cmd.add("--env", cmd_args("CFLAGS=", cmd_args(_tc_cflags, delimiter = " "), delimiter = ""))
    if _tc_ldflags:
        cmd.add("--env", cmd_args("LDFLAGS=", cmd_args(_tc_ldflags, delimiter = " "), delimiter = ""))

    # Dep flags via tset projection files
    add_flag_file(cmd, "--cflags-file", cflags_file)
    add_flag_file(cmd, "--ldflags-file", ldflags_file)
    add_flag_file(cmd, "--pkg-config-file", pkg_config_file)
    add_flag_file(cmd, "--path-file", path_file)
    add_flag_file(cmd, "--lib-dirs-file", lib_dirs_file)

    # Add host_deps bin dirs to PATH
    for arg in host_tool_path_args(ctx):
        cmd.add(arg)

    # Inject user-specified environment variables
    for key, value in ctx.attrs.env.items():
        cmd.add("--env", "{}={}".format(key, value))

    if ctx.attrs.install_prefix_var:
        cmd.add("--destdir-var", ctx.attrs.install_prefix_var)
    # Override install targets when explicit ordering is needed (e.g.
    # e2fsprogs: install-shlibs must finish before install-progs).
    for target in ctx.attrs.install_targets:
        cmd.add("--make-target", target)
    # Suppress autotools regeneration during install (same as compile phase)
    for var in ["ACLOCAL=true", "AUTOMAKE=true", "AUTOCONF=true", "AUTOHEADER=true", "MAKEINFO=true"]:
        cmd.add(cmd_args("--make-arg=", var, delimiter = ""))
    for arg in ctx.attrs.make_args:
        cmd.add(cmd_args("--make-arg=", arg, delimiter = ""))
    for arg in ctx.attrs.install_args:
        cmd.add(cmd_args("--make-arg=", arg, delimiter = ""))

    # Post-install commands (run in the prefix dir after make install)
    for post_cmd in ctx.attrs.post_install_cmds:
        cmd.add("--post-cmd", post_cmd)

    # Ensure dep artifacts are materialized — tset flag files reference
    # dep prefixes but don't register them as action inputs.
    for dep in ctx.attrs.deps:
        cmd.add(cmd_args(hidden = dep[DefaultInfo].default_outputs))

    ctx.actions.run(cmd, category = "install", identifier = ctx.attrs.name)
    return output

# ── Rule implementation ───────────────────────────────────────────────

def _autotools_package_impl(ctx):
    # Phase 1: src_unpack — obtain source from dep
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]

    # Phase 2: src_prepare — apply patches
    prepared = _src_prepare(ctx, source)

    # Collect dep-only tsets and write flag files for build phases.
    # These contain transitive dep flags (includes, libs, pkgconfig, bins)
    # that replace the old manual dep iteration loops.
    dep_compile, dep_link, dep_path = collect_dep_tsets(ctx)
    cflags_file = write_compile_flags(ctx, dep_compile)
    ldflags_file = write_link_flags(ctx, dep_link)
    pkg_config_file = write_pkg_config_paths(ctx, dep_compile)
    path_file = write_bin_dirs(ctx, dep_path)
    lib_dirs_file = write_lib_dirs(ctx, dep_path) if dep_path else None

    # Phase 3: src_configure
    configured = _src_configure(ctx, prepared, cflags_file, ldflags_file,
                                pkg_config_file, path_file)

    # Phase 4: src_compile
    built = _src_compile(ctx, configured, cflags_file, ldflags_file,
                         pkg_config_file, path_file, lib_dirs_file)

    # Phase 5: src_install
    installed = _src_install(ctx, built, cflags_file, ldflags_file,
                             pkg_config_file, path_file, lib_dirs_file)

    # Build transitive sets
    compile_tset, link_tset, path_tset, runtime_tset = build_package_tsets(ctx, installed)

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
        runtime_lib_dirs = collect_runtime_lib_dirs(ctx.attrs.deps, installed),
        pkg_config_path = None,
        cflags = ctx.attrs.extra_cflags,
        ldflags = ctx.attrs.extra_ldflags,
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

autotools_package = rule(
    impl = _autotools_package_impl,
    attrs = {
        # Source and identity
        "source": attrs.dep(),
        "version": attrs.string(),

        # Build configuration
        "configure_args": attrs.list(attrs.string(), default = []),
        "configure_prefix_deps": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        "configure_script": attrs.option(attrs.string(), default = None),
        "skip_configure": attrs.bool(default = False),
        "pre_configure_cmds": attrs.list(attrs.string(), default = []),
        "pre_build_cmds": attrs.list(attrs.string(), default = []),
        "post_install_cmds": attrs.list(attrs.string(), default = []),
        "make_args": attrs.list(attrs.string(), default = []),
        "install_args": attrs.list(attrs.string(), default = []),
        "install_targets": attrs.list(attrs.string(), default = []),
        "install_prefix_var": attrs.option(attrs.string(), default = None),
        "env": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "deps": attrs.list(attrs.dep(), default = []),
        "host_deps": attrs.list(attrs.exec_dep(), default = []),
        "runtime_deps": attrs.list(attrs.dep(), default = []),
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
