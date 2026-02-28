#!/usr/bin/env python3
"""Strip ELF binaries and shared libraries.

Copies input directory to output, finds ELF files, and runs strip on them.
"""

import argparse
import os
import shutil
import subprocess
import sys

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

    parser = argparse.ArgumentParser(description="Strip ELF binaries")
    parser.add_argument("--input", required=True, help="Input directory")
    parser.add_argument("--output", required=True, help="Output directory")
    parser.add_argument("--strip", required=True, dest="strip_bin",
                        help="Path to strip binary")
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

    # Find and strip ELF files
    stripped = 0
    errors = 0
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
                [args.strip_bin, filepath],
                capture_output=True,
                text=True,
            )
            if result.returncode != 0:
                # Some ELF files (e.g. static archives with debug info)
                # may fail to strip; warn but continue
                rel = os.path.relpath(filepath, args.output)
                print(f"warning: strip failed for {rel}: {result.stderr.strip()}", file=sys.stderr)
                errors += 1
            else:
                stripped += 1

    print(f"stripped {stripped} ELF files ({errors} warnings)")


if __name__ == "__main__":
    main()
