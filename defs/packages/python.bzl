"""python_package: pip install (or setup.py install) into the package prefix.

Thin wrapper that delegates to the package() macro with build_rule = "python".
See defs/packages/autotools.bzl for the rationale.

Rule-specific kwargs (forwarded to defs/rules:python.bzl::python_build):
    use_setup_py, pip_args
"""

load("//defs:package.bzl", "package")

def python_package(name, **kwargs):
    package(name = name, build_rule = "python", **kwargs)
