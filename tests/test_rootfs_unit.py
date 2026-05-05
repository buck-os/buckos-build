#!/usr/bin/env python3
"""Unit tests for rootfs assembly logic.

Tests _fix_merged_usr, _fix_var_symlinks, _merge_sbin_into_bin,
and the colon-file merge helpers from tools/rootfs_helper.py.
Stdlib only -- no pytest.
"""

import io
import os
import shutil
import sys
import tempfile
from pathlib import Path

_REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO / "tools"))

from rootfs_helper import (
    _fix_merged_usr,
    _fix_var_symlinks,
    _merge_group_files,
    _merge_passwd_files,
    _merge_sbin_into_bin,
    _merge_shadow_files,
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


def main():
    _real_stdout = sys.stdout
    _buf = io.StringIO()
    sys.stdout = _buf

    # ===================================================================
    # _fix_merged_usr
    # ===================================================================

    # 1. /bin directory merged into /usr/bin, /bin becomes symlink
    print("=== _fix_merged_usr: /bin merged into /usr/bin ===")
    with tempfile.TemporaryDirectory() as rootfs:
        _write(os.path.join(rootfs, "bin", "ls"), "ls-binary")
        _write(os.path.join(rootfs, "bin", "cat"), "cat-binary")
        os.makedirs(os.path.join(rootfs, "usr", "bin"), exist_ok=True)
        _fix_merged_usr(rootfs, "bin")
        bin_path = os.path.join(rootfs, "bin")
        if (os.path.islink(bin_path)
                and os.readlink(bin_path) == "usr/bin"
                and _read(os.path.join(rootfs, "usr", "bin", "ls")) == "ls-binary"
                and _read(os.path.join(rootfs, "usr", "bin", "cat")) == "cat-binary"):
            ok("/bin merged into /usr/bin, symlink created")
        else:
            fail("/bin merge failed")

    # 2. /lib directory merged into /usr/lib, /lib becomes symlink
    print("=== _fix_merged_usr: /lib merged into /usr/lib ===")
    with tempfile.TemporaryDirectory() as rootfs:
        _write(os.path.join(rootfs, "lib", "libc.so"), "libc")
        os.makedirs(os.path.join(rootfs, "usr"), exist_ok=True)
        _fix_merged_usr(rootfs, "lib")
        lib_path = os.path.join(rootfs, "lib")
        if (os.path.islink(lib_path)
                and os.readlink(lib_path) == "usr/lib"
                and _read(os.path.join(rootfs, "usr", "lib", "libc.so")) == "libc"):
            ok("/lib merged into /usr/lib, symlink created")
        else:
            fail("/lib merge failed")

    # 3. /sbin directory merged into /usr/sbin, /sbin becomes symlink
    print("=== _fix_merged_usr: /sbin merged into /usr/sbin ===")
    with tempfile.TemporaryDirectory() as rootfs:
        _write(os.path.join(rootfs, "sbin", "init"), "init-binary")
        os.makedirs(os.path.join(rootfs, "usr"), exist_ok=True)
        _fix_merged_usr(rootfs, "sbin")
        sbin_path = os.path.join(rootfs, "sbin")
        if (os.path.islink(sbin_path)
                and os.readlink(sbin_path) == "usr/sbin"
                and _read(os.path.join(rootfs, "usr", "sbin", "init")) == "init-binary"):
            ok("/sbin merged into /usr/sbin, symlink created")
        else:
            fail("/sbin merge failed")

    # 4. Files already in /usr/bin are preserved when /bin has same name
    print("=== _fix_merged_usr: existing /usr/bin files preserved on conflict ===")
    with tempfile.TemporaryDirectory() as rootfs:
        _write(os.path.join(rootfs, "bin", "ls"), "bin-ls")
        _write(os.path.join(rootfs, "usr", "bin", "ls"), "usr-ls")
        _write(os.path.join(rootfs, "usr", "bin", "grep"), "usr-grep")
        _fix_merged_usr(rootfs, "bin")
        # shutil.move overwrites dst when src is a file and dst exists
        usr_ls = _read(os.path.join(rootfs, "usr", "bin", "ls"))
        usr_grep = _read(os.path.join(rootfs, "usr", "bin", "grep"))
        if usr_ls == "bin-ls" and usr_grep == "usr-grep":
            ok("conflicting file moved (overwritten), non-conflicting preserved")
        else:
            fail(f"conflict resolution wrong: ls={usr_ls!r}, grep={usr_grep!r}")

    # 5. If /bin is already a symlink, no action taken
    print("=== _fix_merged_usr: /bin already symlink => no-op ===")
    with tempfile.TemporaryDirectory() as rootfs:
        os.makedirs(os.path.join(rootfs, "usr", "bin"), exist_ok=True)
        _write(os.path.join(rootfs, "usr", "bin", "ls"), "ls")
        os.symlink("usr/bin", os.path.join(rootfs, "bin"))
        _fix_merged_usr(rootfs, "bin")
        if (os.path.islink(os.path.join(rootfs, "bin"))
                and os.readlink(os.path.join(rootfs, "bin")) == "usr/bin"):
            ok("symlink preserved, no action")
        else:
            fail("symlink was modified")

    # 6. If /bin doesn't exist, no action taken
    print("=== _fix_merged_usr: /bin missing => no-op ===")
    with tempfile.TemporaryDirectory() as rootfs:
        os.makedirs(os.path.join(rootfs, "usr", "bin"), exist_ok=True)
        _fix_merged_usr(rootfs, "bin")
        if not os.path.exists(os.path.join(rootfs, "bin")):
            ok("no /bin, no action")
        else:
            fail("/bin was created unexpectedly")

    # 7. Subdirectories in /bin merged into /usr/bin (dirs_exist_ok)
    print("=== _fix_merged_usr: subdirectories merged via copytree ===")
    with tempfile.TemporaryDirectory() as rootfs:
        _write(os.path.join(rootfs, "lib", "modules", "a.ko"), "mod-a")
        _write(os.path.join(rootfs, "lib", "modules", "b.ko"), "mod-b")
        _write(os.path.join(rootfs, "usr", "lib", "modules", "c.ko"), "mod-c")
        _fix_merged_usr(rootfs, "lib")
        lib_path = os.path.join(rootfs, "lib")
        usr_modules = os.path.join(rootfs, "usr", "lib", "modules")
        if (os.path.islink(lib_path)
                and _read(os.path.join(usr_modules, "a.ko")) == "mod-a"
                and _read(os.path.join(usr_modules, "b.ko")) == "mod-b"
                and _read(os.path.join(usr_modules, "c.ko")) == "mod-c"):
            ok("subdirectories merged with dirs_exist_ok")
        else:
            fail("subdirectory merge failed")

    # ===================================================================
    # _fix_var_symlinks
    # ===================================================================

    # 8. /var/run directory moved to /run, symlink created
    print("=== _fix_var_symlinks: /var/run moved to /run ===")
    with tempfile.TemporaryDirectory() as rootfs:
        _write(os.path.join(rootfs, "var", "run", "pid"), "123")
        _fix_var_symlinks(rootfs)
        var_run = os.path.join(rootfs, "var", "run")
        if (os.path.islink(var_run)
                and os.readlink(var_run) == "../run"
                and _read(os.path.join(rootfs, "run", "pid")) == "123"):
            ok("/var/run -> ../run, contents moved")
        else:
            fail("/var/run symlink fixup failed")

    # 9. /var/run files moved to /run
    print("=== _fix_var_symlinks: multiple files moved ===")
    with tempfile.TemporaryDirectory() as rootfs:
        _write(os.path.join(rootfs, "var", "run", "a.pid"), "1")
        _write(os.path.join(rootfs, "var", "run", "b.pid"), "2")
        _fix_var_symlinks(rootfs)
        if (_read(os.path.join(rootfs, "run", "a.pid")) == "1"
                and _read(os.path.join(rootfs, "run", "b.pid")) == "2"):
            ok("all /var/run files moved to /run")
        else:
            fail("not all files moved")

    # 10. Existing files in /run not overwritten
    print("=== _fix_var_symlinks: existing /run files preserved ===")
    with tempfile.TemporaryDirectory() as rootfs:
        _write(os.path.join(rootfs, "run", "pid"), "existing")
        _write(os.path.join(rootfs, "var", "run", "pid"), "new")
        _write(os.path.join(rootfs, "var", "run", "other"), "other")
        _fix_var_symlinks(rootfs)
        if (_read(os.path.join(rootfs, "run", "pid")) == "existing"
                and _read(os.path.join(rootfs, "run", "other")) == "other"):
            ok("existing /run/pid preserved, new file moved")
        else:
            fail("existing file overwritten or new file not moved")

    # 11. /var/lock directory moved to /run/lock, symlink created
    print("=== _fix_var_symlinks: /var/lock moved to /run/lock ===")
    with tempfile.TemporaryDirectory() as rootfs:
        _write(os.path.join(rootfs, "var", "lock", "subsys"), "locked")
        os.makedirs(os.path.join(rootfs, "run"), exist_ok=True)
        _fix_var_symlinks(rootfs)
        var_lock = os.path.join(rootfs, "var", "lock")
        if (os.path.islink(var_lock)
                and os.readlink(var_lock) == "../run/lock"
                and _read(os.path.join(rootfs, "run", "lock", "subsys")) == "locked"):
            ok("/var/lock -> ../run/lock, contents moved")
        else:
            fail("/var/lock symlink fixup failed")

    # 12. If /var/run is already a symlink, no action taken
    print("=== _fix_var_symlinks: /var/run already symlink => no-op ===")
    with tempfile.TemporaryDirectory() as rootfs:
        os.makedirs(os.path.join(rootfs, "var"), exist_ok=True)
        os.makedirs(os.path.join(rootfs, "run"), exist_ok=True)
        os.symlink("../run", os.path.join(rootfs, "var", "run"))
        _fix_var_symlinks(rootfs)
        var_run = os.path.join(rootfs, "var", "run")
        if os.path.islink(var_run) and os.readlink(var_run) == "../run":
            ok("existing symlink preserved")
        else:
            fail("symlink was modified")

    # 13. If /var/run doesn't exist, no action taken
    print("=== _fix_var_symlinks: /var/run missing => no-op ===")
    with tempfile.TemporaryDirectory() as rootfs:
        os.makedirs(os.path.join(rootfs, "var"), exist_ok=True)
        _fix_var_symlinks(rootfs)
        if not os.path.exists(os.path.join(rootfs, "var", "run")):
            ok("no /var/run, no action")
        else:
            fail("/var/run created unexpectedly")

    # ===================================================================
    # _merge_sbin_into_bin
    # ===================================================================

    # 14. /usr/sbin contents moved to /usr/bin
    print("=== _merge_sbin_into_bin: /usr/sbin contents moved ===")
    with tempfile.TemporaryDirectory() as rootfs:
        _write(os.path.join(rootfs, "usr", "sbin", "fdisk"), "fdisk")
        _write(os.path.join(rootfs, "usr", "sbin", "mkfs"), "mkfs")
        os.makedirs(os.path.join(rootfs, "usr", "bin"), exist_ok=True)
        _merge_sbin_into_bin(rootfs)
        if (_read(os.path.join(rootfs, "usr", "bin", "fdisk")) == "fdisk"
                and _read(os.path.join(rootfs, "usr", "bin", "mkfs")) == "mkfs"):
            ok("/usr/sbin contents moved to /usr/bin")
        else:
            fail("contents not moved")

    # 15. /usr/sbin becomes symlink to "bin"
    print("=== _merge_sbin_into_bin: /usr/sbin becomes symlink ===")
    with tempfile.TemporaryDirectory() as rootfs:
        _write(os.path.join(rootfs, "usr", "sbin", "fdisk"), "fdisk")
        os.makedirs(os.path.join(rootfs, "usr", "bin"), exist_ok=True)
        _merge_sbin_into_bin(rootfs)
        usr_sbin = os.path.join(rootfs, "usr", "sbin")
        if os.path.islink(usr_sbin) and os.readlink(usr_sbin) == "bin":
            ok("/usr/sbin -> bin")
        else:
            fail(f"/usr/sbin not a symlink to 'bin'")

    # 16. /sbin symlink updated to usr/bin
    print("=== _merge_sbin_into_bin: /sbin symlink updated ===")
    with tempfile.TemporaryDirectory() as rootfs:
        _write(os.path.join(rootfs, "usr", "sbin", "fdisk"), "fdisk")
        os.makedirs(os.path.join(rootfs, "usr", "bin"), exist_ok=True)
        # Pre-create /sbin as symlink (as _fix_merged_usr would have done)
        os.symlink("usr/sbin", os.path.join(rootfs, "sbin"))
        _merge_sbin_into_bin(rootfs)
        sbin = os.path.join(rootfs, "sbin")
        if os.path.islink(sbin) and os.readlink(sbin) == "usr/bin":
            ok("/sbin -> usr/bin")
        else:
            fail(f"/sbin not updated: {os.readlink(sbin) if os.path.islink(sbin) else 'not a link'}")

    # 17. Files already in /usr/bin preserved (no overwrite on move)
    print("=== _merge_sbin_into_bin: no-overwrite move for unique files ===")
    with tempfile.TemporaryDirectory() as rootfs:
        _write(os.path.join(rootfs, "usr", "bin", "grep"), "usr-grep")
        _write(os.path.join(rootfs, "usr", "sbin", "fdisk"), "fdisk")
        _merge_sbin_into_bin(rootfs)
        if (_read(os.path.join(rootfs, "usr", "bin", "grep")) == "usr-grep"
                and _read(os.path.join(rootfs, "usr", "bin", "fdisk")) == "fdisk"):
            ok("existing /usr/bin file preserved, unique sbin file moved")
        else:
            fail("merge behavior wrong")

    # 18. Duplicate files in sbin get copy2'd over existing bin files
    print("=== _merge_sbin_into_bin: duplicate file => copy2 overwrites ===")
    with tempfile.TemporaryDirectory() as rootfs:
        _write(os.path.join(rootfs, "usr", "bin", "mount"), "old-mount")
        _write(os.path.join(rootfs, "usr", "sbin", "mount"), "new-mount")
        _merge_sbin_into_bin(rootfs)
        if _read(os.path.join(rootfs, "usr", "bin", "mount")) == "new-mount":
            ok("duplicate file overwritten via copy2")
        else:
            fail(f"expected 'new-mount', got '{_read(os.path.join(rootfs, 'usr', 'bin', 'mount'))}'")

    # 19. If /usr/sbin is already a symlink, no action
    print("=== _merge_sbin_into_bin: /usr/sbin already symlink => no-op ===")
    with tempfile.TemporaryDirectory() as rootfs:
        os.makedirs(os.path.join(rootfs, "usr", "bin"), exist_ok=True)
        os.symlink("bin", os.path.join(rootfs, "usr", "sbin"))
        _merge_sbin_into_bin(rootfs)
        usr_sbin = os.path.join(rootfs, "usr", "sbin")
        if os.path.islink(usr_sbin) and os.readlink(usr_sbin) == "bin":
            ok("existing symlink preserved")
        else:
            fail("symlink was modified")

    # 20. If /usr/sbin doesn't exist, no action
    print("=== _merge_sbin_into_bin: /usr/sbin missing => no-op ===")
    with tempfile.TemporaryDirectory() as rootfs:
        os.makedirs(os.path.join(rootfs, "usr", "bin"), exist_ok=True)
        _merge_sbin_into_bin(rootfs)
        if not os.path.exists(os.path.join(rootfs, "usr", "sbin")):
            ok("no /usr/sbin, no action")
        else:
            fail("/usr/sbin created unexpectedly")

    # ===================================================================
    # _merge_group_files / _merge_passwd_files / _merge_shadow_files
    #
    # Per-package acct entries no longer come from usr/share/acct-* dirs;
    # they ship as /etc/{group,passwd,shadow,gshadow} fragments and are
    # combined across packages by these pure-text merge helpers. The
    # orchestrator (_save_merge_files / _restore_merge_files) is exercised
    # at integration level, not here.
    # ===================================================================

    print("=== _merge_group_files: new groups appended ===")
    existing = "root:x:0:\n"
    incoming = "audio:x:18:\nvideo:x:39:\n"
    merged = _merge_group_files(existing, incoming)
    if "root:x:0:" in merged and "audio:x:18:" in merged and "video:x:39:" in merged:
        ok("new groups merged in")
    else:
        fail(f"merge result missing entries: {merged!r}")

    print("=== _merge_group_files: duplicate group keeps existing ===")
    merged = _merge_group_files("audio:x:18:alice\n", "audio:x:18:bob\n")
    audio = [l for l in merged.splitlines() if l.startswith("audio:")]
    if len(audio) == 1 and "alice" in audio[0] and "bob" in audio[0]:
        ok("duplicate group: members unioned")
    else:
        fail(f"unexpected group dedup: {merged!r}")

    print("=== _merge_group_files: sorted by GID ===")
    merged = _merge_group_files("", "video:x:39:\naudio:x:18:\nroot:x:0:\n")
    names = [l.split(":")[0] for l in merged.splitlines() if l]
    if names == ["root", "audio", "video"]:
        ok("groups sorted by GID")
    else:
        fail(f"order wrong: {names}")

    print("=== _merge_passwd_files: new users appended ===")
    existing = "root:x:0:0:root:/root:/bin/bash\n"
    incoming = "nobody:x:65534:65534:Nobody:/:/sbin/nologin\n"
    merged = _merge_passwd_files(existing, incoming)
    if "root:x:0:0" in merged and "nobody:x:65534" in merged:
        ok("new users merged in")
    else:
        fail(f"merge result missing entries: {merged!r}")

    print("=== _merge_passwd_files: duplicate user not added twice ===")
    merged = _merge_passwd_files(
        "nobody:x:65534:65534:Nobody:/:/sbin/nologin\n",
        "nobody:x:65534:65534:Nobody:/:/sbin/nologin\n",
    )
    if merged.count("nobody:") == 1:
        ok("duplicate user deduplicated")
    else:
        fail(f"nobody appears {merged.count('nobody:')} times")

    print("=== _merge_shadow_files: entries merged ===")
    merged = _merge_shadow_files("root:!:19000::::::\n", "nobody:!:19000::::::\n")
    if "root:!:" in merged and "nobody:!:" in merged:
        ok("shadow entries merged")
    else:
        fail(f"shadow merge wrong: {merged!r}")


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
