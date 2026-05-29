"""cmake_package: cmake -S . -B build && ninja && ninja install.

Thin wrapper that delegates to the package() macro with build_rule = "cmake".
See defs/packages/autotools.bzl for the rationale.

Rule-specific kwargs (forwarded to defs/rules:cmake.bzl::cmake_build):
    source_subdir, cmake_args, cmake_defines, cmake_dep_defines, make_args
"""

load("//defs:package.bzl", "package")

def cmake_package(name, **kwargs):
    package(name = name, build_rule = "cmake", **kwargs)
