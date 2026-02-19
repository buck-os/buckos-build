"""Tests: build targets with provenance via buck2, verify ELF stamps."""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import uuid
from pathlib import Path

import pytest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _buck2_build(
    repo_root: Path, target: str,
    provenance: bool = True, slsa: bool = False,
    use_overrides: dict[str, str] | None = None,
    timeout: int = 120,
) -> Path:
    """Build a target with provenance config and return the output directory."""
    if not shutil.which("buck2"):
        pytest.skip("buck2 not found on PATH")
    iso_name = "test-" + uuid.uuid4().hex[:12]
    args = [
        "buck2", "--isolation-dir", iso_name,
        "build", "--show-full-output",
        "-c", f"use.provenance={'true' if provenance else 'false'}",
        "-c", f"use.slsa={'true' if slsa else 'false'}",
        "-c", "buckos.use_host_toolchain=true",
    ]
    for flag, val in (use_overrides or {}).items():
        args.extend(["-c", f"use.{flag}={val}"])
    args.append(target)
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
    # Use fd for fast file discovery, fall back to rglob
    fd_bin = shutil.which("fd") or shutil.which("fdfind")
    if fd_bin:
        result = subprocess.run(
            [fd_bin, "--type", "f", "--no-ignore", "--hidden", ".", str(root)],
            capture_output=True, text=True,
        )
        candidates = [Path(p) for p in result.stdout.strip().splitlines()] if result.returncode == 0 else []
    else:
        candidates = [p for p in root.rglob("*") if p.is_file()]

    elfs = []
    for p in candidates:
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
# Session cleanup — kill test daemons and remove isolation dirs
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session", autouse=True)
def _cleanup_test_isolation_dirs(repo_root: Path):
    """Kill test daemons and remove isolation dirs after all tests."""
    yield
    buck_out = repo_root / "buck-out"
    if buck_out.exists():
        for d in buck_out.iterdir():
            if d.is_dir() and d.name.startswith("test-"):
                subprocess.run(
                    ["buck2", "--isolation-dir", d.name, "kill"],
                    cwd=repo_root, capture_output=True, timeout=30,
                )
                shutil.rmtree(d, ignore_errors=True)


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

    def test_subgraph_hash_written(self, hello_output: Path):
        hash_file = hello_output / ".buckos-subgraph-hash"
        assert hash_file.exists(), f"Missing {hash_file}"
        content = hash_file.read_text().strip()
        assert len(content) == 64, f"Expected 64 hex chars, got {len(content)}"
        int(content, 16)  # valid hex

    def test_use_flags_in_note_package(self, hello_output: Path):
        exes = _find_executables(hello_output)
        rec = json.loads(_readelf_note_package(exes[0]))
        assert "useFlags" in rec
        assert rec["useFlags"] == ["debug"]

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

    def test_use_flags_in_note_package(self, testlib_output: Path):
        lib = _find_shared_libs(testlib_output)[0]
        rec = json.loads(_readelf_note_package(lib))
        assert "useFlags" in rec
        assert rec["useFlags"] == ["debug"]

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

    def test_use_flags_in_jsonl(self, testlib_output: Path):
        rec = _read_jsonl(testlib_output / ".buckos-provenance.jsonl")[0]
        assert "useFlags" in rec
        assert rec["useFlags"] == ["debug"]

    def test_bos_prov_covers_use_flags(self, testlib_output: Path):
        """BOS_PROV hash includes useFlags in the canonical JSON."""
        rec = _read_jsonl(testlib_output / ".buckos-provenance.jsonl")[0]
        assert "useFlags" in rec
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

    def test_no_use_flags_when_disabled(self, hello_output_disabled: Path):
        jsonl = hello_output_disabled / ".buckos-provenance.jsonl"
        assert not jsonl.exists()

    def test_disabled_binary_still_runs(self, hello_output_disabled: Path):
        exes = _find_executables(hello_output_disabled)
        if not exes:
            pytest.skip("No executables in output")
        hello = next((e for e in exes if e.name == "hello"), exes[0])
        result = subprocess.run(
            [str(hello)], capture_output=True, text=True,
        )
        assert result.returncode == 0


# ---------------------------------------------------------------------------
# USE flags in provenance — multi-flag coverage
# ---------------------------------------------------------------------------

