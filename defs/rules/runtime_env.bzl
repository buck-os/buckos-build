"""runtime_env rule: generate a wrapper script that sets LD_LIBRARY_PATH.

Given a package target, reads its runtime_lib_dirs and writes a shell
script that exports LD_LIBRARY_PATH before exec'ing its arguments.
Tests use this to run Buck2-built binaries with correct library paths.

Uses ctx.actions.run so that all lib-dir artifacts are action inputs
and must be materialised — stronger than write+allow_args whose
other_outputs may not survive daemon restarts or garbage collection.
"""

load("//defs:providers.bzl", "PackageInfo")

def _runtime_env_impl(ctx):
    pkg = ctx.attrs.package[PackageInfo]
    lib_dirs = list(pkg.runtime_lib_dirs)

    wrapper = ctx.actions.declare_output("run-env.sh")

    # cmd_args resolves artifacts to their relative paths.
    lib_paths = cmd_args(lib_dirs, delimiter = ":")

    cmd = cmd_args(ctx.attrs._gen_tool[RunInfo])
    cmd.add(wrapper.as_output())
    # Hidden dep forces Buck2 to materialise every lib dir before running.
    cmd.add(cmd_args(hidden = lib_dirs))

    ctx.actions.run(
        cmd,
        env = {"_LIB_DIRS": lib_paths},
        category = "runtime_env",
        identifier = ctx.attrs.name,
    )

    # Propagate lib dirs as other_outputs so that test consumers also
    # materialise them — not just the wrapper script itself.
    return [DefaultInfo(
        default_output = wrapper,
        other_outputs = [cmd_args(lib_dirs)],
    )]

runtime_env = rule(
    impl = _runtime_env_impl,
    attrs = {
        "package": attrs.dep(providers = [PackageInfo]),
        "_gen_tool": attrs.exec_dep(default = "//tools:gen_runtime_env"),
    },
)
