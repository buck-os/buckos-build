"""test_host_env rule: expose toolchain host tools to sh_test targets.

Reads host_bin_dir from the configured BuildToolchainInfo and generates
a wrapper script that prepends it to PATH.  Tests that need make, file,
cc, etc. depend on this target and pass its output as a wrapper via env.

When the toolchain has no host_bin_dir (bootstrap mode), the wrapper is
a passthrough that just execs its arguments.

The sysroot is included in other_outputs because host-tools-exec
binaries have ELF interpreters pointing to the sysroot ld-linux via
absolute path.  Without this, buck2 may not materialize the sysroot
when tests run, causing "required file not found" errors.
"""

load("//defs:providers.bzl", "BuildToolchainInfo")
load("//defs:toolchain_helpers.bzl", "TOOLCHAIN_ATTRS")

def _test_host_env_impl(ctx):
    tc = ctx.attrs._toolchain[BuildToolchainInfo]
    host_bin = tc.host_bin_dir
    sysroot = tc.sysroot
    wrapper = ctx.actions.declare_output("test-host-env.py")

    if host_bin:
        cmd = cmd_args(ctx.attrs._gen_tool[RunInfo])
        cmd.add(wrapper.as_output())
        cmd.add(cmd_args(hidden = host_bin))

        ctx.actions.run(
            cmd,
            env = {"_HOST_BIN_DIR": cmd_args(host_bin)},
            category = "test_host_env",
            identifier = ctx.attrs.name,
            allow_cache_upload = True,
        )
    else:
        # No host tools — passthrough wrapper
        ctx.actions.write(
            wrapper,
            ["#!/usr/bin/env python3", "import os, sys", "_test = os.environ.get('_BUCKOS_TEST', '')", "if _test:", "    os.chmod(_test, 0o755)", "    os.execv(_test, [_test] + sys.argv[1:])", "elif len(sys.argv) > 1:", "    os.execvp(sys.argv[1], sys.argv[1:])"],
            is_executable = True,
        )

    # Include host_bin_dir and sysroot in other_outputs so buck2
    # materializes both when tests run.  The sysroot is needed because
    # host-tools-exec binaries have ELF interpreters pointing to
    # sysroot/lib64/ld-linux via absolute path.
    outputs = []
    if host_bin:
        outputs.append(cmd_args(host_bin))
    if sysroot:
        outputs.append(cmd_args(sysroot))

    return [DefaultInfo(
        default_output = wrapper,
        other_outputs = outputs,
    )]

test_host_env = rule(
    impl = _test_host_env_impl,
    attrs = {
        "_gen_tool": attrs.exec_dep(default = "//tools:gen_test_host_env"),
    } | TOOLCHAIN_ATTRS,
)
