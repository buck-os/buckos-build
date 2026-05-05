#!/usr/bin/env python3
"""Unit tests for path resolution functions in build helpers."""

import io
import os
import sys
import tempfile
from pathlib import Path

_REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO / "tools"))

from binary_install_helper import _resolve_flag_paths, _resolve_colon_paths
from configure_helper import _resolve_env_paths

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


def check(condition, msg):
    if condition:
        ok(msg)
    else:
        fail(msg)


def main():
    _real_stdout = sys.stdout
    _buf = io.StringIO()
    sys.stdout = _buf

    pr = "/proj"

    # ── _resolve_flag_paths ──────────────────────────────────────────

    print("=== _resolve_flag_paths ===")

    # 1. -I with relative path
    result = _resolve_flag_paths("-Ibuck-out/v2/include", pr)
    check(result == "-I/proj/buck-out/v2/include",
          f"-I relative: {result}")

    # 2. -I with absolute path unchanged
    result = _resolve_flag_paths("-I/usr/include", pr)
    check(result == "-I/usr/include",
          f"-I absolute: {result}")

    # 3. -L with relative path
    result = _resolve_flag_paths("-Lbuck-out/v2/lib", pr)
    check(result == "-L/proj/buck-out/v2/lib",
          f"-L relative: {result}")

    # 4. -Wl,-rpath-link, with relative path
    result = _resolve_flag_paths("-Wl,-rpath-link,buck-out/v2/lib", pr)
    check(result == "-Wl,-rpath-link,/proj/buck-out/v2/lib",
          f"-Wl,-rpath-link relative: {result}")

    # 5. -Wl,-rpath, with relative path
    result = _resolve_flag_paths("-Wl,-rpath,buck-out/v2/lib64", pr)
    check(result == "-Wl,-rpath,/proj/buck-out/v2/lib64",
          f"-Wl,-rpath relative: {result}")

    # 6. --with-sysroot=buck-out/foo resolved
    result = _resolve_flag_paths("--with-sysroot=buck-out/foo", pr)
    check(result == "--with-sysroot=/proj/buck-out/foo",
          f"--flag=buck-out: {result}")

    # 7. --with-sysroot=/abs/path unchanged
    result = _resolve_flag_paths("--with-sysroot=/abs/path", pr)
    check(result == "--with-sysroot=/abs/path",
          f"--flag=abs: {result}")

    # 8. --some-flag=not-buck-out unchanged
    result = _resolve_flag_paths("--some-flag=relative/dir", pr)
    check(result == "--some-flag=relative/dir",
          f"--flag=no-buck-out: {result}")

    # 9. Bare relative path with / resolved
    result = _resolve_flag_paths("buck-out/v2/foo/bar", pr)
    check(result == "/proj/buck-out/v2/foo/bar",
          f"bare relative path: {result}")

    # 10. Bare word without / unchanged
    result = _resolve_flag_paths("-O2", pr)
    check(result == "-O2",
          f"bare flag: {result}")

    # 11. Multiple tokens all resolved
    result = _resolve_flag_paths("-Ibuck-out/inc -Lbuck-out/lib -O2", pr)
    check(result == "-I/proj/buck-out/inc -L/proj/buck-out/lib -O2",
          f"multi token: {result}")

    # 12. Empty string
    result = _resolve_flag_paths("", pr)
    check(result == "",
          f"empty string: '{result}'")

    # 13. All absolute paths unchanged
    result = _resolve_flag_paths("-I/usr/include -L/usr/lib /usr/bin/gcc", pr)
    check(result == "-I/usr/include -L/usr/lib /usr/bin/gcc",
          f"all absolute: {result}")

    # ── _resolve_colon_paths ─────────────────────────────────────────

    print("=== _resolve_colon_paths ===")

    # 14. Single relative path
    result = _resolve_colon_paths("buck-out/v2/pkgconfig", pr)
    check(result == "/proj/buck-out/v2/pkgconfig",
          f"single relative: {result}")

    # 15. Single absolute path unchanged
    result = _resolve_colon_paths("/usr/lib/pkgconfig", pr)
    check(result == "/usr/lib/pkgconfig",
          f"single absolute: {result}")

    # 16. Multiple relative paths
    result = _resolve_colon_paths("buck-out/a:buck-out/b", pr)
    check(result == "/proj/buck-out/a:/proj/buck-out/b",
          f"multi relative: {result}")

    # 17. Mixed absolute and relative
    result = _resolve_colon_paths("/usr/lib:buck-out/v2/lib", pr)
    check(result == "/usr/lib:/proj/buck-out/v2/lib",
          f"mixed colon: {result}")

    # 18. Empty components preserved
    result = _resolve_colon_paths("buck-out/a::buck-out/b", pr)
    check(result == "/proj/buck-out/a::/proj/buck-out/b",
          f"empty components: {result}")

    # 19. Empty string
    result = _resolve_colon_paths("", pr)
    check(result == "",
          f"empty colon: '{result}'")

    # ── _resolve_env_paths (configure_helper) ────────────────────────

    print("=== _resolve_env_paths ===")

    # _resolve_env_paths uses os.path.abspath and os.path.exists, so
    # we chdir into a temp dir to control resolution.
    saved_cwd = os.getcwd()
    tmpdir = tempfile.mkdtemp()
    try:
        os.chdir(tmpdir)

        # Create a fake buck-out tree so abspath resolves predictably
        os.makedirs("buck-out/v2/gen/lib", exist_ok=True)
        os.makedirs("buck-out/v2/gen/include", exist_ok=True)

        expected_prefix = tmpdir

        # 20. Colon-separated buck-out paths resolved
        result = _resolve_env_paths("buck-out/v2/gen/lib:buck-out/v2/gen/include")
        check(
            result == f"{expected_prefix}/buck-out/v2/gen/lib:{expected_prefix}/buck-out/v2/gen/include",
            f"colon buck-out: {result}")

        # 21. Colon-separated with absolute path unchanged
        result = _resolve_env_paths("/usr/lib/pkgconfig:buck-out/v2/gen/lib")
        check(
            result == f"/usr/lib/pkgconfig:{expected_prefix}/buck-out/v2/gen/lib",
            f"colon mixed abs: {result}")

        # 22. -I with buck-out path resolved
        result = _resolve_env_paths("-Ibuck-out/v2/gen/include")
        check(
            result == f"-I{expected_prefix}/buck-out/v2/gen/include",
            f"-I buck-out: {result}")

        # 23. -L with buck-out path resolved
        result = _resolve_env_paths("-Lbuck-out/v2/gen/lib")
        check(
            result == f"-L{expected_prefix}/buck-out/v2/gen/lib",
            f"-L buck-out: {result}")

        # 24. -Wl,-rpath-link, with buck-out path resolved
        result = _resolve_env_paths("-Wl,-rpath-link,buck-out/v2/gen/lib")
        check(
            result == f"-Wl,-rpath-link,{expected_prefix}/buck-out/v2/gen/lib",
            f"-Wl,-rpath-link buck-out: {result}")

        # 25. --flag= with existing path resolved
        result = _resolve_env_paths("--with-sysroot=buck-out/v2/gen/lib")
        # --flag= branch uses os.path.exists, and buck-out/v2/gen/lib exists
        check(
            result == f"--with-sysroot={expected_prefix}/buck-out/v2/gen/lib",
            f"--flag= existing: {result}")

        # 26. Multiple space-separated tokens
        result = _resolve_env_paths("-Ibuck-out/v2/gen/include -Lbuck-out/v2/gen/lib -O2")
        check(
            result == f"-I{expected_prefix}/buck-out/v2/gen/include -L{expected_prefix}/buck-out/v2/gen/lib -O2",
            f"multi token env: {result}")

        # 27. Absolute -I path unchanged
        result = _resolve_env_paths("-I/usr/include")
        check(result == "-I/usr/include",
              f"-I abs unchanged: {result}")

        # 28. Bare existing relative path resolved
        result = _resolve_env_paths("buck-out/v2/gen/lib")
        check(
            result == f"{expected_prefix}/buck-out/v2/gen/lib",
            f"bare existing path: {result}")

        # 29. Bare nonexistent non-buck-out path unchanged
        result = _resolve_env_paths("nonexistent-thing")
        check(result == "nonexistent-thing",
              f"bare nonexistent: {result}")

        # 30. -Wl,-rpath, with buck-out path resolved
        result = _resolve_env_paths("-Wl,-rpath,buck-out/v2/gen/lib")
        check(
            result == f"-Wl,-rpath,{expected_prefix}/buck-out/v2/gen/lib",
            f"-Wl,-rpath buck-out: {result}")

        # 31. Colon-separated with nonexistent non-buck-out path unchanged
        result = _resolve_env_paths("buck-out/v2/gen/lib:/no/such/dir")
        check(
            result == f"{expected_prefix}/buck-out/v2/gen/lib:/no/such/dir",
            f"colon mixed nonexist: {result}")

        # 32. --flag= with nonexistent path unchanged
        result = _resolve_env_paths("--prefix=/opt/buckos")
        check(result == "--prefix=/opt/buckos",
              f"--flag= abs unchanged: {result}")

    finally:
        os.chdir(saved_cwd)

    # ── Summary ──────────────────────────────────────────────────────

    sys.stdout = _real_stdout
    if failed:
        _real_stdout.write(_buf.getvalue())
        for _line in _output_lines:
            print(_line)
        print(f"\n--- {passed} passed, {failed} failed ---")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
