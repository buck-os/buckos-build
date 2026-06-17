#!/usr/bin/env python3
"""Assemble a systemd-stub Unified Kernel Image (UKI).

Adds the .osrel/.uname/.cmdline/.linux/.initrd sections to the systemd-boot
stub (linuxx64.efi.stub) at non-overlapping VMAs computed after the stub's
existing sections, producing a single PE/COFF EFI binary. Signing the result
(osslsigncode) covers the kernel + initramfs + cmdline with one Secure Boot
signature, so the firmware verifies the whole boot artifact via LoadImage.

VMAs are computed (not hardcoded) so a >16 MiB kernel can never collide with
the initrd section — the failure mode of the classic fixed-offset recipe.

Runs both standalone (host objcopy/objdump; e.g. tools/secureboot_validate.sh)
and inside the buck `uki` rule, which passes the toolchain binutils plus the
hermetic-env flags below so they find their shared libraries.
"""
import argparse
import os
import subprocess


def _apply_toolchain_env(args):
    """Set PATH/LD_LIBRARY_PATH so the buckos toolchain binutils find their
    libs. Mirrors tools/strip_helper.py and is only reached when the buck rule
    passes the toolchain flags; the standalone harness uses host tools and the
    `_env` import below never runs there."""
    from _env import sanitize_global_env, sysroot_lib_paths

    sanitize_global_env()
    if args.hermetic_path:
        os.environ["PATH"] = ":".join(os.path.abspath(p) for p in args.hermetic_path)
        lib_dirs = []
        for bp in args.hermetic_path:
            parent = os.path.dirname(os.path.abspath(bp))
            for ld in ("lib", "lib64"):
                d = os.path.join(parent, ld)
                if os.path.isdir(d) and not os.path.exists(
                    os.path.join(d, "libc.so.6")
                ):
                    lib_dirs.append(d)
        if lib_dirs:
            existing = os.environ.get("LD_LIBRARY_PATH", "")
            os.environ["LD_LIBRARY_PATH"] = ":".join(lib_dirs) + (
                ":" + existing if existing else ""
            )
    elif args.hermetic_empty:
        os.environ["PATH"] = ""
    # --allow-host-path keeps the inherited PATH as-is.
    if args.ld_linux:
        sysroot_lib_paths(args.ld_linux, os.environ)


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
    ap.add_argument(
        "--cmdline", help="file holding the kernel cmdline (.cmdline), used as-is"
    )
    ap.add_argument(
        "--cmdline-str", help="kernel cmdline string, NUL-terminated into .cmdline"
    )
    ap.add_argument("--linux", required=True, help="kernel image (.linux)")
    ap.add_argument("--initrd", help="initramfs (.initrd)")
    ap.add_argument("--align", default="0x10000", help="section VMA alignment")
    # Hermetic-env flags (passed by the buck `uki` rule; unused standalone).
    ap.add_argument("--ld-linux")
    ap.add_argument("--hermetic-path", action="append", default=[])
    ap.add_argument("--allow-host-path", action="store_true")
    ap.add_argument("--hermetic-empty", action="store_true")
    args = ap.parse_args()

    if (
        args.ld_linux
        or args.hermetic_path
        or args.allow_host_path
        or args.hermetic_empty
    ):
        _apply_toolchain_env(args)

    align = int(args.align, 16)

    def align_up(x):
        return (x + align - 1) & ~(align - 1)

    vma = align_up(stub_max_vma_end(args.stub, args.objdump))

    # A cmdline passed as a string is written NUL-terminated (what the stub and
    # systemd's ukify expect); a cmdline file is used verbatim.
    cmdline_file = args.cmdline
    if args.cmdline_str is not None:
        cmdline_file = args.output + ".cmdline"
        with open(cmdline_file, "wb") as f:
            f.write(args.cmdline_str.encode("utf-8").rstrip(b"\x00") + b"\x00")

    # The stub locates sections by name; file order only affects layout.
    candidates = [
        (".osrel", args.osrel),
        (".uname", args.uname),
        (".cmdline", cmdline_file),
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
