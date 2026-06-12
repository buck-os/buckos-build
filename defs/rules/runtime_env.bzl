"""runtime_env rule: generate a wrapper script that sets LD_LIBRARY_PATH.

Given a package target, reads its path_info tset and writes a shell
script that exports LD_LIBRARY_PATH before exec'ing its arguments.
Tests use this to run Buck2-built binaries with correct library paths.

Uses ctx.actions.run with the tset projection as a hidden input so
that all lib-dir artifacts are action inputs and must be materialised.
The same projection is propagated via other_outputs so downstream test
consumers also trigger materialisation of every transitive prefix.

Also portabilizes the package's binaries before exec, so buckos-built
ELFs (whose PT_INTERP points at the buckos sysroot ld-linux) can run
on CI hosts that don't have the buckos loader installed at /lib*/.
"""

load("//defs:providers.bzl", "BuildToolchainInfo", "PackageInfo")
load("//defs:toolchain_helpers.bzl", "TOOLCHAIN_ATTRS")

def _ld_linux_path(ctx):
    """Return the package's sysroot ld-linux artifact, or None if unavailable."""
    tc = ctx.attrs._toolchain[BuildToolchainInfo]
    if not tc.sysroot:
        return None
    triple = tc.target_triple
    if triple.startswith("aarch64"):
        sub = "lib/ld-linux-aarch64.so.1"
    else:
        sub = "lib64/ld-linux-x86-64.so.2"
    return tc.sysroot.project(sub)

def _runtime_env_impl(ctx):
    pkg = ctx.attrs.package[PackageInfo]
    wrapper = ctx.actions.declare_output("run-env.sh")

    path_tset = pkg.path_info
    if path_tset:
        # Tset lib_dirs projection gives {prefix}/usr/lib64 and
        # {prefix}/usr/lib for this package and all transitive deps.
        lib_dirs_args = path_tset.project_as_args("lib_dirs", ordering = "preorder")
        lib_paths = cmd_args(lib_dirs_args, delimiter = ":")
    else:
        # Bootstrap fallback — derive lib dirs from prefix directly.
        prefix = pkg.prefix
        lib_dirs_args = cmd_args([
            cmd_args(prefix, format = "{}/usr/lib64"),
            cmd_args(prefix, format = "{}/usr/lib"),
        ])
        lib_paths = cmd_args(lib_dirs_args, delimiter = ":")

    cmd = cmd_args(ctx.attrs._gen_tool[RunInfo])
    cmd.add(wrapper.as_output())
    # Hidden dep forces Buck2 to materialise every lib dir before running.
    cmd.add(cmd_args(hidden = lib_dirs_args))

    env = {"_LIB_DIRS": lib_paths}

    # Everything a downstream consumer must materialise to actually *run*
    # the wrapper, propagated via other_outputs.  The lib dirs alone are
    # not enough once the wrapper hands off to portabilize_run.
    runtime_inputs = [cmd_args(lib_dirs_args)]

    # Plumb portabilization inputs if the toolchain exposes a sysroot.
    # Bootstrap toolchains have no sysroot; for them we skip portabilize
    # and the wrapper just sets LD_LIBRARY_PATH.
    ld_linux = _ld_linux_path(ctx)
    if ld_linux:
        if PackageInfo not in ctx.attrs._patchelf:
            fail("runtime_env: _patchelf dep must provide PackageInfo (got {})".format(
                ctx.attrs._patchelf.label,
            ))
        patchelf = ctx.attrs._patchelf[PackageInfo].prefix.project("usr/bin/patchelf")
        # portabilize_run is an *inplace* PEX: run-env.sh raw-exec's it
        # (os.execvp), so its bootstrap imports the bundled __par__ runtime
        # tree.  The whole RunInfo (stub + tree) has to be materialised, not
        # just default_outputs[0] (the bootstrap stub) — otherwise the exec
        # dies with "No module named '__par__'" (tree missing) or
        # FileNotFoundError (stub missing) on a clean runner.
        portabilize_run = ctx.attrs._portabilize_run[DefaultInfo].default_outputs[0]
        env["_LD_LINUX"] = cmd_args(ld_linux)
        env["_PATCHELF"] = cmd_args(patchelf)
        env["_PORTABILIZE_RUN"] = cmd_args(portabilize_run)
        env["_PREFIX"] = cmd_args(pkg.prefix)
        # Force materialisation at *build* time (gen-action inputs).
        cmd.add(cmd_args(hidden = [
            ld_linux,
            patchelf,
            cmd_args(ctx.attrs._portabilize_run[RunInfo]),
            pkg.prefix,
            ctx.attrs._patchelf[PackageInfo].prefix,
        ]))
        # ...and at *consume* time — this is the fix.  A test that depends on
        # this target's DefaultInfo otherwise never pulls the portabilize
        # toolchain, so os.execvp(portabilize_run.pex) finds nothing.
        # (patchelf is intentionally omitted: portabilize_run no longer uses
        # it — it portabilizes via ld-linux wrapper scripts.)
        runtime_inputs.extend([
            ld_linux,
            cmd_args(ctx.attrs._portabilize_run[RunInfo]),
            pkg.prefix,
        ])

    ctx.actions.run(
        cmd,
        env = env,
        category = "runtime_env",
        identifier = ctx.attrs.name,
        allow_cache_upload = True,
    )

    # Propagate every runtime input as other_outputs so test consumers
    # materialise the full toolchain, not just the wrapper script itself.
    return [DefaultInfo(
        default_output = wrapper,
        other_outputs = runtime_inputs,
    )]

runtime_env = rule(
    impl = _runtime_env_impl,
    attrs = {
        "package": attrs.dep(providers = [PackageInfo]),
        "_gen_tool": attrs.exec_dep(default = "//tools:gen_runtime_env"),
        "_patchelf": attrs.exec_dep(
            default = "//packages/linux/dev-tools/dev-utils/patchelf:patchelf",
        ),
        "_portabilize_run": attrs.exec_dep(default = "//tools:portabilize_run"),
    } | TOOLCHAIN_ATTRS,
)
