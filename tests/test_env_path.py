#!/usr/bin/env python3
"""Unit tests for tools/_env.py setup_path() and add_path_args().

Stdlib only -- no pytest.
"""

import argparse
import os
import sys
from pathlib import Path

_REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO / "tools"))

from _env import add_path_args, setup_path

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


def _make_args(**kwargs):
    """Build a namespace matching add_path_args() defaults, overriding with kwargs."""
    defaults = {
        "hermetic_path": [],
        "allow_host_path": False,
        "hermetic_empty": False,
        "path_prepend": [],
    }
    defaults.update(kwargs)
    return argparse.Namespace(**defaults)


def main():
    # -- add_path_args: registers expected arguments --
    print("=== add_path_args: registers arguments ===")
    parser = argparse.ArgumentParser()
    add_path_args(parser)
    args = parser.parse_args(["--hermetic-path", "/a", "--hermetic-path", "/b",
                              "--path-prepend", "/c"])
    if args.hermetic_path == ["/a", "/b"] and args.path_prepend == ["/c"]:
        ok("add_path_args registers --hermetic-path and --path-prepend")
    else:
        fail(f"unexpected: hermetic_path={args.hermetic_path}, path_prepend={args.path_prepend}")

    # -- add_path_args: --allow-host-path --
    print("=== add_path_args: --allow-host-path ===")
    parser2 = argparse.ArgumentParser()
    add_path_args(parser2)
    args2 = parser2.parse_args(["--allow-host-path"])
    if args2.allow_host_path is True:
        ok("--allow-host-path sets flag")
    else:
        fail(f"expected True, got {args2.allow_host_path}")

    # -- add_path_args: --hermetic-empty --
    print("=== add_path_args: --hermetic-empty ===")
    parser3 = argparse.ArgumentParser()
    add_path_args(parser3)
    args3 = parser3.parse_args(["--hermetic-empty"])
    if args3.hermetic_empty is True:
        ok("--hermetic-empty sets flag")
    else:
        fail(f"expected True, got {args3.hermetic_empty}")

    # -- setup_path: hermetic_path --
    print("=== setup_path: hermetic_path ===")
    env = {}
    setup_path(_make_args(hermetic_path=["/a", "/b"]), env)
    expected = os.path.abspath("/a") + ":" + os.path.abspath("/b")
    if env.get("PATH") == expected:
        ok(f"hermetic_path sets PATH={expected}")
    else:
        fail(f"expected PATH={expected}, got {env.get('PATH')}")

    # -- setup_path: hermetic_empty --
    print("=== setup_path: hermetic_empty ===")
    env = {}
    setup_path(_make_args(hermetic_empty=True), env)
    if env.get("PATH") == "":
        ok("hermetic_empty sets PATH=''")
    else:
        fail(f"expected PATH='', got {env.get('PATH')!r}")

    # -- setup_path: allow_host_path --
    print("=== setup_path: allow_host_path ===")
    env = {}
    setup_path(_make_args(allow_host_path=True), env, host_path="/usr/bin:/bin")
    if env.get("PATH") == "/usr/bin:/bin":
        ok("allow_host_path sets PATH to host_path")
    else:
        fail(f"expected PATH='/usr/bin:/bin', got {env.get('PATH')!r}")

    # -- setup_path: path_prepend with hermetic_path --
    print("=== setup_path: path_prepend + hermetic_path ===")
    env = {}
    setup_path(_make_args(hermetic_path=["/a"], path_prepend=["/c"]), env)
    path = env.get("PATH", "")
    c_abs = os.path.abspath("/c")
    a_abs = os.path.abspath("/a")
    expected = c_abs + ":" + a_abs
    if path == expected:
        ok(f"path_prepend prepended: {path}")
    else:
        fail(f"expected {expected}, got {path}")

    # -- setup_path: path_prepend with hermetic_empty --
    print("=== setup_path: path_prepend + hermetic_empty ===")
    env = {}
    setup_path(_make_args(hermetic_empty=True, path_prepend=["/c"]), env)
    path = env.get("PATH", "")
    c_abs = os.path.abspath("/c")
    if path == c_abs:
        ok(f"path_prepend with empty base: {path}")
    else:
        fail(f"expected {c_abs}, got {path}")

    # -- setup_path: no flags → sys.exit(1) --
    print("=== setup_path: no flags exits ===")
    env = {}
    try:
        setup_path(_make_args(), env)
        fail("expected sys.exit(1) but didn't get it")
    except SystemExit as e:
        if e.code == 1:
            ok("sys.exit(1) on no flags")
        else:
            fail(f"expected exit code 1, got {e.code}")

    # -- Summary --
    print(f"\n--- {passed} passed, {failed} failed ---")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
