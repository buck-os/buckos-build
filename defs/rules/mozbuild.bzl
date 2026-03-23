"""
mozbuild_package rule: Firefox/mach build.

Two cacheable actions:

1. src_prepare   — apply patches + pre_configure_cmds
2. full          — ./mach configure + build + install (single action)

Configure, build, and install run in one action to keep mach's
MOZBUILD_STATE_PATH and virtualenv hashing consistent.  Splitting
them across Buck2 actions broke because each action has its own
scratch directory, producing different srcdirs/src-HASH entries and
stale config.status references.
"""

load("//defs:providers.bzl", "PackageInfo")
load("//defs/rules:_common.bzl",
     "COMMON_PACKAGE_ATTRS",
     "add_flag_file", "build_package_tsets", "collect_dep_tsets",
     "src_prepare",
     "write_dep_prefixes",
)
load("//defs:toolchain_helpers.bzl", "toolchain_ld_linux_args", "toolchain_path_args")
load("//defs:host_tools.bzl", "host_tool_path_args")

# ── Phase helpers ─────────────────────────────────────────────────────

def _build_and_install(ctx, source, dep_prefixes_file = None):
    """Single-action configure + build + install.

    Running all mach phases in one Buck2 action keeps MOZBUILD_STATE_PATH,
    virtualenvs, and objdir paths consistent.  Separate actions broke
    because mach's per-source-path state hashing produced different
    virtualenv directories in each action, leaving config.status with
    stale references that triggered FileNotFoundError on backend regen.
    """
    output = ctx.actions.declare_output("installed", dir = True)
    cmd = cmd_args(ctx.attrs._mozbuild_tool[RunInfo])
    cmd.add("--phase", "full")
    cmd.add("--source-dir", source)
    cmd.add("--output-dir", output.as_output())
    for opt in ctx.attrs.mozconfig_options:
        cmd.add(cmd_args("--mozconfig-option=", opt, delimiter = ""))

    add_flag_file(cmd, "--dep-base-dirs-file", dep_prefixes_file)

    for arg in toolchain_path_args(ctx):
        cmd.add(arg)

    # Inject USE flag and user-specified environment variables
    for entry in ctx.attrs.use_env:
        cmd.add("--env", entry)
    for key, value in ctx.attrs.env.items():
        cmd.add("--env", "{}={}".format(key, value))

    for arg in host_tool_path_args(ctx):
        cmd.add(arg)

    for arg in toolchain_ld_linux_args(ctx):
        cmd.add(arg)

    ctx.actions.run(cmd, category = "mozbuild_build", identifier = ctx.attrs.name, allow_cache_upload = True)
    return output


# ── Rule implementation ───────────────────────────────────────────────

def _mozbuild_package_impl(ctx):
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]
    prepared = src_prepare(ctx, source, "mozbuild_prepare")

    _dep_compile, _dep_link, dep_path = collect_dep_tsets(ctx)
    dep_prefixes_file = write_dep_prefixes(ctx, dep_path)

    installed = _build_and_install(ctx, prepared, dep_prefixes_file)

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
        "_mozbuild_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:mozbuild_helper"),
        ),
    },
)
