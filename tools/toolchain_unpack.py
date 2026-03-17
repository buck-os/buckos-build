#!/usr/bin/env python3
"""Unpack a prebuilt toolchain archive and optionally verify its integrity.

Extracts the archive, reads metadata.json, and optionally verifies the
contents SHA256 matches what was recorded at pack time.
"""

import argparse
import glob as _glob
import hashlib
import json
import os
import stat
import struct
import subprocess
import sys

from _env import clean_env, sanitize_global_env


def sha256_directory(directory):
    """Compute SHA256 of all files in a directory tree, excluding metadata.json."""
    h = hashlib.sha256()
    for root, dirs, files in sorted(os.walk(directory)):
        dirs.sort()
        for fname in sorted(files):
            if fname == "metadata.json" and root == directory:
                continue
            fpath = os.path.join(root, fname)
            rel = os.path.relpath(fpath, directory)
            h.update(rel.encode())
            if os.path.islink(fpath):
                h.update(os.readlink(fpath).encode())
            elif os.path.isfile(fpath):
                with open(fpath, "rb") as f:
                    for chunk in iter(lambda: f.read(65536), b""):
                        h.update(chunk)
    return h.hexdigest()


def detect_compression(path):
    """Detect compression format from file extension."""
    if path.endswith(".tar.zst") or path.endswith(".tar.zstd"):
        return "zst"
    elif path.endswith(".tar.xz"):
        return "xz"
    elif path.endswith(".tar.gz") or path.endswith(".tgz"):
        return "gz"
    elif path.endswith(".zip"):
        return "zip"
    return "auto"


def _unzip_inner(zip_path, dest_dir):
    """Unzip a .zip archive and return the path to the single inner file."""
    import zipfile
    with zipfile.ZipFile(zip_path) as zf:
        names = zf.namelist()
        if len(names) != 1:
            raise ValueError(f"expected exactly one file in zip, got: {names}")
        zf.extractall(dest_dir)
        return os.path.join(dest_dir, names[0])


def _patch_elf_interpreter(path, new_interp):
    """Patch the ELF interpreter (PT_INTERP) in a binary.

    Appends the new interpreter string to the end of the file and
    updates the PT_INTERP program header to point there.  This avoids
    needing to restructure the ELF or depend on patchelf.
    """
    with open(path, "rb") as f:
        data = bytearray(f.read())

    if data[:4] != b"\x7fELF":
        return False

    # Only handle 64-bit little-endian (x86_64)
    ei_class = data[4]
    ei_data = data[5]
    if ei_class != 2 or ei_data != 1:
        return False

    e_phoff = struct.unpack_from("<Q", data, 32)[0]
    e_phentsize = struct.unpack_from("<H", data, 54)[0]
    e_phnum = struct.unpack_from("<H", data, 56)[0]

    PT_INTERP = 3
    interp_found = False

    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type = struct.unpack_from("<I", data, off)[0]
        if p_type != PT_INTERP:
            continue

        p_offset = struct.unpack_from("<Q", data, off + 8)[0]
        p_filesz = struct.unpack_from("<Q", data, off + 32)[0]

        # Read current interpreter (bounded by segment size)
        seg_end = p_offset + p_filesz
        try:
            end = data.index(0, p_offset, seg_end)
        except ValueError:
            end = seg_end
        old_interp = data[p_offset:end].decode("ascii", errors="replace")
        if old_interp == new_interp:
            return False  # already correct

        new_bytes = new_interp.encode("ascii") + b"\x00"

        if len(new_bytes) <= p_filesz:
            # Fits in existing space — overwrite in place
            data[p_offset:p_offset + len(new_bytes)] = new_bytes
            # Pad remaining with nulls
            for j in range(len(new_bytes), p_filesz):
                data[p_offset + j] = 0
        else:
            # Append to end of file, update offset and size
            new_offset = len(data)
            data.extend(new_bytes)
            struct.pack_into("<Q", data, off + 8, new_offset)   # p_offset
            struct.pack_into("<Q", data, off + 16, 0)           # p_vaddr (unused)
            struct.pack_into("<Q", data, off + 24, 0)           # p_paddr (unused)
            struct.pack_into("<Q", data, off + 32, len(new_bytes))  # p_filesz
            struct.pack_into("<Q", data, off + 40, len(new_bytes))  # p_memsz

        interp_found = True
        break

    if not interp_found:
        return False

    orig_mode = os.stat(path).st_mode
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
    with open(path, "wb") as f:
        f.write(data)
    os.chmod(path, orig_mode)
    return True


