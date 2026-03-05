#!/usr/bin/env python3
"""Pack a bootstrap stage output into a distributable toolchain archive.

Collects compiler binaries, sysroot, support libraries, and GCC internal
tools, generates metadata.json, and packs everything into a compressed tar.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

from _env import clean_env, sanitize_global_env


def sha256_directory(directory):
    """Compute SHA256 of all files in a directory tree."""
    h = hashlib.sha256()
    for root, dirs, files in sorted(os.walk(directory)):
        dirs.sort()
        for fname in sorted(files):
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


def sha256_file(path):
    """Compute SHA256 of a single file."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _scrub_build_paths(directory):
    """Replace absolute buck-out paths in ELF binaries with /build.

    Build systems (especially glibc) embed __FILE__ paths in binaries
    that contain the Buck2 action directory (buck-out/...).  Replace
    with a generic /build prefix padded with null bytes to preserve
    binary layout.
    """
    pattern = re.compile(rb'/[^\x00]*?buck-out[^\x00]*')
    scrubbed = 0

    for dirpath, _, filenames in os.walk(directory):
        for name in filenames:
            path = os.path.join(dirpath, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            try:
                with open(path, 'rb') as f:
                    magic = f.read(4)
                if magic != b'\x7fELF':
                    continue
                with open(path, 'rb') as f:
                    data = f.read()
                if b'buck-out' not in data:
                    continue

                def _replace(m):
                    orig = m.group(0)
                    repl = b'/build'
                    if len(repl) >= len(orig):
                        return orig
                    return repl + b'\x00' * (len(orig) - len(repl))

                new_data = pattern.sub(_replace, data)
                if new_data != data:
                    orig_mode = os.stat(path).st_mode
                    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
                    with open(path, 'wb') as f:
                        f.write(new_data)
                    os.chmod(path, orig_mode)
                    scrubbed += 1
            except (PermissionError, OSError):
                pass

    if scrubbed:
        print(f"  scrubbed build paths from {scrubbed} ELF files", file=sys.stderr)


def _pad_elf_interpreter(directory, target_size=256):
    """Pad the ELF interpreter to a fixed size with leading slashes.

    The cross-compiler is built by the host GCC and links against the
    host glibc.  On systems with older glibc the binary segfaults.
    Padding the interpreter to target_size bytes with leading slashes
    (///...///lib64/ld-linux-x86-64.so.2) allows the unpack step to
    overwrite it in-place with the absolute path to the bundled buckos
    ld-linux, making the cross-compiler portable.

    Multiple leading slashes collapse to one per POSIX, so the padded
    path still resolves correctly on the build host.
    """
    STANDARD_INTERP = b"/lib64/ld-linux-x86-64.so.2"
    padded = 0

    for dirpath, _, filenames in os.walk(directory):
        for name in filenames:
            path = os.path.join(dirpath, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            try:
                with open(path, 'rb') as f:
                    data = bytearray(f.read())
            except (PermissionError, OSError):
                continue

            if data[:4] != b'\x7fELF':
                continue
            # Only handle 64-bit little-endian (x86_64)
            if data[4] != 2 or data[5] != 1:
                continue

            e_phoff = struct.unpack_from('<Q', data, 32)[0]
            e_phentsize = struct.unpack_from('<H', data, 54)[0]
            e_phnum = struct.unpack_from('<H', data, 56)[0]

            PT_INTERP = 3
            for i in range(e_phnum):
                off = e_phoff + i * e_phentsize
                p_type = struct.unpack_from('<I', data, off)[0]
                if p_type != PT_INTERP:
                    continue

                p_offset = struct.unpack_from('<Q', data, off + 8)[0]
                p_filesz = struct.unpack_from('<Q', data, off + 32)[0]

                end = data.index(0, p_offset)
                old_interp = data[p_offset:end]
                if old_interp != STANDARD_INTERP:
                    break  # already padded or different interpreter

                # Build padded string: ///...///lib64/ld-linux-x86-64.so.2\0
                # target_size includes the null terminator
                suffix = b"lib64/ld-linux-x86-64.so.2"
                n_slashes = target_size - 1 - len(suffix)  # -1 for null
                new_bytes = b"/" * n_slashes + suffix + b"\x00"

                if len(new_bytes) <= p_filesz:
                    data[p_offset:p_offset + len(new_bytes)] = new_bytes
                    for j in range(len(new_bytes), p_filesz):
                        data[p_offset + j] = 0
                else:
                    new_offset = len(data)
                    data.extend(new_bytes)
                    struct.pack_into('<Q', data, off + 8, new_offset)
                    struct.pack_into('<Q', data, off + 32, len(new_bytes))
                    struct.pack_into('<Q', data, off + 40, len(new_bytes))

                orig_mode = os.stat(path).st_mode
                os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
                with open(path, 'wb') as f:
                    f.write(data)
                os.chmod(path, orig_mode)
                padded += 1
                break

    if padded:
        print(f"  padded ELF interpreter in {padded} binaries", file=sys.stderr)


def _strip_rpath(directory):
    """Strip DT_RPATH and DT_RUNPATH from ELF binaries.

    Libtool-built packages embed build-time RPATH entries pointing to
    buck-out directories and /usr/lib64.  These are incorrect in the
    redistributable seed — host-tools find their libraries via
    LD_LIBRARY_PATH at runtime.  Overwrite the RPATH strings with
    null bytes to remove them without restructuring the ELF.
    """
    DT_RPATH = 15
    DT_RUNPATH = 29
    SHT_DYNAMIC = 6
    stripped = 0

    for dirpath, _, filenames in os.walk(directory):
        for name in filenames:
            path = os.path.join(dirpath, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            try:
                with open(path, 'rb') as f:
                    magic = f.read(4)
                if magic != b'\x7fELF':
                    continue
                with open(path, 'rb') as f:
                    data = bytearray(f.read())

                # Only handle 64-bit LE (x86_64)
                if data[4] != 2 or data[5] != 1:
                    continue

                e_shoff = struct.unpack_from('<Q', data, 40)[0]
                e_shentsize = struct.unpack_from('<H', data, 58)[0]
                e_shnum = struct.unpack_from('<H', data, 60)[0]

                # Find SHT_DYNAMIC section and its linked .dynstr
                dyn_offset = dyn_size = dyn_entsize = dynstr_offset = 0
                for i in range(e_shnum):
                    sh_off = e_shoff + i * e_shentsize
                    sh_type = struct.unpack_from('<I', data, sh_off + 4)[0]
                    if sh_type == SHT_DYNAMIC:
                        dyn_offset = struct.unpack_from('<Q', data, sh_off + 24)[0]
                        dyn_size = struct.unpack_from('<Q', data, sh_off + 32)[0]
                        dyn_entsize = struct.unpack_from('<Q', data, sh_off + 56)[0]
                        sh_link = struct.unpack_from('<I', data, sh_off + 40)[0]
                        dynstr_sh_off = e_shoff + sh_link * e_shentsize
                        dynstr_offset = struct.unpack_from('<Q', data, dynstr_sh_off + 24)[0]
                        break

                if not dyn_offset or not dynstr_offset:
                    continue
                if not dyn_entsize:
                    dyn_entsize = 16  # sizeof(Elf64_Dyn)

                modified = False
                n_entries = dyn_size // dyn_entsize
                for i in range(n_entries):
                    ent_off = dyn_offset + i * dyn_entsize
                    d_tag = struct.unpack_from('<q', data, ent_off)[0]
                    if d_tag in (DT_RPATH, DT_RUNPATH):
                        d_val = struct.unpack_from('<Q', data, ent_off + 8)[0]
                        str_off = dynstr_offset + d_val
                        end = data.index(0, str_off)
                        if end > str_off:
                            for j in range(str_off, end):
                                data[j] = 0
                            modified = True

                if modified:
                    orig_mode = os.stat(path).st_mode
                    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
                    with open(path, 'wb') as f:
                        f.write(data)
                    os.chmod(path, orig_mode)
                    stripped += 1

            except (PermissionError, OSError, ValueError, struct.error):
                pass

    if stripped:
        print(f"  stripped RPATH from {stripped} ELF files", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description="Pack bootstrap toolchain into archive")
    parser.add_argument("--stage-dir", required=True, help="Stage 2 output directory")
    parser.add_argument("--output", required=True, help="Output archive path")
    parser.add_argument("--target-triple", default="x86_64-buckos-linux-gnu")
    parser.add_argument("--gcc-version", default="14.3.0")
    parser.add_argument("--glibc-version", default="2.42")
    parser.add_argument("--compression", choices=["zst", "xz", "gz"], default="zst")
    parser.add_argument("--host-tools-dir", default=None,
                        help="Directory containing host tools to include as host-tools/")
    args = parser.parse_args()
    sanitize_global_env()

    stage_dir = os.path.abspath(args.stage_dir)
    output = os.path.abspath(args.output)

    if not os.path.isdir(stage_dir):
        print(f"error: stage directory not found: {stage_dir}", file=sys.stderr)
        sys.exit(1)

    os.makedirs(os.path.dirname(output) or ".", exist_ok=True)

    with tempfile.TemporaryDirectory() as tmpdir:
        # Copy stage dir so we can scrub build paths (Buck2 artifacts
        # are read-only).
        stage_copy = os.path.join(tmpdir, "stage")
        print("Copying stage dir for path scrubbing...", file=sys.stderr)
        shutil.copytree(stage_dir, stage_copy, symlinks=True)

        # If host tools are provided, stage them under host-tools/ in the
        # temp dir so the archive layout matches what toolchain_import expects.
        host_tools_tar = ""
        has_host_tools = False
        if args.host_tools_dir:
            host_tools_src = os.path.abspath(args.host_tools_dir)
            if not os.path.isdir(host_tools_src):
                print(f"error: host-tools directory not found: {host_tools_src}", file=sys.stderr)
                sys.exit(1)
            host_tools_dst = os.path.join(tmpdir, "host-tools")
            shutil.copytree(host_tools_src, host_tools_dst, symlinks=True)
            host_tools_tar = f" -C {tmpdir} host-tools"
            has_host_tools = True

        # Scrub absolute buck-out paths from ELF binaries in the cross-compiler
        # tree only.  Host-tools binaries must NOT be scrubbed because tools
        # like flex and bison store paths to helper programs (m4) at compile
        # time — scrubbing truncates those to "/build" which breaks exec().
        print("Scrubbing build paths...", file=sys.stderr)
        _scrub_build_paths(stage_copy)

        # Pad the cross-compiler's ELF interpreter with leading slashes
        # so the unpack step can rewrite it to the bundled ld-linux.
        # Host-tools are already padded at build time via extra_ldflags.
        print("Padding cross-compiler interpreter...", file=sys.stderr)
        _pad_elf_interpreter(stage_copy)

        # Strip RPATH/RUNPATH from all seed binaries.  Cross-compiler
        # tools have buck-out RPATHs (scrubbed to /build above); host-tools
        # have libtool-baked paths.  Both are wrong for the redistributable
        # seed — all binaries find libraries via LD_LIBRARY_PATH at runtime.
        print("Stripping RPATH from cross-compiler...", file=sys.stderr)
        _strip_rpath(stage_copy)
        if has_host_tools:
            print("Stripping RPATH from host-tools...", file=sys.stderr)
            _strip_rpath(host_tools_dst)

        # Compute content hash from scrubbed stage
        print("Computing content hash...", file=sys.stderr)
        contents_sha256 = sha256_directory(stage_copy)

        # Generate metadata
        metadata = {
            "format_version": 1,
            "target_triple": args.target_triple,
            "gcc_version": args.gcc_version,
            "glibc_version": args.glibc_version,
            "created_at": datetime.now(timezone.utc).isoformat(),
            "contents_sha256": contents_sha256,
        }
        if has_host_tools:
            metadata["has_host_tools"] = True

        meta_path = os.path.join(tmpdir, "metadata.json")
        with open(meta_path, "w") as f:
            json.dump(metadata, f, indent=2)
            f.write("\n")

        print(f"Packing {stage_dir} -> {output}", file=sys.stderr)

        if args.compression == "zst":
            tar_cmd = (
                f"tar -C {stage_copy} -cf - . -C {tmpdir} metadata.json{host_tools_tar}"
                f" | zstd -T0 -19 -o {output}"
            )
        elif args.compression == "xz":
            tar_cmd = (
                f"tar -C {stage_copy} -cJf {output} . -C {tmpdir} metadata.json{host_tools_tar}"
            )
        else:
            tar_cmd = (
                f"tar -C {stage_copy} -czf {output} . -C {tmpdir} metadata.json{host_tools_tar}"
            )

        result = subprocess.run(tar_cmd, shell=True, env=clean_env())

    if result.returncode != 0:
        print(f"error: tar failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(1)

    # Print summary
    archive_sha256 = sha256_file(output)
    size_bytes = os.path.getsize(output)
    size_mb = size_bytes / (1024 * 1024)

    print(f"Archive:  {output}", file=sys.stderr)
    print(f"Size:     {size_mb:.1f} MB ({size_bytes} bytes)", file=sys.stderr)
    print(f"SHA256:   {archive_sha256}", file=sys.stderr)
    print(f"Triple:   {args.target_triple}", file=sys.stderr)
    print(f"GCC:      {args.gcc_version}", file=sys.stderr)
    print(f"glibc:    {args.glibc_version}", file=sys.stderr)

    # Print machine-readable output to stdout
    print(json.dumps({
        "archive": output,
        "size_bytes": size_bytes,
        "archive_sha256": archive_sha256,
        **metadata,
    }))


if __name__ == "__main__":
    main()
