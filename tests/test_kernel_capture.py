#!/usr/bin/env python3
"""Unit tests for kernel capture-and-replay utilities.

Tests parse_cmd_file, parse_deps, derive_output_path, resolve_make_flag,
config_has, and scan_cmd_files from tools/kernel_capture.py.
Stdlib only -- no pytest.
"""

import os
import sys
import tempfile
from pathlib import Path

_REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO / "tools"))

from kernel_capture import (
    config_has,
    derive_depfile_path,
    derive_output_path,
    parse_cmd_file,
    parse_deps,
    resolve_make_flag,
    scan_cmd_files,
)

passed = 0
failed = 0
_output_lines = []


def ok(msg):
    global passed
    _output_lines.append(f"  PASS: {msg}")
    passed += 1


def fail(msg):
    global failed
    _output_lines.append(f"  FAIL: {msg}")
    failed += 1


def main():
    # ===================================================================
    # parse_deps
    # ===================================================================

    # 1. Simple header list
    deps = parse_deps("include/linux/fs.h include/linux/types.h")
    if deps == ["include/linux/fs.h", "include/linux/types.h"]:
        ok("parse_deps: simple header list")
    else:
        fail(f"parse_deps: simple header list => {deps}")

    # 2. Strip $(wildcard ...) patterns
    deps = parse_deps(
        "$(wildcard include/config/SMP) include/linux/fs.h "
        "$(wildcard include/config/FOO) include/linux/types.h"
    )
    if deps == ["include/linux/fs.h", "include/linux/types.h"]:
        ok("parse_deps: strips $(wildcard ...)")
    else:
        fail(f"parse_deps: strips $(wildcard ...) => {deps}")

    # 3. Empty string
    deps = parse_deps("")
    if deps == []:
        ok("parse_deps: empty string")
    else:
        fail(f"parse_deps: empty string => {deps}")

    # 4. Only wildcards
    deps = parse_deps("$(wildcard include/config/A) $(wildcard include/config/B)")
    if deps == []:
        ok("parse_deps: only wildcards")
    else:
        fail(f"parse_deps: only wildcards => {deps}")

    # ===================================================================
    # parse_cmd_file
    # ===================================================================

    # 5. Standard .cmd file with savedcmd + source + deps
    with tempfile.NamedTemporaryFile(mode="w", suffix=".cmd", delete=False) as f:
        f.write(
            'savedcmd_fs/ext4/inode.o := gcc -c -o fs/ext4/inode.o fs/ext4/inode.c\n'
            '\n'
            'source_fs/ext4/inode.o := fs/ext4/inode.c\n'
            '\n'
            'deps_fs/ext4/inode.o := \\\n'
            '  include/linux/fs.h \\\n'
            '  $(wildcard include/config/EXT4) \\\n'
            '  include/linux/types.h\n'
        )
        f.flush()
        entries = parse_cmd_file(Path(f.name))
    os.unlink(f.name)

    if "fs/ext4/inode.o" in entries:
        e = entries["fs/ext4/inode.o"]
        if (e["cmd"].startswith("gcc -c") and
                e["source"] == "fs/ext4/inode.c" and
                "include/linux/fs.h" in e["deps"] and
                "include/linux/types.h" in e["deps"]):
            ok("parse_cmd_file: standard .cmd")
        else:
            fail(f"parse_cmd_file: standard .cmd => {e}")
    else:
        fail(f"parse_cmd_file: missing entry, got {list(entries.keys())}")

    # 6. cmd_ prefix (older kernel format)
    with tempfile.NamedTemporaryFile(mode="w", suffix=".cmd", delete=False) as f:
        f.write('cmd_kernel/bounds.s := gcc -S -o kernel/bounds.s kernel/bounds.c\n')
        f.flush()
        entries = parse_cmd_file(Path(f.name))
    os.unlink(f.name)

    if "kernel/bounds.s" in entries and entries["kernel/bounds.s"]["cmd"].startswith("gcc -S"):
        ok("parse_cmd_file: cmd_ prefix")
    else:
        fail(f"parse_cmd_file: cmd_ prefix => {entries}")

    # ===================================================================
    # derive_output_path
    # ===================================================================

    bt = "/home/user/build-tree"

    # 7. gcc -o output
    act = {"argv": ["gcc", "-c", "-o", "fs/ext4/inode.o", "fs/ext4/inode.c"],
           "path": "/usr/bin/gcc", "cwd": bt}
    out = derive_output_path(act, bt)
    if out == "fs/ext4/inode.o":
        ok("derive_output_path: gcc -o")
    else:
        fail(f"derive_output_path: gcc -o => {out!r}")

    # 8. ar positional output
    act = {"argv": ["ar", "cDPrST", "built-in.a", "foo.o", "bar.o"],
           "path": "/usr/bin/ar", "cwd": bt}
    out = derive_output_path(act, bt)
    if out == "built-in.a":
        ok("derive_output_path: ar positional")
    else:
        fail(f"derive_output_path: ar positional => {out!r}")

    # 9. No output flag
    act = {"argv": ["echo", "hello"], "path": "/bin/echo", "cwd": bt}
    out = derive_output_path(act, bt)
    if out == "":
        ok("derive_output_path: no -o flag")
    else:
        fail(f"derive_output_path: no -o flag => {out!r}")

    # ===================================================================
    # derive_depfile_path
    # ===================================================================

    # 10. Standard .o -> .d mapping
    d = derive_depfile_path("fs/ext4/inode.o")
    if d == "fs/ext4/.inode.o.d":
        ok("derive_depfile_path: standard .o")
    else:
        fail(f"derive_depfile_path: standard .o => {d!r}")

    # 11. Top-level file
    d = derive_depfile_path("bounds.s")
    if d == ".bounds.s.d":
        ok("derive_depfile_path: top-level")
    else:
        fail(f"derive_depfile_path: top-level => {d!r}")

    # ===================================================================
    # resolve_make_flag
    # ===================================================================

    # 12. No = sign -> passthrough
    r = resolve_make_flag("--verbose")
    if r == "--verbose":
        ok("resolve_make_flag: no = sign")
    else:
        fail(f"resolve_make_flag: no = sign => {r!r}")

    # 13. Absolute path -> unchanged
    r = resolve_make_flag("CC=/usr/bin/gcc")
    if r == "CC=/usr/bin/gcc":
        ok("resolve_make_flag: absolute path")
    else:
        fail(f"resolve_make_flag: absolute path => {r!r}")

    # 14. buck-out relative path -> resolved to absolute
    r = resolve_make_flag("CC=buck-out/v2/gen/gcc")
    if r.startswith("CC=/") and r.endswith("buck-out/v2/gen/gcc"):
        ok("resolve_make_flag: buck-out relative resolved")
    else:
        fail(f"resolve_make_flag: buck-out relative => {r!r}")

    # 15. --sysroot= prefix handling
    r = resolve_make_flag("CFLAGS=--sysroot=buck-out/v2/sysroot")
    if "--sysroot=/" in r and r.endswith("buck-out/v2/sysroot"):
        ok("resolve_make_flag: --sysroot= prefix")
    else:
        fail(f"resolve_make_flag: --sysroot= prefix => {r!r}")

    # ===================================================================
    # config_has
    # ===================================================================

    # 16. Config option present
    with tempfile.NamedTemporaryFile(mode="w", suffix=".config", delete=False) as f:
        f.write("CONFIG_MODULES=y\n# CONFIG_DEBUG is not set\nCONFIG_SMP=y\n")
        f.flush()
        if config_has(Path(f.name), "CONFIG_MODULES=y"):
            ok("config_has: present option")
        else:
            fail("config_has: present option not found")
        if not config_has(Path(f.name), "CONFIG_DEBUG=y"):
            ok("config_has: absent option")
        else:
            fail("config_has: absent option found")
    os.unlink(f.name)

    # 17. Missing file
    if not config_has(Path("/nonexistent/.config"), "CONFIG_FOO=y"):
        ok("config_has: missing file")
    else:
        fail("config_has: missing file returned True")

    # ===================================================================
    # scan_cmd_files
    # ===================================================================

    # 18. Scan a directory tree
    with tempfile.TemporaryDirectory() as d:
        # Create a few .cmd files
        os.makedirs(os.path.join(d, "fs", "ext4"))
        with open(os.path.join(d, "fs", "ext4", ".inode.o.cmd"), "w") as f:
            f.write('savedcmd_fs/ext4/inode.o := gcc -c fs/ext4/inode.c\n')
        with open(os.path.join(d, "fs", "ext4", ".super.o.cmd"), "w") as f:
            f.write('savedcmd_fs/ext4/super.o := gcc -c fs/ext4/super.c\n')
        idx = scan_cmd_files(Path(d))
        if len(idx) == 2 and "fs/ext4/inode.o" in idx and "fs/ext4/super.o" in idx:
            ok("scan_cmd_files: finds .cmd files in tree")
        else:
            fail(f"scan_cmd_files: expected 2 entries, got {len(idx)}: {list(idx.keys())}")

    # -- Summary --
    if failed:
        for line in _output_lines:
            print(line)
        print(f"\n--- {passed} passed, {failed} failed ---")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
