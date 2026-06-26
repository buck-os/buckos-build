"""
meson_build rule: meson setup build && ninja -C build && ninja -C build install.

Five discrete cacheable actions — Buck2 can skip any phase whose
inputs haven't changed.

1. src_unpack  — obtain source artifact from source dep
2. src_prepare — apply patches (zero-cost passthrough when no patches)
3. meson_setup — run meson setup via meson_helper.py
4. src_compile — run ninja via build_helper.py
5. src_install — run ninja install via install_helper.py
   (post_install_cmds run in the prefix dir after install)
"""

load("//defs:host_tools.bzl", "host_tool_path_args")
load("//defs:providers.bzl", "PackageInfo")
load(
    "//defs:toolchain_helpers.bzl",
    "toolchain_env_args",
    "toolchain_extra_cflags",
    "toolchain_extra_ldflags",
    "toolchain_ld_linux_args",
    "toolchain_local_only",
    "toolchain_path_args",
    "toolchain_target_triple",
)
load(
    "//defs/rules:_common.bzl",
    "COMMON_PACKAGE_ATTRS",
    "add_flag_file",
    "build_package_tsets",
    "collect_dep_tsets",
    "collect_host_path_children",
    "package_linker_cflags",
    "package_linker_ldflags",
    "src_prepare",
    "write_bin_dirs",
    "write_compile_flags",
    "write_lib_dirs_with_hosts",
    "write_link_flags",
    "write_pkg_config_paths",
)

# ── Phase helpers ─────────────────────────────────────────────────────

def _meson_setup(ctx, source, cflags_file = None, ldflags_file = None, pkg_config_file = None, lib_dirs_file = None, bin_dirs_file = None):
    """Run meson setup with toolchain env and dep flags.

    Dep flags are propagated via tset projection files — the meson_helper
    reads them and merges into CFLAGS, LDFLAGS, and PKG_CONFIG_PATH.
    """
    cmd = cmd_args(ctx.attrs._meson_tool[RunInfo])

    # Support source subdirectory (e.g. zstd keeps meson.build in build/meson/)
    if ctx.attrs.source_subdir:
        cmd.add("--source-dir", cmd_args(source, "/", ctx.attrs.source_subdir, delimiter = ""))
    else:
        cmd.add("--source-dir", source)
    cmd.add("--build-dir", "@WORK@/configured")

    # Inject toolchain CC/CXX/AR
    for env_arg in toolchain_env_args(ctx):
        cmd.add("--env", env_arg)

    # Hermetic PATH and ld-linux from seed toolchain
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)
    for arg in toolchain_ld_linux_args(ctx):
        cmd.add(arg)

    # Cross-compilation: pass target triple so the helper generates a
    # meson cross file.  This prevents meson from trying to execute
    # compiled test programs (which crash when the padded interpreter
    # resolves to a host ld-linux that is ABI-incompatible with the
    # target libc).
    cmd.add("--cross-triple", toolchain_target_triple(ctx))

    # Inject USE flag and user-specified environment variables
    for entry in ctx.attrs.use_env:
        cmd.add("--env", entry)
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
    cflags = list(toolchain_extra_cflags(ctx)) + list(ctx.attrs.extra_cflags) + package_linker_cflags(ctx)
    ldflags = list(toolchain_extra_ldflags(ctx)) + list(ctx.attrs.extra_ldflags) + package_linker_ldflags(ctx)
    if cflags:
        cmd.add("--env", cmd_args("CFLAGS=", cmd_args(cflags, delimiter = " "), delimiter = ""))
    if ldflags:
        cmd.add("--env", cmd_args("LDFLAGS=", cmd_args(ldflags, delimiter = " "), delimiter = ""))

    # Dep flags via tset projection files
    add_flag_file(cmd, "--cflags-file", cflags_file)
    add_flag_file(cmd, "--ldflags-file", ldflags_file)
    add_flag_file(cmd, "--pkg-config-file", pkg_config_file)
    add_flag_file(cmd, "--lib-dirs-file", lib_dirs_file)

    # Dep bin dirs appended to PATH for *-config discovery scripts
    add_flag_file(cmd, "--path-append-file", bin_dirs_file)

    # Add host_deps bin dirs to PATH
    for arg in host_tool_path_args(ctx):
        cmd.add(arg)

    # Configure arguments from the common interface
    for arg in ctx.attrs.configure_args:
        cmd.add(cmd_args("--meson-arg=", arg, delimiter = ""))

    return cmd