def _rewrite_interpreters(toolchain_dir):
    """Rewrite ELF interpreters in host-tools to use the bundled ld-linux.

    Host-tools binaries are built for buckos (glibc 2.42) but their
    ELF interpreter points to /lib64/ld-linux-x86-64.so.2 which is
    the host system's glibc.  On systems with an older glibc, mixing
    ld-linux versions causes segfaults.  Patch all binaries to use the
    bundled buckos ld-linux so the toolchain is self-contained.
    """
    # Try host-tools first, fall back to sysroot ld-linux.
    # host-tools/lib64/ may not have ld-linux if glibc wasn't copied there.
    ld_linux = os.path.join(toolchain_dir, "host-tools", "lib64", "ld-linux-x86-64.so.2")
    if not os.path.exists(ld_linux):
        # Sysroot ld-linux — always present in cross-compiler output.
        for triple_dir in _glob.glob(os.path.join(toolchain_dir, "tools", "*-linux-gnu")):
            candidate = os.path.join(triple_dir, "sys-root", "lib64", "ld-linux-x86-64.so.2")
            if os.path.exists(candidate):
                ld_linux = candidate
                print(f"  using sysroot ld-linux: {ld_linux}", file=sys.stderr)
                break
        else:
            print(f"warning: no ld-linux found in {toolchain_dir}, skipping interpreter rewrite", file=sys.stderr)
            print(f"  tools dirs: {_glob.glob(os.path.join(toolchain_dir, 'tools', '*'))}", file=sys.stderr)
            return
    else:
        print(f"  using host-tools ld-linux: {ld_linux}", file=sys.stderr)

    new_interp = os.path.abspath(ld_linux)
    patched = 0

    # Only rewrite host-tools — the cross-compiler (tools/) was built by
    # the host GCC against host glibc and must keep the host's ld-linux.
    for subdir in ("host-tools",):
        root = os.path.join(toolchain_dir, subdir)
        if not os.path.isdir(root):
            continue
        for dirpath, _, filenames in os.walk(root):
            for name in filenames:
                fpath = os.path.join(dirpath, name)
                if os.path.islink(fpath) or not os.path.isfile(fpath):
                    continue
                # Quick check for ELF magic before full parse
                try:
                    with open(fpath, "rb") as f:
                        if f.read(4) != b"\x7fELF":
                            continue
                except (PermissionError, OSError):
                    continue
                # Skip shared libraries — they have PT_INTERP (glibc's
                # "executable libc" feature) but rewriting it corrupts
                # the library.  Only rewrite actual executables.
                if ".so." in name or name.endswith(".so"):
                    continue
                if _patch_elf_interpreter(fpath, new_interp):
                    patched += 1

    if patched:
        print(f"  patched ELF interpreter in {patched} binaries", file=sys.stderr)


