"""Shared helpers for package rules."""

load("//defs:providers.bzl", "PackageInfo")

def collect_runtime_lib_dirs(deps, installed):
    """Collect lib dirs from installed prefix and all deps (transitive)."""
    dirs = []
    for dep in deps:
        if PackageInfo in dep:
            dirs.extend(dep[PackageInfo].runtime_lib_dirs)
    dirs.append(cmd_args(installed, format = "{}/usr/lib64"))
    dirs.append(cmd_args(installed, format = "{}/usr/lib"))
    return dirs
