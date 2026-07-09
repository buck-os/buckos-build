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
    bin_dirs, ld_linux_path, scratch_dir=None, patchelf_path=None, wrappers_only=False
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
        # Host-tool bundles (host-tools-exec) whose binaries carry a
        # build-tree-baked interp also need the copy-and-relocate path: ld-linux
        # wrappers can't fix tools that re-exec their own binary by absolute
        # path (e.g. make's recursive $(MAKE) -> the real make exe, dead interp
        # on RE).  Copying + patchelf makes the real binaries runnable anywhere.
        if _needs_copy_relocation(bin_abs):
            # Wrap first: this materializes a runnable (ld-linux-invoked) patchelf
            # wrapper in scratch, which _copy_and_relocate_toolchain needs to
            # relocate the copy (patchelf is itself one of these host tools, so
            # its own baked interp is dead on RE -- the wrapper is the bootstrap).
            # The wrapper dir also supplies patchelf for the gcc toolchain's
            # relocation.  Then copy+patchelf and return the relocated copy so
            # tools that re-exec their own exe (make's recursive $(MAKE)) work.
            pkg_libs = _package_lib_dirs(bin_abs)
            lib_path = base_lib_path
            if pkg_libs:
                lib_path = ":".join(pkg_libs) + ":" + base_lib_path
            wrapper_dir = _create_wrappers(bin_abs, ld_linux, lib_path, scratch_dir)
            if wrappers_only:
                # The prepare phase only applies patches and runs pre-configure
                # commands (patch, bash, sed, ...) -- it never runs make's
                # recursive $(MAKE), so ld-linux wrappers are sufficient.  Skip
                # the copy-and-relocate path, which on some RE workers
                # patchelf-relocates 0 binaries and leaves a dead-interpreter
                # `patch` (-> FileNotFoundError: 'patch').  The wrappers always
                # run because they invoke the binary through a materialized
                # ld-linux with an explicit --library-path.
                result.append(wrapper_dir)
            else:
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
    """True if bin_dir is a *pure* gcc cross-toolchain's bin/.

    A pure gcc toolchain keeps its exec'd subprograms under
    libexec/gcc/<triple>/<ver>/, so a sibling libexec/gcc distinguishes the
    compiler toolchain from ordinary host-tool bin/ directories.

    A host-tool *bundle* (host-tools-exec) also contains gcc -- and therefore
    a libexec/gcc -- but it additionally ships general host tools (bash, sh,
    make, python3, ...) whose OWN interps must be relocated on a remote worker.
    The gcc-only path deliberately skips wrapper creation (a compiler doesn't
    need PATH wrappers), which means it never materializes the patchelf wrapper
    and never repoints bash/sh's dead build-tree interp -- so `sh` fails with
    "No such file or directory" (a dead ELF interpreter reads as ENOENT) on RE.
    Exclude any bin/ that carries a shell: that marks a host-tool bundle, which
    _needs_copy_relocation() handles instead (wrappers + patchelf interp fix).
    """
    parent = os.path.dirname(bin_dir)
    if not os.path.isdir(os.path.join(parent, "libexec", "gcc")):
        return False
    # A host-tool bundle ships bash/sh in bin/; a pure cross toolchain does not.
    for shell in ("bash", "sh"):
        if os.path.exists(os.path.join(bin_dir, shell)):
            return False
    return True


def _read_pt_interp(path):
    """Return an ELF's PT_INTERP string, or None."""
    try:
        with open(path, "rb") as f:
            data = f.read()
        e_phoff = struct.unpack_from("<Q", data, 32)[0]
        e_phentsize = struct.unpack_from("<H", data, 54)[0]
        e_phnum = struct.unpack_from("<H", data, 56)[0]
        for i in range(e_phnum):
            off = e_phoff + i * e_phentsize
            if struct.unpack_from("<I", data, off)[0] == 3:  # PT_INTERP
                p_off = struct.unpack_from("<Q", data, off + 8)[0]
                p_fsz = struct.unpack_from("<Q", data, off + 32)[0]
                return (
                    data[p_off : p_off + p_fsz].rstrip(b"\x00").decode(errors="replace")
                )
    except (struct.error, IndexError, OSError):
        pass
    return None


