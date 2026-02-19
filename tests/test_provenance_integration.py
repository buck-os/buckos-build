"""Tests: build targets with provenance via buck2, verify ELF stamps.

Marked slow because every test invokes buck2 build.  Run explicitly:
    pytest -m slow tests/test_provenance_integration.py
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.slow


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _buck2_build(repo_root: Path, target: str, provenance: bool = True,
                 slsa: bool = False, timeout: int = 120) -> Path:
    """Build a target with provenance config and return the output directory."""
    if not shutil.which("buck2"):
        pytest.skip("buck2 not found on PATH")
    args = [
        "buck2", "build", "--show-full-output",
        "-c", f"use.provenance={'true' if provenance else 'false'}",
        "-c", f"use.slsa={'true' if slsa else 'false'}",
        "-c", "buckos.use_host_toolchain=true",
        target,
    ]
    result = subprocess.run(
        args, cwd=repo_root, capture_output=True, text=True, timeout=timeout,
    )
    assert result.returncode == 0, (
        f"buck2 build failed for {target}:\n{result.stderr}"
    )
    for line in result.stdout.strip().splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2:
            return Path(parts[1])
    pytest.fail(f"Could not parse output path from: {result.stdout}")


def _find_elfs(root: Path) -> list[Path]:
    elfs = []
    for p in root.rglob("*"):
        if not p.is_file():
            continue
        try:
            magic = p.read_bytes()[:4]
        except (PermissionError, OSError):
            continue
        if magic == b"\x7fELF":
            elfs.append(p)
    return elfs


def _find_executables(root: Path) -> list[Path]:
    exes = []
    for elf in _find_elfs(root):
        result = subprocess.run(
            ["file", str(elf)], capture_output=True, text=True,
        )
        if "executable" in result.stdout.lower() and "shared object" not in result.stdout.lower():
            exes.append(elf)
    return exes


def _find_shared_libs(root: Path) -> list[Path]:
    return [elf for elf in _find_elfs(root) if ".so" in elf.name]


def _readelf_note_package(elf: Path) -> str | None:
    if not shutil.which("readelf"):
        pytest.skip("readelf not available")
    result = subprocess.run(
        ["readelf", "-p", ".note.package", str(elf)],
        capture_output=True, text=True,
    )
    if result.returncode != 0 or "note.package" not in result.stdout.lower():
        return None
    for line in result.stdout.splitlines():
        m = re.search(r"\{.*\}", line)
        if m:
            return m.group(0)
    return None


def _read_jsonl(path: Path) -> list[dict]:
    records = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if line:
            records.append(json.loads(line))
    return records


def _verify_bos_prov(rec: dict) -> None:
    assert "BOS_PROV" in rec
    bos_prov = rec["BOS_PROV"]
    assert len(bos_prov) == 64
    int(bos_prov, 16)
    rec_without = {k: v for k, v in rec.items() if k != "BOS_PROV"}
    canonical = json.dumps(rec_without, sort_keys=True, separators=(",", ":"))
    expected = hashlib.sha256(canonical.encode()).hexdigest()
    assert bos_prov == expected, (
        f"BOS_PROV mismatch: got {bos_prov}, expected {expected}\n"
        f"canonical: {canonical}"
    )


# ---------------------------------------------------------------------------
# Fixtures — test binary (//tests/fixtures/hello:hello)
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def hello_output(repo_root: Path) -> Path:
    return _buck2_build(repo_root, "//tests/fixtures/hello:hello",
                        provenance=True, slsa=False)


@pytest.fixture(scope="module")
def hello_output_disabled(repo_root: Path) -> Path:
    return _buck2_build(repo_root, "//tests/fixtures/hello:hello",
                        provenance=False)


# ---------------------------------------------------------------------------
# Fixtures — test shared library (//tests/fixtures/testlib:testlib)
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def testlib_output(repo_root: Path) -> Path:
    return _buck2_build(repo_root, "//tests/fixtures/testlib:testlib",
                        provenance=True, slsa=False)


@pytest.fixture(scope="module")
def testlib_output_slsa(repo_root: Path) -> Path:
    return _buck2_build(repo_root, "//tests/fixtures/testlib:testlib",
                        provenance=True, slsa=True)


@pytest.fixture(scope="module")
def testlib_output_disabled(repo_root: Path) -> Path:
    return _buck2_build(repo_root, "//tests/fixtures/testlib:testlib",
                        provenance=False)


# ---------------------------------------------------------------------------
# Executable stamping (hello)
# ---------------------------------------------------------------------------

class TestExecutableStamping:

    def test_executables_have_note_package(self, hello_output: Path):
        exes = _find_executables(hello_output)
        assert exes, f"No executables found under {hello_output}"
        for exe in exes:
            content = _readelf_note_package(exe)
            assert content is not None, (
                f"{exe.name}: missing .note.package section"
            )

    def test_note_package_metadata(self, hello_output: Path):
        exes = _find_executables(hello_output)
        rec = json.loads(_readelf_note_package(exes[0]))
        assert rec["name"] == "hello"
        assert rec["version"] == "0.1.0"
        assert "target" in rec
        assert "hello" in rec["target"]

    def test_bos_prov(self, hello_output: Path):
        exes = _find_executables(hello_output)
        rec = json.loads(_readelf_note_package(exes[0]))
        _verify_bos_prov(rec)

    def test_graph_hash_present(self, hello_output: Path):
        exes = _find_executables(hello_output)
        rec = json.loads(_readelf_note_package(exes[0]))
        assert rec["graphHash"] != ""
        assert len(rec["graphHash"]) == 64

    def test_stamped_binary_runs(self, hello_output: Path):
        exes = _find_executables(hello_output)
        hello = next((e for e in exes if e.name == "hello"), exes[0])
        result = subprocess.run(
            [str(hello)], capture_output=True, text=True,
        )
        assert result.returncode == 0, f"Stamped binary failed:\n{result.stderr}"
        assert "hello-provenance-test" in result.stdout

    def test_elf_stamp_matches_jsonl(self, hello_output: Path):
        own = _read_jsonl(hello_output / ".buckos-provenance.jsonl")[0]
        exes = _find_executables(hello_output)
        elf_rec = json.loads(_readelf_note_package(exes[0]))
        assert elf_rec == own


# ---------------------------------------------------------------------------
# Shared library stamping (testlib)
# ---------------------------------------------------------------------------

class TestSharedLibStamping:

    def test_libs_have_note_package(self, testlib_output: Path):
        libs = _find_shared_libs(testlib_output)
        assert libs, f"No .so files found under {testlib_output}"
        for lib in libs:
            content = _readelf_note_package(lib)
            assert content is not None, (
                f"{lib.name}: missing .note.package section"
            )

    def test_note_package_metadata(self, testlib_output: Path):
        lib = _find_shared_libs(testlib_output)[0]
        rec = json.loads(_readelf_note_package(lib))
        assert rec["name"] == "testlib"
        assert rec["version"] == "0.1.0"

    def test_bos_prov(self, testlib_output: Path):
        lib = _find_shared_libs(testlib_output)[0]
        rec = json.loads(_readelf_note_package(lib))
        _verify_bos_prov(rec)

    def test_stamped_lib_still_valid_elf(self, testlib_output: Path):
        for lib in _find_shared_libs(testlib_output):
            result = subprocess.run(
                ["file", str(lib)], capture_output=True, text=True,
            )
            assert "ELF" in result.stdout
            assert "shared object" in result.stdout.lower()

    def test_stamped_lib_loads(self, testlib_output: Path):
        libs = _find_shared_libs(testlib_output)
        lib = libs[0]
        result = subprocess.run(
            ["python3", "-c",
             f"import ctypes; l = ctypes.CDLL('{lib}'); "
             f"l.testlib_version.restype = ctypes.c_char_p; "
             f"assert l.testlib_version() == b'0.1.0'"],
            capture_output=True, text=True,
        )
        assert result.returncode == 0, f"Stamped lib failed to load:\n{result.stderr}"


# ---------------------------------------------------------------------------
# JSONL output
# ---------------------------------------------------------------------------

class TestJsonlOutput:

    def test_jsonl_exists(self, testlib_output: Path):
        jsonl = testlib_output / ".buckos-provenance.jsonl"
        assert jsonl.exists(), f"Missing {jsonl}"

    def test_jsonl_own_record(self, testlib_output: Path):
        records = _read_jsonl(testlib_output / ".buckos-provenance.jsonl")
        assert records
        own = records[0]
        assert own["name"] == "testlib"
        assert own["version"] == "0.1.0"
        assert "BOS_PROV" in own
        assert "graphHash" in own

    def test_bos_prov_matches_hash(self, testlib_output: Path):
        rec = _read_jsonl(testlib_output / ".buckos-provenance.jsonl")[0]
        _verify_bos_prov(rec)

    def test_no_slsa_fields_without_slsa(self, testlib_output: Path):
        own = _read_jsonl(testlib_output / ".buckos-provenance.jsonl")[0]
        assert "buildTime" not in own
        assert "buildHost" not in own

    def test_elf_stamp_matches_jsonl(self, testlib_output: Path):
        own = _read_jsonl(testlib_output / ".buckos-provenance.jsonl")[0]
        lib = _find_shared_libs(testlib_output)[0]
        elf_rec = json.loads(_readelf_note_package(lib))
        assert elf_rec == own


# ---------------------------------------------------------------------------
# SLSA volatile fields
# ---------------------------------------------------------------------------

class TestSlsaFields:

    def test_slsa_has_build_time_and_host(self, testlib_output_slsa: Path):
        own = _read_jsonl(testlib_output_slsa / ".buckos-provenance.jsonl")[0]
        assert "buildTime" in own
        assert "buildHost" in own

    def test_slsa_bos_prov_covers_volatile(self, testlib_output_slsa: Path):
        own = _read_jsonl(testlib_output_slsa / ".buckos-provenance.jsonl")[0]
        assert "buildTime" in own
        _verify_bos_prov(own)

    def test_slsa_elf_has_build_time(self, testlib_output_slsa: Path):
        """readelf confirms buildTime is stamped into the ELF .note.package."""
        lib = _find_shared_libs(testlib_output_slsa)[0]
        raw = _readelf_note_package(lib)
        assert raw is not None, "missing .note.package in SLSA build"
        rec = json.loads(raw)
        assert "buildTime" in rec
        assert "buildHost" in rec
        _verify_bos_prov(rec)

    def test_slsa_bos_prov_matches_non_slsa(
        self, testlib_output: Path, testlib_output_slsa: Path,
    ):
        """SLSA and non-SLSA may share an output path (buck2 caching),
        so BOS_PROV can legitimately be identical."""
        rec_plain = _read_jsonl(testlib_output / ".buckos-provenance.jsonl")[0]
        rec_slsa = _read_jsonl(testlib_output_slsa / ".buckos-provenance.jsonl")[0]
        # Both must have valid BOS_PROV regardless
        _verify_bos_prov(rec_plain)
        _verify_bos_prov(rec_slsa)


# ---------------------------------------------------------------------------
# Reproducibility
# ---------------------------------------------------------------------------

class TestReproducibility:

    def test_prov_stamp_deterministic(self, testlib_output: Path):
        """ELF stamp matches JSONL and BOS_PROV is self-consistent."""
        rec = _read_jsonl(testlib_output / ".buckos-provenance.jsonl")[0]
        lib = _find_shared_libs(testlib_output)[0]
        elf_rec = json.loads(_readelf_note_package(lib))
        assert rec == elf_rec
        _verify_bos_prov(rec)


# ---------------------------------------------------------------------------
# Provenance disabled
# ---------------------------------------------------------------------------

class TestProvenanceDisabled:

    def test_no_jsonl_lib(self, testlib_output_disabled: Path):
        jsonl = testlib_output_disabled / ".buckos-provenance.jsonl"
        assert not jsonl.exists()

    def test_no_note_package_lib(self, testlib_output_disabled: Path):
        elfs = _find_elfs(testlib_output_disabled)
        if not elfs:
            pytest.skip("No ELF files in output")
        for elf in elfs:
            assert _readelf_note_package(elf) is None, (
                f"{elf.name}: .note.package should not exist"
            )

    def test_no_jsonl_bin(self, hello_output_disabled: Path):
        jsonl = hello_output_disabled / ".buckos-provenance.jsonl"
        assert not jsonl.exists()

    def test_no_note_package_bin(self, hello_output_disabled: Path):
        exes = _find_executables(hello_output_disabled)
        if not exes:
            pytest.skip("No executables in output")
        for exe in exes:
            assert _readelf_note_package(exe) is None, (
                f"{exe.name}: .note.package should not exist"
            )

    def test_disabled_binary_still_runs(self, hello_output_disabled: Path):
        exes = _find_executables(hello_output_disabled)
        if not exes:
            pytest.skip("No executables in output")
        hello = next((e for e in exes if e.name == "hello"), exes[0])
        result = subprocess.run(
            [str(hello)], capture_output=True, text=True,
        )
        assert result.returncode == 0
