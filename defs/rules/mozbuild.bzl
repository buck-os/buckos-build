"""
mozbuild_package rule: multi-phase Firefox/mach build with discrete caching.

Five cacheable actions:

1. src_unpack    — obtain source from source dep (shared with all rules)
2. src_prepare   — apply patches + pre_configure_cmds
3. configure     — ./mach configure (isolated MOZBUILD_STATE_PATH)
4. build         — ./mach build (with pre-warmed cargo deps from cache)
5. install       — DESTDIR=$OUT ./mach install
"""

load("//defs:providers.bzl", "PackageInfo")
load("//defs/rules:_common.bzl", "COMMON_PACKAGE_ATTRS", "build_package_tsets")
load("//defs:toolchain_helpers.bzl", "toolchain_path_args")
load("//defs:host_tools.bzl", "host_tool_path_args")

# ── Phase helpers ─────────────────────────────────────────────────────

def _src_prepare(ctx, source):
    """Apply patches and pre_configure_cmds."""
    if not ctx.attrs.patches and not ctx.attrs.pre_configure_cmds:
        return source

    output = ctx.actions.declare_output("prepared", dir = True)
    cmd = cmd_args(ctx.attrs._patch_tool[RunInfo])
    cmd.add("--source-dir", source)
    cmd.add("--output-dir", output.as_output())
    for p in ctx.attrs.patches:
        cmd.add("--patch", p)
    for c in ctx.attrs.pre_configure_cmds:
        cmd.add("--cmd", c)

    env = {}
    dep_base_dirs = []
    for dep in ctx.attrs.deps:
        if PackageInfo in dep:
            dep_base_dirs.append(dep[PackageInfo].prefix)
        else:
            dep_base_dirs.append(dep[DefaultInfo].default_outputs[0])
    if dep_base_dirs:
        env["DEP_BASE_DIRS"] = cmd_args(dep_base_dirs, delimiter = ":")

    ctx.actions.run(cmd, env = env, category = "mozbuild_prepare", identifier = ctx.attrs.name, allow_cache_upload = True)
    return output


def _dep_base_dirs_args(ctx):
    """Collect dep base dirs as colon-separated cmd_args."""
    dirs = []
    for dep in ctx.attrs.deps:
        if PackageInfo in dep:
            dirs.append(dep[PackageInfo].prefix)
        else:
            dirs.append(dep[DefaultInfo].default_outputs[0])
    return cmd_args(dirs, delimiter = ":") if dirs else None


def _pkg_config_paths(ctx):
    """Collect PKG_CONFIG_PATH entries from deps."""
    paths = []
    for dep in ctx.attrs.deps:
        if PackageInfo in dep:
            prefix = dep[PackageInfo].prefix
        else:
            prefix = dep[DefaultInfo].default_outputs[0]
        paths.append(cmd_args(prefix, format = "{}/usr/lib64/pkgconfig"))
        paths.append(cmd_args(prefix, format = "{}/usr/lib/pkgconfig"))
        paths.append(cmd_args(prefix, format = "{}/usr/share/pkgconfig"))
    return cmd_args(paths, delimiter = ":") if paths else None


def _dep_bin_paths(ctx):
    """Collect bin paths from deps."""
    paths = []
    for dep in ctx.attrs.deps:
        if PackageInfo in dep:
            prefix = dep[PackageInfo].prefix
        else:
            prefix = dep[DefaultInfo].default_outputs[0]
        paths.append(cmd_args(prefix, format = "{}/usr/bin"))
        paths.append(cmd_args(prefix, format = "{}/usr/sbin"))
    return cmd_args(paths, delimiter = ":") if paths else None


def _dep_lib_paths(ctx):
    """Collect library paths from deps for LD_LIBRARY_PATH."""
    paths = []
    for dep in ctx.attrs.deps:
        if PackageInfo in dep:
            prefix = dep[PackageInfo].prefix
        else:
            prefix = dep[DefaultInfo].default_outputs[0]
        paths.append(cmd_args(prefix, format = "{}/usr/lib64"))
        paths.append(cmd_args(prefix, format = "{}/usr/lib"))
    return cmd_args(paths, delimiter = ":") if paths else None


def _common_env(ctx):
    """Build common environment for mozbuild phases."""
    env = {}

    dep_dirs = _dep_base_dirs_args(ctx)
    if dep_dirs:
        env["DEP_BASE_DIRS"] = dep_dirs

    pc_paths = _pkg_config_paths(ctx)
    if pc_paths:
        env["PKG_CONFIG_PATH"] = pc_paths

    bin_paths = _dep_bin_paths(ctx)
    if bin_paths:
        env["_DEP_BIN_PATHS"] = bin_paths

    # Don't set LD_LIBRARY_PATH — it poisons system Python's shared libs
    # (e.g. pyexpat loads our older expat instead of system's).
    # mach handles library paths internally via pkg-config.

    return env


