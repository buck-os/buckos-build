#!/usr/bin/env python3
"""Rewrite padded ELF interpreters to point to a concrete ld-linux path.

Takes a directory of stage3 host tools (with padded ///...///lib64/ld-linux
interpreters from GCC specs) and rewrites them to point to the actual
buckos ld-linux at a known absolute path.  This makes the binaries
directly executable on the host without using the host's ld-linux.

Used by the host_tools_exec rule to produce host-runnable hermetic tools.
"""

import argparse
import os
import shutil
import struct
import subprocess
import stat
import sys


# Fixed padding length for ELF interpreter path.
# Prepended '/' characters ensure PT_INTERP is long enough for
# in-place rewriting regardless of sysroot path length.
PADDED_LENGTH = 260


_STANDARD_INTERPS = (
    b"/lib64/ld-linux-x86-64.so.2",
    b"/usr/lib64/ld-linux-x86-64.so.2",
    b"/lib/ld-linux-x86-64.so.2",
    b"/lib/ld-linux-aarch64.so.1",
    b"/lib64/ld-linux-aarch64.so.1",
)


def _patch_elf_interpreter(path, new_interp_bytes, patch_standard=False):
    """Patch PT_INTERP in a 64-bit little-endian ELF to new_interp_bytes.

    By default only patches interpreters with leading /// padding (from
    GCC specs).  With patch_standard=True, also patches standard host
    interpreters — used for compiler binaries built during bootstrap
    before specs were in effect.

    Returns True if patched.
    """
    try:
        with open(path, "rb") as f:
            data = bytearray(f.read())
    except (PermissionError, OSError):
        return False

    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        return False

    e_phoff = struct.unpack_from("<Q", data, 32)[0]
    e_phentsize = struct.unpack_from("<H", data, 54)[0]
    e_phnum = struct.unpack_from("<H", data, 56)[0]

    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        if struct.unpack_from("<I", data, off)[0] != 3:  # PT_INTERP
            continue

        p_offset = struct.unpack_from("<Q", data, off + 8)[0]
        p_filesz = struct.unpack_from("<Q", data, off + 32)[0]

        end = data.find(0, p_offset, p_offset + p_filesz)
        if end < 0:
            end = p_offset + p_filesz
        old_interp = data[p_offset:end]

        # Skip if interpreter doesn't need rewriting
        if old_interp.startswith(b"///"):
            pass  # Padded interpreter from GCC specs — always rewrite
        elif patch_standard and old_interp in _STANDARD_INTERPS:
            pass  # Standard host interpreter — rewrite when requested
        else:
            return False

        if len(new_interp_bytes) <= p_filesz:
            data[p_offset:p_offset + len(new_interp_bytes)] = new_interp_bytes
            for j in range(len(new_interp_bytes), p_filesz):
                data[p_offset + j] = 0
        else:
            # Append to end of file
            new_offset = len(data)
            data.extend(new_interp_bytes)
            struct.pack_into("<Q", data, off + 8, new_offset)
            struct.pack_into("<Q", data, off + 32, len(new_interp_bytes))
            struct.pack_into("<Q", data, off + 40, len(new_interp_bytes))

        orig_mode = os.stat(path).st_mode
        os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
        with open(path, "wb") as f:
            f.write(data)
        os.chmod(path, orig_mode)
        return True

    return False