def _needs_copy_relocation(bin_dir):
    """True if a host-tool bin/ has binaries with a build-tree-baked interp.

    Host tools built locally (local_only) bake the build root's ld-linux into
    PT_INTERP (via the `output_artifacts` alias / `patched-compiler` sysroot).
    ld-linux wrappers can't fix this for tools that re-exec their own binary by
    absolute path -- notably `make`, whose recursive `$(MAKE)` resolves to the
    real make exe, not the wrapper -- so those need the copy-and-relocate path
    (patchelf) just like the gcc toolchain.  Probe the first real ELF binary.
    """
    try:
        entries = sorted(os.listdir(bin_dir))
    except OSError:
        return False
    for entry in entries:
        p = os.path.join(bin_dir, entry)
        if os.path.islink(p) or not os.path.isfile(p):
            continue
        if not _is_elf(p) or not _has_pt_interp(p):
            continue
        interp = _read_pt_interp(p) or ""
        # A buck-built ld-linux lives under buck-out and is tied to the build
        # root (e.g. /data/users/<u>/fbsource/buck-out/...).  On a
        # remote-execution worker (or any other root) that path doesn't
        # resolve, so the bundle needs copy+patchelf relocation rather than
        # ld-linux wrappers.  Covers host-tools-exec whose interp points at the
        # stage2 sysroot (no output_artifacts/patched-compiler marker).
        return "/buck-out/" in interp
    return False


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

        # NOTE: do NOT use --reflink=auto here.  On a remote-execution worker
        # the source tree is a CAS-backed input that may be materialized
        # on-access; a reflink (copy-on-write) clone can silently skip entries
        # whose bytes aren't materialized yet, producing an INCOMPLETE copy
        # (e.g. missing libpython3.12.so.1.0) while cp still exits 0 -- the
        # action then fails much later at python startup.  A plain `cp -a`
        # reads every byte, forcing full materialization and a complete copy.
        # -a preserves the symlinks and layout gcc resolves its
        # sysroot/libexec/fixed-includes through relative to the driver.
        subprocess.run(["cp", "-a", src_root, dst_root], check=True)
        # cp -a preserves the read-only input permissions; make the copy
        # writable so the in-place rewrite below can create its temp files and
        # rename them into place.
        subprocess.run(["chmod", "-R", "u+w", dst_root], check=True)

        # The toolchain is built locally (local_only), so rewrite_interps bakes
        # the *local* build root (e.g. /data/users/<u>/fbsource/...) into every
        # PT_INTERP/DT_RPATH.  On a remote-execution worker the tree lives under
        # a different root (/re_cwd/...), and that prefix differs in length from
        # the local one, so the length-preserving byte substitution in
        # _fix_subprogram_paths() can't fix it (it only swaps the equal-length
        # `output_artifacts`->content-hash component) -> the interp stays dead
        # and gcc fails with exit 127 "cannot execute: required file not found".
        # patchelf rewrites the interp/RPATH to the copy's *own* self-contained
        # ld-linux and lib dirs with no length constraint, which is valid on any
        # worker.  Fall back to the byte-sub if patchelf isn't available.
        if not _patchelf_relocate(dst_root, ld_linux, scratch_dir):
            _fix_subprogram_paths(dst_bin, ld_linux)

        print(f"portabilize: copied toolchain to {dst_root}", file=sys.stderr)
        with open(done_marker, "w") as f:
            f.write("ok\n")

    return dst_bin


