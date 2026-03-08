#!/usr/bin/env python3
"""Unit tests for language-specific build helper utilities."""
import io
import os
import sys
import tempfile
from pathlib import Path

_REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO / "tools"))

from cargo_helper import _resolve_env_paths as cargo_resolve
from go_helper import _resolve_env_paths as go_resolve
from python_helper import _resolve_env_paths as python_resolve
from meson_helper import _resolve_env_paths as meson_resolve
from cmake_helper import _resolve_env_paths as cmake_resolve
from mozbuild_helper import _build_dep_env, _write_mozconfig, _resolve

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

    saved_cwd = os.getcwd()
    tmpdir = tempfile.mkdtemp(prefix="test-lang-helpers-")

    try:
        os.chdir(tmpdir)

        # Create fake filesystem entries so os.path.exists returns True
        os.makedirs("buck-out/v2/gen/lib", exist_ok=True)
        os.makedirs("buck-out/v2/gen/include", exist_ok=True)
        os.makedirs("some/rel/dir", exist_ok=True)
        ep = tmpdir  # expected prefix

        # ==============================================================
        # Simple _resolve_env_paths (cargo, go, python)
        # These split on whitespace, handle --flag=path and bare paths.
        # No colon-path or -I/-L support.
        # ==============================================================

        simple_resolvers = [
            ("cargo", cargo_resolve),
            ("go", go_resolve),
            ("python", python_resolve),
        ]

        print("=== simple resolvers: --flag=existing_path resolved ===")
        for name, resolve in simple_resolvers:
            result = resolve("--sysroot=buck-out/v2/gen/lib")
            check(result == f"--sysroot={ep}/buck-out/v2/gen/lib",
                  f"{name}: --flag= existing path -> {result}")

        print("=== simple resolvers: --flag=nonexistent unchanged ===")
        for name, resolve in simple_resolvers:
            result = resolve("--sysroot=no/such/path")
            check(result == "--sysroot=no/such/path",
                  f"{name}: --flag= nonexistent unchanged -> {result}")

        print("=== simple resolvers: --flag=/abs unchanged ===")
        for name, resolve in simple_resolvers:
            result = resolve("--prefix=/opt/buckos")
            check(result == "--prefix=/opt/buckos",
                  f"{name}: --flag= abs unchanged -> {result}")

        print("=== simple resolvers: bare existing path resolved ===")
        for name, resolve in simple_resolvers:
            result = resolve("buck-out/v2/gen/lib")
            check(result == f"{ep}/buck-out/v2/gen/lib",
                  f"{name}: bare existing -> {result}")

        print("=== simple resolvers: bare nonexistent unchanged ===")
        for name, resolve in simple_resolvers:
            result = resolve("-O2")
            check(result == "-O2",
                  f"{name}: bare nonexistent -> {result}")

        print("=== simple resolvers: multi-token ===")
        for name, resolve in simple_resolvers:
            result = resolve("--sysroot=buck-out/v2/gen/lib -O2 buck-out/v2/gen/include")
            check(
                result == f"--sysroot={ep}/buck-out/v2/gen/lib -O2 {ep}/buck-out/v2/gen/include",
                f"{name}: multi-token -> {result}")

        print("=== simple resolvers: consistency across all three ===")
        test_inputs = [
            "--sysroot=buck-out/v2/gen/lib",
            "buck-out/v2/gen/lib",
            "-O2",
            "--prefix=/opt",
            "--sysroot=no/such/path",
            "buck-out/v2/gen/lib -O2 --sysroot=buck-out/v2/gen/include",
        ]
        for inp in test_inputs:
            results = [resolve(inp) for _, resolve in simple_resolvers]
            check(len(set(results)) == 1,
                  f"all simple resolvers agree on {inp!r}: {results[0]}")

        # ==============================================================
        # Enhanced _resolve_env_paths (meson, cmake)
        # Also handles colon paths, -I, -L, -Wl,-rpath* prefixes.
        # ==============================================================

        enhanced_resolvers = [
            ("meson", meson_resolve),
            ("cmake", cmake_resolve),
        ]

        print("=== enhanced resolvers: colon-separated buck-out paths ===")
        for name, resolve in enhanced_resolvers:
            result = resolve("buck-out/v2/gen/lib:buck-out/v2/gen/include")
            check(
                result == f"{ep}/buck-out/v2/gen/lib:{ep}/buck-out/v2/gen/include",
                f"{name}: colon buck-out -> {result}")

        print("=== enhanced resolvers: colon mixed abs+rel ===")
        for name, resolve in enhanced_resolvers:
            result = resolve("/usr/lib:buck-out/v2/gen/lib")
            check(
                result == f"/usr/lib:{ep}/buck-out/v2/gen/lib",
                f"{name}: colon mixed -> {result}")

        print("=== enhanced resolvers: colon all absolute unchanged ===")
        for name, resolve in enhanced_resolvers:
            result = resolve("/usr/lib:/opt/lib")
            check(result == "/usr/lib:/opt/lib",
                  f"{name}: colon abs unchanged -> {result}")

        print("=== enhanced resolvers: -I with buck-out ===")
        for name, resolve in enhanced_resolvers:
            result = resolve("-Ibuck-out/v2/gen/include")
            check(
                result == f"-I{ep}/buck-out/v2/gen/include",
                f"{name}: -I buck-out -> {result}")

        print("=== enhanced resolvers: -L with existing path ===")
        for name, resolve in enhanced_resolvers:
            result = resolve("-Lbuck-out/v2/gen/lib")
            check(
                result == f"-L{ep}/buck-out/v2/gen/lib",
                f"{name}: -L existing -> {result}")

        print("=== enhanced resolvers: -Wl,-rpath-link, ===")
        for name, resolve in enhanced_resolvers:
            result = resolve("-Wl,-rpath-link,buck-out/v2/gen/lib")
            check(
                result == f"-Wl,-rpath-link,{ep}/buck-out/v2/gen/lib",
                f"{name}: -Wl,-rpath-link -> {result}")

        print("=== enhanced resolvers: -Wl,-rpath, ===")
        for name, resolve in enhanced_resolvers:
            result = resolve("-Wl,-rpath,buck-out/v2/gen/lib")
            check(
                result == f"-Wl,-rpath,{ep}/buck-out/v2/gen/lib",
                f"{name}: -Wl,-rpath -> {result}")

        print("=== enhanced resolvers: -I absolute unchanged ===")
        for name, resolve in enhanced_resolvers:
            result = resolve("-I/usr/include")
            check(result == "-I/usr/include",
                  f"{name}: -I abs unchanged -> {result}")

        print("=== enhanced resolvers: --flag=existing resolved ===")
        for name, resolve in enhanced_resolvers:
            result = resolve("--with-sysroot=buck-out/v2/gen/lib")
            check(
                result == f"--with-sysroot={ep}/buck-out/v2/gen/lib",
                f"{name}: --flag= existing -> {result}")

        print("=== enhanced resolvers: bare existing path ===")
        for name, resolve in enhanced_resolvers:
            result = resolve("some/rel/dir")
            check(
                result == f"{ep}/some/rel/dir",
                f"{name}: bare existing -> {result}")

        print("=== enhanced resolvers: bare nonexistent unchanged ===")
        for name, resolve in enhanced_resolvers:
            result = resolve("-O2")
            check(result == "-O2",
                  f"{name}: -O2 unchanged -> {result}")

        print("=== enhanced resolvers: multi-token with -I -L ===")
        for name, resolve in enhanced_resolvers:
            result = resolve("-Ibuck-out/v2/gen/include -Lbuck-out/v2/gen/lib -O2")
            check(
                result == f"-I{ep}/buck-out/v2/gen/include -L{ep}/buck-out/v2/gen/lib -O2",
                f"{name}: multi -I -L -> {result}")

        print("=== enhanced resolvers: consistency between meson and cmake ===")
        enhanced_inputs = [
            "buck-out/v2/gen/lib:buck-out/v2/gen/include",
            "-Ibuck-out/v2/gen/include",
            "-Lbuck-out/v2/gen/lib",
            "-Wl,-rpath,buck-out/v2/gen/lib",
            "--with-sysroot=buck-out/v2/gen/lib",
            "-O2",
            "/usr/lib:/opt/lib",
        ]
        for inp in enhanced_inputs:
            results = [resolve(inp) for _, resolve in enhanced_resolvers]
            check(len(set(results)) == 1,
                  f"meson/cmake agree on {inp!r}: {results[0]}")

        # ==============================================================
        # Divergence: simple vs enhanced on colon-separated input
        # Simple resolvers treat colon as part of a token; enhanced
        # resolvers split on colons first. Document this.
        # ==============================================================

        print("=== divergence: simple resolvers don't split on colons ===")
        colon_input = "buck-out/v2/gen/lib:buck-out/v2/gen/include"
        # Simple resolvers: the whole string is a single token.  It
        # contains "/" so it's checked via os.path.exists — which fails
        # for the colon-joined value, so it passes through unchanged.
        for name, resolve in simple_resolvers:
            result = resolve(colon_input)
            check(result == colon_input,
                  f"{name}: colon input passed through unchanged -> {result}")

        # Enhanced resolvers resolve each component:
        for name, resolve in enhanced_resolvers:
            result = resolve(colon_input)
            check(
                result == f"{ep}/buck-out/v2/gen/lib:{ep}/buck-out/v2/gen/include",
                f"{name}: colon input resolved per-component -> {result}")

        # ==============================================================
        # mozbuild_helper._resolve
        # ==============================================================

        print("=== _resolve: relative path becomes absolute ===")
        result = _resolve("buck-out/v2/gen/lib")
        check(result == f"{ep}/buck-out/v2/gen/lib",
              f"_resolve relative -> {result}")

        print("=== _resolve: absolute path unchanged ===")
        result = _resolve("/usr/lib")
        check(result == "/usr/lib",
              f"_resolve absolute -> {result}")

        # ==============================================================
        # mozbuild_helper._write_mozconfig
        # ==============================================================

        print("=== _write_mozconfig: writes ac_add_options lines ===")
        mozconfig_path = os.path.join(tmpdir, "test_mozconfig")
        options = ["--enable-application=browser", "--disable-debug", "--enable-optimize"]
        _write_mozconfig(mozconfig_path, options)
        with open(mozconfig_path) as f:
            content = f.read()
        lines = content.strip().split("\n")
        check(len(lines) == 3,
              f"_write_mozconfig wrote {len(lines)} lines (expected 3)")

        check(lines[0] == "ac_add_options --enable-application=browser",
              f"line 0: {lines[0]!r}")
        check(lines[1] == "ac_add_options --disable-debug",
              f"line 1: {lines[1]!r}")
        check(lines[2] == "ac_add_options --enable-optimize",
              f"line 2: {lines[2]!r}")

        print("=== _write_mozconfig: empty options writes empty file ===")
        empty_path = os.path.join(tmpdir, "empty_mozconfig")
        _write_mozconfig(empty_path, [])
        with open(empty_path) as f:
            content = f.read()
        check(content == "",
              f"empty options -> empty file: {content!r}")

        # ==============================================================
        # mozbuild_helper._build_dep_env
        # ==============================================================

        print("=== _build_dep_env: pkg-config paths discovered ===")
        dep_dir = os.path.join(tmpdir, "dep1")
        for subdir in ["usr/lib/pkgconfig", "usr/lib64/pkgconfig",
                        "usr/share/pkgconfig", "usr/bin", "usr/sbin",
                        "usr/lib64", "usr/lib", "usr/include"]:
            os.makedirs(os.path.join(dep_dir, subdir), exist_ok=True)

        env = _build_dep_env([dep_dir], None, base_path="/usr/bin")
        pc_path = env.get("PKG_CONFIG_PATH", "")
        check(os.path.join(dep_dir, "usr/lib64/pkgconfig") in pc_path,
              f"lib64/pkgconfig in PKG_CONFIG_PATH")
        check(os.path.join(dep_dir, "usr/lib/pkgconfig") in pc_path,
              f"lib/pkgconfig in PKG_CONFIG_PATH")
        check(os.path.join(dep_dir, "usr/share/pkgconfig") in pc_path,
              f"share/pkgconfig in PKG_CONFIG_PATH")

        print("=== _build_dep_env: dep bin dirs NOT added to PATH ===")
        path = env.get("PATH", "")
        check(os.path.join(dep_dir, "usr/bin") not in path,
              "dep usr/bin not in PATH (deps provide libs, not build tools)")

        print("=== _build_dep_env: LIBRARY_PATH set from lib dirs ===")
        lib_path = env.get("LIBRARY_PATH", "")
        check(os.path.join(dep_dir, "usr/lib64") in lib_path,
              f"usr/lib64 in LIBRARY_PATH")
        check(os.path.join(dep_dir, "usr/lib") in lib_path,
              f"usr/lib in LIBRARY_PATH")

        print("=== _build_dep_env: include paths in C_INCLUDE_PATH ===")
        inc_path = env.get("C_INCLUDE_PATH", "")
        check(os.path.join(dep_dir, "usr/include") in inc_path,
              f"usr/include in C_INCLUDE_PATH")
        cplus = env.get("CPLUS_INCLUDE_PATH", "")
        check(os.path.join(dep_dir, "usr/include") in cplus,
              f"usr/include in CPLUS_INCLUDE_PATH")

        print("=== _build_dep_env: DEP_BASE_DIRS set ===")
        check(env.get("DEP_BASE_DIRS") == dep_dir,
              f"DEP_BASE_DIRS == dep_dir")

        print("=== _build_dep_env: multiple dep dirs ===")
        dep_dir2 = os.path.join(tmpdir, "dep2")
        os.makedirs(os.path.join(dep_dir2, "usr/lib/pkgconfig"), exist_ok=True)
        os.makedirs(os.path.join(dep_dir2, "usr/include"), exist_ok=True)
        env2 = _build_dep_env([dep_dir, dep_dir2], None, base_path="/usr/bin")
        check(
            dep_dir in env2["DEP_BASE_DIRS"] and dep_dir2 in env2["DEP_BASE_DIRS"],
            f"both dep dirs in DEP_BASE_DIRS")
        check(
            os.path.join(dep_dir2, "usr/lib/pkgconfig") in env2.get("PKG_CONFIG_PATH", ""),
            f"dep2 pkgconfig in PKG_CONFIG_PATH")

        print("=== _build_dep_env: existing PKG_CONFIG_PATH appended ===")
        env3 = _build_dep_env([dep_dir], "/existing/pc", base_path="/usr/bin")
        check(
            env3.get("PKG_CONFIG_PATH", "").endswith("/existing/pc"),
            f"existing PKG_CONFIG_PATH appended: {env3.get('PKG_CONFIG_PATH', '')[-30:]}")

        print("=== _build_dep_env: empty dep dirs -> minimal env ===")
        empty_dep = os.path.join(tmpdir, "empty_dep")
        os.makedirs(empty_dep, exist_ok=True)
        env4 = _build_dep_env([empty_dep], None, base_path="/usr/bin")
        check("PKG_CONFIG_PATH" not in env4,
              "no PKG_CONFIG_PATH for empty dep dir")
        check("PATH" not in env4,
              "no PATH for empty dep dir (no usr/bin)")
        check(env4["DEP_BASE_DIRS"] == empty_dep,
              "DEP_BASE_DIRS always set")

        print("=== _build_dep_env: no base_path -> no PATH set ===")
        env5 = _build_dep_env([dep_dir], None, base_path=None)
        check("PATH" not in env5,
              "no base_path and no dep bins -> no PATH set")

    finally:
        os.chdir(saved_cwd)

    sys.stdout = _real_stdout
    if failed:
        _real_stdout.write(_buf.getvalue())
        for _line in _output_lines:
            print(_line)
        print(f"\n--- {passed} passed, {failed} failed ---")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
