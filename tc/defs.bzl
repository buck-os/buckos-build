"""
Shared rule definitions for the tc/ subcell.
"""

load("@prelude//platforms:defs.bzl", "host_configuration")

def _buckos_execution_platforms_impl(ctx: AnalysisContext) -> list[Provider]:
    """Create a local execution platform suitable for BuckOS package builds.

    All BuckOS toolchain modes (host, cross, bootstrap) run actions on
    the local machine.  The distinction between modes is which
    BuildToolchainInfo the rules consume, not where actions execute.
    """
    constraints = dict()
    constraints.update(ctx.attrs.cpu_configuration[ConfigurationInfo].constraints)
    constraints.update(ctx.attrs.os_configuration[ConfigurationInfo].constraints)
    cfg = ConfigurationInfo(constraints = constraints, values = {})

    name = ctx.label.raw_target()
    platform = ExecutionPlatformInfo(
        label = name,
        configuration = cfg,
        executor_config = CommandExecutorConfig(
            local_enabled = True,
            remote_enabled = False,
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
    },
)
