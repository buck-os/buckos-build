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
load("//defs/rules:_common.bzl",
     "COMMON_PACKAGE_ATTRS",
     "add_flag_file", "build_package_tsets", "collect_dep_tsets",
     "src_prepare",
     "write_bin_dirs", "write_compile_flags", "write_lib_dirs",
     "write_link_flags", "write_pkg_config_paths",
)
load("//defs:toolchain_helpers.bzl", "toolchain_env_args", "toolchain_extra_cflags", "toolchain_extra_ldflags", "toolchain_path_args")
load("//defs:host_tools.bzl", "host_tool_path_args")

# ── Phase helpers ─────────────────────────────────────────────────────

def _meson_setup(ctx, source, cflags_file = None, ldflags_file = None,
                 pkg_config_file = None, path_file = None):
    """Run meson setup with toolchain env and dep flags.

    Dep flags are propagated via tset projection files — the meson_helper
    reads them and merges into CFLAGS, LDFLAGS, PKG_CONFIG_PATH, and PATH.
    """
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

    # Hermetic PATH from seed toolchain
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)

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

    # Toolchain and per-package CFLAGS / LDFLAGS.
    # These are merged with dep tset flags by the meson_helper.
    # Note: dep libraries (-l flags) are NOT passed — meson discovers
    # them via pkg-config.  Putting -l flags in LDFLAGS breaks meson's
    # C compiler sanity check (test binaries can't find .so files at runtime).
    cflags = list(toolchain_extra_cflags(ctx)) + list(ctx.attrs.extra_cflags)
    ldflags = list(toolchain_extra_ldflags(ctx)) + list(ctx.attrs.extra_ldflags)
    if cflags:
        cmd.add("--env", cmd_args("CFLAGS=", cmd_args(cflags, delimiter = " "), delimiter = ""))
    if ldflags:
        cmd.add("--env", cmd_args("LDFLAGS=", cmd_args(ldflags, delimiter = " "), delimiter = ""))

    # Dep flags via tset projection files
    add_flag_file(cmd, "--cflags-file", cflags_file)
    add_flag_file(cmd, "--ldflags-file", ldflags_file)
    add_flag_file(cmd, "--pkg-config-file", pkg_config_file)
    add_flag_file(cmd, "--path-file", path_file)

    # Add host_deps bin dirs to PATH
    for arg in host_tool_path_args(ctx):
        cmd.add(arg)

    # Configure arguments from the common interface
    for arg in ctx.attrs.configure_args:
        cmd.add(cmd_args("--meson-arg=", arg, delimiter = ""))

    ctx.actions.run(cmd, category = "meson_configure", identifier = ctx.attrs.name, allow_cache_upload = True)
    return output

def _src_compile(ctx, configured, source, path_file = None, lib_dirs_file = None):
    """Run ninja in the meson build tree."""
    output = ctx.actions.declare_output("built", dir = True)
    cmd = cmd_args(ctx.attrs._build_tool[RunInfo])
    cmd.add("--build-dir", configured)
    cmd.add("--output-dir", output.as_output())
    cmd.add("--build-system", "ninja")

    # Ensure source dir is available — meson out-of-tree builds
    # reference source files by absolute path in build.ninja.
    # Dep prefixes are materialised via tset projections (path_file,
    # lib_dirs_file) passed to add_flag_file below.
    cmd.add(cmd_args(hidden = source))

    # Inject toolchain CC/CXX/AR
    for env_arg in toolchain_env_args(ctx):
        cmd.add("--env", env_arg)

    # Hermetic PATH from seed toolchain
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)

    # Inject user-specified environment variables
    for key, value in ctx.attrs.env.items():
        cmd.add("--env", "{}={}".format(key, value))

    # Dep bin dirs and lib dirs via tset projection files.
    # Build tools (moc, rcc, wayland-scanner, etc.) need shared libs
    # and executables from deps at runtime.
    add_flag_file(cmd, "--path-file", path_file)
    add_flag_file(cmd, "--lib-dirs-file", lib_dirs_file)

    # Add host_deps bin dirs to PATH
    for arg in host_tool_path_args(ctx):
        cmd.add(arg)

    for arg in ctx.attrs.make_args:
        cmd.add("--make-arg", arg)

    ctx.actions.run(cmd, category = "meson_compile", identifier = ctx.attrs.name, allow_cache_upload = True)
    return output

def _src_install(ctx, built, source, path_file = None, lib_dirs_file = None):
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

    # Hermetic PATH from seed toolchain
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)

    # Inject user-specified environment variables
    for key, value in ctx.attrs.env.items():
        cmd.add("--env", "{}={}".format(key, value))

    # Dep bin/lib dirs — install rules may run tools or need shared libs
    add_flag_file(cmd, "--path-file", path_file)
    add_flag_file(cmd, "--lib-dirs-file", lib_dirs_file)

    # Add host_deps bin dirs to PATH
    for arg in host_tool_path_args(ctx):
        cmd.add(arg)

    for arg in ctx.attrs.make_args:
        cmd.add("--make-arg", arg)

    # Post-install commands (run in the prefix dir after install)
    for post_cmd in ctx.attrs.post_install_cmds:
        cmd.add("--post-cmd", post_cmd)

    ctx.actions.run(cmd, category = "meson_install", identifier = ctx.attrs.name, allow_cache_upload = True)
    return output

# ── Rule implementation ───────────────────────────────────────────────

def _meson_package_impl(ctx):
    # Phase 1: src_unpack — obtain source from dep
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]

    # Phase 2: src_prepare — apply patches
    prepared = src_prepare(ctx, source, "meson_prepare")

    # Collect dep-only tsets and write flag files for build phases
    dep_compile, dep_link, dep_path = collect_dep_tsets(ctx)
    cflags_file = write_compile_flags(ctx, dep_compile)
    ldflags_file = write_link_flags(ctx, dep_link)
    pkg_config_file = write_pkg_config_paths(ctx, dep_compile)
    path_file = write_bin_dirs(ctx, dep_path)
    lib_dirs_file = write_lib_dirs(ctx, dep_path) if dep_path else None

    # Phase 3: meson_setup
    configured = _meson_setup(ctx, prepared, cflags_file, ldflags_file,
                              pkg_config_file, path_file)

    # Phase 4: src_compile (source passed as hidden input for out-of-tree builds)
    built = _src_compile(ctx, configured, prepared, path_file, lib_dirs_file)

    # Phase 5: src_install
    installed = _src_install(ctx, built, prepared, path_file, lib_dirs_file)

    # Build transitive sets
    compile_tset, link_tset, path_tset, runtime_tset = build_package_tsets(ctx, installed)

    pkg_info = PackageInfo(
        name = ctx.attrs.name,
        version = ctx.attrs.version,
        prefix = installed,
        libraries = ctx.attrs.libraries,
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

meson_package = rule(
    impl = _meson_package_impl,
    attrs = COMMON_PACKAGE_ATTRS | {
        # Meson-specific
        "meson_args": attrs.list(attrs.string(), default = []),
        "meson_defines": attrs.list(attrs.string(), default = []),
        "source_subdir": attrs.string(default = ""),
        "make_args": attrs.list(attrs.string(), default = []),
        "_meson_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:meson_helper"),
        ),
        "_build_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:build_helper"),
        ),
        "_install_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:install_helper"),
        ),
    },
)
