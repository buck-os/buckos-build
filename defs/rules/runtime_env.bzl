"""runtime_env rule: generate a wrapper script that sets LD_LIBRARY_PATH.

Given a package target, reads its path_info tset and writes a shell
script that exports LD_LIBRARY_PATH before exec'ing its arguments.
Tests use this to run Buck2-built binaries with correct library paths.

Uses ctx.actions.run with the tset projection as a hidden input so
that all lib-dir artifacts are action inputs and must be materialised.
The same projection is propagated via other_outputs so downstream test
consumers also trigger materialisation of every transitive prefix.
"""

load("//defs:providers.bzl", "PackageInfo")

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

    ctx.actions.run(
        cmd,
        env = {"_LIB_DIRS": lib_paths},
        category = "runtime_env",
        identifier = ctx.attrs.name,
        allow_cache_upload = True,
    )

    # Propagate lib dirs as other_outputs so that test consumers also
    # materialise them — not just the wrapper script itself.
    return [DefaultInfo(
        default_output = wrapper,
        other_outputs = [cmd_args(lib_dirs_args)],
    )]

runtime_env = rule(
    impl = _runtime_env_impl,
    attrs = {
        "package": attrs.dep(providers = [PackageInfo]),
        "_gen_tool": attrs.exec_dep(default = "//tools:gen_runtime_env"),
    },
)
