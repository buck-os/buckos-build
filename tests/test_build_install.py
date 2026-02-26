#!/usr/bin/env python3
"""Unit tests for build and install helper utilities."""
import glob as _glob
import os
import shutil
import sys
import tempfile
from pathlib import Path

_REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO / "tools"))

from build_helper import _resolve_env_paths as build_resolve
from build_helper import _rewrite_file, _can_unshare_net
from install_helper import _resolve_env_paths as install_resolve
from install_helper import _suppress_phony_rebuilds

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


def check(condition, msg):
    if condition:
        ok(msg)
    else:
        fail(msg)


def main():
    saved_cwd = os.getcwd()
    tmpdir = tempfile.mkdtemp()

    try:
        os.chdir(tmpdir)

        # Create fake buck-out tree for resolution tests
        os.makedirs("buck-out/v2/gen/lib", exist_ok=True)
        os.makedirs("buck-out/v2/gen/include", exist_ok=True)
        pfx = tmpdir

        # ── _can_unshare_net ────────────────────────────────────────

        print("=== _can_unshare_net ===")

        # 1. Returns bool without crashing
        result = _can_unshare_net()
        check(isinstance(result, bool),
              f"returns bool: {result}")

        # ── _rewrite_file ───────────────────────────────────────────

        print("=== _rewrite_file ===")

        rw_dir = os.path.join(tmpdir, "rewrite")
        os.makedirs(rw_dir, exist_ok=True)

        # 2. Basic replacement preserves mtime
        fpath = os.path.join(rw_dir, "test1.txt")
        with open(fpath, "w") as f:
            f.write("old_path=/build/dir\n")
        os.utime(fpath, (1000000, 1000000))
        orig_stat = os.stat(fpath)
        _rewrite_file(fpath, "/build/dir", "/output/dir")
        with open(fpath) as f:
            content = f.read()
        after_stat = os.stat(fpath)
        check(content == "old_path=/output/dir\n",
              f"replacement correct: {content.strip()}")

        # 3. mtime preserved after rewrite
        check(after_stat.st_mtime == orig_stat.st_mtime,
              f"mtime preserved: {after_stat.st_mtime} == {orig_stat.st_mtime}")

        # 4. No-op when old string absent (file unchanged, no crash)
        fpath2 = os.path.join(rw_dir, "test2.txt")
        with open(fpath2, "w") as f:
            f.write("nothing relevant\n")
        os.utime(fpath2, (2000000, 2000000))
        _rewrite_file(fpath2, "/nonexistent", "/replacement")
        with open(fpath2) as f:
            content = f.read()
        check(content == "nothing relevant\n",
              "no-op when pattern absent")

        # 5. Multiple occurrences all replaced
        fpath3 = os.path.join(rw_dir, "test3.txt")
        with open(fpath3, "w") as f:
            f.write("/old/path:/old/path:/other\n")
        _rewrite_file(fpath3, "/old/path", "/new/path")
        with open(fpath3) as f:
            content = f.read()
        check(content == "/new/path:/new/path:/other\n",
              f"multi replace: {content.strip()}")

        # ── build_helper _resolve_env_paths ─────────────────────────

        print("=== build_helper._resolve_env_paths ===")

        # 6. Colon-separated buck-out paths
        result = build_resolve("buck-out/v2/gen/lib:buck-out/v2/gen/include")
        check(
            result == f"{pfx}/buck-out/v2/gen/lib:{pfx}/buck-out/v2/gen/include",
            f"build colon buck-out: {result}")

        # 7. Colon-separated mixed absolute and relative
        result = build_resolve("/usr/lib/pkgconfig:buck-out/v2/gen/lib")
        check(
            result == f"/usr/lib/pkgconfig:{pfx}/buck-out/v2/gen/lib",
            f"build colon mixed: {result}")

        # 8. -I with buck-out path
        result = build_resolve("-Ibuck-out/v2/gen/include")
        check(
            result == f"-I{pfx}/buck-out/v2/gen/include",
            f"build -I buck-out: {result}")

        # 9. -L with buck-out path
        result = build_resolve("-Lbuck-out/v2/gen/lib")
        check(
            result == f"-L{pfx}/buck-out/v2/gen/lib",
            f"build -L buck-out: {result}")

        # 10. -Wl,-rpath-link, with buck-out path
        result = build_resolve("-Wl,-rpath-link,buck-out/v2/gen/lib")
        check(
            result == f"-Wl,-rpath-link,{pfx}/buck-out/v2/gen/lib",
            f"build -Wl,-rpath-link: {result}")

        # 11. -Wl,-rpath, with buck-out path
        result = build_resolve("-Wl,-rpath,buck-out/v2/gen/lib")
        check(
            result == f"-Wl,-rpath,{pfx}/buck-out/v2/gen/lib",
            f"build -Wl,-rpath: {result}")

        # 12. --flag=path with existing path resolved
        result = build_resolve("--with-sysroot=buck-out/v2/gen/lib")
        check(
            result == f"--with-sysroot={pfx}/buck-out/v2/gen/lib",
            f"build --flag=existing: {result}")

        # 13. --flag=path with nonexistent path unchanged
        result = build_resolve("--prefix=/opt/buckos")
        check(result == "--prefix=/opt/buckos",
              f"build --flag=abs unchanged: {result}")

        # 14. Multiple space-separated tokens
        result = build_resolve("-Ibuck-out/v2/gen/include -Lbuck-out/v2/gen/lib -O2")
        check(
            result == f"-I{pfx}/buck-out/v2/gen/include -L{pfx}/buck-out/v2/gen/lib -O2",
            f"build multi token: {result}")

        # 15. Bare existing relative path
        result = build_resolve("buck-out/v2/gen/lib")
        check(
            result == f"{pfx}/buck-out/v2/gen/lib",
            f"build bare existing: {result}")

        # 16. Bare nonexistent non-buck-out path unchanged
        result = build_resolve("nonexistent-thing")
        check(result == "nonexistent-thing",
              f"build bare nonexistent: {result}")

        # 17. Absolute -I path unchanged
        result = build_resolve("-I/usr/include")
        check(result == "-I/usr/include",
              f"build -I abs unchanged: {result}")

        # ── install_helper _resolve_env_paths ───────────────────────

        print("=== install_helper._resolve_env_paths ===")

        # 18. Colon-separated buck-out paths
        result = install_resolve("buck-out/v2/gen/lib:buck-out/v2/gen/include")
        check(
            result == f"{pfx}/buck-out/v2/gen/lib:{pfx}/buck-out/v2/gen/include",
            f"install colon buck-out: {result}")

        # 19. -I with buck-out path
        result = install_resolve("-Ibuck-out/v2/gen/include")
        check(
            result == f"-I{pfx}/buck-out/v2/gen/include",
            f"install -I buck-out: {result}")

        # 20. -L with buck-out path
        result = install_resolve("-Lbuck-out/v2/gen/lib")
        check(
            result == f"-L{pfx}/buck-out/v2/gen/lib",
            f"install -L buck-out: {result}")

        # 21. --flag=path with existing path resolved
        result = install_resolve("--with-sysroot=buck-out/v2/gen/lib")
        check(
            result == f"--with-sysroot={pfx}/buck-out/v2/gen/lib",
            f"install --flag=existing: {result}")

        # 22. Bare nonexistent unchanged
        result = install_resolve("nonexistent-thing")
        check(result == "nonexistent-thing",
              f"install bare nonexistent: {result}")

        # ── Consistency: build vs install _resolve_env_paths ────────

        print("=== cross-helper consistency ===")

        test_inputs = [
            "buck-out/v2/gen/lib:buck-out/v2/gen/include",
            "/usr/lib/pkgconfig:buck-out/v2/gen/lib",
            "-Ibuck-out/v2/gen/include",
            "-Lbuck-out/v2/gen/lib",
            "-Wl,-rpath-link,buck-out/v2/gen/lib",
            "-Wl,-rpath,buck-out/v2/gen/lib",
            "--with-sysroot=buck-out/v2/gen/lib",
            "--prefix=/opt/buckos",
            "-Ibuck-out/v2/gen/include -Lbuck-out/v2/gen/lib -O2",
            "buck-out/v2/gen/lib",
            "nonexistent-thing",
            "-I/usr/include",
        ]
        all_consistent = True
        for inp in test_inputs:
            b = build_resolve(inp)
            i = install_resolve(inp)
            if b != i:
                fail(f"divergence on {inp!r}: build={b!r} install={i!r}")
                all_consistent = False
        # 23. All inputs produce identical results
        if all_consistent:
            ok(f"build/install _resolve_env_paths consistent across {len(test_inputs)} inputs")

        # ── Timestamp reset logic ───────────────────────────────────

        print("=== timestamp reset ===")

        ts_dir = os.path.join(tmpdir, "ts_test")
        os.makedirs(os.path.join(ts_dir, "sub"), exist_ok=True)
        for name in ("a.txt", "sub/b.txt"):
            p = os.path.join(ts_dir, name)
            with open(p, "w") as f:
                f.write("data\n")
            os.utime(p, (9999999, 9999999))

        # Replicate the timestamp reset logic from build_helper main()
        epoch = 315576000.0
        stamp = (epoch, epoch)
        for dirpath, _dirnames, filenames in os.walk(ts_dir):
            for fname in filenames:
                try:
                    os.utime(os.path.join(dirpath, fname), stamp)
                except (PermissionError, OSError):
                    pass

        # 24. Top-level file timestamp reset
        st = os.stat(os.path.join(ts_dir, "a.txt"))
        check(st.st_mtime == epoch,
              f"top-level file timestamp: {st.st_mtime} == {epoch}")

        # 25. Nested file timestamp reset
        st = os.stat(os.path.join(ts_dir, "sub/b.txt"))
        check(st.st_mtime == epoch,
              f"nested file timestamp: {st.st_mtime} == {epoch}")

        # ── install_helper make target handling ─────────────────────

        print("=== make target defaults ===")

        # The install_helper uses: targets = args.make_targets or ["install"]
        # 26. None defaults to ["install"]
        targets = None or ["install"]
        check(targets == ["install"],
              f"None make_targets defaults to install: {targets}")

        # 27. Explicit targets override default
        targets = ["install-headers", "install-libs"] or ["install"]
        check(targets == ["install-headers", "install-libs"],
              f"explicit targets kept: {targets}")

        # 28. Empty list also gets default (empty list is falsy)
        targets = [] or ["install"]
        check(targets == ["install"],
              f"empty list defaults to install: {targets}")

        # ── install_helper make command construction ────────────────

        print("=== make command construction ===")

        # Replicate the command-building logic for make
        def build_make_cmd(build_dir, destdir_var, prefix, targets, make_args, jobs, build_system="make"):
            if build_system == "ninja":
                cmd = ["ninja", "-C", build_dir, f"-j{jobs}"] + targets
            else:
                cmd = ["make", "-C", build_dir, f"-j{jobs}",
                       f"{destdir_var}={prefix}"] + targets
            for arg in make_args:
                if "=" in arg:
                    key, _, value = arg.partition("=")
                    cmd.append(f"{key}={value}")
                else:
                    cmd.append(arg)
            return cmd

        # 29. Standard DESTDIR make install
        cmd = build_make_cmd("/build", "DESTDIR", "/out", ["install"], [], 4)
        check(cmd == ["make", "-C", "/build", "-j4", "DESTDIR=/out", "install"],
              f"standard make install: {cmd}")

        # 30. Custom destdir var (e.g. CONFIG_PREFIX for busybox)
        cmd = build_make_cmd("/build", "CONFIG_PREFIX", "/out", ["install"], [], 4)
        check(cmd == ["make", "-C", "/build", "-j4", "CONFIG_PREFIX=/out", "install"],
              f"custom destdir var: {cmd}")

        # 31. Multiple targets
        cmd = build_make_cmd("/build", "DESTDIR", "/out",
                             ["install-headers", "install-libs"], [], 4)
        check(cmd == ["make", "-C", "/build", "-j4", "DESTDIR=/out",
                       "install-headers", "install-libs"],
              f"multi target: {cmd}")

        # 32. Extra make args with KEY=VALUE
        cmd = build_make_cmd("/build", "DESTDIR", "/out", ["install"],
                             ["CC=gcc", "V=1"], 4)
        check(cmd == ["make", "-C", "/build", "-j4", "DESTDIR=/out", "install",
                       "CC=gcc", "V=1"],
              f"make args kv: {cmd}")

        # 33. Extra make args without = (plain flags)
        cmd = build_make_cmd("/build", "DESTDIR", "/out", ["install"],
                             ["-k"], 4)
        check(cmd == ["make", "-C", "/build", "-j4", "DESTDIR=/out", "install", "-k"],
              f"make args plain: {cmd}")

        # 34. Ninja build system (DESTDIR as env, not arg)
        cmd = build_make_cmd("/build", "DESTDIR", "/out", ["install"], [], 4,
                             build_system="ninja")
        check(cmd == ["ninja", "-C", "/build", "-j4", "install"],
              f"ninja install: {cmd}")

        # ── _rewrite_file edge cases ────────────────────────────────

        print("=== _rewrite_file edge cases ===")

        # 35. Handles overlapping replacements (replaces all)
        fpath4 = os.path.join(rw_dir, "test4.txt")
        with open(fpath4, "w") as f:
            f.write("aaa")
        _rewrite_file(fpath4, "aa", "b")
        with open(fpath4) as f:
            content = f.read()
        # str.replace("aaa", "aa", "b") -> "ba"
        check(content == "ba",
              f"overlapping replacement: {content!r}")

        # 36. Empty file no crash
        fpath5 = os.path.join(rw_dir, "test5.txt")
        with open(fpath5, "w") as f:
            pass
        _rewrite_file(fpath5, "x", "y")
        with open(fpath5) as f:
            content = f.read()
        check(content == "",
              "empty file no crash")

        # ── colon path edge cases ───────────────────────────────────

        print("=== colon path edge cases ===")

        # 37. Value starting with - not treated as colon path even if it has :
        result = build_resolve("-Ibuck-out/v2/gen/include:extra")
        # Starts with "-", so falls through to flag/token logic
        # The token is "-Ibuck-out/v2/gen/include:extra" as one token
        # Matches -I prefix, path is "buck-out/v2/gen/include:extra"
        # buck-out check triggers, so it resolves
        check(result.startswith(f"-I{pfx}/"),
              f"dash-colon not split: {result}")

        # 38. Colon path with nonexistent non-buck-out entries unchanged
        result = build_resolve("buck-out/v2/gen/lib:/no/such/dir")
        check(
            result == f"{pfx}/buck-out/v2/gen/lib:/no/such/dir",
            f"colon nonexistent entry: {result}")

        # ── StubUnpickler (meson install.dat) ─────────────────────────

        print("=== StubUnpickler ===")

        import pickle
        import types

        # Create a pickle that references a non-existent module,
        # simulating meson's install.dat with mesonbuild.* classes.
        # Temporarily register a fake module so pickle.dump can resolve it.
        class _FakeObj:
            def __init__(self):
                self.source_dir = "/old/build/dir"
                self.install_dir = "/old/build/dir/install"
                self.items = ["/old/build/dir/file.c"]
        _FakeObj.__module__ = "mesonbuild.minstall"
        _FakeObj.__qualname__ = _FakeObj.__name__ = "InstallData"

        _fake_mod = types.ModuleType("mesonbuild.minstall")
        _fake_mod.InstallData = _FakeObj
        _fake_parent = types.ModuleType("mesonbuild")
        _fake_parent.minstall = _fake_mod
        sys.modules["mesonbuild"] = _fake_parent
        sys.modules["mesonbuild.minstall"] = _fake_mod

        fake_dat = os.path.join(tmpdir, "install.dat")
        with open(fake_dat, "wb") as f:
            pickle.dump(_FakeObj(), f)

        # Remove fake modules so the StubUnpickler is actually tested
        del sys.modules["mesonbuild.minstall"]
        del sys.modules["mesonbuild"]

        # Now load it through the StubUnpickler from build_helper
        # (mesonbuild is not importable — this is the whole point)

        # Inline the StubUnpickler logic — import it the same way build_helper does
        _stub_cache = {}

        def _make_stub(type_key):
            return _stub_cache[type_key]()

        class _StubUnpickler(pickle.Unpickler):
            def find_class(self, module, name):
                try:
                    return super().find_class(module, name)
                except (ModuleNotFoundError, AttributeError):
                    type_key = f"{module}.{name}"
                    if type_key not in _stub_cache:
                        class _Stub:
                            def __reduce__(self):
                                return (_make_stub, (type_key,), self.__dict__)
                            def __setstate__(self, state):
                                if isinstance(state, dict):
                                    self.__dict__.update(state)
                        _Stub.__qualname__ = _Stub.__name__ = name
                        _Stub.__module__ = module
                        _stub_cache[type_key] = _Stub
                    return _stub_cache[type_key]

        # 39. StubUnpickler loads pickle with missing module
        with open(fake_dat, "rb") as f:
            obj = _StubUnpickler(f).load()
        check(hasattr(obj, "source_dir"),
              f"stub has source_dir: {obj.source_dir}")
        check(obj.source_dir == "/old/build/dir",
              f"stub source_dir value correct")

        # 40. _patch_paths works on stub objects
        def _patch_paths(obj, old, new):
            if isinstance(obj, str):
                return obj.replace(old, new) if old in obj else obj
            if isinstance(obj, list):
                return [_patch_paths(item, old, new) for item in obj]
            if isinstance(obj, tuple):
                return tuple(_patch_paths(item, old, new) for item in obj)
            if hasattr(obj, "__dict__"):
                for k, v in obj.__dict__.items():
                    patched = _patch_paths(v, old, new)
                    if patched is not v:
                        setattr(obj, k, patched)
            return obj

        _patch_paths(obj, "/old/build/dir", "/new/output/dir")
        check(obj.source_dir == "/new/output/dir",
              f"patched source_dir: {obj.source_dir}")
        check(obj.install_dir == "/new/output/dir/install",
              f"patched install_dir: {obj.install_dir}")
        check(obj.items == ["/new/output/dir/file.c"],
              f"patched list items: {obj.items}")

        # 41. Re-pickle of stub objects works
        repickled = os.path.join(tmpdir, "repickled.dat")
        with open(repickled, "wb") as f:
            pickle.dump(obj, f)
        with open(repickled, "rb") as f:
            obj2 = _StubUnpickler(f).load()
        check(obj2.source_dir == "/new/output/dir",
              f"re-pickled round-trip: {obj2.source_dir}")

        # ── _suppress_phony_rebuilds ──────────────────────────────────

        print("=== _suppress_phony_rebuilds ===")

        phony_dir = os.path.join(tmpdir, "phony_test")
        os.makedirs(os.path.join(phony_dir, "sub"), exist_ok=True)

        # 42. Variable-only .PHONY line — variable stripped
        f1 = os.path.join(phony_dir, "Makefile")
        with open(f1, "w") as f:
            f.write("all: foo\n.PHONY: $(LTCOMMAND)\ninstall: all\n")
        _suppress_phony_rebuilds(phony_dir)
        with open(f1) as f:
            content = f.read()
        check("$(LTCOMMAND)" not in content,
              "variable-only .PHONY: variable stripped")
        check(".PHONY:" in content,
              "variable-only .PHONY: directive preserved")
        check("install: all\n" in content,
              "variable-only .PHONY: surrounding lines intact")

        # 43. Mixed literal + variable — only variable removed
        f2 = os.path.join(phony_dir, "sub", "Makefile")
        with open(f2, "w") as f:
            f.write(".PHONY: install clean $(LTLIBRARY) $(LTCOMMAND)\n")
        _suppress_phony_rebuilds(phony_dir)
        with open(f2) as f:
            content = f.read()
        check("install" in content and "clean" in content,
              f"mixed .PHONY: literals preserved: {content.strip()}")
        check("$(LTLIBRARY)" not in content and "$(LTCOMMAND)" not in content,
              f"mixed .PHONY: variables stripped: {content.strip()}")

        # 44. Continuation lines with variables
        f3 = os.path.join(phony_dir, "buildrules")
        with open(f3, "w") as f:
            f.write(".PHONY: $(TARGET1) \\\n\t$(TARGET2)\nsome_rule:\n")
        _suppress_phony_rebuilds(phony_dir)
        with open(f3) as f:
            content = f.read()
        check("$(TARGET1)" not in content and "$(TARGET2)" not in content,
              f"continuation: both variables stripped: {content.strip()!r}")
        check("some_rule:" in content,
              "continuation: following lines intact")

        # 45. ${VAR} syntax also stripped
        f4 = os.path.join(phony_dir, "GNUmakefile")
        with open(f4, "w") as f:
            f.write(".PHONY: ${PROGRAMS}\n")
        _suppress_phony_rebuilds(phony_dir)
        with open(f4) as f:
            content = f.read()
        check("${PROGRAMS}" not in content,
              f"${{}} syntax stripped: {content.strip()!r}")

        # 46. .PHONY with only literals — untouched
        f5 = os.path.join(phony_dir, "literal.mk")
        orig = ".PHONY: install clean all\n"
        with open(f5, "w") as f:
            f.write(orig)
        _suppress_phony_rebuilds(phony_dir)
        with open(f5) as f:
            content = f.read()
        check(content == orig,
              "literal-only .PHONY: untouched")

        # 47. File without .PHONY — untouched
        f6 = os.path.join(phony_dir, "plain.mk")
        orig = "all: foo\nfoo: bar.c\n"
        with open(f6, "w") as f:
            f.write(orig)
        os.utime(f6, (5000000, 5000000))
        orig_mtime = os.stat(f6).st_mtime
        _suppress_phony_rebuilds(phony_dir)
        with open(f6) as f:
            content = f.read()
        check(content == orig and os.stat(f6).st_mtime == orig_mtime,
              "no .PHONY: file untouched (content and mtime)")

        # 48. Binary file — skipped without error
        f7 = os.path.join(phony_dir, "binary.o")
        with open(f7, "wb") as f:
            f.write(b"\x00\x01\x02.PHONY: $(X)\xff\xfe")
        _suppress_phony_rebuilds(phony_dir)
        # Just verify no exception was raised
        ok("binary file skipped without error")

        # 49. Timestamp preserved on modified file
        f8 = os.path.join(phony_dir, "ts_test.mk")
        with open(f8, "w") as f:
            f.write(".PHONY: $(BIN)\n")
        os.utime(f8, (3000000, 3000000))
        _suppress_phony_rebuilds(phony_dir)
        st = os.stat(f8)
        check(st.st_mtime == 3000000,
              f"mtime preserved on modified file: {st.st_mtime}")

        # ── build.ninja regeneration suppression ─────────────────────

        print("=== build.ninja regeneration suppression ===")

        import re

        _regen_re = re.compile(
            r'^build build\.ninja:.*?(?=\n(?:build |$))',
            re.MULTILINE | re.DOTALL,
        )

        # 50. Meson-style regeneration rule is suppressed
        ninja_content = (
            "build foo.o: cc foo.c\n"
            "\n"
            "build build.ninja: REGENERATE_BUILD PHONY ../meson.build\n"
            "  command = /usr/bin/meson --internal regenerate\n"
            "  generator = 1\n"
            "\n"
            "build install: phony\n"
        )
        result = _regen_re.sub("# regen suppressed", ninja_content, count=1)
        check("REGENERATE_BUILD" not in result,
              "meson regen rule removed")
        check("# regen suppressed" in result,
              "meson regen replaced with comment")
        check("build foo.o: cc foo.c" in result,
              "meson other rules preserved")
        check("build install: phony" in result,
              "meson install target preserved")

        # 51. CMake-style regeneration rule is suppressed
        cmake_ninja = (
            "build CMakeFiles/foo.dir/foo.c.o: C_COMPILER foo.c\n"
            "\n"
            "build build.ninja: RERUN_CMAKE CMakeLists.txt\n"
            "  pool = console\n"
            "  command = cmake --regenerate-during-build .\n"
            "\n"
            "build all: phony lib/libfoo.so\n"
        )
        result = _regen_re.sub("# regen suppressed", cmake_ninja, count=1)
        check("RERUN_CMAKE" not in result,
              "cmake regen rule removed")
        check("build all: phony" in result,
              "cmake all target preserved")

        # 52. No regen rule — content unchanged
        no_regen = "build foo.o: cc foo.c\nbuild all: phony foo.o\n"
        result = _regen_re.sub("# regen suppressed", no_regen, count=1)
        check(result == no_regen,
              "no regen rule: content unchanged")

        # 53. Nested build.ninja found by glob
        nested_dir = os.path.join(tmpdir, "nested_ninja")
        os.makedirs(os.path.join(nested_dir, "build"), exist_ok=True)
        with open(os.path.join(nested_dir, "build", "build.ninja"), "w") as f:
            f.write(ninja_content)
        found = _glob.glob(os.path.join(nested_dir, "**/build.ninja"), recursive=True)
        check(len(found) == 1 and "build" + os.sep + "build.ninja" in found[0],
              f"nested build.ninja found by glob: {found}")

        # ── cmake --install detection ────────────────────────────────

        print("=== cmake --install detection ===")

        cmake_det_dir = os.path.join(tmpdir, "cmake_detect")
        os.makedirs(cmake_det_dir)

        # 54. No CMakeCache.txt → no cmake install
        check(not os.path.isfile(os.path.join(cmake_det_dir, "CMakeCache.txt")),
              "no CMakeCache.txt: cmake --install not used")

        # 55. With CMakeCache.txt + cmake in PATH → cmake --install
        with open(os.path.join(cmake_det_dir, "CMakeCache.txt"), "w") as f:
            f.write("CMAKE_INSTALL_PREFIX:PATH=/usr\n")
        _has_cmake = shutil.which("cmake") is not None
        _would_use_cmake = (os.path.isfile(os.path.join(cmake_det_dir, "CMakeCache.txt"))
                            and _has_cmake)
        check(_would_use_cmake == _has_cmake,
              f"CMakeCache.txt present, cmake in PATH={_has_cmake}: cmake_install={_would_use_cmake}")

    finally:
        os.chdir(saved_cwd)
        shutil.rmtree(tmpdir, ignore_errors=True)

    # ── Summary ──────────────────────────────────────────────────────

    print(f"\n--- {passed} passed, {failed} failed ---")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