def _extract_gcc_spec(gcc_bin, spec_name):
    """Extract a single spec entry from a GCC binary's built-in specs.

    Runs ``gcc -dumpspecs`` and returns the value line for *spec_name,
    or None if not found.
    """
    try:
        result = subprocess.run(
            [gcc_bin, "-dumpspecs"],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            return None
        lines = result.stdout.splitlines()
        marker = f"*{spec_name}:"
        for i, line in enumerate(lines):
            if line.strip() == marker and i + 1 < len(lines):
                return lines[i + 1]
    except (OSError, subprocess.TimeoutExpired):
        pass
    return None


def _install_gcc_specs(output_dir, gcc_triple, ld_subpath, rpath_val=None):
    """Install GCC auto-loaded specs with padded dynamic linker and RPATH.

    Writes a specs file to tools/lib/gcc/<triple>/<version>/specs so GCC
    auto-loads it without needing -specs= on the command line.  Uses %R
    (GCC's sysroot substitution) so the specs content is machine-independent.

    Also preserves the built-in *libgcc: spec, because GCC has a quirk
    where the mere existence of an auto-loaded specs file causes it to
    drop -lgcc_s from the link line unless *libgcc: is explicitly present.
    """
    gcc_lib_base = os.path.join(output_dir, "tools", "lib", "gcc", gcc_triple)
    if not os.path.isdir(gcc_lib_base):
        print(f"warning: GCC lib dir not found: {gcc_lib_base}",
              file=sys.stderr)
        return False

    versions = [d for d in os.listdir(gcc_lib_base)
                if os.path.isdir(os.path.join(gcc_lib_base, d))]
    if not versions:
        print(f"warning: no GCC version dirs in {gcc_lib_base}",
              file=sys.stderr)
        return False

    version = versions[0]
    specs_dir = os.path.join(gcc_lib_base, version)

    # Build padded interpreter using %R (GCC's sysroot substitution).
    padded_ld = "/" * PADDED_LENGTH + "%R/" + ld_subpath

    # Sysroot lib dirs for RPATH using %R.
    sysroot_rpath = "%R/usr/lib64:%R/usr/lib:%R/lib64:%R/lib:%R/../lib64"

    parts = [f"--dynamic-linker {padded_ld}"]
    if rpath_val:
        combined_rpath = sysroot_rpath + ":" + rpath_val
        parts.append(f"--disable-new-dtags -rpath {combined_rpath}")

    # Split: --dynamic-linker only for executables, RPATH for exes + shared libs
    interp_parts = [p for p in parts if "dynamic-linker" in p]
    rpath_parts = [p for p in parts if "dynamic-linker" not in p]

    clauses = []
    if interp_parts:
        clauses.append(f"%{{!shared:%{{!static:{' '.join(interp_parts)}}}}}")
    if rpath_parts:
        clauses.append(f"%{{!static:{' '.join(rpath_parts)}}}")

    specs_content = ""

    # Extract and preserve *libgcc: from the GCC binary.  Without this,
    # GCC silently drops -lgcc_s when any auto-loaded specs file exists.
    gcc_bin = os.path.join(output_dir, "tools", "bin",
                           gcc_triple + "-gcc")
    libgcc_spec = _extract_gcc_spec(gcc_bin, "libgcc")
    if libgcc_spec:
        specs_content += f"*libgcc:\n{libgcc_spec}\n\n"

    specs_content += f"*link:\n+ {' '.join(clauses)}\n\n"

    specs_path = os.path.join(specs_dir, "specs")
    with open(specs_path, "w") as f:
        f.write(specs_content)

    print(f"Installed GCC auto-loaded specs: {specs_path} (version {version})",
          file=sys.stderr)
    return True


def main():
    parser = argparse.ArgumentParser(
        description="Copy host tools and rewrite ELF interpreters")
    parser.add_argument("--tools-dir", required=True,
                        help="Input stage3 host tools directory (merged FHS tree)")
    parser.add_argument("--ld-linux", required=True,
                        help="Path to buckos ld-linux-x86-64.so.2 (sysroot artifact)")
    parser.add_argument("--output-dir", required=True,
                        help="Output directory")
    parser.add_argument("--patch-standard", action="store_true",
                        help="Also patch standard host interpreters and "
                             "set RPATH for sysroot lib discovery")
    parser.add_argument("--patchelf", default=None,
                        help="Path to patchelf binary (required with "
                             "--patch-standard)")
    parser.add_argument("--specs-gcc-triple", default=None,
                        help="GCC target triple for auto-loaded specs install")
    parser.add_argument("--specs-ld-subpath", default=None,
                        help="ld-linux subpath for specs dynamic linker "
                             "(e.g. lib64/ld-linux-x86-64.so.2)")
    parser.add_argument("--specs-rpath", default=None,
                        help="RPATH value to bake into GCC specs")
    args = parser.parse_args()

    tools_dir = os.path.abspath(args.tools_dir)
    output_dir = os.path.abspath(args.output_dir)
    ld_linux = os.path.abspath(args.ld_linux)

    if not os.path.isdir(tools_dir):
        print(f"error: tools dir not found: {tools_dir}", file=sys.stderr)
        sys.exit(1)

    if not os.path.isfile(ld_linux):
        print(f"error: ld-linux not found: {ld_linux}", file=sys.stderr)
        sys.exit(1)

    # Build output tree file-by-file from input.  Files that will be
    # modified (ELFs for interpreter rewriting, scripts with buck-out
    # shebangs) are copied; everything else is hardlinked.
    for dirpath, dirnames, filenames in os.walk(tools_dir):
        reldir = os.path.relpath(dirpath, tools_dir)
        outdir = os.path.join(output_dir, reldir) if reldir != "." else output_dir
        os.makedirs(outdir, exist_ok=True)

        # Recreate directory symlinks; don't descend into them.
        real_dirs = []
        for dname in dirnames:
            src = os.path.join(dirpath, dname)
            if os.path.islink(src):
                dst = os.path.join(outdir, dname)
                if not os.path.lexists(dst):
                    os.symlink(os.readlink(src), dst)
            else:
                real_dirs.append(dname)
        dirnames[:] = real_dirs

        for filename in filenames:
            src = os.path.join(dirpath, filename)
            dst = os.path.join(outdir, filename)
            if os.path.lexists(dst):
                continue

            if os.path.islink(src):
                os.symlink(os.readlink(src), dst)
                continue
            if not os.path.isfile(src):
                continue

            # Determine if the file will be modified by later passes.
            needs_copy = False
            try:
                with open(src, "rb") as f:
                    hdr = f.read(4)
                    if hdr == b"\x7fELF":
                        needs_copy = True
                    elif hdr[:2] == b"#!":
                        line = hdr + f.readline()
                        if b"buck-out" in line:
                            needs_copy = True
            except (OSError, IOError):
                pass

            if needs_copy:
                shutil.copy2(src, dst)
            else:
                try:
                    os.link(src, dst)
                except OSError:
                    shutil.copy2(src, dst)

    if args.patch_standard:
        # Compiler binaries from bootstrap have NO RPATH and standard
        # /lib64/ld-linux interpreters.  Use patchelf to set both the
        # interpreter (sysroot ld-linux) and RPATH (sysroot lib dirs)
        # so the compiler finds buckos glibc without LD_LIBRARY_PATH.
        #
        # Paths must point INTO the output dir (the copy), not the
        # original stage — downstream actions only materialize the
        # patched copy, not the original.
        patchelf = args.patchelf
        if not patchelf:
            print("error: --patch-standard requires --patchelf",
                  file=sys.stderr)
            sys.exit(1)

        # Derive sysroot paths from the COPY (output_dir), not the
        # original.  ld-linux was given as the original path but the
        # same relative structure exists in the output dir.
        rel_ld = os.path.relpath(ld_linux, tools_dir)
        copy_ld = os.path.join(output_dir, rel_ld)
        copy_sysroot = os.path.dirname(os.path.dirname(copy_ld))
        copy_gcc_target = os.path.dirname(copy_sysroot)

        rpath_dirs = []
        for sub in ("lib64", "lib", "usr/lib64", "usr/lib"):
            d = os.path.join(copy_sysroot, sub)
            if os.path.isdir(d):
                rpath_dirs.append(d)
        for sub in ("lib64", "lib"):
            d = os.path.join(copy_gcc_target, sub)
            if os.path.isdir(d):
                rpath_dirs.append(d)
        rpath_val = ":".join(rpath_dirs)

        import subprocess as _sp
        patched = 0
        for dirpath, _, filenames in os.walk(output_dir):
            for name in filenames:
                fpath = os.path.join(dirpath, name)
                if os.path.islink(fpath) or not os.path.isfile(fpath):
                    continue
                try:
                    with open(fpath, "rb") as f:
                        hdr = f.read(5)
                        if hdr[:4] != b"\x7fELF":
                            continue
                        if hdr[4] != 2:  # 64-bit only
                            continue
                except (PermissionError, OSError):
                    continue
                # Only patch executables (files with PT_INTERP).
                # Running patchelf on shared libs (e.g. ld-linux)
                # corrupts them by adding LOAD segments.
                has_interp = False
                try:
                    with open(fpath, "rb") as f:
                        data = f.read()
                    e_phoff = struct.unpack_from("<Q", data, 32)[0]
                    e_phentsize = struct.unpack_from("<H", data, 54)[0]
                    e_phnum = struct.unpack_from("<H", data, 56)[0]
                    for i in range(e_phnum):
                        off = e_phoff + i * e_phentsize
                        if struct.unpack_from("<I", data, off)[0] == 3:
                            has_interp = True
                            break
                except (struct.error, IndexError):
                    pass
                if not has_interp:
                    continue

                os.chmod(fpath, stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)
                # Two-pass patchelf: RPATH first, then interpreter.
                # Combined --set-interpreter --set-rpath in one pass
                # corrupts some binaries.
                _sp.run([patchelf, "--set-rpath", rpath_val, fpath],
                        capture_output=True)
                _sp.run(
                    [patchelf, "--set-interpreter", copy_ld, fpath],
                    capture_output=True,
                )
                patched += 1

        print(f"patchelf: set interpreter + rpath on {patched} binaries",
              file=sys.stderr)
    else:
        # Host-tools mode: rewrite padded interpreters in-place.
        # These binaries already have RPATH from GCC specs.
        new_interp = ld_linux.encode("ascii") + b"\x00"
        patched = 0
        for dirpath, _, filenames in os.walk(output_dir):
            for name in filenames:
                fpath = os.path.join(dirpath, name)
                if os.path.islink(fpath) or not os.path.isfile(fpath):
                    continue
                try:
                    with open(fpath, "rb") as f:
                        if f.read(4) != b"\x7fELF":
                            continue
                except (PermissionError, OSError):
                    continue
                if _patch_elf_interpreter(fpath, new_interp, False):
                    patched += 1

        print(f"Rewrote interpreter in {patched} binaries -> {ld_linux}",
              file=sys.stderr)

    # Install GCC auto-loaded specs if requested.
    if args.specs_ld_subpath and args.specs_gcc_triple:
        _install_gcc_specs(output_dir, args.specs_gcc_triple,
                          args.specs_ld_subpath, args.specs_rpath)

    # Rewrite script shebangs containing buck-out paths.  Build-time
    # shebangs like #!/.../buck-out/.../bash become stale when the remote
    # cache restores actions on a different machine.  Replace with
    # #!/usr/bin/env <interpreter> so scripts find tools via PATH.
    rewritten = 0
    for dirpath, _, filenames in os.walk(output_dir):
        for name in filenames:
            fpath = os.path.join(dirpath, name)
            if os.path.islink(fpath) or not os.path.isfile(fpath):
                continue
            try:
                with open(fpath, "rb") as f:
                    first = f.read(2)
                    if first != b"#!":
                        continue
                    line = first + f.readline()
            except (PermissionError, OSError):
                continue
            shebang = line.decode("utf-8", errors="replace").strip()
            if "buck-out" not in shebang:
                continue
            # Extract interpreter basename (e.g. bash, perl, python3)
            interp_path = shebang[2:].strip().split()[0]
            interp_name = os.path.basename(interp_path)
            if not interp_name:
                continue
            try:
                with open(fpath, "r") as f:
                    content = f.read()
                orig_mode = os.stat(fpath).st_mode
                os.chmod(fpath, stat.S_IRUSR | stat.S_IWUSR)
                with open(fpath, "w") as f:
                    f.write(f"#!/usr/bin/env {interp_name}\n")
                    f.write(content[content.index("\n") + 1:])
                os.chmod(fpath, orig_mode)
                rewritten += 1
            except (ValueError, OSError):
                continue
    if rewritten:
        print(f"Rewrote {rewritten} script shebangs (buck-out -> /usr/bin/env)",
              file=sys.stderr)

    # Symlink sysroot gconv modules so msgfmt/iconv find charset conversions.
    # The sysroot gconv is at <sysroot>/usr/lib/gconv/ — symlink it into
    # the output's lib/gconv/ where derive_lib_paths() expects it.
    sysroot_dir = os.path.dirname(os.path.dirname(ld_linux))
    for gconv_subdir in ("usr/lib/gconv", "usr/lib64/gconv", "lib/gconv"):
        gconv_src = os.path.join(sysroot_dir, gconv_subdir)
        if os.path.isdir(gconv_src):
            gconv_dst = os.path.join(output_dir, "lib", "gconv")
            if not os.path.exists(gconv_dst):
                os.makedirs(os.path.dirname(gconv_dst), exist_ok=True)
                os.symlink(os.path.abspath(gconv_src), gconv_dst)
                print(f"Symlinked sysroot gconv: {gconv_dst} -> {gconv_src}",
                      file=sys.stderr)
            break

    # Cross-link lib/ and lib64/ so RPATH entries for either directory
    # resolve all shared libraries.  Some binaries (e.g. librustc_driver)
    # have RUNPATH=$ORIGIN/../lib while others search lib64/.  The linker
    # also needs rpath-link to resolve DT_NEEDED chains across both dirs.
    _cross_link_lib_dirs(output_dir)


def _cross_link_lib_dirs(output_dir):
    """Create bidirectional symlinks between lib/ and lib64/.

    Ensures shared libraries are discoverable from both directories.
    Only creates symlinks for files missing from one side — real files
    and existing symlinks are never overwritten.
    """
    lib_dir = os.path.join(output_dir, "lib")
    lib64_dir = os.path.join(output_dir, "lib64")

    # Never cross-link libc.so.6 — derive_lib_paths uses its presence
    # as a sentinel to exclude directories from LD_LIBRARY_PATH (to
    # prevent poisoning host processes with buckos glibc).  Symlinking
    # it into lib/ causes both dirs to be excluded, breaking transitive
    # DT_NEEDED resolution for the linker.
    _GLIBC_SKIP = {"libc.so.6"}

    linked = 0
    for src_dir, dst_dir, label in [
        (lib64_dir, lib_dir, "lib/ -> lib64/"),
        (lib_dir, lib64_dir, "lib64/ -> lib/"),
    ]:
        if not os.path.isdir(src_dir):
            continue
        os.makedirs(dst_dir, exist_ok=True)
        for name in os.listdir(src_dir):
            if name in _GLIBC_SKIP:
                continue
            dst_path = os.path.join(dst_dir, name)
            if not os.path.exists(dst_path) and not os.path.islink(dst_path):
                src_path = os.path.join(src_dir, name)
                # Only symlink files, not directories
                if os.path.isfile(src_path) or os.path.islink(src_path):
                    os.symlink(os.path.relpath(src_path, dst_dir), dst_path)
                    linked += 1

    if linked:
        print(f"Created {linked} lib/ <-> lib64/ cross-symlinks",
              file=sys.stderr)


if __name__ == "__main__":
    main()