def _patchelf_relocate(dst_root, ld_linux, scratch_dir):
    """Relocate a copied gcc toolchain's interp + RPATH with patchelf.

    Points every exec'd binary (bin/*, libexec/gcc/.../{cc1,cc1plus,collect2,
    lto1,...}, and the cross binutils in <triple>/bin/*) at the copy's *own*
    ld-linux and lib dirs, so the toolchain is fully self-contained at whatever
    absolute path the copy lives -- no dependency on the build-time root.

    patchelf is one of the hermetic host tools, which portabilize_toolchain
    wraps into scratch (".ld-wrap-...") before the compiler toolchain is
    copied, so a worker-runnable wrapped patchelf is already present.  Returns
    True on success, False if patchelf or the copy's ld-linux can't be found
    (caller falls back to the byte-substitution relocation).
    """
    import glob as _glob_mod

    patchelf = None
    for _cand in _glob_mod.glob(
        os.path.join(scratch_dir, ".ld-wrap-*", "bin", "patchelf")
    ):
        if os.path.isfile(_cand):
            patchelf = _cand
            break
    if not patchelf:
        return False

    abs_ld = os.path.abspath(ld_linux)
    # Prefer the copy's own ld-linux: a gcc toolchain ships its sysroot inside
    # the copied tree (<root>/tools/<triple>/sys-root/...).  Host-tool bundles
    # (host-tools-exec) don't ship a sysroot, so fall back to the external
    # materialized ld-linux, which is valid on the worker (it's a build input).
    copy_ld = ""
    if "/tools/" in ld_linux:
        cand = os.path.join(dst_root, ld_linux.split("/tools/", 1)[1])
        if os.path.isfile(cand):
            copy_ld = cand
    # A gcc toolchain ships its sysroot inside the copy (internal ld-linux) and
    # its binaries carry an absolute, build-root-baked (dead-on-RE) RPATH that
    # must be rewritten.  A host-tool bundle (external ld-linux) already uses an
    # $ORIGIN-relative RPATH + LD_LIBRARY_PATH, so we must ONLY fix its interp --
    # overwriting its RPATH drops the sysroot lib dirs and libpython/libperl then
    # pick up the host's too-old libc (GLIBC_2.xx not found).
    _internal = bool(copy_ld)
    if not copy_ld:
        copy_ld = abs_ld
    if not os.path.isfile(copy_ld):
        return False

    triple = ""
    if "/sys-root/" in ld_linux:
        triple = ld_linux.split("/sys-root/", 1)[0].rsplit("/", 1)[-1]
    ext_sysroot = os.path.dirname(os.path.dirname(abs_ld))  # <sysroot>

    # DT_RPATH (transitive, matching the toolchain's --disable-new-dtags) over
    # the copy's own lib dirs (libstdc++/libgcc_s/libisl for cc1; libreadline/
    # libtinfo for bash; etc.) plus the external sysroot for libc, so every
    # relocated binary resolves its shared libs wherever the copy lives.
    _cand_dirs = [
        os.path.join(dst_root, "lib64"),
        os.path.join(dst_root, "lib"),
    ]
    if triple:
        _cand_dirs += [
            os.path.join(dst_root, triple, "lib64"),
            os.path.join(dst_root, triple, "lib"),
            os.path.join(dst_root, triple, "sys-root", "usr", "lib64"),
            os.path.join(dst_root, triple, "sys-root", "lib64"),
        ]
    _cand_dirs += [
        os.path.join(ext_sysroot, "usr", "lib64"),
        os.path.join(ext_sysroot, "lib64"),
        os.path.join(ext_sysroot, "usr", "lib"),
        os.path.join(ext_sysroot, "lib"),
    ]
    # Also include the external gcc-runtime dirs
    # (patched-compiler/tools/<triple>/{lib64,lib}). These live one level ABOVE
    # the sysroot and hold libstdc++.so.6 / libgcc_s.so.1 from the seed's
    # gcc-pass2 (GCC 14). A host-tool bundle whose install ships only bin/
    # (e.g. the cmake or ninja package's usr/) has no libstdc++ under its own
    # dst_root; without these dirs in the rpath the loader falls through to the
    # remote-execution worker's too-old /lib64/libstdc++.so.6 → "GLIBCXX_3.4.32
    # not found". As with the sysroot entries above, do NOT isdir()-filter —
    # deferred materialization would drop them and reintroduce the same failure.
    for _rt in _derive_gcc_runtime(abs_ld):
        _cand_dirs.append(_rt)
    # NOTE: do NOT os.path.isdir()-filter these.  On RE with deferred
    # materialization the sysroot dir may not be stat-able as a directory when
    # portabilize runs, which would silently drop the external sysroot (libc)
    # from the rpath and make relocated binaries load the worker's too-old
    # /lib64/libc.so.6.  Non-existent rpath entries are harmless (the loader
    # just skips them), so keep them all.
    rpath = ":".join(_cand_dirs)

    # Executables (bin/libexec/<triple>/bin) get their interp repointed AND
    # their rpath fixed.  Shared libraries (lib/lib64/...), which have no
    # PT_INTERP, get ONLY their rpath fixed -- a .so like libpython3.12.so
    # needs libc, and relying on the loading executable's *transitive* rpath is
    # not reliable on RE, so give the .so the sysroot in its own rpath too.
    exec_dirs = [os.path.join(dst_root, "bin"), os.path.join(dst_root, "libexec")]
    exec_dirs += _glob_mod.glob(os.path.join(dst_root, "*", "bin"))
    lib_dirs = [os.path.join(dst_root, "lib"), os.path.join(dst_root, "lib64")]
    lib_dirs += _glob_mod.glob(os.path.join(dst_root, "*", "lib"))
    lib_dirs += _glob_mod.glob(os.path.join(dst_root, "*", "lib64"))

    def _rpath_args(binary):
        """patchelf rpath flags for one binary (empty list if nothing to do)."""
        if not rpath:
            return []
        if _internal:
            # gcc toolchain: its build-baked RPATH is dead-absolute (points at
            # the build root, gone on RE), so replace it with the copy's dirs.
            return ["--force-rpath", "--set-rpath", rpath]
        # Host-tool bundle: it uses the external ld-linux and an $ORIGIN-relative
        # RPATH for its package libs (libreadline for bash, libpython for
        # python3, ...).  We must NOT drop that RPATH, or the binary loses its
        # own libs; but interp-only leaves libc unresolved on RE (the $ORIGIN
        # dirs don't ship glibc, so the loader falls back to the worker's
        # too-old /lib64/libc.so.6 -> "GLIBC_2.xx not found").  Preserve the
        # existing RPATH and APPEND the sysroot lib dirs so buckos libc resolves
        # while $ORIGIN still finds package libs.
        _cur = subprocess.run(
            [patchelf, "--print-rpath", binary], capture_output=True, text=True
        )
        _existing = _cur.stdout.strip() if _cur.returncode == 0 else ""
        _merged = ":".join(x for x in (_existing, rpath) if x)
        return ["--force-rpath", "--set-rpath", _merged] if _merged else []

    count = 0
    seen = set()
    for d in exec_dirs + lib_dirs:
        if not os.path.isdir(d) or d in seen:
            continue
        seen.add(d)
        is_lib_dir = d not in exec_dirs
        for root, _dirs, files in os.walk(d):
            for name in files:
                p = os.path.join(root, name)
                if os.path.islink(p) or not _is_elf(p):
                    continue
                has_interp = _has_pt_interp(p)
                # In exec dirs, only touch things with an interp (executables);
                # in lib dirs, only touch shared libraries (ET_DYN=3).  Skipping
                # non-DYN ELF in lib dirs avoids running patchelf on relocatable
                # objects (.o / .syso, ET_REL=1) -- patchelf aborts on those with
                # "wrong ELF type" (harmless but noisy and wasteful).
                if is_lib_dir and (has_interp or _elf_type(p) != 3):
                    continue
                if not is_lib_dir and not has_interp:
                    continue
                cmd = [patchelf]
                if has_interp:
                    cmd += ["--set-interpreter", copy_ld]
                cmd += _rpath_args(p)
                if len(cmd) == 1:  # nothing to change
                    continue
                cmd.append(p)
                if subprocess.run(cmd).returncode == 0:
                    count += 1
    print(
        f"portabilize: patchelf-relocated {count} toolchain binaries "
        f"(interp={copy_ld}, internal={_internal}, rpath={rpath})",
        file=sys.stderr,
    )
    return count > 0


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
    """Derive GCC runtime lib directories (libstdc++/libgcc_s) from ld-linux.

    Seed layout:
        patched-compiler/tools/<triple>/sys-root/lib64/ld-linux
        patched-compiler/tools/<triple>/lib64/libstdc++.so.6

    Returns a LIST of candidate dirs, NOT os.path.isdir()-filtered: on an RE
    worker with deferred materialization the dir isn't stat-able when the
    wrapper's --library-path is built, which would drop libstdc++ and make a
    wrapped C++ host tool (e.g. cmake) load the worker's too-old
    /lib64/libstdc++.so.6 ("version `GLIBCXX_3.4.xx' not found").  Non-existent
    entries are harmless; the files materialize on access.
    """
    sysroot = _derive_sysroot(ld_linux)
    triple_dir = os.path.dirname(sysroot)
    return [os.path.join(triple_dir, sub) for sub in ("lib64", "lib")]


