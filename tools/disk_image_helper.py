#!/usr/bin/env python3
"""Create a raw disk image from a rootfs.

Replaces the inline bash in image.bzl _raw_disk_image_impl.  Uses
unprivileged populate-from-directory tools (mke2fs -d, mkfs.btrfs --rootdir,
mkfs.xfs -p) — no root, fakeroot, mount, or losetup required.
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

from _env import add_path_args, clean_env, setup_path


def _run(cmd, env, **kwargs):
    """Run a subprocess with clean env, exiting on failure."""
    result = subprocess.run(cmd, env=env, **kwargs)
    if result.returncode != 0:
        print(f"error: {cmd[0]} failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(1)


def _parse_size(size_str):
    """Parse a human-readable size string (e.g. '2G', '512M') to bytes."""
    m = re.fullmatch(r'(\d+)\s*([KMGTkmgt])?[iI]?[bB]?', size_str)
    if not m:
        print(f"error: cannot parse size: {size_str}", file=sys.stderr)
        sys.exit(1)
    n = int(m.group(1))
    suffix = (m.group(2) or '').upper()
    multipliers = {'': 1, 'K': 1024, 'M': 1024**2, 'G': 1024**3, 'T': 1024**4}
    return n * multipliers[suffix]


def _parse_sgdisk_output(text):
    """Parse partition table from sgdisk -p output.

    Returns a list of dicts with keys: number, start, end, size, code, name.
    Start/end/size are in sectors (512 bytes).
    """
    partitions = []
    in_table = False
    for line in text.splitlines():
        if re.match(r'\s*Number\s+Start\s+', line):
            in_table = True
            continue
        if not in_table:
            continue
        m = re.match(
            r'\s*(\d+)\s+(\d+)\s+(\d+)\s+\S+\s+\S+\s+(\w+)\s+(.*)',
            line,
        )
        if m:
            partitions.append({
                'number': int(m.group(1)),
                'start': int(m.group(2)),
                'end': int(m.group(3)),
                'code': m.group(4),
                'name': m.group(5).strip(),
            })
    return partitions


def _build_debugfs_ima_commands(rootfs, image_rel_prefix=""):
    """Generate debugfs commands for IMA xattr injection.

    Walks rootfs for .sig sidecars.  For each sidecar with a matching target:
      - ea_set <image_path> security.ima -f <host_sig_path>
      - rm <image_sig_path>

    Returns (commands_list, count) where commands_list is a list of debugfs
    command strings and count is the number of xattrs applied.
    """
    commands = []
    count = 0
    for dirpath, _, filenames in os.walk(rootfs):
        for fname in sorted(filenames):
            if not fname.endswith(".sig"):
                continue
            sig_path = os.path.join(dirpath, fname)
            target = sig_path[:-4]  # strip .sig
            if not os.path.isfile(target):
                continue
            # Path relative to rootfs, prefixed for image location
            rel = os.path.relpath(target, rootfs)
            image_path = image_rel_prefix + "/" + rel
            image_sig_path = image_path + ".sig"
            commands.append(f"ea_set {image_path} security.ima -f {sig_path}")
            commands.append(f"rm {image_sig_path}")
            count += 1
    return commands, count


def _apply_ima(image, rootfs, filesystem, env):
    """Apply IMA .sig sidecars as security.ima xattrs using debugfs.

    Only works for ext4 images.  For btrfs/xfs, .sig sidecars remain as files
    (no unprivileged equivalent to debugfs for those filesystems).
    """
    if filesystem != "ext4":
        return

    commands, count = _build_debugfs_ima_commands(rootfs)
    if not commands:
        return

    with tempfile.NamedTemporaryFile(mode='w', suffix='.cmds', delete=False) as f:
        f.write('\n'.join(commands) + '\n')
        cmds_file = f.name

    try:
        _run(["debugfs", "-w", "-f", cmds_file, image], env,
             capture_output=True)
    finally:
        os.unlink(cmds_file)

    print(f"Applied security.ima to {count} files")


def _populate_image(output, filesystem, label, rootfs, size_bytes, env):
    """Create and populate a filesystem image from a rootfs directory."""
    if filesystem == "ext4":
        # mke2fs -d populates from directory, no mount needed
        blocks = size_bytes // 4096
        _run(["mke2fs", "-t", "ext4", "-F", "-L", label,
              "-d", rootfs, output, str(blocks)], env)
    elif filesystem == "btrfs":
        _run(["truncate", "-s", str(size_bytes), output], env)
        _run(["mkfs.btrfs", "-f", "-L", label, "--rootdir", rootfs, output], env)
    elif filesystem == "xfs":
        _run(["truncate", "-s", str(size_bytes), output], env)
        _run(["mkfs.xfs", "-L", label, "-p", rootfs, output], env)
    else:
        print(f"Unsupported filesystem: {filesystem}", file=sys.stderr)
        sys.exit(1)


def main():
    _host_path = os.environ.get("PATH", "")

    parser = argparse.ArgumentParser(description="Create raw disk image")
    parser.add_argument("--rootfs", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--size", default="2G")
    parser.add_argument("--filesystem", default="ext4")
    parser.add_argument("--label", default=None)
    parser.add_argument("--partition-table", action="store_true")
    add_path_args(parser)
    args = parser.parse_args()

    env = clean_env()
    setup_path(args, env, _host_path)
    rootfs = os.path.abspath(args.rootfs)
    output = os.path.abspath(args.output)
    label = args.label or "buckos"
    size_bytes = _parse_size(args.size)

    print(f"Creating raw disk image...")
    print(f"  Size: {args.size}")
    print(f"  Filesystem: {args.filesystem}")
    print(f"  Label: {label}")

    if args.partition_table:
        # GPT partition table with EFI system partition
        _run(["truncate", "-s", str(size_bytes), output], env)
        _run(["sgdisk", "-Z", output], env)
        _run(["sgdisk", "-n", "1:2048:+100M", "-t", "1:EF00", "-c", "1:EFI", output], env)
        _run(["sgdisk", "-n", "2:0:0", "-t", "2:8300", "-c", "2:" + label, output], env)

        # Parse partition layout
        result = subprocess.run(
            ["sgdisk", "-p", output],
            env=env, capture_output=True, text=True,
        )
        if result.returncode != 0:
            print("error: sgdisk -p failed", file=sys.stderr)
            sys.exit(1)
        partitions = _parse_sgdisk_output(result.stdout)

        if len(partitions) < 2:
            print("error: expected at least 2 partitions", file=sys.stderr)
            sys.exit(1)

        efi_part = partitions[0]
        root_part = partitions[1]

        tmpdir = tempfile.mkdtemp()
        try:
            # Create EFI partition image
            efi_sectors = efi_part['end'] - efi_part['start'] + 1
            efi_size = efi_sectors * 512
            efi_img = os.path.join(tmpdir, "efi.img")
            _run(["truncate", "-s", str(efi_size), efi_img], env)
            _run(["mkfs.fat", "-F", "32", "-n", "EFI", efi_img], env)

            # Copy EFI content from rootfs if boot/efi exists
            efi_src = os.path.join(rootfs, "boot", "efi")
            if os.path.isdir(efi_src) and os.listdir(efi_src):
                # mcopy from rootfs boot/efi into the FAT image
                for entry in os.listdir(efi_src):
                    src = os.path.join(efi_src, entry)
                    _run(["mcopy", "-s", "-i", efi_img, src, "::/" + entry], env)

            # Create root partition image
            root_sectors = root_part['end'] - root_part['start'] + 1
            root_size = root_sectors * 512
            root_img = os.path.join(tmpdir, "root.img")
            _populate_image(root_img, args.filesystem, label, rootfs, root_size, env)

            # Apply IMA xattrs to root partition image
            _apply_ima(root_img, rootfs, args.filesystem, env)

            # Write partition images into the GPT disk image
            _run(["dd", f"if={efi_img}", f"of={output}",
                  "bs=512", f"seek={efi_part['start']}",
                  "conv=notrunc"], env, capture_output=True)
            _run(["dd", f"if={root_img}", f"of={output}",
                  "bs=512", f"seek={root_part['start']}",
                  "conv=notrunc"], env, capture_output=True)
        finally:
            # Clean up temp files
            for f in os.listdir(tmpdir):
                os.unlink(os.path.join(tmpdir, f))
            os.rmdir(tmpdir)
    else:
        # Simple raw image without partition table
        _populate_image(output, args.filesystem, label, rootfs, size_bytes, env)
        _apply_ima(output, rootfs, args.filesystem, env)

    print(f"Disk image created: {output}")


if __name__ == "__main__":
    main()
