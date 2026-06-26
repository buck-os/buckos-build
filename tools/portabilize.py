"""Make seed toolchain ELF binaries runnable on any host.

The seed toolchain contains gcc, perl, python, make, and ~400 other
host tools linked against sysroot glibc (e.g., 2.38).  On hosts with
older glibc, these binaries crash with "GLIBC_2.38 not found".

This module creates shell wrapper scripts that invoke ELF binaries
through the sysroot ld-linux dynamic linker with the correct library
path.  No patchelf, no binary modification — just wrappers.

Usage:
    from portabilize import portabilize_toolchain
    dirs = portabilize_toolchain(bin_dirs, ld_linux_path)
    env["PATH"] = ":".join(dirs)
"""

import hashlib
import os
import struct
import subprocess
import sys


def portabilize_env(env, ld_linux_path, hermetic_dirs=None, patchelf_path=None):
    """Portabilize PATH and CC/CXX/AR in an env dict.

    Convenience wrapper that portabilizes hermetic PATH dirs and
    CC/CXX/AR binaries in one call.  Modifies env in place.
    Returns list of portabilized PATH dirs.
    """
    result_dirs = []
    if hermetic_dirs:
        result_dirs = portabilize_toolchain(
            hermetic_dirs, ld_linux_path, patchelf_path=patchelf_path
        )

    cc_dirs = set()
    for var in ("CC", "CXX", "AR"):
        val = env.get(var, "")
        if val:
            bin_path = os.path.abspath(val.split()[0])
            if os.path.isfile(bin_path):
                cc_dirs.add(os.path.dirname(bin_path))
    if cc_dirs:
        port_cc = portabilize_toolchain(
            list(cc_dirs), ld_linux_path, patchelf_path=patchelf_path
        )
        port_map = dict(zip(cc_dirs, port_cc))
        for var in ("CC", "CXX", "AR"):
            val = env.get(var, "")
            if not val:
                continue
            parts = val.split()
            bin_path = os.path.abspath(parts[0])
            bin_dir = os.path.dirname(bin_path)
            if bin_dir in port_map:
                parts[0] = os.path.join(port_map[bin_dir], os.path.basename(bin_path))
                env[var] = " ".join(parts)
        if "CPP" in env:
            env["CPP"] = env.get("CC", "cc") + " -E"

    return result_dirs


def _stable_scratch():
    """Return a stable scratch directory that persists across build phases."""
    d = os.path.join(os.getcwd(), "buck-out", "v2", "tmp", "portabilize")
    os.makedirs(d, exist_ok=True)
    return d


def portabilize_toolchain(
    bin_dirs, ld_linux_path, scratch_dir=None, patchelf_path=None
):
    """Create ld-linux wrapper scripts for ELF binaries in bin_dirs.

    For each ELF executable with PT_INTERP, creates a shell script
    wrapper that invokes it through the sysroot ld-linux dynamic
    linker.  Non-ELF files (scripts, symlinks) are symlinked into
    the wrapper directory.

    Args:
        bin_dirs: List of directories containing ELF binaries.
        ld_linux_path: Path to the sysroot ld-linux dynamic linker.
        scratch_dir: Writable directory for wrapper scripts.
        patchelf_path: Unused (kept for API compatibility).

    Returns:
        List of wrapper directory paths to use in PATH.
    """
    if scratch_dir is None:
        scratch_dir = _stable_scratch()
    ld_linux = os.path.abspath(ld_linux_path)
    if not os.path.isfile(ld_linux):
        print(f"portabilize: ld-linux not found: {ld_linux}", file=sys.stderr)
        return list(bin_dirs)

    sysroot = _derive_sysroot(ld_linux)
    gcc_runtime = _derive_gcc_runtime(ld_linux)
    base_lib_path = _build_lib_path(sysroot, gcc_runtime)

    result = []
    for bin_dir in bin_dirs:
        bin_abs = os.path.abspath(bin_dir)
        if not os.path.isdir(bin_abs):
            result.append(bin_abs)
            continue
        # A gcc toolchain execs its subprograms (cc1, cc1plus, collect2, lto1,
        # as, ld, ...) by absolute path, so the bin/ wrappers can't cover them;
        # their interp/RUNPATH must be rewritten in place instead, which needs
        # a writable tree.  Copy the toolchain into writable scratch and
        # relocate the copy (see _copy_and_relocate_toolchain) so this works
        # under remote execution, where action inputs are materialized
        # read-only.
        if _is_gcc_toolchain(bin_abs):
            result.append(_copy_and_relocate_toolchain(bin_abs, ld_linux, scratch_dir))
            continue
        # Non-toolchain host tools: a PATH of ld-linux wrappers is enough and
        # works read-only (the wrappers live in writable scratch, the wrapped
        # binaries are only exec'd).  Include package-local lib dirs so wrapped
        # binaries find their own shared libs (e.g. bash→libreadline,
        # perl→libperl).
        pkg_libs = _package_lib_dirs(bin_abs)
        lib_path = base_lib_path
        if pkg_libs:
            lib_path = ":".join(pkg_libs) + ":" + base_lib_path
        wrapper_dir = _create_wrappers(bin_abs, ld_linux, lib_path, scratch_dir)
        result.append(wrapper_dir)

    return result


