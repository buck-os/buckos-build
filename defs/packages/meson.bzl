"""meson_package: meson setup build && ninja -C build && ninja -C build install.

Thin wrapper that delegates to the package() macro with build_rule = "meson".
See defs/packages/autotools.bzl for the rationale.

Rule-specific kwargs (forwarded to defs/rules:meson.bzl::meson_build):
    meson_args, meson_defines, source_subdir, make_args
"""

load("//defs:package.bzl", "package")

def meson_package(name, **kwargs):
    package(name = name, build_rule = "meson", **kwargs)
