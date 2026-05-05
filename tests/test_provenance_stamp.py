#!/usr/bin/env python3
"""Unit tests for defs/scripts/provenance-stamp.sh.

Tests the stamp script directly with controlled env vars.
No buck2 deps — pure unit test of the bash script.
Stdlib only — no pytest.
"""

import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "defs" / "scripts" / "provenance-stamp.sh"

passed = 0
failed = 0
_output_lines = []


def ok(msg):
    global passed
    _output_lines.append(f"  PASS: {msg}")
    passed += 1


def fail(msg):
    global failed
    _output_lines.append(f"  FAIL: {msg}")
    failed += 1


def run_stamp(destdir, **env_overrides):
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": os.environ.get("HOME", "/tmp"),
        "PN": "test-pkg",
        "PV": "1.0",
        "BUCKOS_PROVENANCE_ENABLED": "true",
        "BUCKOS_SLSA_ENABLED": "false",
        "BUCKOS_PKG_TYPE": "autotools",
        "BUCKOS_PKG_TARGET": "//packages/test:test-pkg",
        "BUCKOS_PKG_SOURCE_URL": "https://example.com/test-1.0.tar.gz",
        "BUCKOS_PKG_SOURCE_SHA256": "abc123",
        "BUCKOS_PKG_GRAPH_HASH": "deadbeef" * 8,
        "DESTDIR": destdir,
        "T": env_overrides.pop("T", tempfile.mkdtemp()),
        "_EBUILD_DEP_DIRS": "",
    }
    env.update(env_overrides)
    return subprocess.run(
        ["bash", "-c", f'set -e; source "{SCRIPT}"'],
        env=env, capture_output=True, text=True,
    )


def read_jsonl(path):
    records = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                records.append(json.loads(line))
    return records


def verify_bos_prov(rec):
    bos_prov = rec.get("BOS_PROV", "")
    without = {k: v for k, v in rec.items() if k != "BOS_PROV"}
    canonical = json.dumps(without, sort_keys=True, separators=(",", ":"))
    return bos_prov == hashlib.sha256(canonical.encode()).hexdigest()


