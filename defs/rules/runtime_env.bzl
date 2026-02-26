"""runtime_env rule: generate a wrapper script that sets LD_LIBRARY_PATH.

Given a package target, reads its runtime_lib_dirs and writes a shell
script that exports LD_LIBRARY_PATH before exec'ing its arguments.
Tests use this to run Buck2-built binaries with correct library paths.
"""

load("//defs:providers.bzl", "PackageInfo")

def _runtime_env_impl(ctx):
    pkg = ctx.attrs.package[PackageInfo]
    lib_dirs = list(pkg.runtime_lib_dirs)

    wrapper = ctx.actions.declare_output("run-env.sh")
    content = cmd_args()
    content.add("#!/bin/sh\n")
    # Buck2 cmd_args produce relative paths.  Resolve them to absolute
    # so the dynamic linker finds libraries regardless of CWD or when
    # outputs are materialised from remote cache.
    content.add(cmd_args(
        "_rel=\"",
        cmd_args(lib_dirs, delimiter = ":"),
        "\"\n",
        delimiter = "",
    ))
    content.add("_abs=\"\"\n")
    content.add("IFS=:\n")
    content.add("for _d in $_rel; do\n")
    content.add("  case \"$_d\" in /*) _abs=\"${_abs:+$_abs:}$_d\" ;; *) _abs=\"${_abs:+$_abs:}$PWD/$_d\" ;; esac\n")
    content.add("done\n")
    content.add("export LD_LIBRARY_PATH=\"$_abs\"\n")
    content.add("exec \"$@\"\n")

    script, hidden = ctx.actions.write(
        wrapper,
        content,
        is_executable = True,
        allow_args = True,
    )
    return [DefaultInfo(default_output = script, other_outputs = hidden)]

runtime_env = rule(
    impl = _runtime_env_impl,
    attrs = {
        "package": attrs.dep(providers = [PackageInfo]),
    },
)
