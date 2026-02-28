"""Host tool PATH helpers for package rules.

DRYs up the host_deps iteration that extracts --path-prepend
flags for Python helpers.
"""

load("//defs:providers.bzl", "PackageInfo")

def host_tool_path_args(ctx):
    """Return --path-prepend cmd_args from ctx.attrs.host_deps."""
    args = []
    for hd in ctx.attrs.host_deps:
        prefix = hd[PackageInfo].prefix if PackageInfo in hd else hd[DefaultInfo].default_outputs[0]
        args.append(cmd_args("--path-prepend", cmd_args(prefix, format = "{}/usr/bin")))
    return args

def host_tool_env_paths(ctx):
    """Return bin dir cmd_args from ctx.attrs.host_deps (for binary_package env vars)."""
    paths = []
    for hd in ctx.attrs.host_deps:
        prefix = hd[PackageInfo].prefix if PackageInfo in hd else hd[DefaultInfo].default_outputs[0]
        paths.append(cmd_args(prefix, format = "{}/usr/bin"))
    return paths
