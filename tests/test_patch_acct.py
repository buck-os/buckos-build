#!/usr/bin/env python3
"""Unit tests for patch helper and standalone acct helper."""
import io
import os
import stat
import sys
import tempfile
from pathlib import Path

_REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO / "tools"))

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


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _write(path, content=""):
    """Create a file (and parent dirs) with the given content."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(content)


def _read(path):
    with open(path) as f:
        return f.read()


def _run_patch_helper(args, env=None):
    """Run patch_helper.py as a subprocess, return CompletedProcess."""
    import subprocess
    cmd = [sys.executable, str(_REPO / "tools" / "patch_helper.py")] + args
    return subprocess.run(cmd, capture_output=True, text=True, env=env)


def _run_acct_helper(args):
    """Run acct_helper.py as a subprocess, return CompletedProcess."""
    import subprocess
    cmd = [sys.executable, str(_REPO / "tools" / "acct_helper.py")] + args
    return subprocess.run(cmd, capture_output=True, text=True)


def main():
    _real_stdout = sys.stdout
    _buf = io.StringIO()
    sys.stdout = _buf

    # ===================================================================
    # patch_helper: source copying
    # ===================================================================

    # 1. Source dir copied to output dir
    print("=== patch_helper: source copied to output ===")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        out = os.path.join(tmp, "out")
        _write(os.path.join(src, "main.c"), "int main() {}")
        _write(os.path.join(src, "sub", "lib.c"), "void lib() {}")
        # Need at least one --cmd to avoid "no patches or commands" error
        r = _run_patch_helper([
            "--source-dir", src,
            "--output-dir", out,
            "--cmd", "true",
        ])
        if r.returncode != 0:
            fail(f"patch_helper exited {r.returncode}: {r.stderr}")
        elif (os.path.isfile(os.path.join(out, "main.c"))
                and _read(os.path.join(out, "main.c")) == "int main() {}"
                and os.path.isfile(os.path.join(out, "sub", "lib.c"))):
            ok("source tree copied to output")
        else:
            fail("source tree not fully copied")

    # 2. Source dir not modified by copy
    print("=== patch_helper: source dir unchanged after copy ===")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        out = os.path.join(tmp, "out")
        _write(os.path.join(src, "file.txt"), "original")
        r = _run_patch_helper([
            "--source-dir", src,
            "--output-dir", out,
            "--cmd", "echo modified >> file.txt",
        ])
        if r.returncode != 0:
            fail(f"patch_helper exited {r.returncode}: {r.stderr}")
        elif _read(os.path.join(src, "file.txt")) == "original":
            ok("source dir unchanged after patch")
        else:
            fail("source dir was modified")

    # 3. Existing output dir is replaced
    print("=== patch_helper: existing output dir replaced ===")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        out = os.path.join(tmp, "out")
        _write(os.path.join(src, "new.txt"), "new")
        _write(os.path.join(out, "stale.txt"), "stale")
        r = _run_patch_helper([
            "--source-dir", src,
            "--output-dir", out,
            "--cmd", "true",
        ])
        if r.returncode != 0:
            fail(f"patch_helper exited {r.returncode}: {r.stderr}")
        elif (os.path.isfile(os.path.join(out, "new.txt"))
                and not os.path.exists(os.path.join(out, "stale.txt"))):
            ok("stale output dir replaced")
        else:
            fail("stale file still present or new file missing")

    # 4. Symlinks preserved in copy
    print("=== patch_helper: symlinks preserved in copy ===")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        out = os.path.join(tmp, "out")
        _write(os.path.join(src, "real.txt"), "data")
        os.symlink("real.txt", os.path.join(src, "link.txt"))
        r = _run_patch_helper([
            "--source-dir", src,
            "--output-dir", out,
            "--cmd", "true",
        ])
        if r.returncode != 0:
            fail(f"patch_helper exited {r.returncode}: {r.stderr}")
        elif (os.path.islink(os.path.join(out, "link.txt"))
                and os.readlink(os.path.join(out, "link.txt")) == "real.txt"):
            ok("symlinks preserved")
        else:
            fail("symlink not preserved")

    # ===================================================================
    # patch_helper: cmd environment
    # ===================================================================

    # 5. WORKDIR env var set for --cmd
    print("=== patch_helper: WORKDIR env var set ===")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        out = os.path.join(tmp, "out")
        _write(os.path.join(src, "x"), "")
        r = _run_patch_helper([
            "--source-dir", src,
            "--output-dir", out,
            "--cmd", "echo $WORKDIR",
        ])
        if r.returncode != 0:
            fail(f"patch_helper exited {r.returncode}: {r.stderr}")
        else:
            workdir = r.stdout.strip()
            # WORKDIR falls back to abspath(output_dir) when BUCK_SCRATCH_PATH unset
            if workdir and os.path.isabs(workdir):
                ok("WORKDIR env var set to absolute path")
            else:
                fail(f"WORKDIR={workdir!r}")

    # 6. Patch application with --patch
    print("=== patch_helper: --patch applies diff ===")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        out = os.path.join(tmp, "out")
        _write(os.path.join(src, "hello.c"), "int main() { return 0; }\n")
        # Create a patch that changes the return value
        patch_content = (
            "--- a/hello.c\n"
            "+++ b/hello.c\n"
            "@@ -1 +1 @@\n"
            "-int main() { return 0; }\n"
            "+int main() { return 42; }\n"
        )
        patch_file = os.path.join(tmp, "fix.patch")
        _write(patch_file, patch_content)
        r = _run_patch_helper([
            "--source-dir", src,
            "--output-dir", out,
            "--patch", patch_file,
        ])
        if r.returncode != 0:
            fail(f"patch_helper exited {r.returncode}: {r.stderr}")
        else:
            content = _read(os.path.join(out, "hello.c"))
            if "return 42" in content:
                ok("patch applied successfully")
            else:
                fail(f"patch not applied: {content!r}")

    # 7. --strip controls path component stripping
    print("=== patch_helper: --strip 0 with flat patch ===")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        out = os.path.join(tmp, "out")
        _write(os.path.join(src, "file.txt"), "old\n")
        patch_content = (
            "--- file.txt\n"
            "+++ file.txt\n"
            "@@ -1 +1 @@\n"
            "-old\n"
            "+new\n"
        )
        patch_file = os.path.join(tmp, "flat.patch")
        _write(patch_file, patch_content)
        r = _run_patch_helper([
            "--source-dir", src,
            "--output-dir", out,
            "--strip", "0",
            "--patch", patch_file,
        ])
        if r.returncode != 0:
            fail(f"patch_helper exited {r.returncode}: {r.stderr}")
        else:
            content = _read(os.path.join(out, "file.txt"))
            if content.strip() == "new":
                ok("--strip 0 applied flat patch")
            else:
                fail(f"content: {content!r}")

    # ===================================================================
    # patch_helper: --cmd execution
    # ===================================================================

    # 8. Single --cmd runs in output dir
    print("=== patch_helper: --cmd runs in output dir ===")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        out = os.path.join(tmp, "out")
        _write(os.path.join(src, "x"), "")
        r = _run_patch_helper([
            "--source-dir", src,
            "--output-dir", out,
            "--cmd", "touch marker.txt",
        ])
        if r.returncode != 0:
            fail(f"patch_helper exited {r.returncode}: {r.stderr}")
        elif os.path.isfile(os.path.join(out, "marker.txt")):
            ok("--cmd ran in output dir")
        else:
            fail("marker.txt not created in output dir")

    # 9. Multiple --cmd args run in order
    print("=== patch_helper: multiple --cmd args run in order ===")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        out = os.path.join(tmp, "out")
        _write(os.path.join(src, "x"), "")
        r = _run_patch_helper([
            "--source-dir", src,
            "--output-dir", out,
            "--cmd", "echo first > order.txt",
            "--cmd", "echo second >> order.txt",
        ])
        if r.returncode != 0:
            fail(f"patch_helper exited {r.returncode}: {r.stderr}")
        else:
            content = _read(os.path.join(out, "order.txt")).strip()
            if content == "first\nsecond":
                ok("multiple --cmd args ran in order")
            else:
                fail(f"order wrong: {content!r}")

    # 10. --cmd has S env var set to output dir
    print("=== patch_helper: --cmd has S env var ===")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        out = os.path.join(tmp, "out")
        _write(os.path.join(src, "x"), "")
        r = _run_patch_helper([
            "--source-dir", src,
            "--output-dir", out,
            "--cmd", "echo $S",
        ])
        if r.returncode != 0:
            fail(f"patch_helper exited {r.returncode}: {r.stderr}")
        else:
            s_val = r.stdout.strip()
            out_abs = os.path.abspath(out)
            if s_val == out_abs:
                ok("S env var set to absolute output dir")
            else:
                fail(f"S={s_val!r}, expected {out_abs!r}")

    # 11. Failing --cmd exits non-zero
    print("=== patch_helper: failing --cmd exits non-zero ===")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        out = os.path.join(tmp, "out")
        _write(os.path.join(src, "x"), "")
        r = _run_patch_helper([
            "--source-dir", src,
            "--output-dir", out,
            "--cmd", "false",
        ])
        if r.returncode != 0:
            ok("failing --cmd causes non-zero exit")
        else:
            fail("failing --cmd did not cause non-zero exit")

    # 12. No patches or commands => error
    print("=== patch_helper: no patches or commands => error ===")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        out = os.path.join(tmp, "out")
        _write(os.path.join(src, "x"), "")
        r = _run_patch_helper([
            "--source-dir", src,
            "--output-dir", out,
        ])
        if r.returncode != 0 and "no patches or commands" in r.stderr:
            ok("no patches or commands gives error")
        else:
            fail(f"expected error, got rc={r.returncode}, stderr={r.stderr!r}")

    # 13. Missing source dir => error
    print("=== patch_helper: missing source dir => error ===")
    with tempfile.TemporaryDirectory() as tmp:
        r = _run_patch_helper([
            "--source-dir", os.path.join(tmp, "nonexistent"),
            "--output-dir", os.path.join(tmp, "out"),
            "--cmd", "true",
        ])
        if r.returncode != 0 and "source directory not found" in r.stderr:
            ok("missing source dir gives error")
        else:
            fail(f"expected error, got rc={r.returncode}, stderr={r.stderr!r}")

    # ===================================================================
    # acct_helper: group mode
    # ===================================================================

    # 14. Group mode generates /etc/group
    print("=== acct_helper: group mode generates /etc/group ===")
    with tempfile.TemporaryDirectory() as tmp:
        r = _run_acct_helper([
            "--mode", "group",
            "--name", "audio",
            "--id", "63",
            "--output-dir", tmp,
        ])
        if r.returncode != 0:
            fail(f"acct_helper exited {r.returncode}: {r.stderr}")
        else:
            content = _read(os.path.join(tmp, "etc", "group"))
            if content.strip() == "audio:x:63:":
                ok("group line format correct")
            else:
                fail(f"group content: {content!r}")

    # 15. Group mode generates /etc/gshadow
    print("=== acct_helper: group mode generates /etc/gshadow ===")
    with tempfile.TemporaryDirectory() as tmp:
        r = _run_acct_helper([
            "--mode", "group",
            "--name", "video",
            "--id", "39",
            "--output-dir", tmp,
        ])
        if r.returncode != 0:
            fail(f"acct_helper exited {r.returncode}: {r.stderr}")
        else:
            content = _read(os.path.join(tmp, "etc", "gshadow"))
            if content.strip() == "video:!::":
                ok("gshadow line format correct")
            else:
                fail(f"gshadow content: {content!r}")

    # ===================================================================
    # acct_helper: user mode
    # ===================================================================

    # 16. User mode generates /etc/passwd with defaults
    print("=== acct_helper: user mode generates /etc/passwd ===")
    with tempfile.TemporaryDirectory() as tmp:
        r = _run_acct_helper([
            "--mode", "user",
            "--name", "nobody",
            "--id", "65534",
            "--output-dir", tmp,
        ])
        if r.returncode != 0:
            fail(f"acct_helper exited {r.returncode}: {r.stderr}")
        else:
            content = _read(os.path.join(tmp, "etc", "passwd"))
            expected = "nobody:x:65534:65534::/nonexistent:/usr/sbin/nologin"
            if content.strip() == expected:
                ok("passwd line with defaults correct")
            else:
                fail(f"passwd content: {content!r}, expected: {expected!r}")

    # 17. User mode generates /etc/shadow
    print("=== acct_helper: user mode generates /etc/shadow ===")
    with tempfile.TemporaryDirectory() as tmp:
        r = _run_acct_helper([
            "--mode", "user",
            "--name", "daemon",
            "--id", "2",
            "--output-dir", tmp,
        ])
        if r.returncode != 0:
            fail(f"acct_helper exited {r.returncode}: {r.stderr}")
        else:
            content = _read(os.path.join(tmp, "etc", "shadow"))
            if content.strip() == "daemon:!:0:0:99999:7:::":
                ok("shadow line format correct")
            else:
                fail(f"shadow content: {content!r}")

    # 18. Shadow file permissions set to 0o640
    print("=== acct_helper: shadow file permissions 0640 ===")
    with tempfile.TemporaryDirectory() as tmp:
        r = _run_acct_helper([
            "--mode", "user",
            "--name", "test",
            "--id", "1000",
            "--output-dir", tmp,
        ])
        if r.returncode != 0:
            fail(f"acct_helper exited {r.returncode}: {r.stderr}")
        else:
            shadow_path = os.path.join(tmp, "etc", "shadow")
            mode = stat.S_IMODE(os.stat(shadow_path).st_mode)
            if mode == 0o640:
                ok("shadow file permissions are 0640")
            else:
                fail(f"shadow permissions: {oct(mode)}, expected 0o640")

    # ===================================================================
    # acct_helper: custom values
    # ===================================================================

    # 19. Custom home directory
    print("=== acct_helper: custom home directory ===")
    with tempfile.TemporaryDirectory() as tmp:
        r = _run_acct_helper([
            "--mode", "user",
            "--name", "www",
            "--id", "80",
            "--home", "/var/www",
            "--output-dir", tmp,
        ])
        if r.returncode != 0:
            fail(f"acct_helper exited {r.returncode}: {r.stderr}")
        else:
            content = _read(os.path.join(tmp, "etc", "passwd"))
            if "www:x:80:80::/var/www:/usr/sbin/nologin" == content.strip():
                ok("custom home directory in passwd")
            else:
                fail(f"passwd content: {content!r}")

    # 20. Custom shell
    print("=== acct_helper: custom shell ===")
    with tempfile.TemporaryDirectory() as tmp:
        r = _run_acct_helper([
            "--mode", "user",
            "--name", "admin",
            "--id", "1000",
            "--shell", "/bin/bash",
            "--output-dir", tmp,
        ])
        if r.returncode != 0:
            fail(f"acct_helper exited {r.returncode}: {r.stderr}")
        else:
            content = _read(os.path.join(tmp, "etc", "passwd"))
            if content.strip().endswith(":/bin/bash"):
                ok("custom shell in passwd")
            else:
                fail(f"passwd content: {content!r}")

    # 21. Custom description (GECOS)
    print("=== acct_helper: custom description ===")
    with tempfile.TemporaryDirectory() as tmp:
        r = _run_acct_helper([
            "--mode", "user",
            "--name", "root",
            "--id", "0",
            "--description", "System Administrator",
            "--output-dir", tmp,
        ])
        if r.returncode != 0:
            fail(f"acct_helper exited {r.returncode}: {r.stderr}")
        else:
            content = _read(os.path.join(tmp, "etc", "passwd"))
            if "root:x:0:0:System Administrator:" in content:
                ok("custom description in passwd")
            else:
                fail(f"passwd content: {content!r}")

    # 22. All custom fields together
    print("=== acct_helper: all custom fields ===")
    with tempfile.TemporaryDirectory() as tmp:
        r = _run_acct_helper([
            "--mode", "user",
            "--name", "svc",
            "--id", "500",
            "--home", "/opt/svc",
            "--shell", "/bin/sh",
            "--description", "Service Account",
            "--output-dir", tmp,
        ])
        if r.returncode != 0:
            fail(f"acct_helper exited {r.returncode}: {r.stderr}")
        else:
            content = _read(os.path.join(tmp, "etc", "passwd"))
            expected = "svc:x:500:500:Service Account:/opt/svc:/bin/sh"
            if content.strip() == expected:
                ok("all custom fields rendered correctly")
            else:
                fail(f"passwd content: {content!r}, expected: {expected!r}")

    # 23. Group mode does NOT create passwd or shadow
    print("=== acct_helper: group mode no passwd/shadow ===")
    with tempfile.TemporaryDirectory() as tmp:
        r = _run_acct_helper([
            "--mode", "group",
            "--name", "wheel",
            "--id", "10",
            "--output-dir", tmp,
        ])
        if r.returncode != 0:
            fail(f"acct_helper exited {r.returncode}: {r.stderr}")
        else:
            has_passwd = os.path.exists(os.path.join(tmp, "etc", "passwd"))
            has_shadow = os.path.exists(os.path.join(tmp, "etc", "shadow"))
            if not has_passwd and not has_shadow:
                ok("group mode does not create passwd or shadow")
            else:
                fail(f"passwd={has_passwd}, shadow={has_shadow}")

    # 24. User mode does NOT create group or gshadow
    print("=== acct_helper: user mode no group/gshadow ===")
    with tempfile.TemporaryDirectory() as tmp:
        r = _run_acct_helper([
            "--mode", "user",
            "--name", "test",
            "--id", "1000",
            "--output-dir", tmp,
        ])
        if r.returncode != 0:
            fail(f"acct_helper exited {r.returncode}: {r.stderr}")
        else:
            has_group = os.path.exists(os.path.join(tmp, "etc", "group"))
            has_gshadow = os.path.exists(os.path.join(tmp, "etc", "gshadow"))
            if not has_group and not has_gshadow:
                ok("user mode does not create group or gshadow")
            else:
                fail(f"group={has_group}, gshadow={has_gshadow}")

    # 25. Appending to existing files (acct_helper uses mode "a")
    print("=== acct_helper: appends to existing group file ===")
    with tempfile.TemporaryDirectory() as tmp:
        etc = os.path.join(tmp, "etc")
        os.makedirs(etc)
        _write(os.path.join(etc, "group"), "root:x:0:\n")
        r = _run_acct_helper([
            "--mode", "group",
            "--name", "audio",
            "--id", "63",
            "--output-dir", tmp,
        ])
        if r.returncode != 0:
            fail(f"acct_helper exited {r.returncode}: {r.stderr}")
        else:
            content = _read(os.path.join(etc, "group"))
            if "root:x:0:\n" in content and "audio:x:63:\n" in content:
                ok("appended to existing group file")
            else:
                fail(f"group content: {content!r}")

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
