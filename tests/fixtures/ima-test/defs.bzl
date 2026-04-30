"""Genrule wrapper that portabilizes buckos-built dep binaries first.

Use for test-fixture rules that exec buckos-built ELF tools (mke2fs,
debugfs, cpio, etc.) directly.  The buckos sysroot ld-linux often
isn't present on the host, so the binaries are patchelf'd to use the
buckos loader+libs before the user cmd runs.
"""

load("//defs:providers.bzl", "PackageInfo")
load(
    "//defs:toolchain_helpers.bzl",
    "TOOLCHAIN_ATTRS",
    "toolchain_ld_linux_args",
)

# Buckos-built patchelf has an absolute PT_INTERP pointing at the seed
# sysroot ld-linux (a deterministic buck-out path), so it runs anywhere
# Buck2 has materialized that input — including CI hosts without a
# system patchelf installed.
_BUCKOS_PATCHELF = "//packages/linux/dev-tools/dev-utils/patchelf:patchelf"

def _portabilized_genrule_impl(ctx):
    out = ctx.actions.declare_output(ctx.attrs.out)

    # Collect the bin dirs we need to portabilize from each PackageInfo dep.
    # `bin_dirs_template` is e.g. ["usr/bin", "usr/sbin"] — these get
    # joined with each dep's prefix.
    cmd = cmd_args(ctx.attrs._portabilize_run[RunInfo])
    for arg in toolchain_ld_linux_args(ctx):
        cmd.add(arg)
    if PackageInfo in ctx.attrs._patchelf:
        cmd.add(
            "--patchelf",
            ctx.attrs._patchelf[PackageInfo].prefix.project("usr/bin/patchelf"),
        )
    for dep in ctx.attrs.portabilize_deps:
        if PackageInfo not in dep:
            fail("portabilize_deps entries must provide PackageInfo: {}".format(dep.label))
        # Pass the install prefix; the helper walks it for bin/sbin
        # subdirs at runtime (avoids buck2 materialization errors when
        # a dep doesn't ship every standard subdir).
        cmd.add("--prefix", dep[PackageInfo].prefix)
    cmd.add("--")
    cmd.add("bash", "-c", "set -e; " + ctx.attrs.cmd)

    # The script gets $OUT as the declared output and dep-prefix vars
    # via env (named by dep_env).  src_env maps env-var → source file.
    env = {"OUT": cmd_args(out.as_output())}
    for name, dep in ctx.attrs.dep_env.items():
        if PackageInfo not in dep:
            fail("dep_env values must provide PackageInfo: {}".format(dep.label))
        env[name] = cmd_args(dep[PackageInfo].prefix)
    for name, src in ctx.attrs.src_env.items():
        env[name] = cmd_args(src[DefaultInfo].default_outputs[0])

    ctx.actions.run(
        cmd,
        env = env,
        category = "portabilized_genrule",
        identifier = ctx.attrs.name,
    )
    return [DefaultInfo(default_output = out)]

_portabilized_genrule_rule = rule(
    impl = _portabilized_genrule_impl,
    attrs = {
        "out": attrs.string(),
        "cmd": attrs.string(),
        "portabilize_deps": attrs.list(attrs.dep(), default = []),
        # Map env-var name → PackageInfo dep (exposes its prefix dir to cmd)
        "dep_env": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        # Map env-var name → source file dep (exposes default output to cmd)
        "src_env": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        "labels": attrs.list(attrs.string(), default = []),
        "_portabilize_run": attrs.default_only(
            attrs.exec_dep(default = "//tools:portabilize_run"),
        ),
        "_patchelf": attrs.default_only(
            attrs.exec_dep(default = _BUCKOS_PATCHELF),
        ),
    } | TOOLCHAIN_ATTRS,
)

def portabilized_genrule(labels = [], **kwargs):
    _portabilized_genrule_rule(labels = labels, **kwargs)
