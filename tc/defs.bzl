"""
Shared rule definitions for the tc/ subcell.
"""

load("@prelude//platforms:defs.bzl", "host_configuration")

def _buckos_execution_platforms_impl(ctx: AnalysisContext) -> list[Provider]:
    """Create a local execution platform suitable for BuckOS package builds.

    All BuckOS builds run actions on the local machine.  The seed
    toolchain provides BuildToolchainInfo; the bootstrap transition
    temporarily switches to host PATH tools when building the seed.
    """
    constraints = dict()
    constraints.update(ctx.attrs.cpu_configuration[ConfigurationInfo].constraints)
    constraints.update(ctx.attrs.os_configuration[ConfigurationInfo].constraints)

    # Include host-target-mode so exec_dep targets (host_deps) resolve to
    # the host toolchain.  When Buck2 configures an exec_dep for this
    # execution platform, the is-host-target constraint is present.
    constraints[ctx.attrs.host_target_setting[ConstraintSettingInfo].label] = \
        ctx.attrs.host_target_value[ConstraintValueInfo]

    cfg = ConfigurationInfo(constraints = constraints, values = {})

    name = ctx.label.raw_target()
    platform = ExecutionPlatformInfo(
        label = name,
        configuration = cfg,
        executor_config = CommandExecutorConfig(
            local_enabled = True,
            remote_enabled = ctx.attrs.remote_execution_enabled,
            remote_cache_enabled = True if ctx.attrs.remote_cache_enabled else None,
            allow_cache_uploads = ctx.attrs.remote_cache_enabled,
            use_limited_hybrid = ctx.attrs.remote_execution_enabled,
            use_windows_path_separators = False,
        ),
    )

    return [
        DefaultInfo(),
        platform,
        PlatformInfo(label = str(name), configuration = cfg),
        ExecutionPlatformRegistrationInfo(platforms = [platform]),
    ]

buckos_execution_platforms = rule(
    impl = _buckos_execution_platforms_impl,
    attrs = {
        "cpu_configuration": attrs.dep(
            providers = [ConfigurationInfo],
            default = host_configuration.cpu,
        ),
        "os_configuration": attrs.dep(
            providers = [ConfigurationInfo],
            default = host_configuration.os,
        ),
        "remote_cache_enabled": attrs.bool(default = False),
        "remote_execution_enabled": attrs.bool(default = False),
        "host_target_setting": attrs.dep(
            providers = [ConstraintSettingInfo],
            default = "//tc/exec:bootstrap-mode-setting",
        ),
        "host_target_value": attrs.dep(
            providers = [ConstraintValueInfo],
            default = "//tc/exec:host-target-mode",
        ),
    },
)
