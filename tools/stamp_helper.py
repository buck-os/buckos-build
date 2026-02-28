#!/usr/bin/env python3
"""Inject build provenance metadata into a package.

Copies input directory to output and writes:
- .buckos-provenance.jsonl  (own NDJSON record + aggregated deps)
- .buckos-subgraph-hash     (graph hash for downstream consumption)
- .note.package ELF section (own record stamped into every ELF binary)
"""

import argparse
import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

from _env import sanitize_global_env


_ELF_MAGIC = b"\x7fELF"


def is_elf(path):
    """Check if a file is an ELF binary by reading its magic bytes."""
    try:
        with open(path, "rb") as f:
            return f.read(4) == _ELF_MAGIC
    except (OSError, IOError):
        return False


def main():
    _host_path = os.environ.get("PATH", "")

    parser = argparse.ArgumentParser(description="Stamp build provenance")
    parser.add_argument("--input", required=True, help="Input directory")
    parser.add_argument("--output", required=True, help="Output directory")
    parser.add_argument("--name", required=True, help="Package name")
    parser.add_argument("--version", required=True, help="Package version")
    parser.add_argument("--build-id", required=True, help="Build identifier")
    parser.add_argument("--type", default="", help="Package type")
    parser.add_argument("--target", default="", help="Build target")
    parser.add_argument("--source-url", default="", help="Source URL")
    parser.add_argument("--source-sha256", default="", help="Source SHA256")
    parser.add_argument("--graph-hash", default="", help="Subgraph hash")
    parser.add_argument("--use-flag", action="append", default=[],
                        help="USE flag (repeatable)")
    parser.add_argument("--slsa", action="store_true",
                        help="Include SLSA volatile fields (buildTime, buildHost)")
    parser.add_argument("--dep-dir", action="append", default=[],
                        help="Dependency dir with .buckos-provenance.jsonl (repeatable)")
    parser.add_argument("--objcopy", default="objcopy",
                        help="Path to objcopy binary")
    parser.add_argument("--hermetic-path", action="append", dest="hermetic_path", default=[],
                        help="Set PATH to only these dirs (replaces host PATH, repeatable)")
    parser.add_argument("--allow-host-path", action="store_true",
                        help="Allow host PATH (bootstrap escape hatch)")
    parser.add_argument("--hermetic-empty", action="store_true",
                        help="Start with empty PATH (populated by --path-prepend)")
    parser.add_argument("--path-prepend", action="append", dest="path_prepend", default=[],
                        help="Directory to prepend to PATH (repeatable, resolved to absolute)")
    args = parser.parse_args()

    sanitize_global_env()

    if not os.path.isdir(args.input):
        print(f"error: input directory not found: {args.input}", file=sys.stderr)
        sys.exit(1)

    if args.hermetic_path:
        os.environ["PATH"] = ":".join(os.path.abspath(p) for p in args.hermetic_path)
        # Derive LD_LIBRARY_PATH from hermetic bin dirs so dynamically
        # linked tools (e.g. cross-ar needing libzstd) find their libs.
        _lib_dirs = []
        for _bp in args.hermetic_path:
            _parent = os.path.dirname(os.path.abspath(_bp))
            for _ld in ("lib", "lib64"):
                _d = os.path.join(_parent, _ld)
                if os.path.isdir(_d):
                    _lib_dirs.append(_d)
        if _lib_dirs:
            _existing = os.environ.get("LD_LIBRARY_PATH", "")
            os.environ["LD_LIBRARY_PATH"] = ":".join(_lib_dirs) + (":" + _existing if _existing else "")
        _py_paths = []
        for _bp in args.hermetic_path:
            _parent = os.path.dirname(os.path.abspath(_bp))
            for _pattern in ("lib/python*/site-packages", "lib/python*/dist-packages",
                             "lib64/python*/site-packages", "lib64/python*/dist-packages"):
                for _sp in __import__("glob").glob(os.path.join(_parent, _pattern)):
                    if os.path.isdir(_sp):
                        _py_paths.append(_sp)
        if _py_paths:
            _existing = os.environ.get("PYTHONPATH", "")
            os.environ["PYTHONPATH"] = ":".join(_py_paths) + (":" + _existing if _existing else "")
    elif args.hermetic_empty:
        os.environ["PATH"] = ""
    elif args.allow_host_path:
        os.environ["PATH"] = _host_path
    else:
        print("error: build requires --hermetic-path, --hermetic-empty, or --allow-host-path",
              file=sys.stderr)
        sys.exit(1)
    if args.path_prepend:
        prepend = ":".join(os.path.abspath(p) for p in args.path_prepend)
        os.environ["PATH"] = prepend + (":" + os.environ["PATH"] if os.environ.get("PATH") else "")
        _dep_lib_dirs = []
        for _bp in args.path_prepend:
            _parent = os.path.dirname(os.path.abspath(_bp))
            for _ld in ("lib", "lib64"):
                _d = os.path.join(_parent, _ld)
                if os.path.isdir(_d):
                    _dep_lib_dirs.append(_d)
        if _dep_lib_dirs:
            _existing = os.environ.get("LD_LIBRARY_PATH", "")
            os.environ["LD_LIBRARY_PATH"] = ":".join(_dep_lib_dirs) + (":" + _existing if _existing else "")

    # Copy input to output
    if os.path.exists(args.output):
        shutil.rmtree(args.output)
    shutil.copytree(args.input, args.output, symlinks=True)

    # Build own provenance record
    rec = {
        "name": args.name,
        "version": args.version,
        "type": args.type,
        "target": args.target,
        "sourceUrl": args.source_url,
        "sourceSha256": args.source_sha256,
        "graphHash": args.graph_hash,
        "useFlags": sorted(args.use_flag),
    }

    if args.slsa:
        rec["buildTime"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        try:
            rec["buildHost"] = socket.getfqdn()
        except Exception:
            rec["buildHost"] = "unknown"

    # BOS_PROV = sha256 of canonical sorted JSON (without BOS_PROV itself)
    canonical = json.dumps(rec, sort_keys=True, separators=(",", ":"))
    rec["BOS_PROV"] = hashlib.sha256(canonical.encode()).hexdigest()

    own_line = json.dumps(rec, sort_keys=True, separators=(",", ":"))

    # Aggregate dependency JSONL with dedup by name|version
    seen = {f"{args.name}|{args.version}"}
    dep_lines = []
    for dep_dir in args.dep_dir:
        jsonl = os.path.join(dep_dir, ".buckos-provenance.jsonl")
        if not os.path.isfile(jsonl):
            continue
        with open(jsonl) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    dep_rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                key = f"{dep_rec.get('name', '')}|{dep_rec.get('version', '')}"
                if key not in seen:
                    seen.add(key)
                    dep_lines.append(line)

    # Write .buckos-provenance.jsonl
    jsonl_path = os.path.join(args.output, ".buckos-provenance.jsonl")
    with open(jsonl_path, "w") as f:
        f.write(own_line + "\n")
        for line in dep_lines:
            f.write(line + "\n")

    # Write .buckos-subgraph-hash
    hash_path = os.path.join(args.output, ".buckos-subgraph-hash")
    with open(hash_path, "w") as f:
        f.write(args.graph_hash + "\n")

    # Stamp ELF binaries with .note.package
    objcopy = shutil.which(args.objcopy)
    if objcopy is None:
        print("stamp: objcopy not found, skipping ELF stamping", file=sys.stderr)
    else:
        stamp_fd, stamp_path = tempfile.mkstemp(suffix=".json")
        try:
            with os.fdopen(stamp_fd, "w") as f:
                f.write(own_line + "\n")

            stamped = 0
            for dirpath, _dirnames, filenames in os.walk(args.output):
                for filename in filenames:
                    filepath = os.path.join(dirpath, filename)
                    if os.path.islink(filepath):
                        continue
                    if not os.path.isfile(filepath):
                        continue
                    if not is_elf(filepath):
                        continue
                    result = subprocess.run(
                        [objcopy,
                         "--add-section", f".note.package={stamp_path}",
                         "--set-section-flags", ".note.package=noload,readonly",
                         filepath],
                        capture_output=True, text=True,
                    )
                    if result.returncode == 0:
                        stamped += 1
                    else:
                        rel = os.path.relpath(filepath, args.output)
                        print(f"stamp: warning: objcopy failed for {rel}: "
                              f"{result.stderr.strip()}", file=sys.stderr)
        finally:
            os.unlink(stamp_path)

        print(f"stamped {stamped} ELF binaries")

    print(f"stamped: {args.name} {args.version} (build {args.build_id})")


if __name__ == "__main__":
    main()