def _configure(ctx, source):
    """Phase: ./mach configure."""
    output = ctx.actions.declare_output("configured", dir = True)
    cmd = cmd_args(ctx.attrs._mozbuild_tool[RunInfo])
    cmd.add("--phase", "configure")
    cmd.add("--source-dir", source)
    cmd.add("--output-dir", output.as_output())
    for opt in ctx.attrs.mozconfig_options:
        cmd.add(cmd_args("--mozconfig-option=", opt, delimiter = ""))

    env = _common_env(ctx)

    # Pass dep base dirs for the helper to build pkg-config paths
    dep_dirs = _dep_base_dirs_args(ctx)
    if dep_dirs:
        cmd.add(cmd_args("--dep-base-dirs=", dep_dirs, delimiter = ""))

    # Hermetic PATH from toolchain
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)

    # Add host_deps bin dirs to PATH
    for arg in host_tool_path_args(ctx):
        cmd.add(arg)

    ctx.actions.run(cmd, env = env, category = "mozbuild_configure", identifier = ctx.attrs.name, allow_cache_upload = True)
    return output


def _build(ctx, source, configured):
    """Phase: ./mach build (configure + compile in one action).

    Combines configure + rust + C++ into a single build phase for
    simplicity.  The key isolation wins (MOZBUILD_STATE_PATH, pkg-config
    --define-prefix) are handled by the Python helper.
    """
    output = ctx.actions.declare_output("built", dir = True)
    cmd = cmd_args(ctx.attrs._mozbuild_tool[RunInfo])
    cmd.add("--phase", "build")
    cmd.add("--source-dir", source)
    cmd.add("--configured-dir", configured)
    cmd.add("--output-dir", output.as_output())
    for opt in ctx.attrs.mozconfig_options:
        cmd.add(cmd_args("--mozconfig-option=", opt, delimiter = ""))

    env = _common_env(ctx)

    dep_dirs = _dep_base_dirs_args(ctx)
    if dep_dirs:
        cmd.add(cmd_args("--dep-base-dirs=", dep_dirs, delimiter = ""))

    # Hermetic PATH from toolchain
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)

    # Add host_deps bin dirs to PATH
    for arg in host_tool_path_args(ctx):
        cmd.add(arg)

    ctx.actions.run(cmd, env = env, category = "mozbuild_build", identifier = ctx.attrs.name, allow_cache_upload = True)
    return output


def _install(ctx, source, built):
    """Phase: DESTDIR=$OUT ./mach install."""
    output = ctx.actions.declare_output("installed", dir = True)
    cmd = cmd_args(ctx.attrs._mozbuild_tool[RunInfo])
    cmd.add("--phase", "install")
    cmd.add("--source-dir", source)
    cmd.add("--built-dir", built)
    cmd.add("--output-dir", output.as_output())
    for opt in ctx.attrs.mozconfig_options:
        cmd.add(cmd_args("--mozconfig-option=", opt, delimiter = ""))

    env = _common_env(ctx)

    dep_dirs = _dep_base_dirs_args(ctx)
    if dep_dirs:
        cmd.add(cmd_args("--dep-base-dirs=", dep_dirs, delimiter = ""))

    # Hermetic PATH from toolchain
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)

    # Add host_deps bin dirs to PATH
    for arg in host_tool_path_args(ctx):
        cmd.add(arg)

    ctx.actions.run(cmd, env = env, category = "mozbuild_install", identifier = ctx.attrs.name, allow_cache_upload = True)
    return output


# ── Rule implementation ───────────────────────────────────────────────

def _mozbuild_package_impl(ctx):
    # Phase 1: src_unpack
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]

    # Phase 2: src_prepare
    prepared = _src_prepare(ctx, source)

    # Phase 3: configure
    configured = _configure(ctx, prepared)

    # Phase 4: build
    built = _build(ctx, prepared, configured)

    # Phase 5: install
    installed = _install(ctx, prepared, built)

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

mozbuild_package = rule(
    impl = _mozbuild_package_impl,
    attrs = COMMON_PACKAGE_ATTRS | {
        # Mozbuild-specific
        "mozconfig_options": attrs.list(attrs.string(), default = []),
        "install_script": attrs.string(default = ""),
        "_mozbuild_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:mozbuild_helper"),
        ),
    },
)
