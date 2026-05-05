#!/usr/bin/env python3
"""Strip ELF binaries and shared libraries.

Copies input directory to output, finds ELF files, and runs strip on them.
"""

import argparse
import os
import shutil
import subprocess
import sys

from _env import sanitize_global_env, sysroot_lib_paths


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
    parser.add_argument("--ld-linux", default=None,
                        help="Buckos ld-linux path (disables posix_spawn)")
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
                if os.path.isdir(_d) and not os.path.exists(os.path.join(_d, "libc.so.6")):
                    _lib_dirs.append(_d)
                    _glibc_d = os.path.join(_d, "glibc")
                    if os.path.isdir(_glibc_d):
                        _lib_dirs.append(_glibc_d)
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
                if os.path.isdir(_d) and not os.path.exists(os.path.join(_d, "libc.so.6")):
                    _dep_lib_dirs.append(_d)
                    _glibc_d = os.path.join(_d, "glibc")
                    if os.path.isdir(_glibc_d):
                        _dep_lib_dirs.append(_glibc_d)
        if _dep_lib_dirs:
            _existing = os.environ.get("LD_LIBRARY_PATH", "")
            os.environ["LD_LIBRARY_PATH"] = ":".join(_dep_lib_dirs) + (":" + _existing if _existing else "")

    if args.ld_linux:
        sysroot_lib_paths(args.ld_linux, os.environ)

    # Build output file-by-file from input.  ELF files are copied and
    # stripped; everything else is hardlinked (no copy needed since the
    # file won't be modified).  The input directory is never touched.
    if os.path.exists(args.output):
        shutil.rmtree(args.output)
    input_dir = os.path.abspath(args.input)
    output_dir = os.path.abspath(args.output)

    stripped = 0
    errors = 0
    for dirpath, dirnames, filenames in os.walk(input_dir):
        reldir = os.path.relpath(dirpath, input_dir)
        outdir = os.path.join(output_dir, reldir) if reldir != "." else output_dir
        os.makedirs(outdir, exist_ok=True)

        # Recreate directory symlinks; don't descend into them.
        real_dirs = []
        for dname in dirnames:
            src = os.path.join(dirpath, dname)
            if os.path.islink(src):
                os.symlink(os.readlink(src), os.path.join(outdir, dname))
            else:
                real_dirs.append(dname)
        dirnames[:] = real_dirs

        for filename in filenames:
            src = os.path.join(dirpath, filename)
            dst = os.path.join(outdir, filename)

            if os.path.islink(src):
                os.symlink(os.readlink(src), dst)
                continue
            if not os.path.isfile(src):
                continue

            if is_elf(src):
                shutil.copy2(src, dst)
                result = subprocess.run(
                    [args.strip_bin, dst],
                    capture_output=True,
                    text=True,
                )
                if result.returncode != 0:
                    rel = os.path.relpath(dst, output_dir)
                    print(f"warning: strip failed for {rel}: {result.stderr.strip()}", file=sys.stderr)
                    errors += 1
                else:
                    stripped += 1
            else:
                try:
                    os.link(src, dst)
                except OSError:
                    shutil.copy2(src, dst)

    print(f"stripped {stripped} ELF files ({errors} warnings)")


if __name__ == "__main__":
    main()
