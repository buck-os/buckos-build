#!/usr/bin/env python3
"""Pack a bootstrap stage output into a distributable toolchain archive.

Collects compiler binaries, sysroot, support libraries, and GCC internal
tools, generates metadata.json, and packs everything into a compressed tar.

Archive layout:
  tools/                  cross-compiler (stage 1 output)
  host-tools/             merged FHS tree (hermetic PATH)
  metadata.json           provenance
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


def _elf_data_ranges(data):
    """Return list of (start, end) byte ranges for ELF data sections.

    Only returns ranges for sections that contain string/path data
    (rodata, strtab, comment, debug sections).  Excludes executable
    code sections (.text, .init, .fini, .plt) to avoid corrupting
    machine code that happens to match path patterns.
    """
    if len(data) < 64 or data[:4] != b'\x7fELF':
        return []
    # Only handle 64-bit LE
    if data[4] != 2 or data[5] != 1:
        return []

    SHT_PROGBITS = 1
    SHT_STRTAB = 3
    SHT_NOTE = 7

    e_shoff = struct.unpack_from('<Q', data, 40)[0]
    e_shentsize = struct.unpack_from('<H', data, 58)[0]
    e_shnum = struct.unpack_from('<H', data, 60)[0]
    e_shstrndx = struct.unpack_from('<H', data, 62)[0]

    if e_shoff == 0 or e_shnum == 0:
        return []

    # Read section header string table to get section names
    shstrtab_off = 0
    if e_shstrndx < e_shnum:
        idx_off = e_shoff + e_shstrndx * e_shentsize
        shstrtab_off = struct.unpack_from('<Q', data, idx_off + 24)[0]

    # Executable section names to skip
    _EXEC_NAMES = {b'.text', b'.init', b'.fini', b'.plt', b'.plt.got',
                   b'.plt.sec'}

    ranges = []
    for i in range(e_shnum):
        sh_off = e_shoff + i * e_shentsize
        sh_type = struct.unpack_from('<I', data, sh_off + 4)[0]
        sh_flags = struct.unpack_from('<Q', data, sh_off + 8)[0]
        sh_offset = struct.unpack_from('<Q', data, sh_off + 24)[0]
        sh_size = struct.unpack_from('<Q', data, sh_off + 32)[0]
        sh_name_idx = struct.unpack_from('<I', data, sh_off)[0]

        if sh_size == 0:
            continue

        # Get section name
        sec_name = b''
        if shstrtab_off and sh_name_idx:
            end = data.find(0, shstrtab_off + sh_name_idx)
            if end > 0:
                sec_name = data[shstrtab_off + sh_name_idx:end]

        # Skip executable sections
        SHF_EXECINSTR = 0x4
        if sh_flags & SHF_EXECINSTR:
            continue
        if sec_name in _EXEC_NAMES:
            continue

        # Include string tables, rodata, comment, debug, note sections
        if sh_type == SHT_STRTAB:
            ranges.append((sh_offset, sh_offset + sh_size))
        elif sh_type == SHT_NOTE:
            ranges.append((sh_offset, sh_offset + sh_size))
        elif sh_type == SHT_PROGBITS and sec_name in (
            b'.rodata', b'.rodata.str1.1', b'.rodata.str1.8',
            b'.comment', b'.GCC.command.line',
        ):
            ranges.append((sh_offset, sh_offset + sh_size))
        elif sec_name.startswith(b'.debug'):
            ranges.append((sh_offset, sh_offset + sh_size))

    return ranges


def _scrub_home_paths(directory):
    """Replace /home/... paths in ELF data sections with zeroes.

    Build-machine home directories should not appear in shipped
    artifacts.  Only scrubs data sections (rodata, strtab, debug
    info) — never touches executable code sections.
    """
    pattern = re.compile(rb'/home/[^\x00]+')
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
                    data = bytearray(f.read())
                if b'/home/' not in data:
                    continue

                ranges = _elf_data_ranges(bytes(data))
                if not ranges:
                    continue

                modified = False
                for m in pattern.finditer(bytes(data)):
                    start, end = m.start(), m.end()
                    # Only scrub if the match falls entirely within a data section
                    in_data = any(rs <= start and end <= re
                                  for rs, re in ranges)
                    if in_data:
                        for j in range(start, end):
                            data[j] = 0
                        modified = True

                if modified:
                    orig_mode = os.stat(path).st_mode
                    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
                    with open(path, 'wb') as f:
                        f.write(data)
                    os.chmod(path, orig_mode)
                    scrubbed += 1
            except (PermissionError, OSError, struct.error):
                pass

    if scrubbed:
        print(f"  scrubbed home paths from {scrubbed} ELF files", file=sys.stderr)



def _pad_unpadded_interpreters(host_tools_dir):
    """Pad standard ELF interpreters so the unpack step can rewrite them.

    Some packages (e.g. lzip) use non-standard configure scripts that
    don't pass through GCC specs, producing binaries with the standard
    27-byte /lib64/ld-linux-x86-64.so.2 interpreter.  The unpack step
    can only rewrite padded interpreters (it needs space to overwrite
    in-place).  Pad any unpadded interpreters to the standard 256-byte
    format so they get properly rewritten at unpack time.
    """
    STANDARD_INTERP = "/lib64/ld-linux-x86-64.so.2"
    PADDED_INTERP = "/" * 228 + "lib64/ld-linux-x86-64.so.2"  # 256 bytes total
    padded = 0

    for dirpath, _, filenames in os.walk(host_tools_dir):
        for name in filenames:
            fpath = os.path.join(dirpath, name)
            if os.path.islink(fpath) or not os.path.isfile(fpath):
                continue
            try:
                with open(fpath, "rb") as f:
                    magic = f.read(4)
                if magic != b"\x7fELF":
                    continue
                with open(fpath, "rb") as f:
                    data = bytearray(f.read())

                # Only handle 64-bit little-endian (x86_64)
                if data[4] != 2 or data[5] != 1:
                    continue

                e_phoff = struct.unpack_from("<Q", data, 32)[0]
                e_phentsize = struct.unpack_from("<H", data, 54)[0]
                e_phnum = struct.unpack_from("<H", data, 56)[0]

                for i in range(e_phnum):
                    off = e_phoff + i * e_phentsize
                    p_type = struct.unpack_from("<I", data, off)[0]
                    if p_type != 3:  # PT_INTERP
                        continue

                    p_offset = struct.unpack_from("<Q", data, off + 8)[0]
                    p_filesz = struct.unpack_from("<Q", data, off + 32)[0]
                    seg_end = p_offset + p_filesz
                    try:
                        end = data.index(0, p_offset, seg_end)
                    except ValueError:
                        end = seg_end
                    old_interp = data[p_offset:end].decode("ascii", errors="replace")

                    if old_interp == STANDARD_INTERP:
                        # Pad by appending to end of file
                        new_bytes = PADDED_INTERP.encode("ascii") + b"\x00"
                        new_offset = len(data)
                        data.extend(new_bytes)
                        struct.pack_into("<Q", data, off + 8, new_offset)
                        struct.pack_into("<Q", data, off + 32, len(new_bytes))
                        struct.pack_into("<Q", data, off + 40, len(new_bytes))

                        orig_mode = os.stat(fpath).st_mode
                        os.chmod(fpath, stat.S_IRUSR | stat.S_IWUSR)
                        with open(fpath, "wb") as f:
                            f.write(data)
                        os.chmod(fpath, orig_mode)
                        padded += 1
                    break
            except (PermissionError, OSError, struct.error):
                pass

    if padded:
        print(f"  padded {padded} host-tools binaries with standard interpreter",
              file=sys.stderr)


def _create_rpath_symlinks(host_tools_dir):
    """Create lib64/lib symlinks so $ORIGIN/../lib64 resolves from any depth.

    GCC specs inject RPATH=$ORIGIN/../lib64:$ORIGIN/../lib.  For a binary
    at host-tools/bin/foo this resolves to host-tools/lib64/ — correct.
    For host-tools/libexec/gcc/triple/ver/cc1 it resolves to
    host-tools/libexec/gcc/triple/lib64/ — wrong.

    Walk all directories containing ELF files and create lib64/lib
    symlinks in their parent directories pointing back to the prefix root.
    """
    root = os.path.abspath(host_tools_dir)
    # Directories that already have real lib64/lib
    skip = {root}
    created = 0

    # Find all directories containing ELF executables/shared libs
    elf_dirs = set()
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            fpath = os.path.join(dirpath, name)
            if os.path.islink(fpath) or not os.path.isfile(fpath):
                continue
            try:
                with open(fpath, "rb") as f:
                    if f.read(4) == b"\x7fELF":
                        elf_dirs.add(dirpath)
            except (PermissionError, OSError):
                pass

    for elf_dir in elf_dirs:
        # $ORIGIN/../lib64 means the parent of the binary's directory
        parent = os.path.dirname(elf_dir)
        if parent in skip or parent == elf_dir:
            continue
        for libdir in ("lib64", "lib"):
            target = os.path.join(root, libdir)
            link = os.path.join(parent, libdir)
            if os.path.isdir(target) and not os.path.exists(link):
                rel = os.path.relpath(target, parent)
                os.symlink(rel, link)
                created += 1

    if created:
        print(f"  created {created} RPATH symlinks for nested binaries",
              file=sys.stderr)


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
        has_host_tools = False
        host_tools_dst = None
        if args.host_tools_dir:
            host_tools_src = os.path.abspath(args.host_tools_dir)
            if not os.path.isdir(host_tools_src):
                print(f"error: host-tools directory not found: {host_tools_src}", file=sys.stderr)
                sys.exit(1)
            host_tools_dst = os.path.join(tmpdir, "host-tools")
            shutil.copytree(host_tools_src, host_tools_dst, symlinks=True)
            has_host_tools = True

        # Scrub absolute buck-out paths from ELF binaries in the cross-compiler
        # tree only.  Host-tools binaries must NOT be scrubbed because tools
        # like flex and bison store paths to helper programs (m4) at compile
        # time — scrubbing truncates those to "/build" which breaks exec().
        print("Scrubbing build paths...", file=sys.stderr)
        _scrub_build_paths(stage_copy)

        # Scrub /home/... paths from data sections so build-machine
        # paths don't appear in shipped artifacts.  Section-aware:
        # only touches rodata, strtab, debug — never executable code.
        print("Scrubbing home paths...", file=sys.stderr)
        _scrub_home_paths(stage_copy)
        if has_host_tools:
            _scrub_home_paths(host_tools_dst)

        # Most host-tools binaries are built by our GCC with specs, so
        # they have padded interp + $ORIGIN RPATH at link time.  Some
        # packages (lzip, etc.) use non-standard build systems that
        # don't pass through GCC specs, leaving the standard 27-byte
        # interpreter.  Pad those so the unpack step can rewrite them.
        if has_host_tools:
            _pad_unpadded_interpreters(host_tools_dst)

        # specs inject $ORIGIN/../lib64 which only resolves for
        # binaries directly in bin/.  Deeply-nested binaries (e.g.
        # libexec/gcc/.../cc1) need more ../ levels.  Create lib64
        # symlinks in intermediate directories so $ORIGIN/../lib64
        # resolves from any depth.
        if has_host_tools:
            _create_rpath_symlinks(host_tools_dst)

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

        # Build tar command with multiple -C flags to collect all
        # archive components without symlinks or --dereference.
        tar_items = ["-C", stage_copy, "."]
        tar_items.extend(["-C", tmpdir, "metadata.json"])
        if has_host_tools:
            tar_items.extend(["-C", tmpdir, "host-tools"])

        if args.compression == "zst":
            tar_p = subprocess.Popen(
                ["tar", "-cf", "-"] + tar_items,
                stdout=subprocess.PIPE, env=clean_env(),
            )
            zstd_p = subprocess.Popen(
                ["zstd", "-T0", "-19", "-o", output],
                stdin=tar_p.stdout, env=clean_env(),
            )
            tar_p.stdout.close()
            zstd_p.wait()
            rc = tar_p.wait() or zstd_p.returncode
            result = type("R", (), {"returncode": rc})()
        elif args.compression == "xz":
            result = subprocess.run(
                ["tar", "-cJf", output] + tar_items,
                env=clean_env())
        else:
            result = subprocess.run(
                ["tar", "-czf", output] + tar_items,
                env=clean_env())

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
