#!/usr/bin/env python3
"""Assemble a systemd-stub Unified Kernel Image (UKI).

Adds the .osrel/.uname/.cmdline/.linux/.initrd sections to the systemd-boot
stub (linuxx64.efi.stub) at non-overlapping VMAs computed after the stub's
existing sections, producing a single PE/COFF EFI binary. Signing the result
(osslsigncode) covers the kernel + initramfs + cmdline with one Secure Boot
signature, so the firmware verifies the whole boot artifact via LoadImage.

VMAs are computed (not hardcoded) so a >16 MiB kernel can never collide with
the initrd section — the failure mode of the classic fixed-offset recipe.
"""
import argparse
import os
import subprocess


def stub_max_vma_end(stub, objdump):
    """Highest VMA+size across the stub's existing PE sections."""
    end = 0
    out = subprocess.check_output([objdump, "-h", stub]).decode()
    for line in out.splitlines():
        p = line.split()
        # objdump -h rows: "Idx Name Size VMA LMA FileOff Algn"
        if len(p) >= 4 and p[0].isdigit():
            try:
                end = max(end, int(p[3], 16) + int(p[2], 16))
            except ValueError:
                pass
    return end


def main():
    ap = argparse.ArgumentParser(description="Assemble a systemd-stub UKI")
    ap.add_argument("--stub", required=True, help="linuxx64.efi.stub")
    ap.add_argument("--output", required=True)
    ap.add_argument("--objcopy", default="objcopy")
    ap.add_argument("--objdump", default="objdump")
    ap.add_argument("--osrel", help="os-release file (.osrel section)")
    ap.add_argument("--uname", help="kernel uname string file (.uname)")
    ap.add_argument("--cmdline", help="file holding the kernel cmdline (.cmdline)")
    ap.add_argument("--linux", required=True, help="kernel image (.linux)")
    ap.add_argument("--initrd", help="initramfs (.initrd)")
    ap.add_argument("--align", default="0x10000", help="section VMA alignment")
    args = ap.parse_args()

    align = int(args.align, 16)

    def align_up(x):
        return (x + align - 1) & ~(align - 1)

    vma = align_up(stub_max_vma_end(args.stub, args.objdump))

    # The stub locates sections by name; file order only affects layout.
    candidates = [
        (".osrel", args.osrel),
        (".uname", args.uname),
        (".cmdline", args.cmdline),
        (".linux", args.linux),
        (".initrd", args.initrd),
    ]

    cmd = [args.objcopy]
    for name, path in candidates:
        if not path:
            continue
        cmd += [
            "--add-section",
            "{}={}".format(name, path),
            "--change-section-vma",
            "{}={}".format(name, hex(vma)),
        ]
        vma = align_up(vma + os.path.getsize(path))
    cmd += [args.stub, args.output]
    subprocess.check_call(cmd)


if __name__ == "__main__":
    main()
