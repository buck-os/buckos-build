#!/usr/bin/env python3
"""Unit tests for kernel build helper utilities."""
import io
import os
import subprocess
import sys
import shutil
import stat
import tempfile
from pathlib import Path

_REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO / "tools"))

from kernel_build import _get_krelease as build_get_krelease
from kernel_build import _gcc14_workaround as build_gcc14_workaround

from kernel_config import _gcc14_workaround as config_gcc14_workaround

# kernel_modules_install._get_krelease has a different signature (runs make),
# so we import it separately and test its subprocess-based behavior.
from kernel_modules_install import _get_krelease as modules_get_krelease

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


def _make_fake_cc(directory, version_output):
    """Create a fake 'gcc' script that prints the given version string."""
    cc_path = os.path.join(directory, "gcc")
    with open(cc_path, "w") as f:
        f.write(f"#!/bin/bash\necho '{version_output}'\n")
    os.chmod(cc_path, 0o755)
    return cc_path


def _make_fake_cc_named(directory, name, version_output):
    """Create a fake compiler script with an arbitrary name."""
    cc_path = os.path.join(directory, name)
    with open(cc_path, "w") as f:
        f.write(f"#!/bin/bash\necho '{version_output}'\n")
    os.chmod(cc_path, 0o755)
    return cc_path


