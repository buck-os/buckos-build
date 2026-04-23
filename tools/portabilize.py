"""Make seed toolchain ELF binaries runnable on any host.

The seed toolchain contains gcc, perl, python, make, and ~400 other
host tools linked against sysroot glibc (e.g., 2.38).  On hosts with
older glibc, these binaries crash with "GLIBC_2.38 not found".

This module patches ELF binaries so they use the sysroot's ld-linux
and find sysroot libs via $ORIGIN-relative RPATH.  No shell wrappers,
no LD_LIBRARY_PATH — the binaries run directly after patching.

Usage:
    from portabilize import portabilize_toolchain
    dirs = portabilize_toolchain(bin_dirs, ld_linux_path, scratch_dir)
    env["PATH"] = ":".join(dirs)
"""

import hashlib
import os
import shutil
import struct
import subprocess
import sys


def _stable_scratch():
    """Return a stable scratch directory that persists across build phases.

    Each build phase (configure/compile/install) gets a different
    BUCK_SCRATCH_PATH, so portabilized copies wouldn't be reusable.
    This uses a fixed location under buck-out that survives across
    phases but is cleaned on `buck2 clean`.
    """
    d = os.path.join(os.getcwd(), "buck-out", "v2", "tmp", "portabilize")
    os.makedirs(d, exist_ok=True)
    return d


def portabilize_toolchain(bin_dirs, ld_linux_path, scratch_dir=None,
                          patchelf_path=None):
    """Make ELF binaries in bin_dirs runnable on any host.

    Patches PT_INTERP to a deterministic /tmp symlink and sets
    $ORIGIN-relative RPATH so binaries find sysroot libs without
    LD_LIBRARY_PATH or shell wrappers.

    Args:
        bin_dirs: List of directories containing ELF binaries (e.g.,
            host-tools/bin from the seed toolchain).
        ld_linux_path: Path to the sysroot ld-linux dynamic linker.
        scratch_dir: Writable directory for creating copies of
            read-only artifacts.
        patchelf_path: Path to patchelf binary.  If None, searched
            on PATH and in bin_dirs.

    Returns:
        List of directory paths to use in PATH.  Read-only input
        dirs are replaced with writable scratch copies.
    """
    if scratch_dir is None:
        scratch_dir = _stable_scratch()
    ld_linux = os.path.abspath(ld_linux_path)
    if not os.path.isfile(ld_linux):
        print(f"portabilize: ld-linux not found: {ld_linux}", file=sys.stderr)
        return list(bin_dirs)

    interp = _ensure_tmp_symlink(ld_linux)
    sysroot = _derive_sysroot(ld_linux)
    gcc_runtime = _derive_gcc_runtime(ld_linux)
    patchelf = _find_patchelf(patchelf_path, bin_dirs)

    result = []
    for bin_dir in bin_dirs:
        bin_abs = os.path.abspath(bin_dir)
        if not os.path.isdir(bin_abs):
            result.append(bin_abs)
            continue

        # Portabilize the parent tree so gcc subprograms (cc1 in
        # libexec/, as in <triple>/bin/) are also patched.
        parent = os.path.dirname(bin_abs)
        work = _copy_tree(parent, scratch_dir)
        _create_sysroot_lib_symlinks(work, sysroot, gcc_runtime)
        _patch_elfs(work, interp, sysroot, gcc_runtime, patchelf)
        result.append(os.path.join(work, os.path.basename(bin_abs)))

    return result


# ── /tmp symlink ──────────────────────────────────────────────────────

def _ensure_tmp_symlink(ld_linux):
    """Create /tmp/.buckos-ld-<hash> → ld_linux symlink.

    The hash is derived from the ld-linux binary content so different
    toolchain versions don't collide.  Uses atomic rename to handle
    concurrent actions.
    """
    with open(ld_linux, "rb") as f:
        h = hashlib.sha1(f.read(8192)).hexdigest()[:12]
    interp = "/tmp/.buckos-ld-" + h
    try:
        import tempfile
        tmp = tempfile.mktemp(dir="/tmp", prefix=".buckos-ld-tmp-")
        os.symlink(ld_linux, tmp)
        os.rename(tmp, interp)
    except OSError:
        pass
    return interp


# ── Sysroot discovery ────────────────────────────────────────────────

