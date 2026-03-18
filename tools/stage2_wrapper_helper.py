#!/usr/bin/env python3
"""Create dynamic linker wrapper scripts for Stage 2 native binaries.

Replaces the inline bash in stage2_wrapper.bzl.  For each ELF binary in
stage2/tools/bin, generates a wrapper script that invokes the sysroot's
ld-linux with the correct library path.
"""

import argparse
import os
import shutil
import stat
import subprocess
import sys

from _env import clean_env

TARGET_TRIPLE = "x86_64-buckos-linux-gnu"

_LD_LINUX = {
    "aarch64": "lib/ld-linux-aarch64.so.1",
    "x86_64": "lib64/ld-linux-x86-64.so.2",
}


def _ld_linux_subpath(triple):
    arch = triple.split("-")[0]
    return _LD_LINUX.get(arch, _LD_LINUX["x86_64"])


def _is_elf(path):
    """Check if a file is an ELF binary."""
    try:
        with open(path, "rb") as f:
            return f.read(4) == b"\x7fELF"
    except (OSError, IOError):
        return False


_WRAPPER_TEMPLATE = """\
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYSROOT="${{SCRIPT_DIR}}/../{triple}/sys-root"
TOOL_NAME="$(basename "$0")"
REAL_TOOL="${{SCRIPT_DIR}}/../../.stage2-real/tools/bin/${{TOOL_NAME}}"

# Library paths for the dynamic linker
LIB_PATH="$SYSROOT/usr/lib64:$SYSROOT/lib64:$SYSROOT/usr/lib:$SYSROOT/lib"

# Invoke the sysroot's dynamic linker to run the stage2 binary
exec "$SYSROOT/{ld_linux}" \\
    --library-path "$LIB_PATH" \\
    "$REAL_TOOL" "$@"
"""


def main():
    parser = argparse.ArgumentParser(description="Create stage2 wrapper scripts")
    parser.add_argument("--stage2-dir", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--target-triple", default=TARGET_TRIPLE)
    args = parser.parse_args()

    env = clean_env()
    project_root = os.getcwd()
    stage2_dir = os.path.join(project_root, args.stage2_dir) if not os.path.isabs(args.stage2_dir) else args.stage2_dir
    output_dir = os.path.join(project_root, args.output_dir) if not os.path.isabs(args.output_dir) else args.output_dir
    triple = args.target_triple

    # Create directory structure
    tools_bin = os.path.join(output_dir, "tools", "bin")
    sysroot_dir = os.path.join(output_dir, "tools", triple, "sys-root")
    os.makedirs(tools_bin, exist_ok=True)
    os.makedirs(sysroot_dir, exist_ok=True)

    # Copy/symlink sysroot
    stage2_sysroot = os.path.join(stage2_dir, "tools", triple, "sys-root")
    if os.path.isdir(stage2_sysroot):
        for item in os.listdir(stage2_sysroot):
            src = os.path.join(stage2_sysroot, item)
            dst = os.path.join(sysroot_dir, item)
            try:
                os.symlink(src, dst)
            except OSError:
                if os.path.isdir(src):
                    shutil.copytree(src, dst, symlinks=True)
                else:
                    shutil.copy2(src, dst)

    # Generate wrappers for each tool
    stage2_bin = os.path.join(stage2_dir, "tools", "bin")
    if os.path.isdir(stage2_bin):
        for name in sorted(os.listdir(stage2_bin)):
            tool = os.path.join(stage2_bin, name)
            if not os.path.isfile(tool) or not os.access(tool, os.X_OK):
                continue
            wrapper_path = os.path.join(tools_bin, name)

            if _is_elf(tool):
                wrapper_content = _WRAPPER_TEMPLATE.format(
                    triple=triple,
                    ld_linux=_ld_linux_subpath(triple),
                )
                with open(wrapper_path, "w") as f:
                    f.write(wrapper_content)
                os.chmod(wrapper_path, 0o755)
            else:
                # Scripts and symlinks: passthrough
                try:
                    os.symlink(tool, wrapper_path)
                except OSError:
                    shutil.copy2(tool, wrapper_path)

    # Create .stage2-real symlink
    stage2_real = os.path.join(output_dir, ".stage2-real")
    try:
        os.symlink(stage2_dir, stage2_real)
    except OSError:
        pass


if __name__ == "__main__":
    main()
