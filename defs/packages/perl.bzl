"""perl_package: perl Makefile.PL && make && make install.

Thin wrapper that delegates to the package() macro with build_rule = "perl".
See defs/packages/autotools.bzl for the rationale.

Rule-specific kwargs (forwarded to defs/rules:perl.bzl::perl_build):
    pre_build_cmds (in addition to common configure_args / post_install_cmds)

Naming note: this wrapper is perl_package for consistency with the other
language wrappers; the underlying rule is perl_build (was perl_module before
the 2026-05 rename).
"""

load("//defs:package.bzl", "package")

def perl_package(name, **kwargs):
    package(name = name, build_rule = "perl", **kwargs)
