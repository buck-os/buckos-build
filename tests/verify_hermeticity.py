#!/usr/bin/env python3
"""Hermeticity gate: assert a built rootfs is ELF-dependency-closed.

Runs tools/elf_audit.py over the rootfs named in $ROOTFS and fails if any
binary has a DT_NEEDED soname not provided anywhere in the image (after the
base-sysroot allowlist).  Catches the class of bug where a package lands in
a rootfs without its transitive runtime shared-lib deps, so the binary dies
at runtime with "error while loading shared libraries".

Env:
  ROOTFS            built rootfs to audit (directory, or .tar/.tar.* archive)
  ALLOW_UNRESOLVED  space-separated sonames to tolerate (escape hatch)
"""

import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

_REPO = Path(__file__).resolve().parent.parent
_ELF_AUDIT = _REPO / "tools" / "elf_audit.py"


def _resolve_rootfs(rootfs):
    """Return (audit_dir, tmp_to_cleanup). Extracts tarballs to a tmp dir."""
    p = Path(rootfs)
    if p.is_dir():
        return p, None
    if p.is_file() and ".tar" in p.name:
        tmp = tempfile.mkdtemp(prefix="hermeticity-")
        with tarfile.open(p) as tf:
            tf.extractall(tmp)
        return Path(tmp), tmp
    print(f"FAIL: ROOTFS not a directory or tar archive: {rootfs}", file=sys.stderr)
    sys.exit(1)


def main():
    rootfs = os.environ.get("ROOTFS", "")
    if not rootfs:
        print("FAIL: ROOTFS env not set", file=sys.stderr)
        sys.exit(1)
    if not _ELF_AUDIT.is_file():
        print(f"FAIL: elf_audit not found at {_ELF_AUDIT}", file=sys.stderr)
        sys.exit(1)

    audit_dir, tmp = _resolve_rootfs(rootfs)
    cmd = [sys.executable, str(_ELF_AUDIT), "--prefix", str(audit_dir)]
    for soname in os.environ.get("ALLOW_UNRESOLVED", "").split():
        cmd += ["--allow-unresolved", soname]

    print(f"hermeticity: auditing ELF closure of {audit_dir}", file=sys.stderr)
    rc = subprocess.call(cmd)

    if tmp:
        shutil.rmtree(tmp, ignore_errors=True)

    if rc == 0:
        print("HERMETICITY: PASS", file=sys.stderr)
    else:
        print(
            "HERMETICITY: FAIL — unresolved shared-lib deps in rootfs", file=sys.stderr
        )
    sys.exit(rc)


if __name__ == "__main__":
    main()
