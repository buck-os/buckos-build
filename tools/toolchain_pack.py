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


# glibc runtime files that must be isolated from LD_LIBRARY_PATH.
# Including these in LD_LIBRARY_PATH causes host processes (bash, sh)
# to load buckos glibc via the host's ld-linux → GLIBC_PRIVATE mismatch.
_GLIBC_RUNTIME_FILES = frozenset({
    "ld-linux-x86-64.so.2",
    "libc.so.6",
    "libm.so.6",
    "libdl.so.2",
    "libpthread.so.0",
    "librt.so.1",
    "libresolv.so.2",
    "libnss_dns.so.2",
    "libnss_files.so.2",
    "libutil.so.1",
    "libmvec.so.1",
    "libthread_db.so.1",
})


def _isolate_glibc(directory):
    """Move glibc runtime files into a private subdirectory.

    Moves libc.so.6 and related glibc files from {directory}/lib64/ to
    {directory}/lib64/glibc/.  After this:

    - LD_LIBRARY_PATH includes lib64/ (safe — no libc.so.6)
    - RPATH-based binaries find glibc via $ORIGIN/../lib64/glibc/
    """
    lib64 = os.path.join(directory, "lib64")
    if not os.path.isdir(lib64):
        return

    glibc_dir = os.path.join(lib64, "glibc")
    moved = 0

    for name in os.listdir(lib64):
        if name not in _GLIBC_RUNTIME_FILES:
            continue
        src = os.path.join(lib64, name)
        if not os.path.isfile(src) and not os.path.islink(src):
            continue
        os.makedirs(glibc_dir, exist_ok=True)
        os.rename(src, os.path.join(glibc_dir, name))
        moved += 1

    if moved:
        print(f"  isolated {moved} glibc files into lib64/glibc/",
              file=sys.stderr)


def _rewrite_rpath(directory):
    """Rewrite RPATH/RUNPATH in ELF binaries to $ORIGIN-relative paths.

    Overwrites existing RPATH/RUNPATH strings in place (from the padded
    placeholder set at build time via GCC specs).  Only processes
    binaries that already have DT_RPATH or DT_RUNPATH entries.
    """
    DT_RPATH = 15
    DT_RUNPATH = 29
    SHT_DYNAMIC = 6
    rewritten = 0

    # Find lib dirs to target.  Includes lib64/glibc/ if present (from
    # _isolate_glibc) so RPATH-based binaries can find buckos libc.
    lib_suffixes = []
    for ld in ("lib", "lib64", os.path.join("lib64", "glibc")):
        if os.path.isdir(os.path.join(directory, ld)):
            lib_suffixes.append(ld)

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
                dyn_offset = dyn_size = dyn_entsize = 0
                dynstr_offset = 0
                for i in range(e_shnum):
                    sh_off = e_shoff + i * e_shentsize
                    sh_type = struct.unpack_from('<I', data, sh_off + 4)[0]
                    if sh_type == SHT_DYNAMIC:
                        dyn_offset = struct.unpack_from('<Q', data, sh_off + 24)[0]
                        dyn_size = struct.unpack_from('<Q', data, sh_off + 32)[0]
                        dyn_entsize = struct.unpack_from('<Q', data, sh_off + 56)[0]
                        sh_link = struct.unpack_from('<I', data, sh_off + 40)[0]
                        dstr_sh = e_shoff + sh_link * e_shentsize
                        dynstr_offset = struct.unpack_from('<Q', data, dstr_sh + 24)[0]
                        break

                if not dyn_offset or not dynstr_offset:
                    continue
                if not dyn_entsize:
                    dyn_entsize = 16  # sizeof(Elf64_Dyn)

                # Compute $ORIGIN-relative paths from this binary to lib dirs
                rel = os.path.relpath(directory, dirpath)
                rpath_parts = []
                for suffix in lib_suffixes:
                    rpath_parts.append("$ORIGIN/" + os.path.join(rel, suffix))
                new_rpath = ":".join(rpath_parts).encode("ascii") if rpath_parts else None
                if not new_rpath:
                    continue

                modified = False
                n_entries = dyn_size // dyn_entsize
                for i in range(n_entries):
                    ent_off = dyn_offset + i * dyn_entsize
                    d_tag = struct.unpack_from('<q', data, ent_off)[0]
                    if d_tag in (DT_RPATH, DT_RUNPATH):
                        d_val = struct.unpack_from('<Q', data, ent_off + 8)[0]
                        str_off = dynstr_offset + d_val
                        end = data.index(0, str_off)
                        avail = end - str_off
                        if avail <= 0:
                            continue
                        if len(new_rpath) <= avail:
                            data[str_off:str_off + len(new_rpath)] = new_rpath
                            for j in range(str_off + len(new_rpath), end):
                                data[j] = 0
                            modified = True
                        else:
                            for j in range(str_off, end):
                                data[j] = 0
                            modified = True

                if modified:
                    orig_mode = os.stat(path).st_mode
                    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
                    with open(path, 'wb') as f:
                        f.write(data)
                    os.chmod(path, orig_mode)
                    rewritten += 1

            except (PermissionError, OSError, ValueError, struct.error):
                pass

    if rewritten:
        print(f"  rewrote RPATH in {rewritten} ELF files", file=sys.stderr)


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

        # GCC specs inject the padded interpreter and RPATH placeholder
        # into ALL binaries at link time, regardless of whether the build
        # system passes LDFLAGS.  Every host-tools binary therefore has
        # a ///.../// interpreter and a padded RPATH placeholder.
        #
        # _isolate_glibc moves libc.so.6 et al. from lib64/ to
        # lib64/glibc/, so LD_LIBRARY_PATH (which includes lib64/) is
        # safe for host processes.  _rewrite_rpath overwrites the RPATH
        # placeholder with $ORIGIN-relative paths including lib64/glibc/.
        if has_host_tools:
            print("Isolating glibc from host-tools...", file=sys.stderr)
            _isolate_glibc(host_tools_dst)
            print("Rewriting RPATH in host-tools...", file=sys.stderr)
            _rewrite_rpath(host_tools_dst)

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
