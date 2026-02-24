"""Shared toolchain helpers for package rules.

Provides TOOLCHAIN_ATTRS (merge into rule attrs dicts) and
toolchain_env_args() (inject CC/CXX/AR into Python helper cmd_args).

The _toolchain attr uses select() on the bootstrap mode constraint:
  DEFAULT        → seed toolchain (toolchains//:buckos)
  is-stage3-mode → stage 2 toolchain (stage 1 + stage 2 host tools)
  is-bootstrap-mode → host PATH toolchain (escape hatch)
"""

load("//defs:providers.bzl", "BuildToolchainInfo")

def _buckos_toolchain_select():
    """Config-driven toolchain selection via select().

    Three modes:
      DEFAULT        — seed toolchain (stage 1 cross-compiler)
      stage3         — stage 2 toolchain (hermetic rebuild)
      bootstrap      — host PATH toolchain (escape hatch)
    """
    return select({
        "//tc/exec:is-stage3-mode": "//tc/bootstrap:stage2-toolchain",
        "//tc/exec:is-bootstrap-mode": "//tc/host:host-toolchain",
        "DEFAULT": "toolchains//:buckos",
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

def toolchain_path_args(ctx):
    """Return --hermetic-path flags for hermetic builds.

    When the toolchain provides a host_bin_dir, the build runs with
    PATH replaced (not prepended) to that directory.  This ensures
    only explicitly declared tools are available.
    """
    tc = ctx.attrs._toolchain[BuildToolchainInfo]
    result = []
    if tc.host_bin_dir:
        result.append(cmd_args("--hermetic-path", tc.host_bin_dir))
    return result

def toolchain_extra_cflags(ctx):
    """Return toolchain-injected CFLAGS (e.g. hardening flags)."""
    return ctx.attrs._toolchain[BuildToolchainInfo].extra_cflags

def toolchain_extra_ldflags(ctx):
    """Return toolchain-injected LDFLAGS (e.g. -fuse-ld=mold)."""
    return ctx.attrs._toolchain[BuildToolchainInfo].extra_ldflags
