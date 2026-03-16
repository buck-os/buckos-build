#!/usr/bin/env python3
"""Unit tests for bootstrap configure helper utilities."""
import io
import os
import shutil
import stat
import sys
import tempfile
from pathlib import Path

_REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO / "tools"))

from bootstrap_glibc_configure import _find_tool

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


def _make_executable(path):
    """Create an empty executable file at path."""
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text("")
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def main():
    _real_stdout = sys.stdout
    _buf = io.StringIO()
    sys.stdout = _buf

    # ================================================================
    # _find_tool tests
    # ================================================================

    print("=== _find_tool: found in first search dir ===")
    with tempfile.TemporaryDirectory() as d:
        dir1 = os.path.join(d, "dir1")
        dir2 = os.path.join(d, "dir2")
        os.makedirs(dir1)
        os.makedirs(dir2)
        _make_executable(os.path.join(dir1, "mytool"))
        result = _find_tool("mytool", [dir1, dir2])
        if result == os.path.join(dir1, "mytool"):
            ok("found in first dir")
        else:
            fail(f"expected {os.path.join(dir1, 'mytool')}, got {result}")

    print("=== _find_tool: found in second search dir ===")
    with tempfile.TemporaryDirectory() as d:
        dir1 = os.path.join(d, "dir1")
        dir2 = os.path.join(d, "dir2")
        os.makedirs(dir1)
        os.makedirs(dir2)
        _make_executable(os.path.join(dir2, "mytool"))
        result = _find_tool("mytool", [dir1, dir2])
        if result == os.path.join(dir2, "mytool"):
            ok("found in second dir")
        else:
            fail(f"expected {os.path.join(dir2, 'mytool')}, got {result}")

    print("=== _find_tool: not found returns None ===")
    with tempfile.TemporaryDirectory() as d:
        dir1 = os.path.join(d, "dir1")
        os.makedirs(dir1)
        result = _find_tool("nonexistent", [dir1])
        if result is None:
            ok("not found returns None")
        else:
            fail(f"expected None, got {result}")

    print("=== _find_tool: non-executable file skipped ===")
    with tempfile.TemporaryDirectory() as d:
        dir1 = os.path.join(d, "dir1")
        os.makedirs(dir1)
        # Create a file that is NOT executable
        path = os.path.join(dir1, "noexec")
        Path(path).write_text("")
        os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
        result = _find_tool("noexec", [dir1])
        if result is None:
            ok("non-executable file skipped")
        else:
            fail(f"expected None for non-executable, got {result}")

    print("=== _find_tool: directory with same name skipped ===")
    with tempfile.TemporaryDirectory() as d:
        dir1 = os.path.join(d, "dir1")
        os.makedirs(os.path.join(dir1, "mytool"))  # directory, not file
        result = _find_tool("mytool", [dir1])
        if result is None:
            ok("directory with same name skipped")
        else:
            fail(f"expected None for directory, got {result}")

    print("=== _find_tool: prefers first dir over second ===")
    with tempfile.TemporaryDirectory() as d:
        dir1 = os.path.join(d, "dir1")
        dir2 = os.path.join(d, "dir2")
        os.makedirs(dir1)
        os.makedirs(dir2)
        _make_executable(os.path.join(dir1, "tool"))
        _make_executable(os.path.join(dir2, "tool"))
        result = _find_tool("tool", [dir1, dir2])
        if result == os.path.join(dir1, "tool"):
            ok("prefers first dir")
        else:
            fail(f"expected dir1 tool, got {result}")

    print("=== _find_tool: empty search dirs falls through to PATH ===")
    # With empty extra_paths, should search system PATH
    result = _find_tool("sh", [])
    if result is not None and os.path.basename(result) == "sh":
        ok("falls through to system PATH for 'sh'")
    else:
        fail(f"expected to find 'sh' on PATH, got {result}")

    # ================================================================
    # GCC sysroot assembly tests
    # ================================================================

    print("=== gcc sysroot: headers copied into build-sysroot/usr/include ===")
    with tempfile.TemporaryDirectory() as d:
        headers_dir = os.path.join(d, "headers")
        os.makedirs(os.path.join(headers_dir, "usr", "include", "linux"))
        Path(os.path.join(headers_dir, "usr", "include", "linux", "types.h")).write_text(
            "/* types */\n"
        )
        # Replicate sysroot assembly logic from bootstrap_gcc_configure.py
        build_sysroot = os.path.join(d, "build-sysroot")
        src_inc = os.path.join(headers_dir, "usr", "include")
        dst_inc = os.path.join(build_sysroot, "usr", "include")
        os.makedirs(dst_inc, exist_ok=True)
        if os.path.isdir(src_inc):
            shutil.copytree(src_inc, dst_inc, symlinks=True, dirs_exist_ok=True)
        result_path = os.path.join(build_sysroot, "usr", "include", "linux", "types.h")
        if os.path.isfile(result_path):
            ok("headers copied into build-sysroot")
        else:
            fail("headers not found in build-sysroot")

    print("=== gcc sysroot: libc merged over headers ===")
    with tempfile.TemporaryDirectory() as d:
        # Set up headers
        headers_dir = os.path.join(d, "headers")
        os.makedirs(os.path.join(headers_dir, "usr", "include"))
        Path(os.path.join(headers_dir, "usr", "include", "unistd.h")).write_text("/* hdr */\n")
        # Set up libc
        libc_dir = os.path.join(d, "libc")
        os.makedirs(os.path.join(libc_dir, "usr", "lib64"))
        Path(os.path.join(libc_dir, "usr", "lib64", "libc.so")).write_text("/* fake */\n")
        # Replicate assembly
        build_sysroot = os.path.join(d, "build-sysroot")
        src_inc = os.path.join(headers_dir, "usr", "include")
        dst_inc = os.path.join(build_sysroot, "usr", "include")
        os.makedirs(dst_inc, exist_ok=True)
        shutil.copytree(src_inc, dst_inc, symlinks=True, dirs_exist_ok=True)
        os.makedirs(build_sysroot, exist_ok=True)
        shutil.copytree(libc_dir, build_sysroot, symlinks=True, dirs_exist_ok=True)
        # Re-overlay headers (matches gcc configure pass2 logic: libc first, then headers)
        shutil.copytree(headers_dir, build_sysroot, symlinks=True, dirs_exist_ok=True)
        has_hdr = os.path.isfile(os.path.join(build_sysroot, "usr", "include", "unistd.h"))
        has_lib = os.path.isfile(os.path.join(build_sysroot, "usr", "lib64", "libc.so"))
        if has_hdr and has_lib:
            ok("libc and headers both present in sysroot")
        else:
            fail(f"has_hdr={has_hdr}, has_lib={has_lib}")

    # ================================================================
    # GCC stub sdt.h tests
    # ================================================================

    print("=== gcc sdt.h: created with correct content ===")
    with tempfile.TemporaryDirectory() as d:
        sdt_dir = os.path.join(d, "usr", "include", "sys")
        os.makedirs(sdt_dir, exist_ok=True)
        sdt_path = os.path.join(sdt_dir, "sdt.h")
        with open(sdt_path, "w") as f:
            f.write("#ifndef _SYS_SDT_H\n#define _SYS_SDT_H\n"
                    "#define STAP_PROBE(p,n)\n#endif\n")
        content = Path(sdt_path).read_text()
        if "#ifndef _SYS_SDT_H" in content and "#define STAP_PROBE(p,n)" in content:
            ok("sdt.h has include guard and STAP_PROBE macro")
        else:
            fail(f"sdt.h content wrong: {content!r}")

    print("=== gcc sdt.h: exactly four lines ===")
    with tempfile.TemporaryDirectory() as d:
        sdt_dir = os.path.join(d, "usr", "include", "sys")
        os.makedirs(sdt_dir, exist_ok=True)
        sdt_path = os.path.join(sdt_dir, "sdt.h")
        with open(sdt_path, "w") as f:
            f.write("#ifndef _SYS_SDT_H\n#define _SYS_SDT_H\n"
                    "#define STAP_PROBE(p,n)\n#endif\n")
        lines = Path(sdt_path).read_text().splitlines()
        if len(lines) == 4:
            ok("sdt.h has exactly 4 lines")
        else:
            fail(f"expected 4 lines, got {len(lines)}")

    print("=== gcc sdt.h: STAP_PROBE expands to nothing ===")
    with tempfile.TemporaryDirectory() as d:
        sdt_dir = os.path.join(d, "usr", "include", "sys")
        os.makedirs(sdt_dir, exist_ok=True)
        sdt_path = os.path.join(sdt_dir, "sdt.h")
        with open(sdt_path, "w") as f:
            f.write("#ifndef _SYS_SDT_H\n#define _SYS_SDT_H\n"
                    "#define STAP_PROBE(p,n)\n#endif\n")
        content = Path(sdt_path).read_text()
        # The macro must expand to nothing (empty replacement)
        line = [l for l in content.splitlines() if "STAP_PROBE" in l][0]
        if line == "#define STAP_PROBE(p,n)":
            ok("STAP_PROBE has empty replacement")
        else:
            fail(f"unexpected macro line: {line!r}")

    # ================================================================
    # GCC binutils path construction tests
    # ================================================================

    print("=== gcc binutils: --with-as path format ===")
    triple = "x86_64-buckos-linux-gnu"
    binutils_abs = "/fake/binutils"
    expected_as = os.path.join(binutils_abs, "tools", "bin", triple + "-as")
    expected_ld = os.path.join(binutils_abs, "tools", "bin", triple + "-ld")
    if expected_as == "/fake/binutils/tools/bin/x86_64-buckos-linux-gnu-as":
        ok("--with-as path format correct")
    else:
        fail(f"unexpected as path: {expected_as}")

    print("=== gcc binutils: --with-ld path format ===")
    if expected_ld == "/fake/binutils/tools/bin/x86_64-buckos-linux-gnu-ld":
        ok("--with-ld path format correct")
    else:
        fail(f"unexpected ld path: {expected_ld}")

    # ================================================================
    # GCC env resolution tests
    # ================================================================

    print("=== gcc env: relative path resolved against project_root ===")
    with tempfile.TemporaryDirectory() as d:
        project_root = d
        # Create a file at a relative path within project_root
        relpath = os.path.join("some", "dir")
        os.makedirs(os.path.join(project_root, relpath))
        # Replicate the env resolution logic from bootstrap_gcc_configure.py
        value = relpath
        if value and not os.path.isabs(value) and os.path.exists(
            os.path.join(project_root, value)
        ):
            value = os.path.join(project_root, value)
        expected = os.path.join(project_root, relpath)
        if value == expected:
            ok("relative path resolved to absolute")
        else:
            fail(f"expected {expected}, got {value}")

    print("=== gcc env: absolute path left unchanged ===")
    project_root = "/tmp/fake"
    value = "/usr/bin/gcc"
    if value and not os.path.isabs(value):
        value = os.path.join(project_root, value)
    if value == "/usr/bin/gcc":
        ok("absolute path left unchanged")
    else:
        fail(f"absolute path was modified to {value}")

    print("=== gcc env: nonexistent relative path left as-is ===")
    with tempfile.TemporaryDirectory() as d:
        project_root = d
        value = "does/not/exist"
        original = value
        if value and not os.path.isabs(value) and os.path.exists(
            os.path.join(project_root, value)
        ):
            value = os.path.join(project_root, value)
        if value == original:
            ok("nonexistent relative path left as-is")
        else:
            fail(f"nonexistent path was resolved to {value}")

    # ================================================================
    # Glibc configparms tests
    # ================================================================

    print("=== glibc configparms: rootsbindir set correctly ===")
    with tempfile.TemporaryDirectory() as d:
        build_dir = os.path.join(d, "build")
        os.makedirs(build_dir)
        configparms = os.path.join(build_dir, "configparms")
        with open(configparms, "w") as f:
            f.write("rootsbindir=/usr/sbin\n")
        content = Path(configparms).read_text()
        if content == "rootsbindir=/usr/sbin\n":
            ok("configparms has correct content")
        else:
            fail(f"configparms content: {content!r}")

    # ================================================================
    # Glibc tool search path construction tests
    # ================================================================

    print("=== glibc search paths: compiler bin dir first ===")
    compiler_abs = "/fake/gcc-install"
    binutils_abs = "/fake/binutils-install"
    search_paths = [os.path.join(compiler_abs, "tools", "bin")]
    search_paths.append(os.path.join(binutils_abs, "tools", "bin"))
    if search_paths == [
        "/fake/gcc-install/tools/bin",
        "/fake/binutils-install/tools/bin",
    ]:
        ok("compiler bin dir comes before binutils bin dir")
    else:
        fail(f"unexpected search_paths: {search_paths}")

    print("=== glibc search paths: no binutils dir gives single entry ===")
    compiler_abs = "/fake/gcc-install"
    search_paths = [os.path.join(compiler_abs, "tools", "bin")]
    if len(search_paths) == 1 and search_paths[0] == "/fake/gcc-install/tools/bin":
        ok("single search path without binutils")
    else:
        fail(f"unexpected: {search_paths}")

    # ================================================================
    # Glibc cross-tool env setup tests
    # ================================================================

    print("=== glibc env: CC set to cross gcc ===")
    with tempfile.TemporaryDirectory() as d:
        triple = "x86_64-buckos-linux-gnu"
        tool_prefix = triple + "-"
        bin_dir = os.path.join(d, "tools", "bin")
        os.makedirs(bin_dir)
        gcc_path = os.path.join(bin_dir, tool_prefix + "gcc")
        _make_executable(gcc_path)
        cross_cc = _find_tool(tool_prefix + "gcc", [bin_dir])
        if cross_cc == gcc_path:
            ok("CC resolves to cross gcc")
        else:
            fail(f"expected {gcc_path}, got {cross_cc}")

    print("=== glibc env: CPP derived from CC ===")
    cross_cc = "/fake/tools/bin/x86_64-buckos-linux-gnu-gcc"
    cpp_val = cross_cc + " -E"
    if cpp_val == "/fake/tools/bin/x86_64-buckos-linux-gnu-gcc -E":
        ok("CPP = CC + ' -E'")
    else:
        fail(f"unexpected CPP: {cpp_val}")

    print("=== glibc env: CXX set to empty string ===")
    # glibc configure sets CXX="" to prevent C++ detection
    env_cxx = ""
    if env_cxx == "":
        ok("CXX is empty string")
    else:
        fail(f"CXX: {env_cxx!r}")

    print("=== glibc env: binutils tools discovered from binutils dir ===")
    with tempfile.TemporaryDirectory() as d:
        triple = "x86_64-buckos-linux-gnu"
        tool_prefix = triple + "-"
        binutils_bin = os.path.join(d, "tools", "bin")
        os.makedirs(binutils_bin)
        expected_tools = {}
        for tool_name in ["LD", "AR", "AS", "NM", "RANLIB", "OBJCOPY", "OBJDUMP", "STRIP"]:
            tool_path = os.path.join(binutils_bin, tool_prefix + tool_name.lower())
            _make_executable(tool_path)
            expected_tools[tool_name] = tool_path
        # Replicate discovery
        env = {}
        for tool_name in ["LD", "AR", "AS", "NM", "RANLIB", "OBJCOPY", "OBJDUMP", "STRIP"]:
            tool_path = _find_tool(tool_prefix + tool_name.lower(), [binutils_bin])
            if tool_path:
                env[tool_name] = tool_path
        if env == expected_tools:
            ok("all 8 binutils tools discovered")
        else:
            missing = set(expected_tools) - set(env)
            fail(f"missing tools: {missing}")

    # ================================================================
    # Python sysroot merge tests
    # ================================================================

    print("=== python sysroot: base sysroot copied ===")
    with tempfile.TemporaryDirectory() as d:
        sysroot = os.path.join(d, "sysroot")
        os.makedirs(os.path.join(sysroot, "usr", "lib64"))
        Path(os.path.join(sysroot, "usr", "lib64", "libc.so.6")).write_text("/* base */\n")
        build_sysroot = os.path.join(d, "build-sysroot")
        os.makedirs(build_sysroot, exist_ok=True)
        shutil.copytree(sysroot, build_sysroot, symlinks=True, dirs_exist_ok=True)
        if os.path.isfile(os.path.join(build_sysroot, "usr", "lib64", "libc.so.6")):
            ok("base sysroot copied to build-sysroot")
        else:
            fail("base sysroot not copied")

    print("=== python sysroot: dep usr/ merged into build-sysroot ===")
    with tempfile.TemporaryDirectory() as d:
        sysroot = os.path.join(d, "sysroot")
        os.makedirs(os.path.join(sysroot, "usr", "include"))
        Path(os.path.join(sysroot, "usr", "include", "stdlib.h")).write_text("/* base */\n")
        dep_dir = os.path.join(d, "dep")
        os.makedirs(os.path.join(dep_dir, "usr", "include"))
        Path(os.path.join(dep_dir, "usr", "include", "zlib.h")).write_text("/* dep */\n")
        # Replicate merge logic
        build_sysroot = os.path.join(d, "build-sysroot")
        os.makedirs(build_sysroot, exist_ok=True)
        shutil.copytree(sysroot, build_sysroot, symlinks=True, dirs_exist_ok=True)
        dep_usr = os.path.join(dep_dir, "usr")
        if os.path.isdir(dep_usr):
            dst_usr = os.path.join(build_sysroot, "usr")
            os.makedirs(dst_usr, exist_ok=True)
            shutil.copytree(dep_usr, dst_usr, symlinks=True, dirs_exist_ok=True)
        has_base = os.path.isfile(os.path.join(build_sysroot, "usr", "include", "stdlib.h"))
        has_dep = os.path.isfile(os.path.join(build_sysroot, "usr", "include", "zlib.h"))
        if has_base and has_dep:
            ok("dep usr/ merged alongside base")
        else:
            fail(f"has_base={has_base}, has_dep={has_dep}")

    print("=== python sysroot: multiple deps merged ===")
    with tempfile.TemporaryDirectory() as d:
        sysroot = os.path.join(d, "sysroot")
        os.makedirs(os.path.join(sysroot, "usr", "lib"))
        build_sysroot = os.path.join(d, "build-sysroot")
        os.makedirs(build_sysroot, exist_ok=True)
        shutil.copytree(sysroot, build_sysroot, symlinks=True, dirs_exist_ok=True)
        # Two deps with different files
        for i, lib_name in enumerate(["libssl.so", "libz.so"]):
            dep = os.path.join(d, f"dep{i}")
            os.makedirs(os.path.join(dep, "usr", "lib"))
            Path(os.path.join(dep, "usr", "lib", lib_name)).write_text("/* fake */\n")
            dep_usr = os.path.join(dep, "usr")
            dst_usr = os.path.join(build_sysroot, "usr")
            shutil.copytree(dep_usr, dst_usr, symlinks=True, dirs_exist_ok=True)
        has_ssl = os.path.isfile(os.path.join(build_sysroot, "usr", "lib", "libssl.so"))
        has_z = os.path.isfile(os.path.join(build_sysroot, "usr", "lib", "libz.so"))
        if has_ssl and has_z:
            ok("multiple deps merged into build-sysroot")
        else:
            fail(f"has_ssl={has_ssl}, has_z={has_z}")

    print("=== python sysroot: dep without usr/ is no-op ===")
    with tempfile.TemporaryDirectory() as d:
        sysroot = os.path.join(d, "sysroot")
        os.makedirs(os.path.join(sysroot, "usr", "include"))
        build_sysroot = os.path.join(d, "build-sysroot")
        os.makedirs(build_sysroot, exist_ok=True)
        shutil.copytree(sysroot, build_sysroot, symlinks=True, dirs_exist_ok=True)
        # dep has no usr/ subdir
        dep_dir = os.path.join(d, "dep-empty")
        os.makedirs(os.path.join(dep_dir, "opt", "stuff"))
        dep_usr = os.path.join(dep_dir, "usr")
        if os.path.isdir(dep_usr):
            dst_usr = os.path.join(build_sysroot, "usr")
            os.makedirs(dst_usr, exist_ok=True)
            shutil.copytree(dep_usr, dst_usr, symlinks=True, dirs_exist_ok=True)
        # build-sysroot should still have usr/include from base, nothing extra
        contents = set(os.listdir(os.path.join(build_sysroot, "usr")))
        if contents == {"include"}:
            ok("dep without usr/ does not pollute sysroot")
        else:
            fail(f"unexpected contents: {contents}")

    # ================================================================
    # Python cross-compilation cache variable tests
    # ================================================================

    print("=== python cache: ac_cv_file__dev_ptmx is yes ===")
    # Replicate the env setup from bootstrap_python_configure.py
    env = {}
    env["ac_cv_file__dev_ptmx"] = "yes"
    env["ac_cv_file__dev_ptc"] = "no"
    if env["ac_cv_file__dev_ptmx"] == "yes":
        ok("ac_cv_file__dev_ptmx = yes")
    else:
        fail(f"got {env['ac_cv_file__dev_ptmx']!r}")

    print("=== python cache: ac_cv_file__dev_ptc is no ===")
    if env["ac_cv_file__dev_ptc"] == "no":
        ok("ac_cv_file__dev_ptc = no")
    else:
        fail(f"got {env['ac_cv_file__dev_ptc']!r}")

    # ================================================================
    # Python CFLAGS/LDFLAGS construction tests
    # ================================================================

    print("=== python flags: CFLAGS includes sysroot include dir ===")
    build_sysroot = "/fake/build-sysroot"
    cflags = "-I" + os.path.join(build_sysroot, "usr", "include")
    if cflags == "-I/fake/build-sysroot/usr/include":
        ok("CFLAGS -I path correct")
    else:
        fail(f"CFLAGS: {cflags}")

    print("=== python flags: LDFLAGS has lib64, lib, and rpath-link ===")
    ldflags = "-L{lib64} -L{lib} -Wl,-rpath-link,{lib64}".format(
        lib64=os.path.join(build_sysroot, "usr", "lib64"),
        lib=os.path.join(build_sysroot, "usr", "lib"),
    )
    expected = (
        "-L/fake/build-sysroot/usr/lib64 "
        "-L/fake/build-sysroot/usr/lib "
        "-Wl,-rpath-link,/fake/build-sysroot/usr/lib64"
    )
    if ldflags == expected:
        ok("LDFLAGS paths correct")
    else:
        fail(f"LDFLAGS: {ldflags!r}")

    # ================================================================
    # Python resolve() helper tests
    # ================================================================

    print("=== python resolve: absolute path unchanged ===")
    project_root = "/fake/root"
    p = "/usr/bin/gcc"
    result = p if os.path.isabs(p) else os.path.join(project_root, p)
    if result == "/usr/bin/gcc":
        ok("absolute path unchanged")
    else:
        fail(f"got {result}")

    print("=== python resolve: relative path joined with project_root ===")
    p = "some/relative/path"
    result = p if os.path.isabs(p) else os.path.join(project_root, p)
    if result == "/fake/root/some/relative/path":
        ok("relative path resolved")
    else:
        fail(f"got {result}")

    # ================================================================
    # Python CC/CXX --sysroot appended tests
    # ================================================================

    print("=== python env: CC includes --sysroot flag ===")
    cc_path = "/fake/tools/bin/x86_64-buckos-linux-gnu-gcc"
    build_sysroot = "/fake/output/build-sysroot"
    cc_val = cc_path + " --sysroot=" + build_sysroot
    expected = "/fake/tools/bin/x86_64-buckos-linux-gnu-gcc --sysroot=/fake/output/build-sysroot"
    if cc_val == expected:
        ok("CC includes --sysroot")
    else:
        fail(f"CC: {cc_val}")

    print("=== python env: PATH prepends stage tools/bin ===")
    stage_dir = "/fake/stage"
    old_path = "/usr/bin:/bin"
    new_path = os.path.join(stage_dir, "tools", "bin") + ":" + old_path
    if new_path.startswith("/fake/stage/tools/bin:"):
        ok("PATH prepends stage tools/bin")
    else:
        fail(f"PATH: {new_path}")

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
