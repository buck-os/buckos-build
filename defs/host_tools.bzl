"""Host tool PATH helpers for package rules.

DRYs up the host_deps iteration that extracts --path-prepend
flags for Python helpers.
"""

load("//defs:providers.bzl", "PackageInfo")

def _all_host_tools(ctx):
    """Return combined list of base host tools + per-package host_deps."""
    tools = []
    if hasattr(ctx.attrs, "_base_host_tools"):
        tools.extend(ctx.attrs._base_host_tools)
    tools.extend(ctx.attrs.host_deps)
    return tools

def host_tool_path_args(ctx):
    """Return --path-prepend cmd_args from base host tools + host_deps."""
    args = []
    for hd in _all_host_tools(ctx):
        prefix = hd[PackageInfo].prefix if PackageInfo in hd else hd[DefaultInfo].default_outputs[0]
        args.append(cmd_args("--path-prepend", cmd_args(prefix, format = "{}/usr/bin")))
    return args

def host_tool_env_paths(ctx):
    """Return bin dir cmd_args from base host tools + host_deps (for binary_package env vars)."""
    paths = []
    for hd in _all_host_tools(ctx):
        prefix = hd[PackageInfo].prefix if PackageInfo in hd else hd[DefaultInfo].default_outputs[0]
        paths.append(cmd_args(prefix, format = "{}/usr/bin"))
    return paths
