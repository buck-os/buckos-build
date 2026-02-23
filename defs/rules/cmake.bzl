"""
cmake_package rule: cmake -S . -B build && ninja && ninja install.

Five discrete cacheable actions — Buck2 can skip any phase whose
inputs haven't changed.

1. src_unpack  — obtain source artifact from source dep
2. src_prepare — apply patches (zero-cost passthrough when no patches)
3. cmake_configure — run cmake via cmake_helper.py
4. src_compile — run ninja via build_helper.py
5. src_install — run ninja install via install_helper.py
   (post_install_cmds run in the prefix dir after install)
"""

load("//defs:providers.bzl", "PackageInfo")
load("//defs/rules:_common.bzl", "collect_runtime_lib_dirs")
load("//defs:toolchain_helpers.bzl", "TOOLCHAIN_ATTRS", "toolchain_env_args", "toolchain_extra_cflags", "toolchain_extra_ldflags", "toolchain_path_args")

# ── Phase helpers ─────────────────────────────────────────────────────

def _src_prepare(ctx, source):
    """Apply patches and pre-configure commands.  Separate action so unpatched source stays cached."""
    if not ctx.attrs.patches and not ctx.attrs.pre_configure_cmds:
        return source  # Nothing to do — zero-cost passthrough

    output = ctx.actions.declare_output("prepared", dir = True)
    cmd = cmd_args(ctx.attrs._patch_tool[RunInfo])
    cmd.add("--source-dir", source)
    cmd.add("--output-dir", output.as_output())
    for p in ctx.attrs.patches:
        cmd.add("--patch", p)
    for c in ctx.attrs.pre_configure_cmds:
        cmd.add("--cmd", c)

    ctx.actions.run(cmd, category = "prepare", identifier = ctx.attrs.name)
    return output

def _cmake_configure(ctx, source):
    """Run cmake configure with toolchain env and dep flags."""
    output = ctx.actions.declare_output("configured", dir = True)
    cmd = cmd_args(ctx.attrs._cmake_tool[RunInfo])
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

    # Source subdirectory (e.g. LLVM has CMakeLists.txt in llvm/)
    if ctx.attrs.source_subdir:
        cmd.add("--source-subdir", ctx.attrs.source_subdir)

    # CMake arguments (use = form so argparse doesn't treat -D... as a flag)
    for arg in ctx.attrs.cmake_args:
        cmd.add(cmd_args("--cmake-arg=", arg, delimiter = ""))

    # CMake defines (KEY=VALUE strings)
    for define in ctx.attrs.cmake_defines:
        cmd.add(cmd_args("--cmake-define=", define, delimiter = ""))

    # Extra CFLAGS / LDFLAGS — pass as CMAKE_C_FLAGS / CMAKE_EXE_LINKER_FLAGS
    cflags = list(toolchain_extra_cflags(ctx)) + list(ctx.attrs.extra_cflags)
    ldflags = list(toolchain_extra_ldflags(ctx)) + list(ctx.attrs.extra_ldflags)

    # Propagate flags, pkg-config paths, and cmake prefix paths from dependencies
    pkg_config_paths = []
    lib_paths = []
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
        ldflags.append(cmd_args(prefix, format = "-Wl,-rpath-link,{}/usr/lib64"))
        ldflags.append(cmd_args(prefix, format = "-Wl,-rpath-link,{}/usr/lib"))
        pkg_config_paths.append(cmd_args(prefix, format = "{}/usr/lib64/pkgconfig"))
        pkg_config_paths.append(cmd_args(prefix, format = "{}/usr/lib/pkgconfig"))
        pkg_config_paths.append(cmd_args(prefix, format = "{}/usr/share/pkgconfig"))

        # Add dep prefix to CMAKE_PREFIX_PATH for find_package()
        cmd.add("--prefix-path", cmd_args(prefix, format = "{}/usr"))
        # Add dep bin dirs to PATH so cmake can run dep tools (qtpaths, etc.)
        cmd.add("--path-prepend", cmd_args(prefix, format = "{}/usr/bin"))
        # Collect lib paths for LD_LIBRARY_PATH (dep tools need shared libs)
        lib_paths.append(cmd_args(prefix, format = "{}/usr/lib64"))
        lib_paths.append(cmd_args(prefix, format = "{}/usr/lib"))

    if lib_paths:
        cmd.add("--env", cmd_args("LD_LIBRARY_PATH=", cmd_args(lib_paths, delimiter = ":"), delimiter = ""))
    if cflags:
        _cf = cmd_args(cflags, delimiter = " ")
        cmd.add(cmd_args("--cmake-define=", "CMAKE_C_FLAGS=", _cf, delimiter = ""))
        cmd.add(cmd_args("--cmake-define=", "CMAKE_CXX_FLAGS=", _cf, delimiter = ""))
    if ldflags:
        _ld = cmd_args(ldflags, delimiter = " ")
        cmd.add(cmd_args("--cmake-define=", "CMAKE_EXE_LINKER_FLAGS=", _ld, delimiter = ""))
        cmd.add(cmd_args("--cmake-define=", "CMAKE_SHARED_LINKER_FLAGS=", _ld, delimiter = ""))
        cmd.add(cmd_args("--cmake-define=", "CMAKE_MODULE_LINKER_FLAGS=", _ld, delimiter = ""))
    if pkg_config_paths:
        cmd.add("--env", cmd_args("PKG_CONFIG_PATH=", cmd_args(pkg_config_paths, delimiter = ":"), delimiter = ""))

    # Pass dep prefix paths as cmake defines (e.g. SPIRV-Headers_SOURCE_DIR)
    for var_name, dep in ctx.attrs.cmake_dep_defines.items():
        if PackageInfo in dep:
            dep_prefix = dep[PackageInfo].prefix
        else:
            dep_prefix = dep[DefaultInfo].default_outputs[0]
        cmd.add(cmd_args("--cmake-define=", var_name, "=", dep_prefix, "/usr", delimiter = ""))

    # Configure arguments from the common interface
    for arg in ctx.attrs.configure_args:
        cmd.add(cmd_args("--cmake-arg=", arg, delimiter = ""))

    ctx.actions.run(cmd, category = "configure", identifier = ctx.attrs.name)
    return output

