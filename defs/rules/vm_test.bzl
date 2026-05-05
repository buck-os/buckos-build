"""
vm_test rule: boot kernel + rootfs in QEMU, run commands, check results.

Generates a guest test script from the commands list, builds an initramfs
from the rootfs with injected binaries and the test script, then returns
ExternalRunnerTestInfo so `buck2 test` drives the QEMU invocation via
tools/vm_test_runner.py.
"""

load("//defs:providers.bzl", "KernelInfo")

_SUCCESS_MARKER = "VM_TEST_PASSED"

def _vm_test_impl(ctx):
    # -- 1. Generate the guest test script ----------------------------------
    #
    # Each command runs under `set -e` so the first failure aborts.
    # After all commands succeed, echo the success marker and poweroff.
    script_lines = ["#!/bin/sh", "set -e", ""]
    for cmd in ctx.attrs.commands:
        script_lines.append(cmd)
    script_lines.append("")
    script_lines.append("echo " + _SUCCESS_MARKER)
    script_lines.append("poweroff -f")
    script_lines.append("")

    guest_script = ctx.actions.write(
        "guest_test.sh",
        "\n".join(script_lines),
        is_executable = True,
    )

    # -- 2. Resolve kernel image --------------------------------------------
    if KernelInfo in ctx.attrs.kernel:
        kernel_out = ctx.attrs.kernel[KernelInfo].bzimage
    else:
        kernel_out = ctx.attrs.kernel[DefaultInfo].default_outputs[0]

    # -- 3. Resolve rootfs directory ----------------------------------------
    rootfs_out = ctx.attrs.rootfs[DefaultInfo].default_outputs[0]

    # -- 4. Build the test runner command -----------------------------------
    #
    # vm_test_runner.py builds the initramfs internally from the rootfs dir,
    # injected files, and guest script, then boots QEMU.
    runner = ctx.attrs._vm_test_runner[RunInfo]
    run_cmd = cmd_args(runner)
    run_cmd.add("--kernel", kernel_out)
    run_cmd.add("--rootfs", rootfs_out)
    run_cmd.add("--guest-script", guest_script)
    run_cmd.add("--timeout", str(ctx.attrs.timeout_secs))
    run_cmd.add("--memory", str(ctx.attrs.memory_mb))
    run_cmd.add("--cpus", str(ctx.attrs.cpus))
    run_cmd.add("--success-marker", _SUCCESS_MARKER)

    # Inject binaries: dict[dest_path_in_vm, dep]
    for dest_path, dep in ctx.attrs.inject_binaries.items():
        src_artifact = dep[DefaultInfo].default_outputs[0]
        run_cmd.add("--inject", cmd_args(src_artifact, ":", dest_path, delimiter = ""))

    return [
        DefaultInfo(default_output = guest_script),
        ExternalRunnerTestInfo(
            command = [run_cmd],
            type = "custom",
            labels = ctx.attrs.labels,
        ),
    ]

vm_test = rule(
    impl = _vm_test_impl,
    attrs = {
        "commands": attrs.list(attrs.string()),
        "kernel": attrs.dep(),
        "rootfs": attrs.dep(),
        "inject_binaries": attrs.dict(
            key = attrs.string(),
            value = attrs.dep(),
            default = {},
        ),
        "timeout_secs": attrs.int(default = 60),
        "memory_mb": attrs.int(default = 512),
        "cpus": attrs.int(default = 2),
        "labels": attrs.list(attrs.string(), default = []),
        "_vm_test_runner": attrs.default_only(
            attrs.exec_dep(default = "//tools:vm_test_runner"),
        ),
    },
)