def _src_compile(ctx, configured, source, lib_dirs_file = None):
    """Run ninja in the meson build tree."""
    cmd = cmd_args(ctx.attrs._build_tool[RunInfo])
    cmd.add("--build-dir", "@WORK@/configured")
    cmd.add("--output-dir", "@WORK@/built")
    cmd.add("--build-system", "ninja")

    # Ensure source dir is available — meson out-of-tree builds
    # reference source files by absolute path in build.ninja.
    # Dep prefixes are materialised via tset projections (lib_dirs_file)
    # passed to add_flag_file below.
    cmd.add(cmd_args(hidden = source))

    # Inject toolchain CC/CXX/AR
    for env_arg in toolchain_env_args(ctx):
        cmd.add("--env", env_arg)

    # Hermetic PATH and ld-linux from seed toolchain
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)
    for arg in toolchain_ld_linux_args(ctx):
        cmd.add(arg)

    # Inject USE flag and user-specified environment variables
    for entry in ctx.attrs.use_env:
        cmd.add("--env", entry)
    for key, value in ctx.attrs.env.items():
        cmd.add("--env", "{}={}".format(key, value))

    # Dep bin dirs and lib dirs via tset projection files.
    # Build tools (moc, rcc, wayland-scanner, etc.) need shared libs
    # and executables from deps at runtime.
    add_flag_file(cmd, "--lib-dirs-file", lib_dirs_file)

    # Add host_deps bin dirs to PATH
    for arg in host_tool_path_args(ctx):
        cmd.add(arg)

    for arg in ctx.attrs.make_args:
        cmd.add("--make-arg", arg)

    return cmd

def _src_install(ctx, built, source, lib_dirs_file = None, test_marker = None):
    """Run ninja install into the output prefix."""
    cmd = cmd_args(ctx.attrs._install_tool[RunInfo])
    cmd.add("--build-dir", "@WORK@/built")
    cmd.add("--prefix", "@OUT@")
    cmd.add("--build-system", "ninja")

    # Ensure source dir is available for meson install rules
    cmd.add(cmd_args(hidden = source))

    # Opt-in src_test gates install (Gentoo order: compile -> test -> install).
    # When run_tests = False (default) test_marker is None and install is unchanged.
    if test_marker:
        cmd.add(cmd_args(hidden = [test_marker]))

    # Inject toolchain CC/CXX/AR
    for env_arg in toolchain_env_args(ctx):
        cmd.add("--env", env_arg)

    # Hermetic PATH and ld-linux from seed toolchain
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)
    for arg in toolchain_ld_linux_args(ctx):
        cmd.add(arg)

    # Inject USE flag and user-specified environment variables
    for entry in ctx.attrs.use_env:
        cmd.add("--env", entry)
    for key, value in ctx.attrs.env.items():
        cmd.add("--env", "{}={}".format(key, value))

    # Dep bin/lib dirs — install rules may run tools or need shared libs
    add_flag_file(cmd, "--lib-dirs-file", lib_dirs_file)

    # Add host_deps bin dirs to PATH
    for arg in host_tool_path_args(ctx):
        cmd.add(arg)

    for arg in ctx.attrs.make_args:
        cmd.add("--make-arg", arg)

    # Post-install commands (run in the prefix dir after install)
    for post_cmd in ctx.attrs.post_install_cmds:
        cmd.add("--post-cmd", post_cmd)

    return cmd

# ── Phase: src_test (opt-in) ──────────────────────────────────────────

def _src_test(ctx, built, source, lib_dirs_file = None):
    """Run `meson test` on the built tree (opt-in: run_tests = True).

    Reuses build_helper (the compile helper) with --test-mode meson so the
    full hermetic env — PATH, LD_LIBRARY_PATH, ld-linux, SHELL, network
    isolation — matches the compile phase.  That parity matters because
    tests run target binaries.  Mirrors Gentoo's meson.eclass src_test
    (`meson test`).  Native-only: target test binaries can't run under a
    cross build, so don't opt aarch64-only packages in.
    """
    cmd = cmd_args(ctx.attrs._build_tool[RunInfo])
    cmd.add("--build-dir", "@WORK@/built")
    cmd.add("--output-dir", "@WORK@/tested")
    cmd.add("--build-system", "ninja")
    cmd.add("--test-mode", "meson")

    # Ensure source dir is available (meson build trees reference it).
    cmd.add(cmd_args(hidden = source))

    # Inject toolchain CC/CXX/AR
    for env_arg in toolchain_env_args(ctx):
        cmd.add("--env", env_arg)

    # Hermetic PATH and ld-linux from seed toolchain
    for arg in toolchain_path_args(ctx):
        cmd.add(arg)
    for arg in toolchain_ld_linux_args(ctx):
        cmd.add(arg)

    # Inject USE flag and user-specified environment variables
    for entry in ctx.attrs.use_env:
        cmd.add("--env", entry)
    for key, value in ctx.attrs.env.items():
        cmd.add("--env", "{}={}".format(key, value))

    add_flag_file(cmd, "--lib-dirs-file", lib_dirs_file)

    # Add host_deps bin dirs to PATH
    for arg in host_tool_path_args(ctx):
        cmd.add(arg)

    for arg in ctx.attrs.test_args:
        cmd.add("--test-arg", arg)

    return cmd

