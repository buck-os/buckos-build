#!/usr/bin/env python3
"""Validate a Unified Kernel Image and its Secure Boot signature (SPEC-007 S5c).

Parses the PE section table directly (no objdump) to assert the UKI carries the
kernel + initramfs + cmdline + os-release as sections, then checks the signed
UKI is a larger PE (an Authenticode certificate table was appended). Building
the fixtures already runs the assembly + osslsigncode self-verify; this asserts
the structure end to end.

Env:
    UKI         the unsigned UKI (//tests/fixtures/secureboot:demo-uki)
    SIGNED_UKI  the signed UKI (//tests/fixtures/secureboot:demo-uki-signed)
"""

import os
import struct
import sys


def pe_section_names(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:2] != b"MZ":
        raise ValueError("not a PE (no MZ magic)")
    e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
    if data[e_lfanew : e_lfanew + 4] != b"PE\0\0":
        raise ValueError("no PE signature")
    coff = e_lfanew + 4
    num_sections = struct.unpack_from("<H", data, coff + 2)[0]
    opt_size = struct.unpack_from("<H", data, coff + 16)[0]
    sect_off = coff + 20 + opt_size
    names = []
    for i in range(num_sections):
        off = sect_off + i * 40
        names.append(data[off : off + 8].rstrip(b"\0").decode("ascii", "replace"))
    return names


def main():
    uki = os.environ["UKI"]
    signed = os.environ["SIGNED_UKI"]

    secs = pe_section_names(uki)
    required = [".osrel", ".cmdline", ".linux", ".initrd"]
    missing = [s for s in required if s not in secs]
    if missing:
        print("FAIL: UKI missing sections %s (have %s)" % (missing, secs))
        return 1

    with open(signed, "rb") as f:
        if f.read(2) != b"MZ":
            print("FAIL: signed UKI is not a PE")
            return 1
    u_sz, s_sz = os.path.getsize(uki), os.path.getsize(signed)
    if s_sz <= u_sz:
        print("FAIL: signed UKI (%d) not larger than unsigned (%d)" % (s_sz, u_sz))
        return 1

    print(
        "UKI OK: sections=%s; signed +%d bytes (Authenticode table)"
        % (secs, s_sz - u_sz)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
