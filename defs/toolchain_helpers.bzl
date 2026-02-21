"""Shared toolchain helpers for package rules.

Provides TOOLCHAIN_ATTRS (merge into rule attrs dicts) and
toolchain_env_args() (inject CC/CXX/AR into Python helper cmd_args).

Package rules never hard-code a toolchain target.  The _toolchain attr
uses select() on tc.mode config_settings so --config tc.mode=... picks
the right toolchain at analysis time.
"""

load("//defs:providers.bzl", "BuildToolchainInfo")

def _buckos_toolchain_select():
    """Config-driven toolchain selection via select().

    Returns the appropriate toolchain target based on --config tc.mode=...
    Falls back to host toolchain when tc.mode is unset.
    """
    return select({
        "//tc/exec:mode-host": "//tc/host:host-toolchain",
        "//tc/exec:mode-cross": "//tc/cross:cross-toolchain",
        "//tc/exec:mode-bootstrap": "//tc/bootstrap:bootstrap-toolchain",
        "//tc/exec:mode-prebuilt": "//tc/prebuilt:prebuilt-toolchain",
        "DEFAULT": "//tc/host:host-toolchain",
    })

# Merge into rule attrs dicts via: attrs = { ... } | TOOLCHAIN_ATTRS
TOOLCHAIN_ATTRS = {
    "_toolchain": attrs.default_only(
        attrs.toolchain_dep(
            default = _buckos_toolchain_select(),
            providers = [BuildToolchainInfo],
        ),
    ),
}

def toolchain_env_args(ctx):
    """Return --env flag cmd_args for CC/CXX/AR from BuildToolchainInfo.

    Each returned cmd_args renders as a single argv entry like
    "CC=gcc --sysroot=/path".  Python helpers resolve relative Buck2
    artifact paths via _resolve_env_paths().
    """
    tc = ctx.attrs._toolchain[BuildToolchainInfo]
    result = []
    # delimiter=" " flattens multi-part RunInfo.args (e.g. "gcc --sysroot=/path")
    # into a single token.  Outer delimiter="" joins "CC=" prefix with the value.
    result.append(cmd_args("CC=", cmd_args(tc.cc.args, delimiter = " "), delimiter = ""))
    result.append(cmd_args("CXX=", cmd_args(tc.cxx.args, delimiter = " "), delimiter = ""))
    result.append(cmd_args("AR=", cmd_args(tc.ar.args, delimiter = " "), delimiter = ""))
    return result

def toolchain_extra_cflags(ctx):
    """Return toolchain-injected CFLAGS (e.g. hardening flags)."""
    return ctx.attrs._toolchain[BuildToolchainInfo].extra_cflags

def toolchain_extra_ldflags(ctx):
    """Return toolchain-injected LDFLAGS (e.g. -fuse-ld=mold)."""
    return ctx.attrs._toolchain[BuildToolchainInfo].extra_ldflags
