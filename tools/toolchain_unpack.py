#!/usr/bin/env python3
"""Unpack a prebuilt toolchain archive and optionally verify its integrity.

Extracts the archive, reads metadata.json, and optionally verifies the
contents SHA256 matches what was recorded at pack time.
"""

import argparse
import hashlib
import json
import os
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
    return "auto"


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
            if comp == "zst":
                cmd = f"zstd -dc {archive} | tar -C {tmpdir} -xf - ./metadata.json"
            elif comp == "xz":
                cmd = f"tar -C {tmpdir} -xJf {archive} ./metadata.json"
            else:
                cmd = f"tar -C {tmpdir} -xzf {archive} ./metadata.json"

            result = subprocess.run(cmd, shell=True, capture_output=True, env=clean_env())
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
    if comp == "zst":
        cmd = f"zstd -dc {archive} | tar -C {output} -xf -"
    elif comp == "xz":
        cmd = f"tar -C {output} -xJf {archive}"
    else:
        cmd = f"tar -C {output} -xzf {archive}"

    result = subprocess.run(cmd, shell=True, env=clean_env())
    if result.returncode != 0:
        print(f"error: extraction failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(1)

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
