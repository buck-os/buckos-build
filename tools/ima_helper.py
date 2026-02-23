#!/usr/bin/env python3
"""IMA signing via evmctl.

Copies input directory to output and signs all regular files using
evmctl ima_sign --sigfile, which creates detached .sig sidecar files.

Symlinks and .sig sidecars are skipped.  evmctl --sigfile returns
non-zero because the xattr attempt fails without CAP_SYS_ADMIN,
but the .sig sidecar is still created.
"""

import argparse
import os
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description="IMA sign files with evmctl")
    parser.add_argument("--input", required=True, help="Input directory")
    parser.add_argument("--output", required=True, help="Output directory")
    parser.add_argument("--key", required=True, help="Path to signing key (PEM)")
    parser.add_argument("--hermetic-path", action="append", dest="hermetic_path", default=[],
                        help="Set PATH to only these dirs (replaces host PATH, repeatable)")
    args = parser.parse_args()

    if not os.path.isdir(args.input):
        print(f"error: input directory not found: {args.input}", file=sys.stderr)
        sys.exit(1)

    if not os.path.isfile(args.key):
        print(f"error: signing key not found: {args.key}", file=sys.stderr)
        sys.exit(1)

    # Clear host build env vars that could poison the build.
    # Deps inject these explicitly via --env args.
    for var in ["LD_LIBRARY_PATH", "PKG_CONFIG_PATH", "PYTHONPATH",
                "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "LIBRARY_PATH",
                "ACLOCAL_PATH"]:
        os.environ.pop(var, None)

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

    evmctl = shutil.which("evmctl")
    if evmctl is None:
        print("error: evmctl not found in PATH", file=sys.stderr)
        sys.exit(1)

    # Copy input to output
    if os.path.exists(args.output):
        shutil.rmtree(args.output)
    shutil.copytree(args.input, args.output, symlinks=True)

    # Sign all regular files (skip symlinks and .sig sidecars)
    signed = 0
    errors = 0
    for dirpath, _dirnames, filenames in os.walk(args.output):
        for filename in filenames:
            filepath = os.path.join(dirpath, filename)
            if os.path.islink(filepath):
                continue
            if not os.path.isfile(filepath):
                continue
            if filepath.endswith(".sig"):
                continue

            # evmctl --sigfile creates .sig sidecar; the xattr attempt fails
            # without CAP_SYS_ADMIN so the exit code is non-zero, but the
            # .sig file is still created successfully
            subprocess.run(
                [evmctl, "ima_sign", "--sigfile", "--key", args.key, filepath],
                capture_output=True,
            )
            sig_file = filepath + ".sig"
            if os.path.isfile(sig_file):
                signed += 1
            else:
                rel = os.path.relpath(filepath, args.output)
                print(f"error: no .sig sidecar for {rel}", file=sys.stderr)
                errors += 1

    if errors > 0:
        print(f"error: {errors} files failed to sign", file=sys.stderr)
        sys.exit(1)

    print(f"signed {signed} files")


if __name__ == "__main__":
    main()