def _inject_missing_rpath(toolchain_dir):
    """Inject $ORIGIN RPATH into host-tools binaries that lack one.

    Some packages (e.g. lzip) use non-standard build systems that
    bypass GCC specs, producing binaries without RPATH.  Without RPATH
    they fall back to host libc, breaking hermeticity.  Use the bundled
    patchelf to inject the standard $ORIGIN/../lib64:$ORIGIN/../lib RPATH.
    """
    patchelf = os.path.join(toolchain_dir, "host-tools", "bin", "patchelf")
    if not os.path.isfile(patchelf):
        return

    host_tools = os.path.join(toolchain_dir, "host-tools")
    if not os.path.isdir(host_tools):
        return

    # Set up env so patchelf can run (it needs the bundled ld-linux)
    env = clean_env()
    # Find ld-linux for LD_LIBRARY_PATH — try host-tools then sysroot.
    ld_linux = os.path.join(host_tools, "lib64", "ld-linux-x86-64.so.2")
    if not os.path.exists(ld_linux):
        for triple_dir in _glob.glob(os.path.join(toolchain_dir, "tools", "*-linux-gnu")):
            candidate = os.path.join(triple_dir, "sys-root", "lib64", "ld-linux-x86-64.so.2")
            if os.path.exists(candidate):
                ld_linux = candidate
                break
    if os.path.exists(ld_linux):
        env["LD_LIBRARY_PATH"] = os.path.abspath(os.path.dirname(ld_linux))

    rpath = "$ORIGIN/../lib64:$ORIGIN/../lib"
    patched = 0

    for dirpath, _, filenames in os.walk(host_tools):
        for name in filenames:
            fpath = os.path.join(dirpath, name)
            if os.path.islink(fpath) or not os.path.isfile(fpath):
                continue
            try:
                with open(fpath, "rb") as f:
                    data = f.read(64)
                if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
                    continue
                # Skip shared libraries (e.g. libc.so.6 has PT_INTERP
                # but patchelf corrupts it)
                if ".so." in name or name.endswith(".so"):
                    continue

                # Check for PT_INTERP (executable, not shared lib) and
                # absence of DT_RPATH/DT_RUNPATH
                with open(fpath, "rb") as f:
                    full = f.read()
                e_phoff = struct.unpack_from("<Q", full, 32)[0]
                e_phentsize = struct.unpack_from("<H", full, 54)[0]
                e_phnum = struct.unpack_from("<H", full, 56)[0]

                has_interp = False
                has_rpath = False
                for i in range(e_phnum):
                    off = e_phoff + i * e_phentsize
                    p_type = struct.unpack_from("<I", full, off)[0]
                    if p_type == 3:  # PT_INTERP
                        has_interp = True
                    if p_type == 2:  # PT_DYNAMIC
                        p_offset = struct.unpack_from("<Q", full, off + 8)[0]
                        p_filesz = struct.unpack_from("<Q", full, off + 32)[0]
                        for j in range(0, p_filesz, 16):
                            d_tag = struct.unpack_from("<q", full, p_offset + j)[0]
                            if d_tag in (15, 29):  # DT_RPATH, DT_RUNPATH
                                has_rpath = True
                            if d_tag == 0:
                                break

                if not has_interp or has_rpath:
                    continue

                # Make writable, inject RPATH, restore permissions
                orig_mode = os.stat(fpath).st_mode
                os.chmod(fpath, stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)
                result = subprocess.run(
                    [patchelf, "--set-rpath", rpath, fpath],
                    capture_output=True, env=env, timeout=30,
                )
                os.chmod(fpath, orig_mode)
                if result.returncode == 0:
                    patched += 1
            except (PermissionError, OSError, struct.error,
                    subprocess.TimeoutExpired):
                pass

    if patched:
        print(f"  injected RPATH into {patched} host-tools binaries",
              file=sys.stderr)


