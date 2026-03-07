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

        # Only rewrite interpreters with padding (leading ///) from build time.
        # Non-padded interpreters belong to host-built binaries that should
        # use the system ld-linux.
        if not old_interp.startswith("///"):
            return False

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
    # Check both the direct path and the glibc-isolated path (pack-time
    # _isolate_glibc moves ld-linux from lib64/ to lib64/glibc/).
    ld_linux = os.path.join(toolchain_dir, "host-tools", "lib64", "ld-linux-x86-64.so.2")
    if not os.path.exists(ld_linux):
        ld_linux = os.path.join(toolchain_dir, "host-tools", "lib64", "glibc", "ld-linux-x86-64.so.2")
    if not os.path.exists(ld_linux):
        return

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
                if _patch_elf_interpreter(fpath, new_interp):
                    patched += 1

    if patched:
        print(f"  patched ELF interpreter in {patched} binaries", file=sys.stderr)


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

    Combined with LD_LIBRARY_PATH (set by the build helpers to include
    host-tools/lib64), all compiled programs find the matching buckos
    ld-linux + libc at runtime.
    """
    installed = 0

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
            _write_specs(gcc_libdir, sysroot_ld_abs)
            installed += 1

    # Host-tools GCC: host-tools/lib64/gcc/<triple>/<ver>/specs
    # Uses host-tools ld-linux as dynamic linker.  Check the glibc-isolated
    # path too (pack-time _isolate_glibc moves ld-linux to lib64/glibc/).
    host_ld = os.path.join(
        toolchain_dir, "host-tools", "lib64", "ld-linux-x86-64.so.2",
    )
    if not os.path.exists(host_ld):
        host_ld = os.path.join(
            toolchain_dir, "host-tools", "lib64", "glibc", "ld-linux-x86-64.so.2",
        )
    if os.path.exists(host_ld):
        host_ld_abs = os.path.abspath(host_ld)
        # Host-tools GCC may use a different triple (e.g. x86_64-pc-linux-gnu)
        pattern = os.path.join(
            toolchain_dir, "host-tools", "lib64", "gcc", "*", "*",
        )
        for gcc_libdir in sorted(_glob.glob(pattern)):
            if os.path.isdir(gcc_libdir):
                _write_specs(gcc_libdir, host_ld_abs)
                installed += 1

    if installed:
        print(f"  installed specs in {installed} GCC directories",
              file=sys.stderr)


def _write_specs(gcc_libdir, ld_linux_abs):
    """Write a specs override into a GCC lib directory."""
    rpath_placeholder = "/buckos-rpath-pad" + "X" * 228
    specs_content = (
        "*link:\n"
        f"+ %{{!shared:%{{!static:--dynamic-linker {ld_linux_abs}"
        f" -rpath {rpath_placeholder}}}}}\n"
        "\n"
    )
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

    # Patch ELF interpreters to use bundled ld-linux
    _rewrite_interpreters(output)

    # Install GCC specs so cross-compiled programs use the sysroot's
    # ld-linux instead of the host's (avoids glibc version mismatch).
    _install_gcc_specs(output)

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