def main():
    _real_stdout = sys.stdout
    _buf = io.StringIO()
    sys.stdout = _buf

    # ----------------------------------------------------------------
    # kernel_build._get_krelease tests
    # ----------------------------------------------------------------

    print("=== build_get_krelease: reads kernel.release file ===")
    with tempfile.TemporaryDirectory() as build_dir:
        release_dir = os.path.join(build_dir, "include", "config")
        os.makedirs(release_dir)
        with open(os.path.join(release_dir, "kernel.release"), "w") as f:
            f.write("6.1.0-buckos")
        result = build_get_krelease(build_dir)
        if result == "6.1.0-buckos":
            ok("reads exact release string")
        else:
            fail(f"expected '6.1.0-buckos', got {result!r}")

    print("=== build_get_krelease: strips trailing newline ===")
    with tempfile.TemporaryDirectory() as build_dir:
        release_dir = os.path.join(build_dir, "include", "config")
        os.makedirs(release_dir)
        with open(os.path.join(release_dir, "kernel.release"), "w") as f:
            f.write("6.12.5-buckos\n")
        result = build_get_krelease(build_dir)
        if result == "6.12.5-buckos":
            ok("trailing newline stripped")
        else:
            fail(f"expected '6.12.5-buckos', got {result!r}")

    print("=== build_get_krelease: strips leading/trailing whitespace ===")
    with tempfile.TemporaryDirectory() as build_dir:
        release_dir = os.path.join(build_dir, "include", "config")
        os.makedirs(release_dir)
        with open(os.path.join(release_dir, "kernel.release"), "w") as f:
            f.write("  6.8.0-rc1  \n")
        result = build_get_krelease(build_dir)
        if result == "6.8.0-rc1":
            ok("leading/trailing whitespace stripped")
        else:
            fail(f"expected '6.8.0-rc1', got {result!r}")

    print("=== build_get_krelease: missing file returns empty string ===")
    with tempfile.TemporaryDirectory() as build_dir:
        result = build_get_krelease(build_dir)
        if result == "":
            ok("missing file returns empty string")
        else:
            fail(f"expected '', got {result!r}")

    print("=== build_get_krelease: empty file returns empty string ===")
    with tempfile.TemporaryDirectory() as build_dir:
        release_dir = os.path.join(build_dir, "include", "config")
        os.makedirs(release_dir)
        with open(os.path.join(release_dir, "kernel.release"), "w") as f:
            pass  # empty
        result = build_get_krelease(build_dir)
        if result == "":
            ok("empty file returns empty string")
        else:
            fail(f"expected '', got {result!r}")

    print("=== build_get_krelease: file with only whitespace returns empty ===")
    with tempfile.TemporaryDirectory() as build_dir:
        release_dir = os.path.join(build_dir, "include", "config")
        os.makedirs(release_dir)
        with open(os.path.join(release_dir, "kernel.release"), "w") as f:
            f.write("   \n\n  ")
        result = build_get_krelease(build_dir)
        if result == "":
            ok("whitespace-only file returns empty string")
        else:
            fail(f"expected '', got {result!r}")

    print("=== build_get_krelease: directory exists but no file returns empty ===")
    with tempfile.TemporaryDirectory() as build_dir:
        os.makedirs(os.path.join(build_dir, "include", "config"))
        result = build_get_krelease(build_dir)
        if result == "":
            ok("directory without kernel.release returns empty string")
        else:
            fail(f"expected '', got {result!r}")

    # ----------------------------------------------------------------
    # kernel_build._gcc14_workaround tests
    # ----------------------------------------------------------------

    print("=== build_gcc14_workaround: GCC 14 creates wrapper ===")
    with tempfile.TemporaryDirectory() as fake_bin:
        with tempfile.TemporaryDirectory() as build_dir:
            _make_fake_cc(fake_bin, "gcc (GCC) 14.2.1 20240910")
            old_path = os.environ.get("PATH", "")
            os.environ["PATH"] = fake_bin + ":" + old_path
            try:
                result = build_gcc14_workaround(build_dir)
                if (len(result) == 1
                        and result[0].startswith("CC=")):
                    ok("GCC 14 returns CC wrapper arg")
                else:
                    fail(f"unexpected result: {result!r}")
            finally:
                os.environ["PATH"] = old_path

    print("=== build_gcc14_workaround: GCC 15 creates wrapper ===")
    with tempfile.TemporaryDirectory() as fake_bin:
        with tempfile.TemporaryDirectory() as build_dir:
            _make_fake_cc(fake_bin, "gcc (GCC) 15.1.0")
            old_path = os.environ.get("PATH", "")
            os.environ["PATH"] = fake_bin + ":" + old_path
            try:
                result = build_gcc14_workaround(build_dir)
                if len(result) == 1:
                    ok("GCC 15 also triggers wrapper")
                else:
                    fail(f"expected 1 arg, got {result!r}")
            finally:
                os.environ["PATH"] = old_path

    print("=== build_gcc14_workaround: GCC 13 returns empty ===")
    with tempfile.TemporaryDirectory() as fake_bin:
        with tempfile.TemporaryDirectory() as build_dir:
            _make_fake_cc(fake_bin, "gcc (GCC) 13.3.0")
            old_path = os.environ.get("PATH", "")
            os.environ["PATH"] = fake_bin + ":" + old_path
            try:
                result = build_gcc14_workaround(build_dir)
                if result == []:
                    ok("GCC 13 returns empty list")
                else:
                    fail(f"expected [], got {result!r}")
            finally:
                os.environ["PATH"] = old_path

    print("=== build_gcc14_workaround: clang returns empty ===")
    with tempfile.TemporaryDirectory() as fake_bin:
        with tempfile.TemporaryDirectory() as build_dir:
            _make_fake_cc(fake_bin, "clang version 18.1.8 (Fedora 18.1.8-1.fc40)")
            old_path = os.environ.get("PATH", "")
            os.environ["PATH"] = fake_bin + ":" + old_path
            try:
                result = build_gcc14_workaround(build_dir)
                if result == []:
                    ok("clang returns empty list")
                else:
                    fail(f"expected [], got {result!r}")
            finally:
                os.environ["PATH"] = old_path

    print("=== build_gcc14_workaround: wrapper contains -std=gnu11 ===")
    with tempfile.TemporaryDirectory() as fake_bin:
        with tempfile.TemporaryDirectory() as build_dir:
            _make_fake_cc(fake_bin, "gcc (GCC) 14.1.0")
            old_path = os.environ.get("PATH", "")
            os.environ["PATH"] = fake_bin + ":" + old_path
            try:
                result = build_gcc14_workaround(build_dir)
                if result:
                    wrapper_path = result[0].split("=", 1)[1]
                    with open(wrapper_path) as f:
                        content = f.read()
                    if "-std=gnu11" in content:
                        ok("wrapper script contains -std=gnu11")
                    else:
                        fail(f"wrapper missing -std=gnu11: {content!r}")
                else:
                    fail("no wrapper created")
            finally:
                os.environ["PATH"] = old_path

    print("=== build_gcc14_workaround: wrapper is executable ===")
    with tempfile.TemporaryDirectory() as fake_bin:
        with tempfile.TemporaryDirectory() as build_dir:
            _make_fake_cc(fake_bin, "gcc (GCC) 14.0.0")
            old_path = os.environ.get("PATH", "")
            os.environ["PATH"] = fake_bin + ":" + old_path
            try:
                result = build_gcc14_workaround(build_dir)
                if result:
                    wrapper_path = result[0].split("=", 1)[1]
                    mode = os.stat(wrapper_path).st_mode
                    if mode & stat.S_IXUSR:
                        ok("wrapper is executable")
                    else:
                        fail(f"wrapper not executable: mode={oct(mode)}")
                else:
                    fail("no wrapper created")
            finally:
                os.environ["PATH"] = old_path

    print("=== build_gcc14_workaround: gcc not on PATH returns empty ===")
    with tempfile.TemporaryDirectory() as build_dir:
        old_path = os.environ.get("PATH", "")
        os.environ["PATH"] = "/nonexistent"
        try:
            result = build_gcc14_workaround(build_dir)
            if result == []:
                ok("missing gcc returns empty list")
            else:
                fail(f"expected [], got {result!r}")
        finally:
            os.environ["PATH"] = old_path

    # ----------------------------------------------------------------
    # kernel_config._gcc14_workaround tests (takes cc_bin parameter)
    # ----------------------------------------------------------------

    print("=== config_gcc14_workaround: default cc_bin uses gcc ===")
    with tempfile.TemporaryDirectory() as fake_bin:
        with tempfile.TemporaryDirectory() as build_dir:
            _make_fake_cc(fake_bin, "gcc (GCC) 14.2.0")
            old_path = os.environ.get("PATH", "")
            os.environ["PATH"] = fake_bin + ":" + old_path
            try:
                result = config_gcc14_workaround(build_dir, "")
                if (len(result) == 1
                        and result[0].startswith("CC=")):
                    ok("empty cc_bin defaults to gcc and triggers wrapper")
                else:
                    fail(f"expected 1 CC arg, got {result!r}")
            finally:
                os.environ["PATH"] = old_path

    print("=== config_gcc14_workaround: custom cc_bin used ===")
    with tempfile.TemporaryDirectory() as fake_bin:
        with tempfile.TemporaryDirectory() as build_dir:
            _make_fake_cc_named(fake_bin, "my-gcc",
                                "my-gcc (GCC) 14.3.0")
            old_path = os.environ.get("PATH", "")
            os.environ["PATH"] = fake_bin + ":" + old_path
            try:
                result = config_gcc14_workaround(build_dir, "my-gcc")
                if (len(result) == 1
                        and result[0].startswith("CC=")):
                    ok("custom cc_bin triggers wrapper for GCC 14+")
                else:
                    fail(f"expected 1 CC arg, got {result!r}")
            finally:
                os.environ["PATH"] = old_path

    print("=== config_gcc14_workaround: custom cc_bin GCC 13 returns empty ===")
    with tempfile.TemporaryDirectory() as fake_bin:
        with tempfile.TemporaryDirectory() as build_dir:
            _make_fake_cc_named(fake_bin, "my-gcc",
                                "my-gcc (GCC) 13.2.0")
            old_path = os.environ.get("PATH", "")
            os.environ["PATH"] = fake_bin + ":" + old_path
            try:
                result = config_gcc14_workaround(build_dir, "my-gcc")
                if result == []:
                    ok("custom cc_bin GCC 13 returns empty list")
                else:
                    fail(f"expected [], got {result!r}")
            finally:
                os.environ["PATH"] = old_path

    print("=== config_gcc14_workaround: custom cc_bin not found returns empty ===")
    with tempfile.TemporaryDirectory() as build_dir:
        old_path = os.environ.get("PATH", "")
        os.environ["PATH"] = "/nonexistent"
        try:
            result = config_gcc14_workaround(build_dir, "no-such-gcc")
            if result == []:
                ok("nonexistent custom cc_bin returns empty list")
            else:
                fail(f"expected [], got {result!r}")
        finally:
            os.environ["PATH"] = old_path

    # ----------------------------------------------------------------
    # kernel_modules_install._get_krelease tests
    # ----------------------------------------------------------------
    # This variant runs `make -s kernelrelease` so we mock it with a
    # fake Makefile that prints a version string.

    print("=== modules_get_krelease: reads version from make kernelrelease ===")
    with tempfile.TemporaryDirectory() as build_tree:
        makefile = os.path.join(build_tree, "Makefile")
        with open(makefile, "w") as f:
            # Minimal Makefile: kernelrelease target prints version
            f.write("kernelrelease:\n\t@echo 6.11.0-buckos\n")
        result = modules_get_krelease(build_tree, "x86", "", [])
        if result == "6.11.0-buckos":
            ok("reads version from make kernelrelease")
        else:
            fail(f"expected '6.11.0-buckos', got {result!r}")

    print("=== modules_get_krelease: strips whitespace from make output ===")
    with tempfile.TemporaryDirectory() as build_tree:
        makefile = os.path.join(build_tree, "Makefile")
        with open(makefile, "w") as f:
            f.write("kernelrelease:\n\t@echo '  6.9.0-rc2  '\n")
        result = modules_get_krelease(build_tree, "x86", "", [])
        if result == "6.9.0-rc2":
            ok("make output whitespace stripped")
        else:
            fail(f"expected '6.9.0-rc2', got {result!r}")

    print("=== modules_get_krelease: broken Makefile returns None ===")
    with tempfile.TemporaryDirectory() as build_tree:
        makefile = os.path.join(build_tree, "Makefile")
        with open(makefile, "w") as f:
            f.write("kernelrelease:\n\t@exit 1\n")
        result = modules_get_krelease(build_tree, "x86", "", [])
        if result is None:
            ok("failed make returns None")
        else:
            fail(f"expected None, got {result!r}")

    print("=== modules_get_krelease: no Makefile returns None ===")
    with tempfile.TemporaryDirectory() as build_tree:
        result = modules_get_krelease(build_tree, "x86", "", [])
        if result is None:
            ok("missing Makefile returns None")
        else:
            fail(f"expected None, got {result!r}")

    # -- Summary --
    sys.stdout = _real_stdout
    if failed:
        _real_stdout.write(_buf.getvalue())
        for _line in _output_lines:
            print(_line)
        print(f"\n--- {passed} passed, {failed} failed ---")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
