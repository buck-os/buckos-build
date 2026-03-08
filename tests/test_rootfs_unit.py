#!/usr/bin/env python3
"""Unit tests for rootfs assembly logic.

Tests _fix_merged_usr, _fix_var_symlinks, _merge_sbin_into_bin,
and _merge_acct_entries from tools/rootfs_helper.py.
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
    _merge_acct_entries,
    _merge_sbin_into_bin,
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
    # _merge_acct_entries
    # ===================================================================

    # 21. Group entries merged from acct-group dir into /etc/group
    print("=== _merge_acct_entries: groups merged into /etc/group ===")
    with tempfile.TemporaryDirectory() as rootfs:
        _write(os.path.join(rootfs, "etc", "group"), "root:x:0:\n")
        acct = os.path.join(rootfs, "usr", "share", "acct-group")
        _write(os.path.join(acct, "audio.group"), "audio:x:63:")
        _write(os.path.join(acct, "video.group"), "video:x:39:")
        _merge_acct_entries(rootfs)
        content = _read(os.path.join(rootfs, "etc", "group"))
        if "audio:x:63:" in content and "video:x:39:" in content and "root:x:0:" in content:
            ok("groups merged into /etc/group")
        else:
            fail(f"group merge failed: {content!r}")

    # 22. User entries merged into /etc/passwd + /etc/shadow
    print("=== _merge_acct_entries: users merged into passwd + shadow ===")
    with tempfile.TemporaryDirectory() as rootfs:
        _write(os.path.join(rootfs, "etc", "passwd"), "root:x:0:0:root:/root:/bin/bash\n")
        _write(os.path.join(rootfs, "etc", "shadow"), "root:!:19000::::::\n")
        _write(os.path.join(rootfs, "etc", "group"), "root:x:0:\n")
        acct = os.path.join(rootfs, "usr", "share", "acct-user")
        _write(os.path.join(acct, "nobody.passwd"), "nobody:x:65534:65534:Nobody:/:/sbin/nologin")
        _write(os.path.join(acct, "nobody.shadow"), "nobody:!:19000::::::")
        _merge_acct_entries(rootfs)
        passwd = _read(os.path.join(rootfs, "etc", "passwd"))
        shadow = _read(os.path.join(rootfs, "etc", "shadow"))
        if ("nobody:x:65534:65534" in passwd
                and "nobody:!:19000" in shadow
                and "root:x:0:0" in passwd):
            ok("user merged into passwd + shadow")
        else:
            fail(f"user merge failed: passwd={passwd!r}, shadow={shadow!r}")

    # 23. Duplicate group names not added twice
    print("=== _merge_acct_entries: duplicate group not added ===")
    with tempfile.TemporaryDirectory() as rootfs:
        _write(os.path.join(rootfs, "etc", "group"), "audio:x:63:\n")
        acct = os.path.join(rootfs, "usr", "share", "acct-group")
        _write(os.path.join(acct, "audio.group"), "audio:x:63:")
        _merge_acct_entries(rootfs)
        content = _read(os.path.join(rootfs, "etc", "group"))
        count = content.count("audio:")
        if count == 1:
            ok("duplicate group not added")
        else:
            fail(f"audio appears {count} times")

    # 24. Supplementary group membership (.groups files) applied
    print("=== _merge_acct_entries: supplementary groups applied ===")
    with tempfile.TemporaryDirectory() as rootfs:
        _write(os.path.join(rootfs, "etc", "group"),
               "root:x:0:\naudio:x:63:\nvideo:x:39:\n")
        _write(os.path.join(rootfs, "etc", "passwd"), "root:x:0:0:root:/root:/bin/bash\n")
        _write(os.path.join(rootfs, "etc", "shadow"), "root:!:19000::::::\n")
        acct = os.path.join(rootfs, "usr", "share", "acct-user")
        _write(os.path.join(acct, "pulse.passwd"),
               "pulse:x:500:500:PulseAudio:/var/run/pulse:/sbin/nologin")
        _write(os.path.join(acct, "pulse.shadow"), "pulse:!:19000::::::")
        _write(os.path.join(acct, "pulse.groups"), "audio,video")
        _merge_acct_entries(rootfs)
        content = _read(os.path.join(rootfs, "etc", "group"))
        # audio line should have pulse as member
        audio_ok = False
        video_ok = False
        for line in content.splitlines():
            if line.startswith("audio:"):
                audio_ok = "pulse" in line.split(":")[-1]
            if line.startswith("video:"):
                video_ok = "pulse" in line.split(":")[-1]
        if audio_ok and video_ok:
            ok("pulse added to audio and video supplementary groups")
        else:
            fail(f"supplementary groups not applied: {content!r}")

    # 25. No acct dirs = no-op (no crash)
    print("=== _merge_acct_entries: no acct dirs => no-op ===")
    with tempfile.TemporaryDirectory() as rootfs:
        _write(os.path.join(rootfs, "etc", "group"), "root:x:0:\n")
        _write(os.path.join(rootfs, "etc", "passwd"), "root:x:0:0:root:/root:/bin/bash\n")
        try:
            _merge_acct_entries(rootfs)
            ok("no acct dirs, no crash")
        except Exception as e:
            fail(f"raised {e}")

    # 26. Duplicate user names not added twice
    print("=== _merge_acct_entries: duplicate user not added ===")
    with tempfile.TemporaryDirectory() as rootfs:
        _write(os.path.join(rootfs, "etc", "passwd"),
               "nobody:x:65534:65534:Nobody:/:/sbin/nologin\n")
        _write(os.path.join(rootfs, "etc", "shadow"), "nobody:!:19000::::::\n")
        _write(os.path.join(rootfs, "etc", "group"), "root:x:0:\n")
        acct = os.path.join(rootfs, "usr", "share", "acct-user")
        _write(os.path.join(acct, "nobody.passwd"),
               "nobody:x:65534:65534:Nobody:/:/sbin/nologin")
        _write(os.path.join(acct, "nobody.shadow"), "nobody:!:19000::::::")
        _merge_acct_entries(rootfs)
        passwd = _read(os.path.join(rootfs, "etc", "passwd"))
        count = passwd.count("nobody:")
        if count == 1:
            ok("duplicate user not added")
        else:
            fail(f"nobody appears {count} times")

    # 27. Non-.group files in acct-group dir are ignored
    print("=== _merge_acct_entries: non-.group files ignored ===")
    with tempfile.TemporaryDirectory() as rootfs:
        _write(os.path.join(rootfs, "etc", "group"), "root:x:0:\n")
        acct = os.path.join(rootfs, "usr", "share", "acct-group")
        _write(os.path.join(acct, "audio.group"), "audio:x:63:")
        _write(os.path.join(acct, "README"), "do not parse")
        _write(os.path.join(acct, "audio.bak"), "bogus:x:999:")
        _merge_acct_entries(rootfs)
        content = _read(os.path.join(rootfs, "etc", "group"))
        if "audio:x:63:" in content and "bogus" not in content and "do not" not in content:
            ok("non-.group files ignored")
        else:
            fail(f"unexpected content: {content!r}")

    # 28. Supplementary group with existing member doesn't duplicate
    print("=== _merge_acct_entries: supplementary group no duplicate member ===")
    with tempfile.TemporaryDirectory() as rootfs:
        _write(os.path.join(rootfs, "etc", "group"),
               "root:x:0:\naudio:x:63:pulse\n")
        _write(os.path.join(rootfs, "etc", "passwd"), "root:x:0:0:root:/root:/bin/bash\n")
        _write(os.path.join(rootfs, "etc", "shadow"), "root:!:19000::::::\n")
        acct = os.path.join(rootfs, "usr", "share", "acct-user")
        _write(os.path.join(acct, "pulse.passwd"),
               "pulse:x:500:500:PulseAudio:/var/run/pulse:/sbin/nologin")
        _write(os.path.join(acct, "pulse.shadow"), "pulse:!:19000::::::")
        _write(os.path.join(acct, "pulse.groups"), "audio")
        _merge_acct_entries(rootfs)
        content = _read(os.path.join(rootfs, "etc", "group"))
        for line in content.splitlines():
            if line.startswith("audio:"):
                members = line.split(":")[3]
                count = members.split(",").count("pulse")
                if count == 1:
                    ok("pulse not duplicated in audio group")
                else:
                    fail(f"pulse appears {count} times in audio members: {line!r}")
                break
        else:
            fail("audio group line not found")

    # 29. Shadow entries not merged when shadow file doesn't exist
    print("=== _merge_acct_entries: no shadow file => shadow entries skipped ===")
    with tempfile.TemporaryDirectory() as rootfs:
        _write(os.path.join(rootfs, "etc", "passwd"), "root:x:0:0:root:/root:/bin/bash\n")
        _write(os.path.join(rootfs, "etc", "group"), "root:x:0:\n")
        acct = os.path.join(rootfs, "usr", "share", "acct-user")
        _write(os.path.join(acct, "daemon.passwd"),
               "daemon:x:2:2:daemon:/sbin:/sbin/nologin")
        _write(os.path.join(acct, "daemon.shadow"), "daemon:!:19000::::::")
        try:
            _merge_acct_entries(rootfs)
            passwd = _read(os.path.join(rootfs, "etc", "passwd"))
            shadow_exists = os.path.isfile(os.path.join(rootfs, "etc", "shadow"))
            if "daemon:x:2:2" in passwd and not shadow_exists:
                ok("user added to passwd, shadow skipped (no shadow file)")
            else:
                fail(f"unexpected: passwd={passwd!r}, shadow_exists={shadow_exists}")
        except Exception as e:
            fail(f"raised {e}")

    # 30. Multiple groups merged in sorted order
    print("=== _merge_acct_entries: groups merged in sorted order ===")
    with tempfile.TemporaryDirectory() as rootfs:
        _write(os.path.join(rootfs, "etc", "group"), "")
        acct = os.path.join(rootfs, "usr", "share", "acct-group")
        _write(os.path.join(acct, "video.group"), "video:x:39:")
        _write(os.path.join(acct, "audio.group"), "audio:x:63:")
        _write(os.path.join(acct, "cdrom.group"), "cdrom:x:11:")
        _merge_acct_entries(rootfs)
        content = _read(os.path.join(rootfs, "etc", "group"))
        lines = [l for l in content.strip().splitlines() if l]
        names = [l.split(":")[0] for l in lines]
        if names == ["audio", "cdrom", "video"]:
            ok("groups merged in sorted filename order")
        else:
            fail(f"order wrong: {names}")

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
