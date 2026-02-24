"""
Configuration transition rules for toolchain selection.

The bootstrap build uses a constraint setting (bootstrap-mode-setting) with
multiple values to control which toolchain TOOLCHAIN_ATTRS select() resolves:

  bootstrap-mode-true  → host PATH toolchain (escape hatch)
  stage3-mode-true     → stage 2 toolchain (hermetic rebuild)
  bootstrap-mode-false → seed toolchain (same as DEFAULT)
  DEFAULT              → seed toolchain (toolchains//:buckos)

Three transitions:

  default_transition  — reset to DEFAULT (seed toolchain).  Used by
                        stage2-toolchain to resolve host_tools in DEFAULT
                        config, breaking the stage3 → stage2 → host-tools
                        dependency cycle.

  stage3_transition   — flip to stage3 mode.  Applied by toolchain_export
                        to the host_tools dep so stage 3 tools are built
                        with the stage 2 toolchain (hermetic PATH).

  bootstrap_transition — flip to bootstrap mode (escape hatch).
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

def _default_dep_impl(ctx):
    """Forward a dep's DefaultInfo through the default transition.

    Used to break dependency cycles: wraps a target with the default
    transition so it resolves in DEFAULT config even when the consumer
    is in stage3 config.  Toolchain rules can't use transition_dep
    directly, so this wrapper sits between the toolchain and its dep.
    """
    return [ctx.attrs.dep[DefaultInfo]]

default_dep = rule(
    impl = _default_dep_impl,
    attrs = {
        "dep": attrs.transition_dep(cfg = "//tc/exec:default-transition"),
    },
)

stage3_transition = rule(
    impl = _config_transition_impl,
    attrs = {
        "_setting": attrs.dep(default = "//tc/exec:bootstrap-mode-setting"),
        "_value": attrs.dep(default = "//tc/exec:stage3-mode-true"),
    },
    is_configuration_rule = True,
)