def _sysroot_lib_dirs(sysroot):
    """Return the sysroot lib directories for the ld-linux --library-path.

    Do NOT os.path.isdir()-filter these.  On a remote-execution worker with
    deferred materialization, the sysroot dir may not be stat-able as a
    directory when portabilize builds the wrapper's --library-path, which would
    silently drop the sysroot (glibc) and make the wrapped host tools load the
    worker's too-old /lib64/libc.so.6 ("version `GLIBC_2.xx' not found").
    Non-existent --library-path entries are harmless (the loader skips them),
    and the files materialize on access at runtime, so keep them all.
    """
    return [os.path.join(sysroot, sub) for sub in ("usr/lib64", "usr/lib", "lib64", "lib")]


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
    """Return lib/lib64 dirs sibling to a bin directory (a package's own libs).

    Not os.path.isdir()-filtered -- see _sysroot_lib_dirs: on RE with deferred
    materialization these may not be stat-able when the wrapper is built, and
    dropping them makes the wrapped tool miss its bundled libs.  Harmless if
    absent.
    """
    parent = os.path.dirname(bin_dir)
    return [os.path.join(parent, sub) for sub in ("lib", "lib64")]


def _build_lib_path(sysroot, gcc_runtime):
    """Build the library path string for ld-linux --library-path.

    gcc_runtime is a list of GCC runtime lib dirs (libstdc++/libgcc_s).  None
    of the entries are isdir-filtered so RE deferred materialization can't drop
    the buckos glibc/libstdc++ (see _sysroot_lib_dirs / _derive_gcc_runtime).
    """
    dirs = _sysroot_lib_dirs(sysroot)
    if gcc_runtime:
        dirs.extend(gcc_runtime if isinstance(gcc_runtime, list) else [gcc_runtime])
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


def _elf_type(path):
    """Return the ELF e_type (1=REL/.o, 2=EXEC, 3=DYN/.so) or None."""
    try:
        with open(path, "rb") as f:
            hdr = f.read(18)
        if hdr[:4] != b"\x7fELF":
            return None
        return int.from_bytes(hdr[16:18], "little")
    except (OSError, PermissionError):
        return None


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