# ── Single-action phase runner ────────────────────────────────────────
#
# Internal buck2 re-materializes declared outputs between split actions
# (with normalized mtimes and alias/hash path duality), which breaks meson:
# meson bakes the configure-dir path of generated headers into build.ninja
# (e.g. -DMAPI_ABI_HEADER=.../output_artifacts/configured/.../g_*.h ->
# "No such file or directory" at compile time, since that alias path isn't
# materialized in the compile action).  Run configure -> compile -> [test]
# -> install as ONE action with plain scratch intermediates so paths/mtimes
# stay consistent, exactly like the cmake/autotools rules.  Each phase cmd
# uses @WORK@ (scratch) and @OUT@ (installed) placeholders the orchestrator
# substitutes; args are passed via argv (separated by ::NEXT::) so values
# with spaces/newlines (multi-line post_install_cmds) survive.

def _meson_run_phases(ctx, phases, extra_hidden = []):
    installed = ctx.actions.declare_output("installed", dir = True)

    lines = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        'OUT="$1"; shift',
        'WORK="${BUCK_SCRATCH_PATH:-${TMPDIR:-/tmp}}/meson_build"',
        'rm -rf "$WORK"; mkdir -p "$WORK"',
        "phase=()",
        "runphase() {",
        "  [ ${#phase[@]} -eq 0 ] && return 0",
        "  local a=() x",
        '  for x in "${phase[@]}"; do x="${x//@WORK@/$WORK}"; x="${x//@OUT@/$OUT}"; a+=("$x"); done',
        '  "${a[@]}"',
        "}",
        'for arg in "$@"; do',
        '  if [ "$arg" = "::NEXT::" ]; then runphase; phase=(); else phase+=("$arg"); fi',
        "done",
        "runphase",
    ]
    orch = ctx.actions.write("meson_build.sh", "\n".join(lines) + "\n", is_executable = True)

    parts = [orch, installed.as_output()]
    for i, ph in enumerate(phases):
        if i > 0:
            parts.append("::NEXT::")
        parts.append(ph)
    run_cmd = cmd_args(parts, hidden = extra_hidden)
    ctx.actions.run(run_cmd, category = "meson_build", identifier = ctx.attrs.name, allow_cache_upload = True, local_only = toolchain_local_only(ctx))
    return installed

# ── Rule implementation ───────────────────────────────────────────────

def _meson_build_impl(ctx):
    # Phase 1: src_unpack — obtain source from dep
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]

    # Phase 2: src_prepare — apply patches
    prepared = src_prepare(ctx, source, "meson_prepare")

    # Collect dep-only tsets and write flag files for build phases
    dep_compile, dep_link, dep_path = collect_dep_tsets(ctx)
    cflags_file = write_compile_flags(ctx, dep_compile)
    ldflags_file = write_link_flags(ctx, dep_link)
    pkg_config_file = write_pkg_config_paths(ctx, dep_compile)
    host_path_children = collect_host_path_children(ctx)
    lib_dirs_file = write_lib_dirs_with_hosts(ctx, dep_path, host_path_children)
    bin_dirs_file = write_bin_dirs(ctx, dep_path)

    # Phases configure -> compile -> [test] -> install run as ONE action
    # (single-action) with plain scratch intermediates, so paths/mtimes stay
    # consistent across phases (internal buck2 otherwise re-materializes
    # split-action outputs and breaks meson's baked generated-header paths).
    conf_cmd = _meson_setup(ctx, prepared, cflags_file, ldflags_file, pkg_config_file, lib_dirs_file, bin_dirs_file)
    build_cmd = _src_compile(ctx, prepared, prepared, lib_dirs_file)
    phases = [conf_cmd, build_cmd]
    if ctx.attrs.run_tests:
        phases.append(_src_test(ctx, prepared, prepared, lib_dirs_file))
    phases.append(_src_install(ctx, prepared, prepared, lib_dirs_file, test_marker = None))

    installed = _meson_run_phases(ctx, phases, extra_hidden = [prepared])

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

meson_build = rule(
    impl = _meson_build_impl,
    attrs = COMMON_PACKAGE_ATTRS
    | {
        "make_args": attrs.list(attrs.string(), default = []),
        # Meson-specific
        "meson_args": attrs.list(attrs.string(), default = []),
        "meson_defines": attrs.list(attrs.string(), default = []),
        # src_test (opt-in): run_tests = True runs `meson test` after
        # compile and gates install.  Default off = noop (no extra action).
        # test_target is unused (meson test is the runner); kept for a
        # uniform interface.  ("tests" is a Buck2 built-in attr.)
        "run_tests": attrs.bool(default = False),
        "source_subdir": attrs.string(default = ""),
        "test_args": attrs.list(attrs.string(), default = []),
        "test_target": attrs.string(default = ""),
        "_build_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:build_helper"),
        ),
        "_install_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:install_helper"),
        ),
        "_meson_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:meson_helper"),
        ),
    },
)
