"""mozbuild_package: Firefox/mach-based builds.

Thin wrapper that delegates to the package() macro with build_rule = "mozbuild".
See defs/packages/autotools.bzl for the rationale.

Rule-specific kwargs (forwarded to defs/rules:mozbuild.bzl::mozbuild_build):
    mozconfig_options
"""

load("//defs:package.bzl", "package")

def mozbuild_package(name, **kwargs):
    package(name = name, build_rule = "mozbuild", **kwargs)