def _rewrite_script_shebangs(toolchain_dir):
    """Rewrite absolute shebangs in host-tools to use seed interpreters.

    Scripts may have shebangs pointing to build-time buck-out paths
    (e.g. #!/.../buck-out/.../bash) or absolute system paths
    (e.g. #!/usr/bin/perl).  Both break hermeticity — the seed must
    not depend on the host having any particular interpreter installed.

    Rewrites all absolute shebangs to the corresponding interpreter in
    host-tools/bin/ so the seed is self-contained and relocatable.
    """
    host_bin = os.path.join(toolchain_dir, "host-tools", "bin")
    if not os.path.isdir(host_bin):
        return

    # Build a map of available interpreters in host-tools/bin
    available = {}
    for name in os.listdir(host_bin):
        fpath = os.path.join(host_bin, name)
        if os.path.isfile(fpath) and not os.path.islink(fpath):
            available[name] = os.path.abspath(fpath)

    patched = 0
    root = os.path.join(toolchain_dir, "host-tools")
    if not os.path.isdir(root):
        return
    for dirpath, _, filenames in os.walk(root):
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
                shebang = line.decode("ascii", errors="replace").strip()
                rest = shebang[2:].strip()
                parts = rest.split(None, 1)
                if not parts:
                    continue
                interp_path = parts[0]
                interp_basename = os.path.basename(interp_path)

                # Skip shebangs already pointing into host-tools
                if os.path.abspath(host_bin) in os.path.abspath(interp_path):
                    continue

                # Find matching interpreter in host-tools/bin
                replacement = available.get(interp_basename)
                if not replacement:
                    # Try common aliases (e.g. perl5 -> perl)
                    for candidate in available:
                        if interp_basename.startswith(candidate):
                            replacement = available[candidate]
                            break
                if not replacement:
                    continue

                # Preserve arguments after interpreter path
                args_suffix = b" " + parts[1].encode("ascii") if len(parts) > 1 else b""
                new_line = b"#!" + replacement.encode("ascii") + args_suffix + b"\n"
                with open(fpath, "rb") as f:
                    content = f.read()
                old_end = content.find(b"\n")
                if old_end < 0:
                    continue
                new_content = new_line + content[old_end + 1:]
                orig_mode = os.stat(fpath).st_mode
                os.chmod(fpath, stat.S_IRUSR | stat.S_IWUSR)
                with open(fpath, "wb") as f:
                    f.write(new_content)
                os.chmod(fpath, orig_mode)
                patched += 1
            except (PermissionError, OSError, UnicodeDecodeError):
                pass

    if patched:
        print(f"  rewrote shebangs in {patched} host-tools scripts",
              file=sys.stderr)


def _install_gcc_specs(toolchain_dir, target_triple="x86_64-buckos-linux-gnu"):
    """Install GCC specs so compiled programs use the bundled ld-linux.

    Both the cross-compiler (tools/bin/<triple>-gcc) and host-tools GCC
    (host-tools/bin/gcc) produce binaries that default to using the host's
    /lib64/ld-linux-x86-64.so.2.  On hosts with older glibc, mixing the
    host ld-linux with buckos-linked CRT objects causes segfaults.

    Write a minimal specs override that appends --dynamic-linker pointing
    to the bundled ld-linux.  The leading '+' tells GCC to append to the
    built-in link spec.  ld uses the last --dynamic-linker, so our append
    overrides the default.

    Also injects --sysroot into *self_spec so that ALL GCC invocations
    (including bare "gcc" calls from Rust build scripts, configure tests,
    etc.) find CRT files and headers without explicit --sysroot.  Build
    rules that pass their own --sysroot override the specs default since
    command-line args take precedence.

    Combined with $ORIGIN-relative RPATH (also in specs), compiled
    programs find the matching buckos ld-linux + libc at runtime
    without LD_LIBRARY_PATH.
    """
    installed = 0

    # Sysroot shared by cross-compiler and host-tools gcc.
    sysroot = os.path.join(
        toolchain_dir, "tools", target_triple, "sys-root",
    )
    sysroot_abs = os.path.abspath(sysroot) if os.path.isdir(sysroot) else None

    # Cross-compiler: tools/lib/gcc/<triple>/<ver>/specs
    # Uses sysroot ld-linux as dynamic linker.
    sysroot_ld = os.path.join(
        toolchain_dir, "tools", target_triple, "sys-root",
        "lib64", "ld-linux-x86-64.so.2",
    )
    if os.path.exists(sysroot_ld):
        sysroot_ld_abs = os.path.abspath(sysroot_ld)
        pattern = os.path.join(
            toolchain_dir, "tools", "lib", "gcc", target_triple, "*",
        )
        for gcc_libdir in sorted(_glob.glob(pattern)):
            _write_specs(gcc_libdir, sysroot_ld_abs, sysroot=sysroot_abs)
            installed += 1

    # Host-tools GCC: host-tools/lib64/gcc/<triple>/<ver>/specs
    # Uses host-tools ld-linux as dynamic linker.
    # Keep --sysroot pointing to cross sysroot for header discovery
    # (sys/types.h etc.), but also add -L flags for CRT discovery.
    # gcc-native was built with --prefix=/usr and doesn't apply
    # --sysroot to startfile search (not built with --with-sysroot),
    # so CRTs (crt1.o, crti.o) need explicit -L paths.
    host_ld = os.path.join(
        toolchain_dir, "host-tools", "lib64", "ld-linux-x86-64.so.2",
    )
    if os.path.exists(host_ld):
        host_ld_abs = os.path.abspath(host_ld)
        host_prefix = os.path.abspath(
            os.path.join(toolchain_dir, "host-tools"),
        )
        # Host-tools GCC may use a different triple (e.g. x86_64-pc-linux-gnu)
        pattern = os.path.join(
            toolchain_dir, "host-tools", "lib64", "gcc", "*", "*",
        )
        for gcc_libdir in sorted(_glob.glob(pattern)):
            if os.path.isdir(gcc_libdir):
                _write_specs(
                    gcc_libdir, host_ld_abs,
                    sysroot=sysroot_abs, host_prefix=host_prefix,
                )
                installed += 1

    if installed:
        print(f"  installed specs in {installed} GCC directories",
              file=sys.stderr)