def _src_compile(ctx, configured, source):
    """Run ninja in the cmake build tree."""
    output = ctx.actions.declare_output("built", dir = True)
    cmd = cmd_args(ctx.attrs._build_tool[RunInfo])
    cmd.add("--build-dir", configured)
    cmd.add("--output-dir", output.as_output())
    cmd.add("--build-system", "ninja")

    # Ensure source dir and dep artifacts are available — cmake
    # out-of-tree builds reference them in build.ninja.
    cmd.add(cmd_args(hidden = source))
    for dep in ctx.attrs.deps:
        cmd.add(cmd_args(hidden = dep[DefaultInfo].default_outputs))

    # Inject toolchain CC/CXX/AR
    for env_arg in toolchain_env_args(ctx):
        cmd.add("--env", env_arg)

    # Hermetic PATH from seed toolchain
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)

    # Inject user-specified environment variables
    for key, value in ctx.attrs.env.items():
        cmd.add("--env", "{}={}".format(key, value))

    # Set LD_LIBRARY_PATH and PATH so build tools (moc, rcc,
    # qtwaylandscanner, etc.) can find shared libs and executables
    # from deps at runtime.
    lib_paths = []
    for dep in ctx.attrs.deps:
        if PackageInfo in dep:
            prefix = dep[PackageInfo].prefix
        else:
            prefix = dep[DefaultInfo].default_outputs[0]
        lib_paths.append(cmd_args(prefix, format = "{}/usr/lib64"))
        lib_paths.append(cmd_args(prefix, format = "{}/usr/lib"))
        cmd.add("--path-prepend", cmd_args(prefix, format = "{}/usr/bin"))
    if lib_paths:
        cmd.add("--env", cmd_args("LD_LIBRARY_PATH=", cmd_args(lib_paths, delimiter = ":"), delimiter = ""))

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

    # Ensure source dir is available for cmake install rules
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

    for arg in ctx.attrs.make_args:
        cmd.add("--make-arg", arg)

    # Post-install commands (run in the prefix dir after install)
    for post_cmd in ctx.attrs.post_install_cmds:
        cmd.add("--post-cmd", post_cmd)

    ctx.actions.run(cmd, category = "install", identifier = ctx.attrs.name)
    return output

# ── Rule implementation ───────────────────────────────────────────────

def _cmake_package_impl(ctx):
    # Phase 1: src_unpack — obtain source from dep
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]

    # Phase 2: src_prepare — apply patches
    prepared = _src_prepare(ctx, source)

    # Phase 3: cmake_configure
    configured = _cmake_configure(ctx, prepared)

    # Phase 4: src_compile (source passed as hidden input for cmake out-of-tree builds)
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
        runtime_lib_dirs = collect_runtime_lib_dirs(ctx.attrs.deps, installed),
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

cmake_package = rule(
    impl = _cmake_package_impl,
    attrs = {
        # Source and identity
        "source": attrs.dep(),
        "version": attrs.string(),

        # Build configuration
        "source_subdir": attrs.option(attrs.string(), default = None),
        "configure_args": attrs.list(attrs.string(), default = []),
        "cmake_args": attrs.list(attrs.string(), default = []),
        "cmake_defines": attrs.list(attrs.string(), default = []),
        "cmake_dep_defines": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        "make_args": attrs.list(attrs.string(), default = []),
        "post_install_cmds": attrs.list(attrs.string(), default = []),
        "pre_configure_cmds": attrs.list(attrs.string(), default = []),
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
        "_cmake_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:cmake_helper"),
        ),
        "_build_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:build_helper"),
        ),
        "_install_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:install_helper"),
        ),
    } | TOOLCHAIN_ATTRS,
)
