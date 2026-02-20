#!/usr/bin/env python3
"""Provenance verification test.

Env vars from sh_test:
    OUTPUT_DIR        — build output directory
    EXPECT_PROVENANCE — "true"/"false" (default: true)
    EXPECT_NAME       — expected package name (required if provenance=true)
    EXPECT_VERSION    — expected version (required if provenance=true)
    EXPECT_IMA        — "true" if IMA .sig sidecars expected (default: false)
    EXPECT_LIB        — "true" if checking a shared library (default: false)
"""

import hashlib
import json
import os
import subprocess
import sys

passed = 0
failed = 0


def ok(msg):
    global passed
    print(f"  PASS: {msg}")
    passed += 1


def fail(msg):
    global failed
    print(f"  FAIL: {msg}")
    failed += 1


def find_elfs(root):
    elfs = []
    for dirpath, _, filenames in os.walk(root):
        for f in filenames:
            path = os.path.join(dirpath, f)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            try:
                with open(path, "rb") as fh:
                    if fh.read(4) == b"\x7fELF":
                        elfs.append(path)
            except OSError:
                pass
    return elfs


def readelf_note_package(elf):
    r = subprocess.run(
        ["readelf", "-p", ".note.package", elf],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        return None
    for line in r.stdout.splitlines():
        start = line.find("{")
        end = line.rfind("}")
        if start >= 0 and end > start:
            return line[start:end + 1]
    return None


def verify_bos_prov(rec):
    bos_prov = rec.get("BOS_PROV", "")
    rec_without = {k: v for k, v in rec.items() if k != "BOS_PROV"}
    canonical = json.dumps(rec_without, sort_keys=True, separators=(",", ":"))
    expected = hashlib.sha256(canonical.encode()).hexdigest()
    return bos_prov == expected


def main():
    output_dir = os.environ.get("OUTPUT_DIR")
    if not output_dir:
        print("ERROR: OUTPUT_DIR not set")
        sys.exit(1)

    expect_prov = os.environ.get("EXPECT_PROVENANCE", "true") == "true"
    expect_ima = os.environ.get("EXPECT_IMA", "false") == "true"
    expect_lib = os.environ.get("EXPECT_LIB", "false") == "true"

    elfs = find_elfs(output_dir)

    # -- Provenance disabled --
    if not expect_prov:
        print("=== Verifying provenance disabled ===")
        jsonl = os.path.join(output_dir, ".buckos-provenance.jsonl")
        if not os.path.exists(jsonl):
            ok("no .buckos-provenance.jsonl")
        else:
            fail(".buckos-provenance.jsonl should not exist")

        for elf in elfs:
            name = os.path.basename(elf)
            if readelf_note_package(elf) is not None:
                fail(f"{name} has .note.package (should not)")
            else:
                ok(f"{name}: no .note.package")

        if not expect_lib:
            for elf in elfs:
                r = subprocess.run(
                    ["file", elf], capture_output=True, text=True,
                )
                if "executable" in r.stdout.lower():
                    er = subprocess.run([elf], capture_output=True)
                    if er.returncode == 0:
                        ok(f"{os.path.basename(elf)} executes")
                    else:
                        fail(f"{os.path.basename(elf)} failed to execute")

        print(f"--- {passed} passed, {failed} failed ---")
        sys.exit(1 if failed else 0)

    # -- Provenance enabled --
    print("=== Verifying provenance ===")
    expect_name = os.environ.get("EXPECT_NAME", "")
    expect_version = os.environ.get("EXPECT_VERSION", "")

    jsonl_path = os.path.join(output_dir, ".buckos-provenance.jsonl")
    if os.path.exists(jsonl_path):
        ok(".buckos-provenance.jsonl exists")
    else:
        fail(".buckos-provenance.jsonl missing")
        print(f"--- {passed} passed, {failed} failed ---")
        sys.exit(1)

    with open(jsonl_path) as f:
        rec = json.loads(f.readline().strip())

    # Check fields
    for field, expected in [("name", expect_name), ("version", expect_version)]:
        if expected and rec.get(field) == expected:
            ok(f"{field} = {expected}")
        elif expected:
            fail(f"{field}: expected '{expected}', got '{rec.get(field)}'")

    # BOS_PROV
    if verify_bos_prov(rec):
        ok("BOS_PROV hash valid")
    else:
        fail("BOS_PROV hash invalid")

    # Subgraph hash
    hash_file = os.path.join(output_dir, ".buckos-subgraph-hash")
    if os.path.exists(hash_file):
        ok(".buckos-subgraph-hash exists")
    else:
        fail(".buckos-subgraph-hash missing")

    # ELF .note.package
    own_line = json.dumps(rec, sort_keys=True, separators=(",", ":"))
    for elf in elfs:
        name = os.path.basename(elf)
        note = readelf_note_package(elf)
        if note and expect_name in note:
            ok(f"{name}: .note.package present")
        else:
            fail(f"{name}: .note.package missing or wrong")

        # ELF stamp matches JSONL
        if note:
            try:
                elf_rec = json.loads(note)
                if elf_rec == rec:
                    ok(f"{name}: ELF stamp matches JSONL")
                else:
                    fail(f"{name}: ELF stamp differs from JSONL")
            except json.JSONDecodeError:
                fail(f"{name}: ELF stamp not valid JSON")

    # Binary executes / lib is valid
    if expect_lib:
        for elf in elfs:
            r = subprocess.run(["file", elf], capture_output=True, text=True)
            if "shared object" in r.stdout.lower():
                ok(f"{os.path.basename(elf)}: valid ELF shared object")
    else:
        for elf in elfs:
            r = subprocess.run(["file", elf], capture_output=True, text=True)
            if "executable" in r.stdout.lower():
                er = subprocess.run([elf], capture_output=True)
                if er.returncode == 0:
                    ok(f"{os.path.basename(elf)} executes after stamp")
                else:
                    fail(f"{os.path.basename(elf)} fails to execute after stamp")

    # IMA checks
    if expect_ima:
        print("=== Verifying IMA signatures ===")
        for elf in elfs:
            sig = elf + ".sig"
            name = os.path.basename(elf)
            if os.path.exists(sig):
                ok(f"{name}: .sig sidecar exists")
            else:
                fail(f"{name}: .sig sidecar missing")

    print(f"--- {passed} passed, {failed} failed ---")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