def _write_specs(gcc_libdir, ld_linux_abs, sysroot=None, host_prefix=None):
    """Write a specs override into a GCC lib directory.

    Uses $ORIGIN-relative RPATH so compiled binaries find their libs
    at runtime without LD_LIBRARY_PATH.  Works in both seed layout
    (bin/foo → ../lib64/) and rootfs (/usr/bin/foo → /usr/lib64/).

    When sysroot is provided, injects --sysroot via *self_spec so bare
    gcc invocations (Rust build scripts, configure tests) find CRT files
    and headers without explicit --sysroot on the command line.

    When host_prefix is provided (for gcc-native in host-tools), adds
    -L flags for CRT discovery instead of --sysroot.  gcc-native was
    built with --prefix=/usr and doesn't honour --sysroot for startfile
    search (not built with --with-sysroot).
    """
    # ld-linux is at <prefix>/lib64/ld-linux-x86-64.so.2.
    ld_dir = os.path.dirname(ld_linux_abs)
    prefix = os.path.dirname(ld_dir)  # up from lib64

    # $ORIGIN-relative RPATH works for binaries installed in standard
    # layout (bin/foo → ../lib64/).  Add absolute paths too so programs
    # compiled in random build directories (configure test programs,
    # kernel's fixdep, Rust build scripts) find the bundled glibc
    # without LD_LIBRARY_PATH.
    abs_parts = []
    for d in ("lib64", "lib", "usr/lib64", "usr/lib"):
        p = os.path.join(prefix, d)
        if os.path.isdir(p):
            abs_parts.append(os.path.abspath(p))
    rpath_str = "$ORIGIN/../lib64:$ORIGIN/../lib"
    if abs_parts:
        rpath_str += ":" + ":".join(abs_parts)

    specs_content = ""

    # Inject --sysroot so all gcc invocations find CRT files and headers.
    # Build rules pass their own --sysroot which overrides this default
    # (command-line args take precedence over *self_spec).
    if sysroot:
        specs_content += f"*self_spec:\n+ --sysroot={sysroot}\n\n"

    # Override *libgcc to ensure -lgcc_eh is linked for static builds.
    # GCC's built-in spec claims %{static:-lgcc -lgcc_eh} but the
    # cross-compiler drops -lgcc_eh from the actual collect2 invocation.
    # Providing the identical spec text via a specs file forces GCC to
    # use the external version which correctly includes -lgcc_eh.
    specs_content += (
        "*libgcc:\n"
        "%{static|static-libgcc|static-pie:-lgcc -lgcc_eh}"
        "%{!static:%{!static-libgcc:%{!static-pie:"
        "%{!shared-libgcc:-lgcc --push-state --as-needed -lgcc_s --pop-state}"
        "%{shared-libgcc:-lgcc_s%{!shared: -lgcc}}}}}\n"
        "\n"
    )

    # Build the *link spec: dynamic linker + RPATH + optional -L for CRTs.
    #
    # Cross-compiler: use %R (GCC's sysroot substitution) so specs are
    # machine-independent.  %R expands to --sysroot value at gcc
    # invocation time.  Padded with '/' for in-place interpreter
    # rewriting by rewrite_interps.py.
    #
    # Host-tools gcc-native: keep absolute paths — the ld-linux is in
    # host-tools (not the sysroot), so %R can't reference it.  Protected
    # by allow_cache_upload=False in toolchain_import.
    if host_prefix:
        # gcc-native: absolute paths + -L for CRT discovery
        link_extra = (
            f"%{{!shared:%{{!static:--dynamic-linker {ld_linux_abs}"
            f" -rpath {rpath_str}}}}}"
        )
        lib_flags = ""
        for d in ("lib", "lib64", "usr/lib", "usr/lib64"):
            p = os.path.join(host_prefix, d)
            if os.path.isdir(p):
                lib_flags += f" -L{os.path.abspath(p)}"
        if lib_flags:
            link_extra += lib_flags
    else:
        # Cross-compiler: %R-relative paths (machine-independent)
        pad = "/" * 260
        interp = f"{pad}%R/lib64/ld-linux-x86-64.so.2"
        sysroot_rpath = "%R/lib64:%R/lib:%R/usr/lib64:%R/usr/lib"
        link_extra = (
            f"%{{!shared:%{{!static:--dynamic-linker {interp}}}}}"
            f" %{{!static:--disable-new-dtags"
            f" -rpath {sysroot_rpath}:{rpath_str}}}"
        )

    specs_content += f"*link:\n+ {link_extra}\n\n"

    specs_path = os.path.join(gcc_libdir, "specs")
    with open(specs_path, "w") as f:
        f.write(specs_content)


