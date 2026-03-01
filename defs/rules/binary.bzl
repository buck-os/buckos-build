"""
binary_package rule: custom install script for pre-built packages.

Four discrete cacheable actions:

1. src_unpack   — obtain source artifact from source dep
2. src_prepare  — apply patches + pre_configure_cmds (zero-cost passthrough when none)
3. install      — run install_script in a shell with $SRC and $OUT set
"""

load("//defs:providers.bzl", "BuildToolchainInfo", "PackageInfo")
load("//defs/rules:_common.bzl", "COMMON_PACKAGE_ATTRS", "build_package_tsets")
load("//defs:toolchain_helpers.bzl",
     "toolchain_extra_cflags", "toolchain_extra_ldflags")
load("//defs:host_tools.bzl", "host_tool_env_paths")

# ── Phase helpers ─────────────────────────────────────────────────────

def _src_prepare(ctx, source):
    """Apply patches and pre_configure_cmds.

    Separate action so unpatched source stays cached.
    Uses patch_helper.py which copies source first (no artifact corruption).
    """
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

    # Pass dep base dirs so pre_configure_cmds can locate dep sources
    env = {}
    dep_base_dirs = []
    for dep in ctx.attrs.deps:
        if PackageInfo in dep:
            dep_base_dirs.append(dep[PackageInfo].prefix)
        else:
            dep_base_dirs.append(dep[DefaultInfo].default_outputs[0])
    if dep_base_dirs:
        env["DEP_BASE_DIRS"] = cmd_args(dep_base_dirs, delimiter = ":")

    ctx.actions.run(cmd, env = env, category = "binary_prepare", identifier = ctx.attrs.name, allow_cache_upload = True)
    return output

def _dep_env_args(ctx):
    """Build environment variables and PATH dirs from deps.

    Returns (env dict entries, dep_bin_paths list).
    Models on autotools' _dep_env_args() for consistent dep propagation.
    """
    pkg_config_paths = []
    path_dirs = []
    lib_dirs = []
    dep_base_dirs = []
    cflags = list(toolchain_extra_cflags(ctx)) + list(ctx.attrs.extra_cflags)
    ldflags = list(toolchain_extra_ldflags(ctx)) + list(ctx.attrs.extra_ldflags)

    for dep in ctx.attrs.deps:
        if PackageInfo in dep:
            prefix = dep[PackageInfo].prefix
            for f in dep[PackageInfo].cflags:
                cflags.append(f)
            for f in dep[PackageInfo].ldflags:
                ldflags.append(f)
        else:
            prefix = dep[DefaultInfo].default_outputs[0]
        dep_base_dirs.append(prefix)
        cflags.append(cmd_args(prefix, format = "-I{}/usr/include"))
        ldflags.append(cmd_args(prefix, format = "-L{}/usr/lib64"))
        ldflags.append(cmd_args(prefix, format = "-L{}/usr/lib"))
        lib_dirs.append(cmd_args(prefix, format = "{}/usr/lib64"))
        lib_dirs.append(cmd_args(prefix, format = "{}/usr/lib"))
        ldflags.append(cmd_args(prefix, format = "-Wl,-rpath-link,{}/usr/lib64"))
        ldflags.append(cmd_args(prefix, format = "-Wl,-rpath-link,{}/usr/lib"))
        pkg_config_paths.append(cmd_args(prefix, format = "{}/usr/lib64/pkgconfig"))
        pkg_config_paths.append(cmd_args(prefix, format = "{}/usr/lib/pkgconfig"))
        pkg_config_paths.append(cmd_args(prefix, format = "{}/usr/share/pkgconfig"))
        path_dirs.append(cmd_args(prefix, format = "{}/usr/bin"))
        path_dirs.append(cmd_args(prefix, format = "{}/usr/sbin"))
        # Bootstrap packages use /tools prefix
        cflags.append(cmd_args(prefix, format = "-I{}/tools/include"))
        ldflags.append(cmd_args(prefix, format = "-L{}/tools/lib64"))
        ldflags.append(cmd_args(prefix, format = "-L{}/tools/lib"))
        lib_dirs.append(cmd_args(prefix, format = "{}/tools/lib64"))
        lib_dirs.append(cmd_args(prefix, format = "{}/tools/lib"))
        ldflags.append(cmd_args(prefix, format = "-Wl,-rpath-link,{}/tools/lib64"))
        ldflags.append(cmd_args(prefix, format = "-Wl,-rpath-link,{}/tools/lib"))

        pkg_config_paths.append(cmd_args(prefix, format = "{}/tools/lib64/pkgconfig"))
        pkg_config_paths.append(cmd_args(prefix, format = "{}/tools/lib/pkgconfig"))
        path_dirs.append(cmd_args(prefix, format = "{}/tools/bin"))
        path_dirs.append(cmd_args(prefix, format = "{}/tools/sbin"))

    env = {}
    if pkg_config_paths:
        env["PKG_CONFIG_PATH"] = cmd_args(pkg_config_paths, delimiter = ":")
    if cflags:
        env["CFLAGS"] = cmd_args(cflags, delimiter = " ")
    if ldflags:
        env["LDFLAGS"] = cmd_args(ldflags, delimiter = " ")
    if dep_base_dirs:
        env["DEP_BASE_DIRS"] = cmd_args(dep_base_dirs, delimiter = ":")
    if lib_dirs:
        # Use an underscore-prefixed name so the dynamic linker of the
        # host Python process doesn't load target libraries (e.g. buckos
        # glibc).  binary_install_helper translates this to LD_LIBRARY_PATH
        # only for the install subprocess.
        env["_DEP_LD_LIBRARY_PATH"] = cmd_args(lib_dirs, delimiter = ":")

    return env, path_dirs

