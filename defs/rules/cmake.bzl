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
load("//defs/rules:_common.bzl",
     "COMMON_PACKAGE_ATTRS",
     "add_flag_file", "build_package_tsets", "collect_dep_tsets",
     "src_prepare",
     "write_bin_dirs", "write_cmake_prefix_paths", "write_compile_flags",
     "write_lib_dirs", "write_link_flags", "write_pkg_config_paths",
)
load("//defs:toolchain_helpers.bzl", "toolchain_env_args", "toolchain_extra_cflags", "toolchain_extra_ldflags", "toolchain_path_args")
load("//defs:host_tools.bzl", "host_tool_path_args")

# ── Phase helpers ─────────────────────────────────────────────────────

def _cmake_configure(ctx, source, cflags_file = None, ldflags_file = None,
                     pkg_config_file = None, path_file = None,
                     prefix_path_file = None, lib_dirs_file = None):
    """Run cmake configure with toolchain env and dep flags.

    Dep flags are propagated via tset projection files — the cmake_helper
    reads them and merges into CMAKE_*_FLAGS defines, CMAKE_PREFIX_PATH,
    PKG_CONFIG_PATH, LD_LIBRARY_PATH, and PATH.
    """
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

    # Toolchain and per-package CFLAGS / LDFLAGS as cmake defines.
    # These are merged with dep tset flags by the cmake_helper.
    cflags = list(toolchain_extra_cflags(ctx)) + list(ctx.attrs.extra_cflags)
    ldflags = list(toolchain_extra_ldflags(ctx)) + list(ctx.attrs.extra_ldflags)
    if cflags:
        _cf = cmd_args(cflags, delimiter = " ")
        cmd.add(cmd_args("--cmake-define=", "CMAKE_C_FLAGS=", _cf, delimiter = ""))
        cmd.add(cmd_args("--cmake-define=", "CMAKE_CXX_FLAGS=", _cf, delimiter = ""))
    if ldflags:
        _ld = cmd_args(ldflags, delimiter = " ")
        cmd.add(cmd_args("--cmake-define=", "CMAKE_EXE_LINKER_FLAGS=", _ld, delimiter = ""))
        cmd.add(cmd_args("--cmake-define=", "CMAKE_SHARED_LINKER_FLAGS=", _ld, delimiter = ""))
        cmd.add(cmd_args("--cmake-define=", "CMAKE_MODULE_LINKER_FLAGS=", _ld, delimiter = ""))

    # Dep flags via tset projection files
    add_flag_file(cmd, "--cflags-file", cflags_file)
    add_flag_file(cmd, "--ldflags-file", ldflags_file)
    add_flag_file(cmd, "--pkg-config-file", pkg_config_file)
    add_flag_file(cmd, "--path-file", path_file)
    add_flag_file(cmd, "--prefix-path-file", prefix_path_file)
    add_flag_file(cmd, "--lib-dirs-file", lib_dirs_file)

    # Add host_deps bin dirs to PATH
    for arg in host_tool_path_args(ctx):
        cmd.add(arg)

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

    ctx.actions.run(cmd, category = "cmake_configure", identifier = ctx.attrs.name, allow_cache_upload = True)
    return output

def _src_compile(ctx, configured, source, path_file = None, lib_dirs_file = None):
    """Run ninja in the cmake build tree."""
    output = ctx.actions.declare_output("built", dir = True)
    cmd = cmd_args(ctx.attrs._build_tool[RunInfo])
    cmd.add("--build-dir", configured)
    cmd.add("--output-dir", output.as_output())
    cmd.add("--build-system", "ninja")

    # Ensure source dir is available — cmake out-of-tree builds
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
    # Build tools (moc, rcc, qtwaylandscanner, etc.) need shared libs
    # and executables from deps at runtime.
    add_flag_file(cmd, "--path-file", path_file)
    add_flag_file(cmd, "--lib-dirs-file", lib_dirs_file)

    # Add host_deps bin dirs to PATH
    for arg in host_tool_path_args(ctx):
        cmd.add(arg)

    for arg in ctx.attrs.make_args:
        cmd.add("--make-arg", arg)

    ctx.actions.run(cmd, category = "cmake_compile", identifier = ctx.attrs.name, allow_cache_upload = True)
    return output

def _src_install(ctx, built, source, path_file = None, lib_dirs_file = None):
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

    ctx.actions.run(cmd, category = "cmake_install", identifier = ctx.attrs.name, allow_cache_upload = True)
    return output

# ── Rule implementation ───────────────────────────────────────────────

def _cmake_package_impl(ctx):
    # Phase 1: src_unpack — obtain source from dep
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]

    # Phase 2: src_prepare — apply patches
    prepared = src_prepare(ctx, source, "cmake_prepare")

    # Collect dep-only tsets and write flag files for build phases
    dep_compile, dep_link, dep_path = collect_dep_tsets(ctx)
    cflags_file = write_compile_flags(ctx, dep_compile)
    ldflags_file = write_link_flags(ctx, dep_link)
    pkg_config_file = write_pkg_config_paths(ctx, dep_compile)
    path_file = write_bin_dirs(ctx, dep_path)
    prefix_path_file = write_cmake_prefix_paths(ctx, dep_path)
    lib_dirs_file = write_lib_dirs(ctx, dep_path)

    # Phase 3: cmake_configure
    configured = _cmake_configure(ctx, prepared, cflags_file, ldflags_file,
                                  pkg_config_file, path_file,
                                  prefix_path_file, lib_dirs_file)

    # Phase 4: src_compile (source passed as hidden input for cmake out-of-tree builds)
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

cmake_package = rule(
    impl = _cmake_package_impl,
    attrs = COMMON_PACKAGE_ATTRS | {
        # CMake-specific
        "source_subdir": attrs.string(default = ""),
        "cmake_args": attrs.list(attrs.string(), default = []),
        "cmake_defines": attrs.list(attrs.string(), default = []),
        "cmake_dep_defines": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        "make_args": attrs.list(attrs.string(), default = []),
        "_cmake_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:cmake_helper"),
        ),
        "_build_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:build_helper"),
        ),
        "_install_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:install_helper"),
        ),
    },
)
