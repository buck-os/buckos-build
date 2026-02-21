"""
USE flag helper functions for Buck2 select()-based configuration.

These helpers bridge the use/ subcell constraint system with package
rule attributes. They return select() expressions that Buck2 resolves
at analysis time based on the active platform/profile.

Usage in package BUCK files:

    load("//defs:use_helpers.bzl", "use_bool", "use_dep", "use_configure_arg")

    autotools_package(
        ...
        deps = [
            "//packages/linux/core/zlib:zlib",
        ] + use_dep("ssl", "//packages/linux/dev-libs/openssl:openssl"),
        configure_args = [
            "--prefix=/usr",
        ] + use_configure_arg("ssl", "--with-ssl", "--without-ssl"),
    )
"""

def use_bool(flag):
    """Resolve a USE flag to a bool via select(). For use in rule attrs.

    Defaults to False when the platform doesn't include the constraint."""
    return select({
        "//use/constraints:{}-on".format(flag): True,
        "//use/constraints:{}-off".format(flag): False,
        "DEFAULT": False,
    })

def use_dep(flag, dep):
    """Conditional dependency based on a USE flag.

    Returns a list with the dep when the flag is on, empty list when off.
    Concatenate with + into a deps list."""
    return select({
        "//use/constraints:{}-on".format(flag): [dep],
        "//use/constraints:{}-off".format(flag): [],
        "DEFAULT": [],
    })

def use_configure_arg(flag, on_arg, off_arg = None):
    """Conditional configure arg based on a USE flag.

    on_arg / off_arg can be a string or a list of strings.
    Returns a list with the arg(s) when the condition matches.
    Concatenate with + into a configure_args list."""
    on_list = on_arg if type(on_arg) == "list" else [on_arg]
    if off_arg == None:
        off_list = []
    elif type(off_arg) == "list":
        off_list = off_arg
    else:
        off_list = [off_arg]
    return select({
        "//use/constraints:{}-on".format(flag): on_list,
        "//use/constraints:{}-off".format(flag): off_list,
        "DEFAULT": off_list,
    })

def use_feature(flag, feature):
    """Conditional cargo feature based on a USE flag.

    Returns a list with the feature when the flag is on, empty list when off.
    Concatenate with + into a features list."""
    return select({
        "//use/constraints:{}-on".format(flag): [feature],
        "//use/constraints:{}-off".format(flag): [],
        "DEFAULT": [],
    })

def use_expand_select(expand_name, value_map):
    """Single-select USE_EXPAND: map each possible value to a result.

    Example:
        use_expand_select("python_single_target", {
            "python3_11": "//third-party/python:3.11",
            "python3_12": "//third-party/python:3.12",
        })
    """
    return select({
        "//use/constraints:{}-{}".format(expand_name, v): result
        for v, result in value_map.items()
    })

def use_expand_dep(expand_name, value, dep):
    """Conditional dep on a multi-select USE_EXPAND value."""
    flag = "{}_{}".format(expand_name, value)
    return use_dep(flag, dep)

def use_expand_multi_deps(expand_name, value_dep_map):
    """Conditional deps for all values of a multi-select USE_EXPAND.

    Example:
        use_expand_multi_deps("python_targets", {
            "python3_11": "//third-party/python:3.11",
            "python3_12": "//third-party/python:3.12",
        })

    Returns a concatenation of select() expressions, one per value.
    """
    result = []
    for value, dep in value_dep_map.items():
        result += use_expand_dep(expand_name, value, dep)
    return result

def use_versioned_dep(expand_name, version_map):
    """Select between package versions based on a USE_EXPAND slot.

    Example:
        use_versioned_dep("openssl_slot", {
            "3": "//packages/linux/dev-libs/openssl:openssl-3",
            "1.1": "//packages/linux/dev-libs/openssl:openssl-1.1",
        })

    Returns a select() that resolves to a single-element list with the
    appropriate versioned dep target.
    """
    return select({
        "//use/constraints:{}-{}".format(expand_name, v): [dep]
        for v, dep in version_map.items()
    })