def _install(ctx, source):
    """Run install_script with SRC pointing to source and OUT to output prefix."""
    output = ctx.actions.declare_output("installed", dir = True)

    script = ctx.actions.write("install.sh", ctx.attrs.install_script, is_executable = True)

    cmd = cmd_args(ctx.attrs._binary_install_tool[RunInfo])
    cmd.add(source, output.as_output(), ctx.attrs.version, script)

    env = {}

    # Inject toolchain CC/CXX/AR directly from BuildToolchainInfo
    tc = ctx.attrs._toolchain[BuildToolchainInfo]
    env["CC"] = cmd_args(tc.cc.args, delimiter = " ")
    env["CXX"] = cmd_args(tc.cxx.args, delimiter = " ")
    env["AR"] = cmd_args(tc.ar.args, delimiter = " ")

    # Hermetic PATH from toolchain (replaces host PATH in wrapper)
    if tc.host_bin_dir:
        env["_HERMETIC_PATH"] = cmd_args(tc.host_bin_dir)
    elif tc.allows_host_path:
        env["_ALLOW_HOST_PATH"] = "1"
    else:
        env["_HERMETIC_EMPTY"] = "1"


    # Inject dep environment (CFLAGS, LDFLAGS, PKG_CONFIG_PATH, PATH)
    dep_env, dep_paths = _dep_env_args(ctx)
    for key, value in dep_env.items():
        env[key] = value

    # Add host_deps bin dirs to dep paths
    dep_paths.extend(host_tool_env_paths(ctx))

    if dep_paths:
        env["_DEP_BIN_PATHS"] = cmd_args(dep_paths, delimiter = ":")

    # Inject user-specified environment variables (last — overrides everything)
    for key, value in ctx.attrs.env.items():
        env[key] = value

    ctx.actions.run(
        cmd,
        env = env,
        category = "binary_install",
        identifier = ctx.attrs.name,
        allow_cache_upload = True,
    )
    return output

# ── Rule implementation ───────────────────────────────────────────────

def _binary_package_impl(ctx):
    # Phase 1: src_unpack — obtain source from dep
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]

    # Phase 2: src_prepare — apply patches + pre_configure_cmds
    prepared = _src_prepare(ctx, source)

    # Phase 3: install
    installed = _install(ctx, prepared)

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

binary_package = rule(
    impl = _binary_package_impl,
    attrs = COMMON_PACKAGE_ATTRS | {
        # Binary-specific
        "install_script": attrs.string(default = "cp -a \"$SRCS\"/. \"$OUT/\""),
        "_binary_install_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:binary_install_helper"),
        ),
    },
)
