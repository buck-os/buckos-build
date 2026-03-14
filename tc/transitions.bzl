"""
Configuration transition rules for toolchain selection.

The bootstrap build uses a constraint setting (bootstrap-mode-setting) with
multiple values to control which toolchain TOOLCHAIN_ATTRS select() resolves:

  bootstrap-mode-true  → host PATH toolchain (escape hatch)
  bootstrap-mode-false → seed toolchain (same as DEFAULT)
  DEFAULT              → seed toolchain (toolchains//:buckos)

Three transitions:

  default_transition  — reset to DEFAULT (seed toolchain).  Used by
                        stage3-toolchain to resolve host_tools in DEFAULT
                        config, breaking dependency cycles.

  bootstrap_transition — flip to bootstrap mode (escape hatch).

  strip_toolchain_mode_transition — remove bootstrap-mode-setting entirely,
                        returning to the base platform.  Applied as cfg on
                        rules whose output is configuration-independent
                        (source extraction, stage 2 bootstrap, kernel
                        config/headers) to prevent duplicate actions when
                        the same targets are reached through multiple
                        configurations.
"""

def _config_transition_impl(ctx):
    """Generic transition: set a constraint value on a constraint setting."""
    setting = ctx.attrs._setting
    value = ctx.attrs._value
    label_name = ctx.label.name

    def _impl(platform):
        constraints = dict(platform.configuration.constraints)
        constraints[setting[ConstraintSettingInfo].label] = value[ConstraintValueInfo]
        return PlatformInfo(
            label = "<{}>".format(label_name),
            configuration = ConfigurationInfo(
                constraints = constraints,
                values = platform.configuration.values,
            ),
        )

    return [
        DefaultInfo(),
        TransitionInfo(impl = _impl),
    ]

default_transition = rule(
    impl = _config_transition_impl,
    attrs = {
        "_setting": attrs.dep(default = "//tc/exec:bootstrap-mode-setting"),
        "_value": attrs.dep(default = "//tc/exec:bootstrap-mode-false"),
    },
    is_configuration_rule = True,
)

bootstrap_transition = rule(
    impl = _config_transition_impl,
    attrs = {
        "_setting": attrs.dep(default = "//tc/exec:bootstrap-mode-setting"),
        "_value": attrs.dep(default = "//tc/exec:bootstrap-mode-true"),
    },
    is_configuration_rule = True,
)

host_tools_transition = rule(
    impl = _config_transition_impl,
    attrs = {
        "_setting": attrs.dep(default = "//tc/exec:bootstrap-mode-setting"),
        "_value": attrs.dep(default = "//tc/exec:host-tools-mode"),
    },
    is_configuration_rule = True,
)

def _default_dep_impl(ctx):
    """Forward a dep's DefaultInfo through the default transition.

    Used to break dependency cycles: wraps a target with the default
    transition so it resolves in DEFAULT config even when the consumer
    is in a different config.  Toolchain rules can't use transition_dep
    directly, so this wrapper sits between the toolchain and its dep.
    """
    return [ctx.attrs.dep[DefaultInfo]]

default_dep = rule(
    impl = _default_dep_impl,
    attrs = {
        "dep": attrs.transition_dep(cfg = "//tc/exec:default-transition"),
    },
)

def _strip_toolchain_mode_impl(platform: PlatformInfo, refs: struct) -> PlatformInfo:
    """Strip the bootstrap-mode constraint, returning to the base platform.

    Stripping (not setting to bootstrap-mode-false) is deliberate: the DEFAULT
    config has no bootstrap-mode-setting at all, so stripping produces the
    exact same configuration hash — true dedup with zero extra configurations.
    """
    constraints = dict(platform.configuration.constraints)
    constraints.pop(refs.setting[ConstraintSettingInfo].label, None)
    return PlatformInfo(
        label = "<base>",
        configuration = ConfigurationInfo(
            constraints = constraints,
            values = platform.configuration.values,
        ),
    )

strip_toolchain_mode = transition(
    impl = _strip_toolchain_mode_impl,
    refs = {"setting": "//tc/exec:bootstrap-mode-setting"},
)