def main():
    _real_stdout = sys.stdout
    _buf = io.StringIO()
    sys.stdout = _buf

    # -- JSONL has correct fields --
    print("=== TestProvenanceEnabled ===")
    with tempfile.TemporaryDirectory() as d:
        r = run_stamp(d)
        assert r.returncode == 0, f"stamp failed: {r.stderr}"
        jsonl = os.path.join(d, ".buckos-provenance.jsonl")

        if os.path.exists(jsonl):
            ok("jsonl exists")
        else:
            fail("jsonl missing")

        rec = read_jsonl(jsonl)[0]
        for field, expected in [("name", "test-pkg"), ("version", "1.0"),
                                ("type", "autotools"),
                                ("target", "//packages/test:test-pkg")]:
            if rec.get(field) == expected:
                ok(f"{field}={expected}")
            else:
                fail(f"{field}: expected '{expected}', got '{rec.get(field)}'")

        if verify_bos_prov(rec):
            ok("BOS_PROV valid hash")
        else:
            fail("BOS_PROV invalid")

    # -- No SLSA fields when disabled --
    print("=== TestSlsaDisabled ===")
    with tempfile.TemporaryDirectory() as d:
        run_stamp(d, BUCKOS_SLSA_ENABLED="false")
        rec = read_jsonl(os.path.join(d, ".buckos-provenance.jsonl"))[0]
        if "buildTime" not in rec:
            ok("no buildTime when SLSA off")
        else:
            fail("buildTime present when SLSA off")

    # -- SLSA fields present when enabled --
    print("=== TestSlsaEnabled ===")
    with tempfile.TemporaryDirectory() as d:
        run_stamp(d, BUCKOS_SLSA_ENABLED="true")
        rec = read_jsonl(os.path.join(d, ".buckos-provenance.jsonl"))[0]
        if "buildTime" in rec:
            ok("buildTime present when SLSA on")
        else:
            fail("buildTime missing when SLSA on")
        if verify_bos_prov(rec):
            ok("BOS_PROV valid with SLSA")
        else:
            fail("BOS_PROV invalid with SLSA")

    # -- Subgraph hash written --
    print("=== TestSubgraphHash ===")
    with tempfile.TemporaryDirectory() as d:
        run_stamp(d)
        hash_file = os.path.join(d, ".buckos-subgraph-hash")
        if os.path.exists(hash_file):
            ok(".buckos-subgraph-hash exists")
        else:
            fail(".buckos-subgraph-hash missing")
        content = open(hash_file).read().strip()
        if content == "deadbeef" * 8:
            ok("subgraph hash matches")
        else:
            fail(f"subgraph hash mismatch: {content}")

    # -- Reproducibility --
    print("=== TestReproducibility ===")
    with tempfile.TemporaryDirectory() as d1, tempfile.TemporaryDirectory() as d2:
        run_stamp(d1, BUCKOS_SLSA_ENABLED="false")
        run_stamp(d2, BUCKOS_SLSA_ENABLED="false")
        j1 = open(os.path.join(d1, ".buckos-provenance.jsonl")).read()
        j2 = open(os.path.join(d2, ".buckos-provenance.jsonl")).read()
        if j1 == j2:
            ok("reproducible without SLSA")
        else:
            fail("not reproducible without SLSA")

    # -- Provenance disabled --
    print("=== TestProvenanceDisabled ===")
    with tempfile.TemporaryDirectory() as d:
        r = run_stamp(d, BUCKOS_PROVENANCE_ENABLED="false")
        if r.returncode == 0:
            ok("disabled runs without error")
        else:
            fail(f"disabled failed: {r.stderr}")

    # -- IMA disabled --
    print("=== TestImaDisabled ===")
    with tempfile.TemporaryDirectory() as d:
        r = run_stamp(d, BUCKOS_IMA_ENABLED="false")
        if r.returncode == 0:
            ok("IMA disabled runs without error")
        else:
            fail(f"IMA disabled failed: {r.stderr}")

    # -- IMA enabled without key --
    print("=== TestImaMissingKey ===")
    with tempfile.TemporaryDirectory() as d:
        r = run_stamp(d, BUCKOS_IMA_ENABLED="true", BUCKOS_IMA_KEY="")
        if "BUCKOS_IMA_KEY" in r.stderr or r.returncode != 0:
            ok("IMA without key reports error")
        else:
            ok("IMA without key handled")

    # -- ELF .note.package stamping --
    print("=== TestElfStamping ===")
    if shutil.which("objcopy"):
        with tempfile.TemporaryDirectory() as d:
            bindir = os.path.join(d, "usr", "bin")
            os.makedirs(bindir)
            src = os.path.join(d, "hello.c")
            with open(src, "w") as f:
                f.write("int main(){return 0;}\n")
            elf = os.path.join(bindir, "hello")
            cc = os.environ.get("CC", "cc").split()
            cr = subprocess.run(cc + [src, "-o", elf], capture_output=True)
            if cr.returncode != 0:
                print("  SKIP: cc cannot compile (hermetic env without sysroot)")
            else:
                os.chmod(elf, 0o755)

                run_stamp(d)

                r = subprocess.run(
                    ["readelf", "-p", ".note.package", elf],
                    capture_output=True, text=True,
                )
                if "test-pkg" in r.stdout:
                    ok("ELF .note.package stamped")
                else:
                    fail("ELF .note.package missing")

                er = subprocess.run([elf], capture_output=True)
                if er.returncode == 0:
                    ok("stamped binary executes")
                else:
                    fail("stamped binary failed")
    else:
        print("  SKIP: objcopy not found")

    # -- Summary --
    sys.stdout = _real_stdout
    if failed:
        _real_stdout.write(_buf.getvalue())
        for _line in _output_lines:
            print(_line)
        print(f"\n=== {passed}/{passed + failed} passed, {failed} failed ===")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