def _is_gcc_toolchain(bin_dir):
    """True if bin_dir is a gcc toolchain's bin/ (has a sibling libexec/gcc).

    gcc keeps its exec'd subprograms under libexec/gcc/<triple>/<ver>/, so its
    presence cleanly distinguishes the compiler toolchain (which needs the
    copy-and-relocate path) from ordinary host-tool bin/ directories.
    """
    return os.path.isdir(os.path.join(os.path.dirname(bin_dir), "libexec", "gcc"))


def _copy_and_relocate_toolchain(bin_dir, ld_linux, scratch_dir):
    """Copy a gcc toolchain into writable scratch and relocate the copy there.

    gcc execs its subprograms (cc1, as, ld, ...) by absolute path, and both
    their PT_INTERP and DT_RUNPATH embed the toolchain's build-time
    `output_artifacts` alias directory, which isn't materialized in consuming
    actions.  _fix_subprogram_paths() repoints them at the materialized tree,
    but to do so it must create a temp file in each binary's directory and
    rename it over the original -- which needs a writable directory.  Remote
    execution materializes action inputs read-only, so that rewrite silently
    fails on the worker and gcc can't run cc1 ("C compiler cannot create
    executables").

    Copying the toolchain into writable scratch first makes the existing
    in-place rewrite succeed everywhere.  Interps/RUNPATHs are still repointed
    at the original materialized tree (read-only is fine -- the loader and the
    shared libs are only read, never written), which keeps the byte
    substitution length-preserving.

    Idempotent (skips if the .done marker exists) and lock-guarded for
    concurrent actions, like _create_wrappers().  Returns the copy's bin/ dir.
    """
    import fcntl
    import shutil

    src_root = os.path.dirname(bin_dir)  # .../patched-compiler/tools
    path_hash = hashlib.sha1(src_root.encode()).hexdigest()[:12]
    container_dir = os.path.join(scratch_dir, ".tc-copy-" + path_hash)
    dst_root = os.path.join(container_dir, os.path.basename(src_root))
    dst_bin = os.path.join(dst_root, "bin")
    done_marker = container_dir + ".done"

    if os.path.exists(done_marker):
        return dst_bin

    os.makedirs(scratch_dir, exist_ok=True)
    lock_path = container_dir + ".lock"
    with open(lock_path, "w") as lock_fd:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        if os.path.exists(done_marker):
            return dst_bin
        if os.path.exists(container_dir):
            shutil.rmtree(container_dir)
        os.makedirs(container_dir)

        # --reflink=auto makes this a near-free copy-on-write clone on
        # filesystems that support it (btrfs/xfs), falling back to a full copy
        # elsewhere.  -a preserves the symlinks and layout gcc resolves its
        # sysroot/libexec/fixed-includes through relative to the driver.
        subprocess.run(["cp", "-a", "--reflink=auto", src_root, dst_root], check=True)
        # cp -a preserves the read-only input permissions; make the copy
        # writable so the in-place rewrite below can create its temp files and
        # rename them into place.
        subprocess.run(["chmod", "-R", "u+w", dst_root], check=True)

        _fix_subprogram_paths(dst_bin, ld_linux)

        print(f"portabilize: copied toolchain to {dst_root}", file=sys.stderr)
        with open(done_marker, "w") as f:
            f.write("ok\n")

    return dst_bin


