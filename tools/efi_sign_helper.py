#!/usr/bin/env python3
"""Sign an EFI PE binary (e.g. the kernel) for UEFI Secure Boot (SPEC-007 Tier 2).

Runs the buckos-built osslsigncode (an OpenSSL-based Authenticode/PE signer) via
the seed loader + its dep lib closure to attach a signature with the Secure Boot
`db` key, then self-verifies against the db certificate — the same Authenticode
check UEFI firmware performs against the enrolled db at boot. A failed sign or
verify fails the build.
"""

import argparse
import os
import subprocess
import sys


def _read_lines(path):
    with open(path) as fh:
        return [ln.strip() for ln in fh if ln.strip()]


def main():
    ap = argparse.ArgumentParser(description="Sign an EFI PE binary for Secure Boot")
    ap.add_argument("--ld-linux", required=True, help="seed dynamic loader")
    ap.add_argument("--osslsigncode", required=True, help="osslsigncode binary")
    ap.add_argument(
        "--lib-dirs-file", required=True, help="dep lib dirs for --library-path"
    )
    ap.add_argument("--in", dest="infile", required=True, help="input EFI PE binary")
    ap.add_argument("--cert", required=True, help="Secure Boot db certificate (PEM)")
    ap.add_argument("--key", required=True, help="Secure Boot db private key (PEM)")
    ap.add_argument("--out", required=True, help="signed EFI PE output")
    args = ap.parse_args()

    ld = os.path.abspath(args.ld_linux)
    ossl = os.path.abspath(args.osslsigncode)
    lib_path = ":".join(os.path.abspath(d) for d in _read_lines(args.lib_dirs_file))
    pe = os.path.abspath(args.infile)
    cert = os.path.abspath(args.cert)
    key = os.path.abspath(args.key)
    out = os.path.abspath(args.out)

    with open(pe, "rb") as fh:
        if fh.read(2) != b"MZ":
            sys.stderr.write("input %s is not a PE (no MZ header)\n" % pe)
            return 1

    env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "HOME": os.path.dirname(out)}

    def ossl_run(extra):
        return subprocess.run(
            [ld, "--library-path", lib_path, ossl] + extra,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )

    sign = ossl_run(["sign", "-certs", cert, "-key", key, "-in", pe, "-out", out])
    if sign.returncode != 0 or "Succeeded" not in sign.stdout:
        sys.stderr.write("osslsigncode sign failed:\n%s\n" % sign.stdout)
        return 1

    # Self-verify against the db cert (what the firmware does against enrolled db).
    verify = ossl_run(["verify", "-in", out, "-CAfile", cert])
    if verify.returncode != 0 or "Signature verification: ok" not in verify.stdout:
        sys.stderr.write("Secure Boot self-verify failed:\n%s\n" % verify.stdout)
        return 1

    print(
        "efi_sign: signed %s -> %s (db signature verified)"
        % (os.path.basename(pe), out)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
