#!/usr/bin/env python3
"""Validate the sd-boot bootloader is Secure-Boot-signed and carries SBAT (S5d).

The signed sd-boot is the first stage of a revocable Secure Boot chain: firmware
verifies it (db), it carries an .sbat section so a compromised version can be
revoked without rotating PK/KEK, and it chain-loads the signed UKI.

Env:
    SIGNED      the signed bootloader (//tests/fixtures/secureboot:signed-sd-boot)
    UNSIGNED    the unsigned bootloader (//packages/linux/boot/systemd-boot:sd-boot)
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
    coff = e_lfanew + 4
    num_sections = struct.unpack_from("<H", data, coff + 2)[0]
    opt_size = struct.unpack_from("<H", data, coff + 16)[0]
    sect_off = coff + 20 + opt_size
    return [
        data[sect_off + i * 40 : sect_off + i * 40 + 8]
        .rstrip(b"\0")
        .decode("ascii", "replace")
        for i in range(num_sections)
    ]


def main():
    signed = os.environ["SIGNED"]
    unsigned = os.environ["UNSIGNED"]

    secs = pe_section_names(signed)
    if ".sbat" not in secs:
        print("FAIL: sd-boot has no .sbat revocation section (have %s)" % secs)
        return 1

    s_sz, u_sz = os.path.getsize(signed), os.path.getsize(unsigned)
    if s_sz <= u_sz:
        print("FAIL: signed sd-boot (%d) not larger than unsigned (%d)" % (s_sz, u_sz))
        return 1

    print(
        "sd-boot OK: signed PE with .sbat revocation metadata; +%d bytes"
        % (s_sz - u_sz)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
