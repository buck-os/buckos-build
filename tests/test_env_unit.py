#!/usr/bin/env python3
"""Unit tests for tools/_env.py.

Tests the whitelist-based environment sanitization used by build helpers.
Stdlib only -- no pytest.
"""

import os
import sys
from pathlib import Path

_REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO / "tools"))

from _env import clean_env, sanitize_global_env, _PASSTHROUGH, _DETERMINISM_PINS

passed = 0
failed = 0


def ok(msg):
    global passed
    print(f"  PASS: {msg}")
    passed += 1


def fail(msg):
    global failed
    print(f"  FAIL: {msg}")
    failed += 1


def main():
    # -- clean_env: returns only passthrough + determinism pins --
    print("=== clean_env: only expected keys ===")
    saved = dict(os.environ)
    try:
        os.environ.clear()
        os.environ["HOME"] = "/home/test"
        os.environ["PATH"] = "/usr/bin"
        os.environ["CC"] = "gcc"
        os.environ["LDFLAGS"] = "-L/usr/lib"
        env = clean_env()
        allowed = _PASSTHROUGH | _DETERMINISM_PINS.keys()
        extra = set(env.keys()) - allowed
        if not extra:
            ok("no unexpected keys in result")
        else:
            fail(f"unexpected keys: {extra}")
    finally:
        os.environ.clear()
        os.environ.update(saved)

    # -- clean_env: preserves HOME when set --
    print("=== clean_env: preserves HOME ===")
    saved = dict(os.environ)
    try:
        os.environ["HOME"] = "/home/testuser"
        env = clean_env()
        if env.get("HOME") == "/home/testuser":
            ok("HOME preserved")
        else:
            fail(f"HOME: expected '/home/testuser', got '{env.get('HOME')}'")
    finally:
        os.environ.clear()
        os.environ.update(saved)

    # -- clean_env: PATH is NOT passed through (hermetic enforcement) --
    # PATH is managed explicitly by each helper via --hermetic-path,
    # --hermetic-empty, or --allow-host-path.  clean_env() must not
    # leak host PATH into the build environment.
    print("=== clean_env: PATH not passed through ===")
    saved = dict(os.environ)
    try:
        os.environ["PATH"] = "/usr/local/bin:/usr/bin"
        env = clean_env()
        if "PATH" not in env:
            ok("PATH not in clean_env result")
        else:
            fail(f"PATH leaked into clean_env: '{env.get('PATH')}'")
    finally:
        os.environ.clear()
        os.environ.update(saved)

    # -- clean_env: preserves BUCK_SCRATCH_PATH when set --
    print("=== clean_env: preserves BUCK_SCRATCH_PATH ===")
    saved = dict(os.environ)
    try:
        os.environ["BUCK_SCRATCH_PATH"] = "/tmp/buck-scratch"
        env = clean_env()
        if env.get("BUCK_SCRATCH_PATH") == "/tmp/buck-scratch":
            ok("BUCK_SCRATCH_PATH preserved")
        else:
            fail(f"BUCK_SCRATCH_PATH: got '{env.get('BUCK_SCRATCH_PATH')}'")
    finally:
        os.environ.clear()
        os.environ.update(saved)

    # -- clean_env: omits passthrough vars not in os.environ --
    print("=== clean_env: omits unset passthrough vars ===")
    saved = dict(os.environ)
    try:
        os.environ.clear()
        # Set nothing -- all passthrough vars absent
        env = clean_env()
        present_passthrough = set(env.keys()) & _PASSTHROUGH
        if not present_passthrough:
            ok("no passthrough vars when none set")
        else:
            fail(f"unexpected passthrough vars: {present_passthrough}")
    finally:
        os.environ.clear()
        os.environ.update(saved)

    # -- clean_env: always includes all determinism pins --
    print("=== clean_env: all determinism pins present ===")
    saved = dict(os.environ)
    try:
        os.environ.clear()
        env = clean_env()
        missing = set(_DETERMINISM_PINS.keys()) - set(env.keys())
        if not missing:
            ok("all determinism pins present")
        else:
            fail(f"missing pins: {missing}")
    finally:
        os.environ.clear()
        os.environ.update(saved)

    # -- clean_env: LC_ALL is "C" --
    print("=== clean_env: LC_ALL ===")
    saved = dict(os.environ)
    try:
        env = clean_env()
        if env.get("LC_ALL") == "C":
            ok("LC_ALL is 'C'")
        else:
            fail(f"LC_ALL: expected 'C', got '{env.get('LC_ALL')}'")
    finally:
        os.environ.clear()
        os.environ.update(saved)

    # -- clean_env: SOURCE_DATE_EPOCH is "315576000" --
    print("=== clean_env: SOURCE_DATE_EPOCH ===")
    saved = dict(os.environ)
    try:
        env = clean_env()
        if env.get("SOURCE_DATE_EPOCH") == "315576000":
            ok("SOURCE_DATE_EPOCH is '315576000'")
        else:
            fail(f"SOURCE_DATE_EPOCH: got '{env.get('SOURCE_DATE_EPOCH')}'")
    finally:
        os.environ.clear()
        os.environ.update(saved)

    # -- clean_env: CCACHE_DISABLE is "1" --
    print("=== clean_env: CCACHE_DISABLE ===")
    saved = dict(os.environ)
    try:
        env = clean_env()
        if env.get("CCACHE_DISABLE") == "1":
            ok("CCACHE_DISABLE is '1'")
        else:
            fail(f"CCACHE_DISABLE: got '{env.get('CCACHE_DISABLE')}'")
    finally:
        os.environ.clear()
        os.environ.update(saved)

    # -- clean_env: RUSTC_WRAPPER is empty string --
    print("=== clean_env: RUSTC_WRAPPER ===")
    saved = dict(os.environ)
    try:
        env = clean_env()
        if "RUSTC_WRAPPER" in env and env["RUSTC_WRAPPER"] == "":
            ok("RUSTC_WRAPPER is empty string")
        else:
            fail(f"RUSTC_WRAPPER: got '{env.get('RUSTC_WRAPPER', '<missing>')}'")
    finally:
        os.environ.clear()
        os.environ.update(saved)

    # -- clean_env: does NOT leak random host vars --
    print("=== clean_env: no leaked host vars ===")
    saved = dict(os.environ)
    try:
        os.environ["CC"] = "gcc"
        os.environ["CXX"] = "g++"
        os.environ["LDFLAGS"] = "-L/usr/lib"
        os.environ["CFLAGS"] = "-O2"
        os.environ["PYTHONPATH"] = "/usr/lib/python"
        os.environ["LD_LIBRARY_PATH"] = "/usr/lib"
        os.environ["PKG_CONFIG_PATH"] = "/usr/lib/pkgconfig"
        env = clean_env()
        leaked = {"CC", "CXX", "LDFLAGS", "CFLAGS", "PYTHONPATH",
                  "LD_LIBRARY_PATH", "PKG_CONFIG_PATH"} & set(env.keys())
        if not leaked:
            ok("no leaked host vars")
        else:
            fail(f"leaked vars: {leaked}")
    finally:
        os.environ.clear()
        os.environ.update(saved)

    # -- clean_env: does NOT modify os.environ --
    print("=== clean_env: does not modify os.environ ===")
    saved = dict(os.environ)
    try:
        os.environ["CC"] = "gcc"
        os.environ["HOME"] = "/home/test"
        before = dict(os.environ)
        clean_env()
        after = dict(os.environ)
        if before == after:
            ok("os.environ unchanged after clean_env()")
        else:
            fail("os.environ modified by clean_env()")
    finally:
        os.environ.clear()
        os.environ.update(saved)

    # -- sanitize_global_env: clears non-passthrough vars --
    print("=== sanitize_global_env: clears non-passthrough ===")
    saved = dict(os.environ)
    try:
        os.environ["CC"] = "gcc"
        os.environ["CXX"] = "g++"
        os.environ["LDFLAGS"] = "-L/usr/lib"
        os.environ["HOME"] = "/home/test"
        sanitize_global_env()
        if "CC" not in os.environ and "CXX" not in os.environ and "LDFLAGS" not in os.environ:
            ok("non-passthrough vars cleared")
        else:
            remaining = {"CC", "CXX", "LDFLAGS"} & set(os.environ.keys())
            fail(f"vars not cleared: {remaining}")
    finally:
        os.environ.clear()
        os.environ.update(saved)

    # -- sanitize_global_env: preserves passthrough vars --
    print("=== sanitize_global_env: preserves passthrough ===")
    saved = dict(os.environ)
    try:
        os.environ["HOME"] = "/home/test"
        os.environ["USER"] = "testuser"
        sanitize_global_env()
        if (os.environ.get("HOME") == "/home/test"
                and os.environ.get("USER") == "testuser"):
            ok("passthrough vars preserved")
        else:
            fail("passthrough vars not preserved")
    finally:
        os.environ.clear()
        os.environ.update(saved)

    # -- sanitize_global_env: applies determinism pins --
    print("=== sanitize_global_env: applies determinism pins ===")
    saved = dict(os.environ)
    try:
        os.environ.clear()
        sanitize_global_env()
        all_present = True
        for key, val in _DETERMINISM_PINS.items():
            if os.environ.get(key) != val:
                all_present = False
                fail(f"pin {key}: expected '{val}', got '{os.environ.get(key, '<missing>')}'")
        if all_present:
            ok("all determinism pins applied to os.environ")
    finally:
        os.environ.clear()
        os.environ.update(saved)

    # -- sanitize_global_env: removes CC, CXX, LDFLAGS, CFLAGS --
    print("=== sanitize_global_env: removes build vars ===")
    saved = dict(os.environ)
    try:
        os.environ["CC"] = "gcc"
        os.environ["CXX"] = "g++"
        os.environ["LDFLAGS"] = "-L/usr/lib"
        os.environ["CFLAGS"] = "-O2"
        sanitize_global_env()
        remaining = {"CC", "CXX", "LDFLAGS", "CFLAGS"} & set(os.environ.keys())
        if not remaining:
            ok("CC/CXX/LDFLAGS/CFLAGS removed")
        else:
            fail(f"build vars not removed: {remaining}")
    finally:
        os.environ.clear()
        os.environ.update(saved)

    # -- sanitize_global_env: preserves TMPDIR, TEMP, TMP --
    print("=== sanitize_global_env: preserves temp vars ===")
    saved = dict(os.environ)
    try:
        os.environ["TMPDIR"] = "/tmp/a"
        os.environ["TEMP"] = "/tmp/b"
        os.environ["TMP"] = "/tmp/c"
        sanitize_global_env()
        if (os.environ.get("TMPDIR") == "/tmp/a"
                and os.environ.get("TEMP") == "/tmp/b"
                and os.environ.get("TMP") == "/tmp/c"):
            ok("TMPDIR/TEMP/TMP preserved")
        else:
            fail("TMPDIR/TEMP/TMP not preserved")
    finally:
        os.environ.clear()
        os.environ.update(saved)

    # -- clean_env: idempotent (multiple calls same result) --
    print("=== clean_env: idempotent ===")
    saved = dict(os.environ)
    try:
        os.environ["HOME"] = "/home/test"
        os.environ["CC"] = "gcc"
        r1 = clean_env()
        r2 = clean_env()
        if r1 == r2:
            ok("multiple calls return same result")
        else:
            fail("results differ between calls")
    finally:
        os.environ.clear()
        os.environ.update(saved)

    # -- clean_env: result has no keys outside passthrough + pins --
    print("=== clean_env: no keys outside allowed set ===")
    saved = dict(os.environ)
    try:
        # Pollute os.environ heavily
        os.environ["GOPATH"] = "/go"
        os.environ["JAVA_HOME"] = "/usr/lib/jvm"
        os.environ["npm_config_cache"] = "/tmp/npm"
        os.environ["DISPLAY"] = ":0"
        os.environ["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=/run/bus"
        env = clean_env()
        allowed = _PASSTHROUGH | _DETERMINISM_PINS.keys()
        extra = set(env.keys()) - allowed
        if not extra:
            ok("no keys outside allowed set")
        else:
            fail(f"extra keys: {extra}")
    finally:
        os.environ.clear()
        os.environ.update(saved)

    # -- BUCK: _env library has base_module="" (pex namespace regression) --
    # Without base_module="", Buck2 puts _env.py under the tools/ namespace
    # in the pex link-tree, so `from _env import ...` fails at runtime.
    print("=== BUCK: _env base_module ===")
    buck_file = _REPO / "tools" / "BUCK"
    buck_text = buck_file.read_text()
    # Look for the _env python_library block and check it has base_module = ""
    import re
    _env_block = re.search(
        r'python_library\(\s*\n(.*?)\)',
        buck_text, re.DOTALL)
    if _env_block and 'name = "_env"' in _env_block.group(0):
        if 'base_module = ""' in _env_block.group(0):
            ok('_env library has base_module = ""')
        else:
            fail('_env library missing base_module = "" — pex imports will break')
    else:
        fail("could not find _env python_library block in tools/BUCK")

    # -- Summary --
    print(f"\n--- {passed} passed, {failed} failed ---")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