def _derive_sysroot(ld_linux):
    """Derive sysroot root from ld-linux path.

    ld-linux is at <sysroot>/lib64/ld-linux-x86-64.so.2 (or lib/ on aarch64).
    Returns the sysroot directory.
    """
    return os.path.dirname(os.path.dirname(ld_linux))


def _derive_gcc_runtime(ld_linux):
    """Derive GCC runtime lib directory from ld-linux path.

    The seed layout is:
        patched-compiler/tools/<triple>/sys-root/lib64/ld-linux  (sysroot)
        patched-compiler/tools/<triple>/lib64/libstdc++.so.6     (gcc runtime)

    Or for toolchain_import:
        toolchain/tools/<triple>/sys-root/lib64/ld-linux
        toolchain/tools/<triple>/lib64/libstdc++.so.6
    """
    sysroot = _derive_sysroot(ld_linux)
    triple_dir = os.path.dirname(sysroot)
    for sub in ("lib64", "lib"):
        d = os.path.join(triple_dir, sub)
        if os.path.isdir(d):
            return d
    return None


def _sysroot_lib_dirs(sysroot):
    """Return existing lib directories in the sysroot."""
    dirs = []
    for sub in ("usr/lib64", "usr/lib", "lib64", "lib"):
        d = os.path.join(sysroot, sub)
        if os.path.isdir(d):
            dirs.append(d)
    return dirs


# ── Writable copy ────────────────────────────────────────────────────

def _copy_tree(tree_dir, scratch_dir):
    """Create a writable copy of tree_dir in scratch.

    Always copies — never modifies the original, which may be a
    Buck2 cached artifact or a shared seed archive.

    Uses a content-addressed path so the copy is reused across
    build phases (configure/compile/install) which each get
    different BUCK_SCRATCH_PATH values.

    Returns the path to the copy.
    """
    tree_abs = os.path.abspath(tree_dir)
    # Use a hash of the absolute path for stable, unique naming.
    # This ensures the same input dir always maps to the same
    # scratch copy, reusable across phases.
    path_hash = hashlib.sha1(tree_abs.encode()).hexdigest()[:12]
    copy_name = os.path.basename(tree_abs) + "-" + path_hash
    copy = os.path.join(scratch_dir, ".port-" + copy_name)

    if os.path.exists(copy):
        return copy

    shutil.copytree(tree_abs, copy, symlinks=True)
    return copy


# ── RPATH computation ────────────────────────────────────────────────

_SYSROOT_LIBS = (
    "libc.so.6", "libm.so.6", "libdl.so.2", "libpthread.so.0",
    "librt.so.1", "libresolv.so.2", "libutil.so.1",
    "libcrypt.so.1", "libmvec.so.1",
)

_GCC_RUNTIME_LIBS = (
    "libgcc_s.so.1", "libstdc++.so.6",
)


def _create_sysroot_lib_symlinks(container, sysroot, gcc_runtime):
    """Create sibling lib directories with symlinks to sysroot libs.

    After this, $ORIGIN/../sysroot-lib64 contains symlinks to
    sysroot's libc.so.6, libm.so.6, etc.  The RPATH we set on
    binaries includes $ORIGIN/../sysroot-lib64.
    """
    sysroot_dirs = _sysroot_lib_dirs(sysroot)

    for target_name in ("sysroot-lib64", "sysroot-lib"):
        target = os.path.join(container, target_name)
        os.makedirs(target, exist_ok=True)

        for lib_name in _SYSROOT_LIBS:
            dst = os.path.join(target, lib_name)
            if os.path.exists(dst):
                continue
            for sdir in sysroot_dirs:
                src = os.path.join(sdir, lib_name)
                if os.path.exists(src):
                    try:
                        os.symlink(src, dst)
                    except OSError:
                        pass
                    break

        if gcc_runtime:
            for lib_name in _GCC_RUNTIME_LIBS:
                dst = os.path.join(target, lib_name)
                if os.path.exists(dst):
                    continue
                src = os.path.join(gcc_runtime, lib_name)
                if os.path.exists(src):
                    try:
                        os.symlink(src, dst)
                    except OSError:
                        pass


# ── ELF patching ─────────────────────────────────────────────────────