def _pipe_extract(producer_cmd, consumer_cmd):
    """Run producer | consumer without shell=True, return combined result."""
    producer = subprocess.Popen(
        producer_cmd, stdout=subprocess.PIPE, env=clean_env(),
    )
    consumer = subprocess.Popen(
        consumer_cmd, stdin=producer.stdout,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=clean_env(),
    )
    producer.stdout.close()
    consumer.communicate()
    rc = consumer.returncode or producer.wait()
    return type("R", (), {"returncode": rc})()


def _symlink_sysroot_libs(toolchain_dir):
    """Symlink sysroot shared libs into host-tools/lib64/.

    Host-tools binaries have RPATH=$ORIGIN/../lib64 which resolves to
    host-tools/lib64/.  But glibc (libc.so.6, libm.so.6, etc.) lives
    in the sysroot, not in host-tools.  Without these symlinks, the
    dynamic linker falls through to the host's glibc which may be an
    incompatible version (e.g. missing __nptl_change_stack_perm).
    """
    ht_lib64 = os.path.join(toolchain_dir, "host-tools", "lib64")
    if not os.path.isdir(ht_lib64):
        return

    # Find sysroot lib dirs
    sysroot_lib_dirs = []
    for triple_dir in sorted(_glob.glob(os.path.join(toolchain_dir, "tools", "*-linux-gnu"))):
        for subdir in ("sys-root/usr/lib64", "sys-root/usr/lib", "sys-root/lib64", "sys-root/lib"):
            d = os.path.join(triple_dir, subdir)
            if os.path.isdir(d):
                sysroot_lib_dirs.append(d)

    linked = 0
    for src_dir in sysroot_lib_dirs:
        for name in os.listdir(src_dir):
            if not (name.endswith(".so") or ".so." in name):
                continue
            src = os.path.join(src_dir, name)
            dst = os.path.join(ht_lib64, name)
            if os.path.exists(dst):
                continue
            rel = os.path.relpath(src, ht_lib64)
            os.symlink(rel, dst)
            linked += 1

    if linked:
        print(f"  symlinked {linked} sysroot libs into host-tools/lib64/", file=sys.stderr)

    # Symlink sysroot gconv modules into host-tools/lib/gconv/ so
    # msgfmt (from gettext) can find charset conversion modules.
    for src_dir in sysroot_lib_dirs:
        gconv_src = os.path.join(src_dir, "gconv")
        if os.path.isdir(gconv_src):
            ht_lib = os.path.join(toolchain_dir, "host-tools", "lib")
            os.makedirs(ht_lib, exist_ok=True)
            gconv_dst = os.path.join(ht_lib, "gconv")
            if not os.path.exists(gconv_dst):
                rel = os.path.relpath(gconv_src, ht_lib)
                os.symlink(rel, gconv_dst)
                print(f"  symlinked sysroot gconv into host-tools/lib/gconv/", file=sys.stderr)
            break


