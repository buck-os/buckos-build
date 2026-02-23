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
import subprocess
import sys
import tempfile
from datetime import datetime, timezone


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

        # Scrub absolute buck-out paths from ELF binaries in both trees
        print("Scrubbing build paths...", file=sys.stderr)
        _scrub_build_paths(stage_copy)
        if has_host_tools:
            _scrub_build_paths(os.path.join(tmpdir, "host-tools"))

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

        result = subprocess.run(tar_cmd, shell=True)

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
