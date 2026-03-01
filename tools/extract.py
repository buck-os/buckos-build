#!/usr/bin/env python3
"""Universal archive extractor.

Supports: .tar.gz, .tgz, .tar.xz, .txz, .tar.bz2, .tbz2, .tar.zst,
          .tar.lz, .tar.lz4, .tar, .zip, .whl

Auto-detects format from filename. --format overrides detection.
Uses Python tarfile/zipfile for natively supported formats; pipes through
external decompressors (zstd, lzip, lz4) for others.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tarfile
import zipfile

from _env import add_path_args, sanitize_global_env, setup_path


# Map of format string -> (tarfile mode or None, external decompressor or None)
_FORMATS = {
    "tar.gz":  ("r:gz",  None),
    "tgz":     ("r:gz",  None),
    "tar.xz":  ("r:xz",  None),
    "txz":     ("r:xz",  None),
    "tar.bz2": ("r:bz2", None),
    "tbz2":    ("r:bz2", None),
    "tar.zst": (None,     "zstd"),
    "tar.lz":  (None,     "lzip"),
    "tar.lz4": (None,     "lz4"),
    "tar":     ("r:",     None),
    "zip":     (None,     None),    # handled separately
    "whl":     (None,     None),    # Python wheels are zip files
}


def detect_format(path):
    """Detect archive format from filename."""
    name = os.path.basename(path).lower()
    # Check multi-part extensions first (longest match)
    for fmt in ("tar.gz", "tar.xz", "tar.bz2", "tar.zst", "tar.lz4", "tar.lz"):
        if name.endswith("." + fmt):
            return fmt
    for fmt in ("tgz", "txz", "tbz2", "tar", "zip", "whl"):
        if name.endswith("." + fmt):
            return fmt
    return None


def _matches_exclude(name, patterns):
    """Check if name matches any exclude glob pattern."""
    import fnmatch
    return any(fnmatch.fnmatch(name, p) for p in patterns)


def extract_tar_native(archive, output, strip_components, mode, exclude_patterns=None):
    """Extract using Python's tarfile module."""
    exclude_patterns = exclude_patterns or []
    with tarfile.open(archive, mode) as tf:
        for member in tf.getmembers():
            if strip_components > 0:
                parts = member.name.split("/", strip_components)
                if len(parts) <= strip_components:
                    continue
                member.name = parts[-1]
                if not member.name:
                    continue
                # Strip the same prefix from hardlink targets so tarfile
                # can resolve them after renaming.
                if member.islnk() and member.linkname:
                    link_parts = member.linkname.split("/", strip_components)
                    if len(link_parts) > strip_components:
                        member.linkname = link_parts[-1]
            member.name = os.path.normpath(member.name)
            # Skip excluded patterns
            if exclude_patterns and _matches_exclude(member.name, exclude_patterns):
                continue
            # Skip filenames with backslashes — Buck2 treats them as path
            # separators and rejects the output.  Affects systemd unit
            # templates like system-systemd\x2dcryptsetup.slice.
            if "\\" in member.name:
                continue
            # Skip problematic symlinks that Buck2 can't materialise:
            # - empty or "." targets (e.g. include/alsa -> .)
            # - self-referencing (e.g. itself -> itself)
            if member.issym():
                target = member.linkname
                if target in ("", "."):
                    continue
                # Self-referencing: target equals own filename
                if target == os.path.basename(member.name):
                    continue
            # Security: prevent path traversal
            dest = os.path.join(output, member.name)
            if not os.path.abspath(dest).startswith(os.path.abspath(output)):
                print(f"error: path traversal detected: {member.name}", file=sys.stderr)
                sys.exit(1)
            tf.extract(member, output, filter="tar")


def extract_tar_external(archive, output, strip_components, decompressor):
    """Extract tar archives that need an external decompressor."""
    decomp_bin = shutil.which(decompressor)
    if decomp_bin is None:
        print(f"error: decompressor '{decompressor}' not found in PATH", file=sys.stderr)
        sys.exit(1)

    decomp_cmd = [decomp_bin, "-dc", archive]
    tar_cmd = ["tar", "xf", "-", "-C", output]
    if strip_components > 0:
        tar_cmd.extend([f"--strip-components={strip_components}"])

    decomp_proc = subprocess.Popen(decomp_cmd, stdout=subprocess.PIPE)
    tar_proc = subprocess.Popen(tar_cmd, stdin=decomp_proc.stdout)
    decomp_proc.stdout.close()
    tar_proc.communicate()
    decomp_proc.wait()

    if decomp_proc.returncode != 0:
        print(f"error: {decompressor} exited with code {decomp_proc.returncode}", file=sys.stderr)
        sys.exit(1)
    if tar_proc.returncode != 0:
        print(f"error: tar exited with code {tar_proc.returncode}", file=sys.stderr)
        sys.exit(1)


def extract_zip(archive, output, strip_components):
    """Extract zip archives using Python's zipfile module."""
    with zipfile.ZipFile(archive, "r") as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            name = info.filename
            if strip_components > 0:
                parts = name.split("/", strip_components)
                if len(parts) <= strip_components:
                    continue
                name = parts[-1]
                if not name:
                    continue
            dest = os.path.join(output, name)
            if not os.path.abspath(dest).startswith(os.path.abspath(output)):
                print(f"error: path traversal detected: {name}", file=sys.stderr)
                sys.exit(1)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with zf.open(info) as src, open(dest, "wb") as dst:
                shutil.copyfileobj(src, dst)


def main():
    _host_path = os.environ.get("PATH", "")

    parser = argparse.ArgumentParser(description="Universal archive extractor")
    parser.add_argument("--archive", required=True, help="Path to the archive file")
    parser.add_argument("--output", required=True, help="Output directory")
    parser.add_argument("--strip-components", type=int, default=0,
                        help="Strip leading path components (default: 0)")
    parser.add_argument("--format", default=None, choices=list(_FORMATS.keys()),
                        help="Archive format (auto-detected from filename if omitted)")
    parser.add_argument("--exclude", action="append", default=[],
                        help="Glob pattern to exclude from extraction (repeatable)")
    add_path_args(parser)
    args = parser.parse_args()
    sanitize_global_env()

    # Restore PATH for external decompressors (zstd, lzip, lz4) and tar
    env = {}
    setup_path(args, env, _host_path)
    os.environ["PATH"] = env.get("PATH", "")

    if not os.path.isfile(args.archive):
        print(f"error: archive not found: {args.archive}", file=sys.stderr)
        sys.exit(1)

    fmt = args.format or detect_format(args.archive)
    if fmt is None:
        print(f"error: cannot detect format of {args.archive}; use --format", file=sys.stderr)
        sys.exit(1)

    os.makedirs(args.output, exist_ok=True)

    if fmt in ("zip", "whl"):
        extract_zip(args.archive, args.output, args.strip_components)
    else:
        tar_mode, decompressor = _FORMATS[fmt]
        if decompressor:
            extract_tar_external(args.archive, args.output, args.strip_components, decompressor)
        else:
            extract_tar_native(args.archive, args.output, args.strip_components, tar_mode,
                               exclude_patterns=args.exclude)


if __name__ == "__main__":
    main()
