"""autotools_package: ./configure && make && make install builds.

Thin wrapper that delegates to the package() macro with build_rule = "autotools".
All cross-cutting concerns (private patch merge, source download, USE flag
expansion, vendor wiring, host-tool injection, transforms, SBOM labels) are
handled by package() — wrappers exist purely so BUCK files read better.

Rule-specific kwargs (forwarded to defs/rules:autotools.bzl::autotools_build):
    configure_prefix_deps, configure_script, skip_configure,
    cc_as_configure_arg, skip_cc_auto_arg, skip_host_arg, build_subdir,
    pre_build_cmds, make_args, install_args, install_targets,
    install_prefix_var
"""

load("//defs:package.bzl", "package")

def autotools_package(name, **kwargs):
    package(name = name, build_rule = "autotools", **kwargs)

def make_package(name, **kwargs):
    """autotools_package with skip_configure=True default (raw Makefile builds)."""
    package(name = name, build_rule = "make", **kwargs)