def _fix_subprogram_paths(bin_dir, ld_linux):
    """Repoint toolchain subprograms gcc execs by path at the materialized tree.

    Covers gcc's libexec subprograms (cc1, cc1plus, collect2, lto1,
    lto-wrapper) and the cross binutils in <triple>/bin (as, ld, ar, ...),
    which gcc invokes by absolute path, bypassing the PATH wrappers from
    _create_wrappers.  Their PT_INTERP and DT_RUNPATH embed the toolchain's
    `output_artifacts` alias directory.  Buck materializes the toolchain
    under a 16-hex-char content hash, and `output_artifacts` is also exactly
    16 chars, so we can replace every occurrence of the alias path prefix
    with the materialized prefix in place -- no ELF offsets change.
    """
    import glob as _glob_mod

    ld_linux = os.path.abspath(ld_linux)
    marker = "/patched-compiler/"
    idx = ld_linux.find(marker)
    if idx < 0:
        return
    materialized_prefix = ld_linux[:idx]  # .../__bootstrap-toolchain__/<hash>
    dead_prefix = os.path.dirname(materialized_prefix) + "/output_artifacts"
    old = dead_prefix.encode()
    new = materialized_prefix.encode()
    if len(old) != len(new):
        return  # length changed -> in-place substitution would corrupt offsets

    parent = os.path.dirname(os.path.abspath(bin_dir))
    exec_dirs = [os.path.join(parent, "libexec"), os.path.join(parent, "bin")]
    # Cross binutils live in <triple>/bin (e.g. x86_64-buckos-linux-gnu/bin/as).
    exec_dirs += _glob_mod.glob(os.path.join(parent, "*", "bin"))
    seen = set()
    for d in exec_dirs:
        if not os.path.isdir(d) or d in seen:
            continue
        seen.add(d)
        for root, _dirs, files in os.walk(d):
            for name in files:
                p = os.path.join(root, name)
                if os.path.islink(p) or not _is_elf(p):
                    continue
                _subst_bytes_inplace(p, old, new)


def _subst_bytes_inplace(path, old, new):
    """Length-preserving global byte substitution in a file, applied atomically.

    Replaces every occurrence of `old` with `new` (which must be the same
    length, so no file offsets shift -- safe for ELF interp/dynstr).  Only
    rewrites if `old` is present (idempotent).  Writes a patched copy and
    os.replace()s it over the original; we never open `path` itself for
    writing, so a parallel build action exec'ing this shared toolchain
    binary can't fail with ETXTBSY ("Text file busy").  rename(2) over a
    running executable is safe on Linux.
    """
    if len(old) != len(new):
        return
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return
    if old not in data:
        return  # already materialized (idempotent) or unrelated binary
    data = data.replace(old, new)
    dir_ = os.path.dirname(path) or "."
    tmp = os.path.join(
        dir_, "." + os.path.basename(path) + ".subst." + str(os.getpid())
    )
    try:
        st = os.stat(path)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o700)
        try:
            os.write(fd, data)
        finally:
            os.close(fd)
        os.chmod(tmp, st.st_mode)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


# ── Sysroot discovery ────────────────────────────────────────────────


def _derive_sysroot(ld_linux):
    """Derive sysroot root from ld-linux path.

    ld-linux is at <sysroot>/lib64/ld-linux-x86-64.so.2.
    """
    return os.path.dirname(os.path.dirname(ld_linux))


