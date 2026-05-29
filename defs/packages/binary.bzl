"""binary_package: custom install_script for pre-built or unusual packages.

Thin wrapper that delegates to the package() macro with build_rule = "binary".
See defs/packages/autotools.bzl for the rationale.

Rule-specific kwargs (forwarded to defs/rules:binary.bzl::binary_build):
    install_script

Note: passing src_compile / src_install to autotools_package() also dispatches
to the binary rule via package()'s auto-conversion (defs/package.bzl:614).
"""

load("//defs:package.bzl", "package")

def binary_package(name, **kwargs):
    package(name = name, build_rule = "binary", **kwargs)