def _find_patchelf(patchelf_path, bin_dirs):
    """Find patchelf binary."""
    if patchelf_path and os.path.isfile(patchelf_path):
        return patchelf_path
    for d in bin_dirs:
        p = os.path.join(os.path.abspath(d), "patchelf")
        if os.path.isfile(p):
            return p
    p = shutil.which("patchelf")
    if p:
        return p
    return None


def _is_elf(path):
    """Check if file is a 64-bit ELF."""
    try:
        with open(path, "rb") as f:
            hdr = f.read(5)
        return hdr[:4] == b"\x7fELF" and hdr[4] == 2
    except (OSError, PermissionError):
        return False


def _has_pt_interp(path):
    """Check if ELF has PT_INTERP (is an executable, not a shared lib)."""
    try:
        with open(path, "rb") as f:
            data = f.read()
        e_phoff = struct.unpack_from("<Q", data, 32)[0]
        e_phentsize = struct.unpack_from("<H", data, 54)[0]
        e_phnum = struct.unpack_from("<H", data, 56)[0]
        for i in range(e_phnum):
            off = e_phoff + i * e_phentsize
            if struct.unpack_from("<I", data, off)[0] == 3:
                return True
    except (struct.error, IndexError, OSError):
        pass
    return False


def _patch_elfs(container, interp, sysroot, gcc_runtime, patchelf):
    """Patch PT_INTERP and RPATH on all ELF executables in container."""
    if not patchelf:
        print("portabilize: patchelf not found, skipping ELF patching",
              file=sys.stderr)
        return

    patched = 0
    # Walk the container to find all ELF executables
    for dirpath, dirnames, filenames in os.walk(container):
        # Don't descend into sysroot symlink dirs
        dirnames[:] = [d for d in dirnames
                       if not d.startswith("sysroot-")]
        for fname in filenames:
            fpath = os.path.join(dirpath, fname)
            if os.path.islink(fpath):
                continue
            if fname.endswith(".so") or ".so." in fname:
                continue
            if not _is_elf(fpath) or not _has_pt_interp(fpath):
                continue

            os.chmod(fpath, 0o755)

            # Compute $ORIGIN-relative RPATH
            rpath = _compute_rpath(fpath, container, gcc_runtime)

            try:
                subprocess.run(
                    [patchelf, "--set-interpreter", interp, fpath],
                    capture_output=True, timeout=30,
                )
                subprocess.run(
                    [patchelf, "--set-rpath", rpath, fpath],
                    capture_output=True, timeout=30,
                )
                patched += 1
            except (subprocess.TimeoutExpired, OSError) as e:
                print(f"portabilize: patchelf failed on {fpath}: {e}",
                      file=sys.stderr)

    print(f"portabilize: patched {patched} ELF binaries in {container}",
          file=sys.stderr)


def _compute_rpath(elf_path, container, gcc_runtime):
    """Compute $ORIGIN-relative RPATH for an ELF binary.

    Includes paths to:
    1. Package-local lib dirs (../lib, ../lib64)
    2. Sysroot libs (../sysroot-lib64)
    3. GCC runtime libs (if gcc_runtime is provided)
    """
    bin_dir = os.path.dirname(elf_path)
    entries = []

    # Package-local lib dirs
    for sub in ("lib", "lib64"):
        d = os.path.join(os.path.dirname(bin_dir), sub)
        if os.path.isdir(d):
            rel = os.path.relpath(d, bin_dir)
            entries.append("$ORIGIN/" + rel)

    # Sysroot lib symlinks
    for sub in ("sysroot-lib64", "sysroot-lib"):
        d = os.path.join(container, sub)
        if os.path.isdir(d):
            rel = os.path.relpath(d, bin_dir)
            entries.append("$ORIGIN/" + rel)

    return ":".join(entries) if entries else "$ORIGIN/../lib"


# ── Standalone test ──────────────────────────────────────────────────

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(
        description="Portabilize seed toolchain binaries")
    parser.add_argument("--bin-dir", action="append", required=True,
                        help="Directory of ELF binaries (repeatable)")
    parser.add_argument("--ld-linux", required=True,
                        help="Path to sysroot ld-linux")
    parser.add_argument("--scratch-dir", required=True,
                        help="Writable scratch directory")
    parser.add_argument("--patchelf", default=None,
                        help="Path to patchelf binary")
    args = parser.parse_args()

    result = portabilize_toolchain(
        args.bin_dir, args.ld_linux, args.scratch_dir, args.patchelf)
    for d in result:
        print(d)