def _derive_gcc_runtime(ld_linux):
    """Derive GCC runtime lib directory from ld-linux path.

    Seed layout:
        patched-compiler/tools/<triple>/sys-root/lib64/ld-linux
        patched-compiler/tools/<triple>/lib64/libstdc++.so.6
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


def _find_perl5lib(bin_dir):
    """Build PERL5LIB from perl5 lib dirs sibling to bin_dir."""
    import glob as _glob_mod

    parent = os.path.dirname(bin_dir)
    dirs = []
    for ld in ("lib", "lib64"):
        for d in _glob_mod.glob(os.path.join(parent, ld, "perl5", "*")):
            if os.path.isdir(d):
                dirs.append(d)
                arch_dir = os.path.join(d, "x86_64-linux-thread-multi")
                if os.path.isdir(arch_dir):
                    dirs.append(arch_dir)
    return ":".join(dirs) if dirs else None


def _package_lib_dirs(bin_dir):
    """Find lib/lib64 directories sibling to a bin directory."""
    parent = os.path.dirname(bin_dir)
    dirs = []
    for sub in ("lib", "lib64"):
        d = os.path.join(parent, sub)
        if os.path.isdir(d):
            dirs.append(d)
    return dirs


def _build_lib_path(sysroot, gcc_runtime):
    """Build the library path string for ld-linux --library-path."""
    dirs = _sysroot_lib_dirs(sysroot)
    if gcc_runtime and os.path.isdir(gcc_runtime):
        dirs.append(gcc_runtime)
    return ":".join(dirs)


# ── Wrapper creation ─────────────────────────────────────────────────


def _create_wrappers(bin_dir, ld_linux, lib_path, scratch_dir):
    """Create a wrapper directory with ld-linux wrappers for ELF binaries.

    Idempotent: skips if .done marker exists.
    Atomic: uses lock file for concurrent actions.
    """
    path_hash = hashlib.sha1(bin_dir.encode()).hexdigest()[:12]
    bin_basename = os.path.basename(bin_dir)
    container_name = (
        ".ld-wrap-" + os.path.basename(os.path.dirname(bin_dir)) + "-" + path_hash
    )
    container_dir = os.path.join(scratch_dir, container_name)
    wrapper_dir = os.path.join(container_dir, bin_basename)
    done_marker = container_dir + ".done"

    if os.path.exists(done_marker):
        return wrapper_dir

    import fcntl

    lock_path = container_dir + ".lock"
    os.makedirs(scratch_dir, exist_ok=True)
    with open(lock_path, "w") as lock_fd:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        if os.path.exists(done_marker):
            return wrapper_dir
        if os.path.exists(container_dir):
            import shutil

            shutil.rmtree(container_dir)
        os.makedirs(wrapper_dir)

        # Detect perl5 lib dirs for PERL5LIB (set only in perl wrappers
        # to avoid poisoning host perl with buckos XS modules).
        perl5lib = _find_perl5lib(bin_dir)

        wrapped = 0
        linked = 0
        for entry in sorted(os.listdir(bin_dir)):
            src = os.path.join(bin_dir, entry)
            dst = os.path.join(wrapper_dir, entry)
            # Set PERL5LIB only for perl binaries. Also set PERL to the
            # wrapper path so programs using $^X (like OpenSSL's Configure)
            # re-invoke perl through the wrapper, not the unwrapped binary.
            _p5 = perl5lib if entry.startswith("perl") else None

            if os.path.islink(src):
                target = os.readlink(src)
                if os.path.isabs(target):
                    if (
                        os.path.isfile(target)
                        and _is_elf(target)
                        and _has_pt_interp(target)
                    ):
                        _write_wrapper(dst, ld_linux, lib_path, target, perl5lib=_p5)
                        wrapped += 1
                    else:
                        os.symlink(target, dst)
                        linked += 1
                else:
                    resolved = os.path.join(bin_dir, target)
                    if (
                        os.path.isfile(resolved)
                        and _is_elf(resolved)
                        and _has_pt_interp(resolved)
                    ):
                        _write_wrapper(
                            dst,
                            ld_linux,
                            lib_path,
                            os.path.realpath(resolved),
                            perl5lib=_p5,
                        )
                        wrapped += 1
                    else:
                        os.symlink(target, dst)
                        linked += 1
            elif os.path.isfile(src) and _is_elf(src) and _has_pt_interp(src):
                _write_wrapper(dst, ld_linux, lib_path, src, perl5lib=_p5)
                wrapped += 1
            elif os.path.isfile(src):
                os.symlink(src, dst)
                linked += 1

        # Symlink sibling dirs from the original package into the container
        # so derive_lib_paths() finds libraries and tools find data files
        # (e.g. autoconf's share/autoconf, perl's lib/perl5).
        orig_parent = os.path.dirname(bin_dir)
        for sub in ("lib", "lib64", "share", "libexec"):
            orig_sub = os.path.join(orig_parent, sub)
            container_sub = os.path.join(container_dir, sub)
            if os.path.isdir(orig_sub) and not os.path.exists(container_sub):
                os.symlink(orig_sub, container_sub)

        print(
            f"portabilize: {wrapped} wrappers, {linked} symlinks in {wrapper_dir}",
            file=sys.stderr,
        )

        with open(done_marker, "w") as f:
            f.write("ok\n")

    return wrapper_dir


def _write_wrapper(path, ld_linux, lib_path, binary, perl5lib=None):
    """Write a shell wrapper that invokes binary through ld-linux."""
    name = os.path.basename(path)
    binary_name = os.path.basename(binary)
    with open(path, "w") as f:
        f.write("#!/bin/sh\n")
        if perl5lib:
            f.write(f'export PERL5LIB="{perl5lib}${{PERL5LIB:+:$PERL5LIB}}"\n')
            f.write(f'export PERL="{path}"\n')
            # Fix $^X: when perl runs through ld-linux, /proc/self/exe
            # resolves to ld-linux, so $^X = ld-linux.  Scripts that pipe
            # through $^X (OpenSSL perlasm) then invoke ld-linux directly
            # on .pl files, causing "invalid ELF header".
            # Create a tiny module that overrides $^X at BEGIN time,
            # loaded via PERL5OPT=-M.
            _fixup_dir = os.path.join(os.path.dirname(path), ".perl-fixup")
            os.makedirs(_fixup_dir, exist_ok=True)
            _fixup_mod = os.path.join(_fixup_dir, "BuckOSPerl.pm")
            if not os.path.exists(_fixup_mod):
                with open(_fixup_mod, "w") as mf:
                    mf.write(
                        f"package BuckOSPerl;$^X=$ENV{{PERL}} if $ENV{{PERL}};1;\n"
                    )
            f.write(f'export PERL5OPT="-I{_fixup_dir} -MBuckOSPerl ${{PERL5OPT:-}}"\n')
            f.write(
                f'exec "{ld_linux}" --library-path '
                f'"{lib_path}${{LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}}" '
                f'"{binary}" "$@"\n'
            )
        # Use --argv0 only for multi-call binaries where the wrapper name
        # differs from the binary name (e.g. mtools symlinks).
        # For normal binaries, let ld-linux pass the real path as argv[0]
        # so programs like gcc can find their subprograms (cc1) via $0.
        elif name != binary_name:
            f.write(
                f'exec "{ld_linux}" --argv0 "{name}" --library-path '
                f'"{lib_path}${{LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}}" '
                f'"{binary}" "$@"\n'
            )
        else:
            f.write(
                f'exec "{ld_linux}" --library-path '
                f'"{lib_path}${{LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}}" '
                f'"{binary}" "$@"\n'
            )
    os.chmod(path, 0o755)


# ── ELF detection ────────────────────────────────────────────────────


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


# ── Standalone test ──────────────────────────────────────────────────

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(
        description="Create ld-linux wrappers for seed toolchain binaries"
    )
    parser.add_argument(
        "--bin-dir",
        action="append",
        required=True,
        help="Directory of ELF binaries (repeatable)",
    )
    parser.add_argument("--ld-linux", required=True, help="Path to sysroot ld-linux")
    parser.add_argument(
        "--scratch-dir", required=True, help="Writable scratch directory"
    )
    parser.add_argument(
        "--patchelf", default=None, help="Unused (kept for compatibility)"
    )
    args = parser.parse_args()

    result = portabilize_toolchain(
        args.bin_dir, args.ld_linux, args.scratch_dir, args.patchelf
    )
    for d in result:
        print(d)