def _symlink_host_crts(toolchain_dir):
    """Symlink glibc CRT objects into host-tools/lib64/ for gcc-native.

    gcc-native (x86_64-pc-linux-gnu) searches lib64/ for CRT startfiles
    but glibc installs them in lib/.  GCC resolves startfiles before -L
    flags take effect, so the files must be in a standard search dir.
    """
    src_dir = os.path.join(toolchain_dir, "host-tools", "lib")
    dst_dir = os.path.join(toolchain_dir, "host-tools", "lib64")
    if not os.path.isdir(src_dir) or not os.path.isdir(dst_dir):
        return
    linked = 0
    for name in os.listdir(src_dir):
        if name.startswith("crt") and name.endswith(".o"):
            src = os.path.join(src_dir, name)
            dst = os.path.join(dst_dir, name)
            if not os.path.exists(dst):
                os.symlink(os.path.relpath(src, dst_dir), dst)
                linked += 1
    if linked:
        print(f"  symlinked {linked} CRT objects into host-tools/lib64/",
              file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description="Unpack prebuilt toolchain archive")
    parser.add_argument("--archive", required=True, help="Input archive path")
    parser.add_argument("--output", help="Output directory")
    parser.add_argument("--verify", action="store_true",
                        help="Verify contents SHA256 from metadata.json")
    parser.add_argument("--print-metadata", action="store_true",
                        help="Print metadata and exit")
    args = parser.parse_args()
    sanitize_global_env()

    archive = os.path.abspath(args.archive)
    if not os.path.isfile(archive):
        print(f"error: archive not found: {archive}", file=sys.stderr)
        sys.exit(1)

    if args.print_metadata and not args.output:
        # Extract just metadata.json to a temp location
        import tempfile
        with tempfile.TemporaryDirectory() as tmpdir:
            comp = detect_compression(archive)
            if comp == "zip":
                inner = _unzip_inner(archive, tmpdir)
                inner_comp = detect_compression(inner)
                if inner_comp == "zst":
                    result = _pipe_extract(
                        ["zstd", "-dc", inner],
                        ["tar", "-C", tmpdir, "-xf", "-", "./metadata.json"],
                    )
                else:
                    result = subprocess.run(
                        ["tar", "-C", tmpdir, "-xf", inner, "./metadata.json"],
                        capture_output=True, env=clean_env())
            elif comp == "zst":
                result = _pipe_extract(
                    ["zstd", "-dc", archive],
                    ["tar", "-C", tmpdir, "-xf", "-", "./metadata.json"],
                )
            elif comp == "xz":
                result = subprocess.run(
                    ["tar", "-C", tmpdir, "-xJf", archive, "./metadata.json"],
                    capture_output=True, env=clean_env())
            else:
                result = subprocess.run(
                    ["tar", "-C", tmpdir, "-xzf", archive, "./metadata.json"],
                    capture_output=True, env=clean_env())

            if result.returncode != 0:
                print(f"error: failed to extract metadata.json", file=sys.stderr)
                sys.exit(1)

            meta_path = os.path.join(tmpdir, "metadata.json")
            if os.path.exists(meta_path):
                with open(meta_path) as f:
                    metadata = json.load(f)
                print(json.dumps(metadata, indent=2))
            else:
                print("error: no metadata.json in archive", file=sys.stderr)
                sys.exit(1)
        return

    if not args.output:
        print("error: --output is required unless using --print-metadata", file=sys.stderr)
        sys.exit(1)

    output = os.path.abspath(args.output)
    os.makedirs(output, exist_ok=True)

    # Extract
    print(f"Extracting {archive} -> {output}", file=sys.stderr)
    comp = detect_compression(archive)
    if comp == "zip":
        import tempfile
        with tempfile.TemporaryDirectory() as tmpdir:
            inner = _unzip_inner(archive, tmpdir)
            inner_comp = detect_compression(inner)
            if inner_comp == "zst":
                result = _pipe_extract(
                    ["zstd", "-dc", inner],
                    ["tar", "-C", output, "-xf", "-"],
                )
            else:
                result = subprocess.run(
                    ["tar", "-C", output, "-xf", inner], env=clean_env())
    elif comp == "zst":
        result = _pipe_extract(
            ["zstd", "-dc", archive],
            ["tar", "-C", output, "-xf", "-"],
        )
    elif comp == "xz":
        result = subprocess.run(
            ["tar", "-C", output, "-xJf", archive], env=clean_env())
    else:
        result = subprocess.run(
            ["tar", "-C", output, "-xzf", archive], env=clean_env())

    if result.returncode != 0:
        print(f"error: extraction failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(1)

    # Verify extraction produced expected content
    extracted = os.listdir(output)
    print(f"Extracted contents: {sorted(extracted)}", file=sys.stderr)
    if "tools" not in extracted:
        print("error: seed archive missing 'tools/' directory", file=sys.stderr)
        sys.exit(1)

    # Patch ELF interpreters to use bundled ld-linux
    _rewrite_interpreters(output)

    # Symlink sysroot shared libs into host-tools/lib64/ so the
    # $ORIGIN/../lib64 RPATH in host-tools binaries finds glibc.
    _symlink_sysroot_libs(output)

    # Inject RPATH into host-tools binaries that lack one (e.g. lzip)
    _inject_missing_rpath(output)

    # Fix script shebangs that point to build-time paths
    _rewrite_script_shebangs(output)

    # Install GCC specs so cross-compiled programs use the sysroot's
    # ld-linux instead of the host's (avoids glibc version mismatch).
    _install_gcc_specs(output)

    # Symlink CRT objects into host-tools/lib64/ so gcc-native can find
    # them.  gcc-native was built with --prefix=/usr and searches lib64/
    # but CRT files from glibc are installed in lib/.  GCC resolves CRT
    # startfiles before -L flags take effect, so symlinks are needed.
    _symlink_host_crts(output)

    # Read metadata
    meta_path = os.path.join(output, "metadata.json")
    metadata = {}
    if os.path.exists(meta_path):
        with open(meta_path) as f:
            metadata = json.load(f)
        print(f"Triple:   {metadata.get('target_triple', 'unknown')}", file=sys.stderr)
        print(f"GCC:      {metadata.get('gcc_version', 'unknown')}", file=sys.stderr)
        print(f"glibc:    {metadata.get('glibc_version', 'unknown')}", file=sys.stderr)
        print(f"Created:  {metadata.get('created_at', 'unknown')}", file=sys.stderr)
    else:
        print("warning: no metadata.json in archive", file=sys.stderr)

    # Verify
    if args.verify:
        expected = metadata.get("contents_sha256")
        if not expected:
            print("error: no contents_sha256 in metadata, cannot verify", file=sys.stderr)
            sys.exit(1)

        print("Verifying contents hash...", file=sys.stderr)
        actual = sha256_directory(output)

        if actual == expected:
            print("Verification: PASS", file=sys.stderr)
        else:
            print(f"Verification: FAIL", file=sys.stderr)
            print(f"  expected: {expected}", file=sys.stderr)
            print(f"  actual:   {actual}", file=sys.stderr)
            sys.exit(1)

    if args.print_metadata and metadata:
        print(json.dumps(metadata, indent=2))

    print(f"Extracted to: {output}", file=sys.stderr)


if __name__ == "__main__":
    main()
