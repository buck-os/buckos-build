#!/usr/bin/env python3
"""Unit tests for sysroot_merge.py."""
import io
import os
import subprocess
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


def _run(args):
    """Run sysroot_merge.py as a subprocess, return CompletedProcess."""
    cmd = [sys.executable, str(_REPO / "tools" / "sysroot_merge.py")] + args
    return subprocess.run(cmd, capture_output=True, text=True)


def main():
    _real_stdout = sys.stdout
    _buf = io.StringIO()
    sys.stdout = _buf

    # ===================================================================
    # 1. Base-only copy: creates output matching base contents
    # ===================================================================

    print("=== base-only copy ===")
    with tempfile.TemporaryDirectory() as tmp:
        base = os.path.join(tmp, "base")
        out = os.path.join(tmp, "out")
        _write(os.path.join(base, "include", "stdio.h"), "#pragma once\n")
        _write(os.path.join(base, "lib", "libc.so"), "ELF")
        r = _run(["--base", base, "--output-dir", out])
        if r.returncode != 0:
            fail(f"base-only exited {r.returncode}: {r.stderr}")
        else:
            if os.path.isfile(os.path.join(out, "include", "stdio.h")):
                ok("base header copied")
            else:
                fail("base header missing")
            if _read(os.path.join(out, "lib", "libc.so")) == "ELF":
                ok("base lib content correct")
            else:
                fail("base lib content wrong")

    # ===================================================================
    # 2. Base preserves symlinks
    # ===================================================================

    print("=== base preserves symlinks ===")
    with tempfile.TemporaryDirectory() as tmp:
        base = os.path.join(tmp, "base")
        out = os.path.join(tmp, "out")
        _write(os.path.join(base, "lib", "libc.so.6"), "ELF")
        os.symlink("libc.so.6", os.path.join(base, "lib", "libc.so"))
        r = _run(["--base", base, "--output-dir", out])
        if r.returncode != 0:
            fail(f"base symlink exited {r.returncode}: {r.stderr}")
        else:
            link = os.path.join(out, "lib", "libc.so")
            if os.path.islink(link) and os.readlink(link) == "libc.so.6":
                ok("base symlink preserved")
            else:
                fail("base symlink not preserved")

    # ===================================================================
    # 3. Overlay-only (no base): creates output with overlay contents
    # ===================================================================

    print("=== overlay-only (no base) ===")
    with tempfile.TemporaryDirectory() as tmp:
        overlay = os.path.join(tmp, "overlay")
        out = os.path.join(tmp, "out")
        _write(os.path.join(overlay, "include", "linux", "types.h"), "/* types */\n")
        r = _run(["--overlay", overlay, "--output-dir", out])
        if r.returncode != 0:
            fail(f"overlay-only exited {r.returncode}: {r.stderr}")
        else:
            if os.path.isfile(os.path.join(out, "include", "linux", "types.h")):
                ok("overlay-only file present")
            else:
                fail("overlay-only file missing")
            if _read(os.path.join(out, "include", "linux", "types.h")) == "/* types */\n":
                ok("overlay-only file content correct")
            else:
                fail("overlay-only file content wrong")

    # ===================================================================
    # 4. Base + single overlay: overlay files merge into base
    # ===================================================================

    print("=== base + single overlay merge ===")
    with tempfile.TemporaryDirectory() as tmp:
        base = os.path.join(tmp, "base")
        overlay = os.path.join(tmp, "overlay")
        out = os.path.join(tmp, "out")
        _write(os.path.join(base, "include", "stdio.h"), "stdio\n")
        _write(os.path.join(overlay, "include", "stdlib.h"), "stdlib\n")
        r = _run(["--base", base, "--overlay", overlay, "--output-dir", out])
        if r.returncode != 0:
            fail(f"base+overlay exited {r.returncode}: {r.stderr}")
        else:
            has_base = os.path.isfile(os.path.join(out, "include", "stdio.h"))
            has_overlay = os.path.isfile(os.path.join(out, "include", "stdlib.h"))
            if has_base and has_overlay:
                ok("base and overlay files both present")
            else:
                fail(f"base={has_base}, overlay={has_overlay}")

    # ===================================================================
    # 5. Overlay overwrites existing base file
    # ===================================================================

    print("=== overlay overwrites base file ===")
    with tempfile.TemporaryDirectory() as tmp:
        base = os.path.join(tmp, "base")
        overlay = os.path.join(tmp, "overlay")
        out = os.path.join(tmp, "out")
        _write(os.path.join(base, "include", "version.h"), "v1\n")
        _write(os.path.join(overlay, "include", "version.h"), "v2\n")
        r = _run(["--base", base, "--overlay", overlay, "--output-dir", out])
        if r.returncode != 0:
            fail(f"overlay overwrite exited {r.returncode}: {r.stderr}")
        else:
            content = _read(os.path.join(out, "include", "version.h"))
            if content == "v2\n":
                ok("overlay overwrote base file")
            else:
                fail(f"expected 'v2\\n', got {content!r}")

    # ===================================================================
    # 6. Multiple overlays applied in order (later overrides earlier)
    # ===================================================================

    print("=== multiple overlays in order ===")
    with tempfile.TemporaryDirectory() as tmp:
        base = os.path.join(tmp, "base")
        ov1 = os.path.join(tmp, "ov1")
        ov2 = os.path.join(tmp, "ov2")
        out = os.path.join(tmp, "out")
        _write(os.path.join(base, "lib", "base.txt"), "base")
        _write(os.path.join(ov1, "lib", "shared.txt"), "from-ov1")
        _write(os.path.join(ov1, "lib", "ov1-only.txt"), "ov1")
        _write(os.path.join(ov2, "lib", "shared.txt"), "from-ov2")
        _write(os.path.join(ov2, "lib", "ov2-only.txt"), "ov2")
        r = _run([
            "--base", base,
            "--overlay", ov1,
            "--overlay", ov2,
            "--output-dir", out,
        ])
        if r.returncode != 0:
            fail(f"multi-overlay exited {r.returncode}: {r.stderr}")
        else:
            # shared.txt should have ov2's content (later wins)
            if _read(os.path.join(out, "lib", "shared.txt")) == "from-ov2":
                ok("later overlay overrides earlier")
            else:
                fail("shared.txt not from ov2")
            # each overlay's unique file present
            if (os.path.isfile(os.path.join(out, "lib", "ov1-only.txt"))
                    and os.path.isfile(os.path.join(out, "lib", "ov2-only.txt"))):
                ok("both overlay-unique files present")
            else:
                fail("overlay-unique files missing")
            # base file still present
            if os.path.isfile(os.path.join(out, "lib", "base.txt")):
                ok("base file survives overlays")
            else:
                fail("base file missing after overlays")

    # ===================================================================
    # 7. Overlay preserves symlinks (replaces existing file with symlink)
    # ===================================================================

    print("=== overlay preserves symlinks ===")
    with tempfile.TemporaryDirectory() as tmp:
        base = os.path.join(tmp, "base")
        overlay = os.path.join(tmp, "overlay")
        out = os.path.join(tmp, "out")
        _write(os.path.join(base, "lib", "libfoo.so"), "regular-file")
        _write(os.path.join(overlay, "lib", "libfoo.so.1"), "ELF")
        os.symlink("libfoo.so.1", os.path.join(overlay, "lib", "libfoo.so"))
        r = _run(["--base", base, "--overlay", overlay, "--output-dir", out])
        if r.returncode != 0:
            fail(f"overlay symlink exited {r.returncode}: {r.stderr}")
        else:
            link = os.path.join(out, "lib", "libfoo.so")
            if os.path.islink(link) and os.readlink(link) == "libfoo.so.1":
                ok("overlay symlink replaced regular file")
            else:
                fail("overlay symlink not preserved")

    # ===================================================================
    # 8. Overlay regular file over base symlink writes through link
    # ===================================================================

    # shutil.copy2 follows the destination symlink, so the overlay content
    # lands in the link target while the symlink itself is preserved.
    print("=== overlay regular file writes through base symlink ===")
    with tempfile.TemporaryDirectory() as tmp:
        base = os.path.join(tmp, "base")
        overlay = os.path.join(tmp, "overlay")
        out = os.path.join(tmp, "out")
        _write(os.path.join(base, "lib", "libbar.so.1"), "old-ELF")
        os.symlink("libbar.so.1", os.path.join(base, "lib", "libbar.so"))
        _write(os.path.join(overlay, "lib", "libbar.so"), "new-content")
        r = _run(["--base", base, "--overlay", overlay, "--output-dir", out])
        if r.returncode != 0:
            fail(f"write-through exited {r.returncode}: {r.stderr}")
        else:
            link = os.path.join(out, "lib", "libbar.so")
            target = os.path.join(out, "lib", "libbar.so.1")
            # symlink preserved, content written through to target
            if (os.path.islink(link)
                    and _read(target) == "new-content"):
                ok("overlay wrote through base symlink to target")
            else:
                fail("write-through behavior not observed")

    # ===================================================================
    # 9. Deep nested directory merging
    # ===================================================================

    print("=== deep nested directory merging ===")
    with tempfile.TemporaryDirectory() as tmp:
        base = os.path.join(tmp, "base")
        overlay = os.path.join(tmp, "overlay")
        out = os.path.join(tmp, "out")
        _write(os.path.join(base, "a", "b", "c", "base.txt"), "base")
        _write(os.path.join(overlay, "a", "b", "c", "overlay.txt"), "overlay")
        _write(os.path.join(overlay, "a", "b", "d", "new.txt"), "new-dir")
        r = _run(["--base", base, "--overlay", overlay, "--output-dir", out])
        if r.returncode != 0:
            fail(f"deep nested exited {r.returncode}: {r.stderr}")
        else:
            if os.path.isfile(os.path.join(out, "a", "b", "c", "base.txt")):
                ok("deep nested base file preserved")
            else:
                fail("deep nested base file missing")
            if os.path.isfile(os.path.join(out, "a", "b", "c", "overlay.txt")):
                ok("deep nested overlay file merged")
            else:
                fail("deep nested overlay file missing")
            if os.path.isfile(os.path.join(out, "a", "b", "d", "new.txt")):
                ok("deep nested new directory created")
            else:
                fail("deep nested new directory missing")

    # ===================================================================
    # 10. No base, no overlay -> exit code 1
    # ===================================================================

    print("=== no base, no overlay -> error ===")
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "out")
        r = _run(["--output-dir", out])
        if r.returncode != 0 and "at least" in r.stderr:
            ok("no base or overlay gives error")
        else:
            fail(f"expected error, got rc={r.returncode}, stderr={r.stderr!r}")

    # ===================================================================
    # 11. Missing base directory -> exit code 1
    # ===================================================================

    print("=== missing base directory -> error ===")
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "out")
        r = _run(["--base", os.path.join(tmp, "nonexistent"), "--output-dir", out])
        if r.returncode != 0 and "not found" in r.stderr:
            ok("missing base directory gives error")
        else:
            fail(f"expected error, got rc={r.returncode}, stderr={r.stderr!r}")

    # ===================================================================
    # 12. Missing overlay directory -> exit code 1
    # ===================================================================

    print("=== missing overlay directory -> error ===")
    with tempfile.TemporaryDirectory() as tmp:
        base = os.path.join(tmp, "base")
        out = os.path.join(tmp, "out")
        os.makedirs(base)
        r = _run([
            "--base", base,
            "--overlay", os.path.join(tmp, "nonexistent"),
            "--output-dir", out,
        ])
        if r.returncode != 0 and "not found" in r.stderr:
            ok("missing overlay directory gives error")
        else:
            fail(f"expected error, got rc={r.returncode}, stderr={r.stderr!r}")

    # ===================================================================
    # 13. Existing output directory gets cleaned before merge
    # ===================================================================

    print("=== existing output directory cleaned ===")
    with tempfile.TemporaryDirectory() as tmp:
        base = os.path.join(tmp, "base")
        out = os.path.join(tmp, "out")
        _write(os.path.join(base, "new.txt"), "new")
        _write(os.path.join(out, "stale.txt"), "stale")
        _write(os.path.join(out, "sub", "deep.txt"), "deep-stale")
        r = _run(["--base", base, "--output-dir", out])
        if r.returncode != 0:
            fail(f"clean output exited {r.returncode}: {r.stderr}")
        else:
            has_new = os.path.isfile(os.path.join(out, "new.txt"))
            has_stale = os.path.exists(os.path.join(out, "stale.txt"))
            has_deep = os.path.exists(os.path.join(out, "sub", "deep.txt"))
            if has_new and not has_stale and not has_deep:
                ok("existing output dir cleaned before merge")
            else:
                fail(f"new={has_new}, stale={has_stale}, deep={has_deep}")

    # ===================================================================
    # 14. Base files not modified by merge
    # ===================================================================

    print("=== base files not modified ===")
    with tempfile.TemporaryDirectory() as tmp:
        base = os.path.join(tmp, "base")
        overlay = os.path.join(tmp, "overlay")
        out = os.path.join(tmp, "out")
        _write(os.path.join(base, "file.txt"), "original")
        _write(os.path.join(overlay, "file.txt"), "overwritten")
        r = _run(["--base", base, "--overlay", overlay, "--output-dir", out])
        if r.returncode != 0:
            fail(f"base unmodified exited {r.returncode}: {r.stderr}")
        else:
            if _read(os.path.join(base, "file.txt")) == "original":
                ok("base directory not modified")
            else:
                fail("base directory was modified")

    # ===================================================================
    # 15. Overlay adds new subdirectory not in base
    # ===================================================================

    print("=== overlay adds new subdirectory ===")
    with tempfile.TemporaryDirectory() as tmp:
        base = os.path.join(tmp, "base")
        overlay = os.path.join(tmp, "overlay")
        out = os.path.join(tmp, "out")
        _write(os.path.join(base, "include", "a.h"), "a")
        _write(os.path.join(overlay, "lib", "pkgconfig", "foo.pc"), "pc")
        r = _run(["--base", base, "--overlay", overlay, "--output-dir", out])
        if r.returncode != 0:
            fail(f"new subdir exited {r.returncode}: {r.stderr}")
        else:
            if (os.path.isfile(os.path.join(out, "include", "a.h"))
                    and os.path.isfile(os.path.join(out, "lib", "pkgconfig", "foo.pc"))):
                ok("overlay added new subdirectory alongside base")
            else:
                fail("new subdirectory or base file missing")

    # ===================================================================
    # 16. Multiple overlays without base
    # ===================================================================

    print("=== multiple overlays without base ===")
    with tempfile.TemporaryDirectory() as tmp:
        ov1 = os.path.join(tmp, "ov1")
        ov2 = os.path.join(tmp, "ov2")
        out = os.path.join(tmp, "out")
        _write(os.path.join(ov1, "bin", "tool1"), "t1")
        _write(os.path.join(ov2, "bin", "tool2"), "t2")
        r = _run(["--overlay", ov1, "--overlay", ov2, "--output-dir", out])
        if r.returncode != 0:
            fail(f"multi-overlay no base exited {r.returncode}: {r.stderr}")
        else:
            has_t1 = os.path.isfile(os.path.join(out, "bin", "tool1"))
            has_t2 = os.path.isfile(os.path.join(out, "bin", "tool2"))
            if has_t1 and has_t2:
                ok("multiple overlays without base merged correctly")
            else:
                fail(f"tool1={has_t1}, tool2={has_t2}")

    # ===================================================================
    # 17. Empty base directory produces empty output
    # ===================================================================

    print("=== empty base directory ===")
    with tempfile.TemporaryDirectory() as tmp:
        base = os.path.join(tmp, "base")
        out = os.path.join(tmp, "out")
        os.makedirs(base)
        r = _run(["--base", base, "--output-dir", out])
        if r.returncode != 0:
            fail(f"empty base exited {r.returncode}: {r.stderr}")
        else:
            if os.path.isdir(out) and os.listdir(out) == []:
                ok("empty base produces empty output")
            else:
                fail(f"output contents: {os.listdir(out)}")

    # ===================================================================
    # 18. Overlay with dangling symlink
    # ===================================================================

    print("=== overlay with dangling symlink ===")
    with tempfile.TemporaryDirectory() as tmp:
        overlay = os.path.join(tmp, "overlay")
        out = os.path.join(tmp, "out")
        os.makedirs(os.path.join(overlay, "lib"))
        os.symlink("nonexistent.so.1", os.path.join(overlay, "lib", "libdangle.so"))
        r = _run(["--overlay", overlay, "--output-dir", out])
        if r.returncode != 0:
            fail(f"dangling symlink exited {r.returncode}: {r.stderr}")
        else:
            link = os.path.join(out, "lib", "libdangle.so")
            if (os.path.islink(link)
                    and os.readlink(link) == "nonexistent.so.1"
                    and not os.path.exists(link)):
                ok("dangling symlink preserved in overlay")
            else:
                fail("dangling symlink not handled correctly")

    # ===================================================================
    # 19. File permissions preserved via copy2
    # ===================================================================

    print("=== file permissions preserved ===")
    with tempfile.TemporaryDirectory() as tmp:
        base = os.path.join(tmp, "base")
        out = os.path.join(tmp, "out")
        exe = os.path.join(base, "bin", "prog")
        _write(exe, "#!/bin/sh\n")
        os.chmod(exe, 0o755)
        r = _run(["--base", base, "--output-dir", out])
        if r.returncode != 0:
            fail(f"permissions exited {r.returncode}: {r.stderr}")
        else:
            import stat
            mode = stat.S_IMODE(os.stat(os.path.join(out, "bin", "prog")).st_mode)
            if mode & 0o111:
                ok("executable permission preserved")
            else:
                fail(f"mode={oct(mode)}, expected executable bit set")

    # ===================================================================
    # 20. Overlay file over dangling base symlink creates target file
    # ===================================================================

    # shutil.copy2 follows the dangling symlink at the dest and creates
    # the target file, so the symlink becomes valid after the copy.
    print("=== overlay file over dangling base symlink ===")
    with tempfile.TemporaryDirectory() as tmp:
        base = os.path.join(tmp, "base")
        overlay = os.path.join(tmp, "overlay")
        out = os.path.join(tmp, "out")
        os.makedirs(os.path.join(base, "lib"))
        os.symlink("lib.so.1", os.path.join(base, "lib", "lib.so"))
        _write(os.path.join(overlay, "lib", "lib.so"), "real-content")
        r = _run(["--base", base, "--overlay", overlay, "--output-dir", out])
        if r.returncode != 0:
            fail(f"dangling overlay exited {r.returncode}: {r.stderr}")
        else:
            link = os.path.join(out, "lib", "lib.so")
            target = os.path.join(out, "lib", "lib.so.1")
            # symlink kept, target file created with overlay content
            if (os.path.islink(link)
                    and os.path.isfile(target)
                    and _read(target) == "real-content"):
                ok("overlay created target file through dangling symlink")
            else:
                fail("dangling symlink behavior unexpected")

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
