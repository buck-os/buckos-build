def use_flag(name):
    """Simple on/off USE flag."""
    native.constraint_setting(name = name)
    native.constraint_value(name = name + "-on", constraint_setting = ":" + name)
    native.constraint_value(name = name + "-off", constraint_setting = ":" + name)

def use_expand(name, values):
    """USE_EXPAND single-select: pick exactly one value.
    Example: use_expand("python_single_target", ["python3_11", "python3_12"])
    Creates one constraint_setting with N constraint_values."""
    native.constraint_setting(name = name)
    for v in values:
        native.constraint_value(name = name + "-" + v, constraint_setting = ":" + name)

def use_expand_multi(name, values):
    """USE_EXPAND multi-select: enable any combination of values.
    Example: use_expand_multi("python_targets", ["python3_11", "python3_12"])
    Creates N independent constraint_settings, each with on/off.
    This matches Gentoo's internal expansion: PYTHON_TARGETS="python3_11 python3_12"
    becomes USE="python_targets_python3_11 python_targets_python3_12"."""
    for v in values:
        flag_name = name + "_" + v
        native.constraint_setting(name = flag_name)
        native.constraint_value(name = flag_name + "-on", constraint_setting = ":" + flag_name)
        native.constraint_value(name = flag_name + "-off", constraint_setting = ":" + flag_name)
