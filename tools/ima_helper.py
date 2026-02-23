#!/usr/bin/env python3
"""IMA signing via evmctl.

Copies input directory to output and signs ELF files using
evmctl ima_sign --sigfile, which creates detached .sig sidecar files.

Only ELF binaries are signed; non-ELF regular files are skipped.
evmctl --sigfile returns non-zero because the xattr attempt fails
without CAP_SYS_ADMIN, but the .sig sidecar is still created.
"""

import argparse
import os
import shutil
import subprocess
import sys


_ELF_MAGIC = b"\x7fELF"


def is_elf(path):
    """Check if a file is an ELF binary by reading its magic bytes."""
    try:
        with open(path, "rb") as f:
            return f.read(4) == _ELF_MAGIC
    except (OSError, IOError):
        return False


def main():
    parser = argparse.ArgumentParser(description="IMA sign ELF files with evmctl")
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

    evmctl = shutil.which("evmctl")
    if evmctl is None:
        print("error: evmctl not found in PATH", file=sys.stderr)
        sys.exit(1)

    # Copy input to output
    if os.path.exists(args.output):
        shutil.rmtree(args.output)
    shutil.copytree(args.input, args.output, symlinks=True)

    # Sign ELF files only
    signed = 0
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

    print(f"signed {signed} ELF files")


if __name__ == "__main__":
    main()