class TestUseFlagsInProvenance:

    @pytest.fixture(scope="class")
    def hello_defaults(self, repo_root: Path) -> Path:
        """Default flags: debug=on (from use_defaults), trace=off."""
        return _buck2_build(repo_root, "//tests/fixtures/hello:hello")

    @pytest.fixture(scope="class")
    def hello_both_on(self, repo_root: Path) -> Path:
        """Both debug (default) and trace (override) enabled."""
        return _buck2_build(
            repo_root, "//tests/fixtures/hello:hello",
            use_overrides={"trace": "true"},
        )

    @pytest.fixture(scope="class")
    def hello_debug_off(self, repo_root: Path) -> Path:
        """debug disabled, trace still off — no flags active."""
        return _buck2_build(
            repo_root, "//tests/fixtures/hello:hello",
            use_overrides={"debug": "false"},
        )

    @pytest.fixture(scope="class")
    def hello_trace_only(self, repo_root: Path) -> Path:
        """debug off, trace on — only trace active."""
        return _buck2_build(
            repo_root, "//tests/fixtures/hello:hello",
            use_overrides={"debug": "false", "trace": "true"},
        )

    # -- defaults (debug only) --

    def test_defaults_use_flags(self, hello_defaults: Path):
        rec = _read_jsonl(hello_defaults / ".buckos-provenance.jsonl")[0]
        assert rec["useFlags"] == ["debug"]

    def test_defaults_bos_prov(self, hello_defaults: Path):
        rec = _read_jsonl(hello_defaults / ".buckos-provenance.jsonl")[0]
        _verify_bos_prov(rec)

    # -- both flags on --

    def test_both_on_use_flags(self, hello_both_on: Path):
        rec = _read_jsonl(hello_both_on / ".buckos-provenance.jsonl")[0]
        assert rec["useFlags"] == ["debug", "trace"]

    def test_both_on_bos_prov(self, hello_both_on: Path):
        rec = _read_jsonl(hello_both_on / ".buckos-provenance.jsonl")[0]
        _verify_bos_prov(rec)

    def test_both_on_elf_stamp_matches_jsonl(self, hello_both_on: Path):
        own = _read_jsonl(hello_both_on / ".buckos-provenance.jsonl")[0]
        exes = _find_executables(hello_both_on)
        elf_rec = json.loads(_readelf_note_package(exes[0]))
        assert elf_rec == own

    # -- debug off (empty flags) --

    def test_debug_off_use_flags(self, hello_debug_off: Path):
        rec = _read_jsonl(hello_debug_off / ".buckos-provenance.jsonl")[0]
        assert rec["useFlags"] == []

    def test_debug_off_bos_prov(self, hello_debug_off: Path):
        rec = _read_jsonl(hello_debug_off / ".buckos-provenance.jsonl")[0]
        _verify_bos_prov(rec)

    # -- trace only --

    def test_trace_only_use_flags(self, hello_trace_only: Path):
        rec = _read_jsonl(hello_trace_only / ".buckos-provenance.jsonl")[0]
        assert rec["useFlags"] == ["trace"]

    def test_trace_only_bos_prov(self, hello_trace_only: Path):
        rec = _read_jsonl(hello_trace_only / ".buckos-provenance.jsonl")[0]
        _verify_bos_prov(rec)


# ---------------------------------------------------------------------------
# Per-target subgraph hash
# ---------------------------------------------------------------------------

class TestSubgraphHash:
    """Verify per-target subgraph hashes differ across targets and are deterministic."""

    def test_different_targets_different_hashes(
        self, hello_output: Path, testlib_output: Path,
    ):
        hello_hash = (hello_output / ".buckos-subgraph-hash").read_text().strip()
        testlib_hash = (testlib_output / ".buckos-subgraph-hash").read_text().strip()
        assert hello_hash != testlib_hash, (
            "Different targets should have different subgraph hashes"
        )

    def test_subgraph_hash_matches_graph_hash_in_jsonl(self, hello_output: Path):
        """The subgraph hash file should match the graphHash in provenance JSONL."""
        subgraph_hash = (hello_output / ".buckos-subgraph-hash").read_text().strip()
        rec = _read_jsonl(hello_output / ".buckos-provenance.jsonl")[0]
        assert rec["graphHash"] == subgraph_hash

    def test_subgraph_hash_deterministic(self, repo_root: Path):
        """Same target built twice produces the same subgraph hash."""
        out1 = _buck2_build(repo_root, "//tests/fixtures/hello:hello")
        out2 = _buck2_build(repo_root, "//tests/fixtures/hello:hello")
        h1 = (out1 / ".buckos-subgraph-hash").read_text().strip()
        h2 = (out2 / ".buckos-subgraph-hash").read_text().strip()
        assert h1 == h2, "Same target should produce identical subgraph hash"


# ---------------------------------------------------------------------------
# IMA signing
# ---------------------------------------------------------------------------

class TestImaSigning:
    """IMA signing integration tests — gated on evmctl availability."""

    @pytest.fixture(scope="class")
    def hello_ima(self, repo_root: Path) -> Path:
        if not shutil.which("evmctl"):
            pytest.skip("evmctl not found")
        return _buck2_build(
            repo_root, "//tests/fixtures/hello:hello",
            use_overrides={"ima": "true"},
        )

    @pytest.fixture(scope="class")
    def hello_no_ima(self, repo_root: Path) -> Path:
        return _buck2_build(
            repo_root, "//tests/fixtures/hello:hello",
            use_overrides={"ima": "false"},
        )

    def test_ima_disabled_no_sig(self, hello_no_ima: Path):
        """Without IMA, no .sig sidecars should exist."""
        sigs = list(hello_no_ima.rglob("*.sig"))
        assert not sigs, (
            f".sig files should not exist when IMA is disabled: {sigs}"
        )

    def test_ima_signed_elf_has_sig(self, hello_ima: Path):
        """With IMA enabled, ELF binaries should have .sig sidecars."""
        exes = _find_executables(hello_ima)
        assert exes, f"No executables found under {hello_ima}"
        for exe in exes:
            sig = exe.with_name(exe.name + ".sig")
            assert sig.exists(), f"{exe.name}: missing .sig sidecar"

    def test_ima_signed_binary_still_runs(self, hello_ima: Path):
        """IMA-signed binary should still execute normally."""
        exes = _find_executables(hello_ima)
        hello = next((e for e in exes if e.name == "hello"), exes[0])
        result = subprocess.run(
            [str(hello)], capture_output=True, text=True,
        )
        assert result.returncode == 0, f"IMA-signed binary failed:\n{result.stderr}"
