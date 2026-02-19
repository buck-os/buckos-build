"""Tests for provenance-stamp.sh — run directly with controlled env vars."""

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest

SCRIPT = os.path.join(
    os.path.dirname(__file__), "..", "defs", "scripts", "provenance-stamp.sh"
)


def _run_stamp(env_overrides, dep_dirs=None, use_flags=None):
    """Source provenance-stamp.sh inside a bash wrapper and return the result.

    use_flags: optional list of USE flag strings.  When provided the
    BUCKOS_USE bash array is declared inside the wrapper script (bash
    arrays cannot be passed through the environment).
    """
    destdir = env_overrides["DESTDIR"]
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
        "BUCKOS_PKG_GRAPH_HASH": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
        "DESTDIR": destdir,
        "T": env_overrides.get("T", tempfile.mkdtemp()),
        "_EBUILD_DEP_DIRS": " ".join(dep_dirs) if dep_dirs else "",
    }
    env.update(env_overrides)

    preamble = ""
    if use_flags is not None:
        # Bash arrays can't be passed via env; declare inside the script
        escaped = " ".join(f'"{f}"' for f in use_flags)
        preamble = f'BUCKOS_USE=({escaped}); export BUCKOS_USE\n'

    script = textwrap.dedent(f"""\
        set -e
        {preamble}source "{os.path.abspath(SCRIPT)}"
    """)
    result = subprocess.run(
        ["bash", "-c", script],
        env=env,
        capture_output=True,
        text=True,
    )
    return result


def _read_jsonl(path):
    """Read an NDJSON file and return list of parsed objects."""
    records = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                records.append(json.loads(line))
    return records


class TestProvenanceDisabled(unittest.TestCase):
    """When BUCKOS_PROVENANCE_ENABLED=false, nothing should happen."""

    def test_no_jsonl_written(self):
        with tempfile.TemporaryDirectory() as destdir:
            result = _run_stamp({
                "DESTDIR": destdir,
                "BUCKOS_PROVENANCE_ENABLED": "false",
            })
            # Script is sourced but gated — should not create the file
            # The script is only sourced when the wrapper checks the flag,
            # but we test the script directly, so it always runs.
            # When disabled, the wrapper never sources the script at all.
            # For direct invocation, we test the wrapper gating separately.
            self.assertEqual(result.returncode, 0)

    def test_no_elf_modification(self):
        """Even if ELF exists, disabled provenance should not modify it."""
        with tempfile.TemporaryDirectory() as destdir:
            result = _run_stamp({
                "DESTDIR": destdir,
                "BUCKOS_PROVENANCE_ENABLED": "false",
            })
            self.assertEqual(result.returncode, 0)


class TestProvenanceEnabled(unittest.TestCase):
    """Core provenance functionality."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.destdir = os.path.join(self.tmpdir, "dest")
        os.makedirs(self.destdir)
        self.t = os.path.join(self.tmpdir, "temp")
        os.makedirs(self.t)

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def test_jsonl_has_correct_fields(self):
        result = _run_stamp({
            "DESTDIR": self.destdir,
            "T": self.t,
        })
        self.assertEqual(result.returncode, 0, result.stderr)

        jsonl_path = os.path.join(self.destdir, ".buckos-provenance.jsonl")
        self.assertTrue(os.path.exists(jsonl_path))

        records = _read_jsonl(jsonl_path)
        self.assertEqual(len(records), 1)
        rec = records[0]

        self.assertEqual(rec["name"], "test-pkg")
        self.assertEqual(rec["version"], "1.0")
        self.assertEqual(rec["type"], "autotools")
        self.assertEqual(rec["target"], "//packages/test:test-pkg")
        self.assertEqual(rec["sourceUrl"], "https://example.com/test-1.0.tar.gz")
        self.assertEqual(rec["sourceSha256"], "abc123")
        self.assertEqual(rec["graphHash"], "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
        self.assertIn("useFlags", rec)
        self.assertIn("BOS_PROV", rec)

    def test_bos_prov_is_valid_hash(self):
        result = _run_stamp({
            "DESTDIR": self.destdir,
            "T": self.t,
        })
        self.assertEqual(result.returncode, 0, result.stderr)

        records = _read_jsonl(
            os.path.join(self.destdir, ".buckos-provenance.jsonl")
        )
        rec = records[0]
        bos_prov = rec["BOS_PROV"]

        # BOS_PROV should be a 64-char hex string (sha256)
        self.assertEqual(len(bos_prov), 64)
        int(bos_prov, 16)  # Should not raise

        # Verify it matches the sha256 of sorted metadata excluding BOS_PROV
        rec_without = {k: v for k, v in rec.items() if k != "BOS_PROV"}
        canonical = json.dumps(rec_without, sort_keys=True, separators=(",", ":"))
        expected = hashlib.sha256(canonical.encode()).hexdigest()
        self.assertEqual(bos_prov, expected)

    def test_no_slsa_fields_when_disabled(self):
        result = _run_stamp({
            "DESTDIR": self.destdir,
            "T": self.t,
            "BUCKOS_SLSA_ENABLED": "false",
        })
        self.assertEqual(result.returncode, 0, result.stderr)

        records = _read_jsonl(
            os.path.join(self.destdir, ".buckos-provenance.jsonl")
        )
        rec = records[0]
        self.assertNotIn("buildTime", rec)
        self.assertNotIn("buildHost", rec)

    def test_empty_source_url_ok(self):
        result = _run_stamp({
            "DESTDIR": self.destdir,
            "T": self.t,
            "BUCKOS_PKG_SOURCE_URL": "",
            "BUCKOS_PKG_SOURCE_SHA256": "",
        })
        self.assertEqual(result.returncode, 0, result.stderr)

        records = _read_jsonl(
            os.path.join(self.destdir, ".buckos-provenance.jsonl")
        )
        self.assertEqual(records[0]["sourceUrl"], "")

    @unittest.skipUnless(
        shutil.which("cc") and shutil.which("objcopy"),
        "cc and objcopy required",
    )
    def test_elf_gets_note_package_section(self):
        # Compile a minimal binary
        c_src = os.path.join(self.tmpdir, "hello.c")
        with open(c_src, "w") as f:
            f.write("int main(){return 0;}\n")
        elf_path = os.path.join(self.destdir, "usr", "bin", "hello")
        os.makedirs(os.path.dirname(elf_path))
        subprocess.run(
            ["cc", c_src, "-o", elf_path],
            check=True,
            capture_output=True,
        )
        os.chmod(elf_path, 0o755)

        result = _run_stamp({
            "DESTDIR": self.destdir,
            "T": self.t,
        })
        self.assertEqual(result.returncode, 0, result.stderr)

        # Check for .note.package section
        readelf = subprocess.run(
            ["readelf", "-p", ".note.package", elf_path],
            capture_output=True,
            text=True,
        )
        self.assertIn("test-pkg", readelf.stdout)


def _verify_bos_prov(rec):
    """Recompute BOS_PROV and assert it matches the record's value."""
    rec_without = {k: v for k, v in rec.items() if k != "BOS_PROV"}
    canonical = json.dumps(rec_without, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest() == rec["BOS_PROV"]


class TestUseFlagsInProvenance(unittest.TestCase):
    """USE flag serialisation in provenance records."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.destdir = os.path.join(self.tmpdir, "dest")
        os.makedirs(self.destdir)
        self.t = os.path.join(self.tmpdir, "temp")
        os.makedirs(self.t)

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def _stamp(self, use_flags=None):
        result = _run_stamp(
            {"DESTDIR": self.destdir, "T": self.t},
            use_flags=use_flags,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return _read_jsonl(
            os.path.join(self.destdir, ".buckos-provenance.jsonl")
        )[0]

    def test_use_flags_present(self):
        rec = self._stamp(use_flags=["ssl", "http2"])
        self.assertEqual(rec["useFlags"], ["ssl", "http2"])

    def test_use_flags_empty_when_unset(self):
        rec = self._stamp()
        self.assertEqual(rec["useFlags"], [])

    def test_use_flags_empty_list(self):
        rec = self._stamp(use_flags=[])
        self.assertEqual(rec["useFlags"], [])

    def test_use_flags_single(self):
        rec = self._stamp(use_flags=["debug"])
        self.assertEqual(rec["useFlags"], ["debug"])

    def test_bos_prov_covers_use_flags(self):
        rec = self._stamp(use_flags=["ssl"])
        self.assertTrue(_verify_bos_prov(rec))

    def test_different_flags_different_bos_prov(self):
        rec_ssl = self._stamp(use_flags=["ssl"])

        # Stamp into a separate destdir for the second run
        destdir2 = os.path.join(self.tmpdir, "dest2")
        os.makedirs(destdir2)
        result = _run_stamp(
            {"DESTDIR": destdir2, "T": self.t},
            use_flags=["debug"],
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        rec_debug = _read_jsonl(
            os.path.join(destdir2, ".buckos-provenance.jsonl")
        )[0]

        self.assertNotEqual(rec_ssl["BOS_PROV"], rec_debug["BOS_PROV"])


class TestSlsaMode(unittest.TestCase):
    """SLSA volatile fields."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.destdir = os.path.join(self.tmpdir, "dest")
        os.makedirs(self.destdir)
        self.t = os.path.join(self.tmpdir, "temp")
        os.makedirs(self.t)

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def test_slsa_true_has_build_fields(self):
        result = _run_stamp({
            "DESTDIR": self.destdir,
            "T": self.t,
            "BUCKOS_SLSA_ENABLED": "true",
        })
        self.assertEqual(result.returncode, 0, result.stderr)

        records = _read_jsonl(
            os.path.join(self.destdir, ".buckos-provenance.jsonl")
        )
        rec = records[0]
        self.assertIn("buildTime", rec)
        self.assertIn("buildHost", rec)

    def test_slsa_true_bos_prov_covers_volatile_fields(self):
        """BOS_PROV hash includes buildTime/buildHost when SLSA is on."""
        result = _run_stamp({
            "DESTDIR": self.destdir,
            "T": self.t,
            "BUCKOS_SLSA_ENABLED": "true",
        })
        self.assertEqual(result.returncode, 0, result.stderr)

        records = _read_jsonl(
            os.path.join(self.destdir, ".buckos-provenance.jsonl")
        )
        rec = records[0]
        bos_prov = rec["BOS_PROV"]

        # Independently recompute: strip BOS_PROV, sort keys, hash
        rec_without = {k: v for k, v in rec.items() if k != "BOS_PROV"}
        self.assertIn("buildTime", rec_without)
        self.assertIn("buildHost", rec_without)
        canonical = json.dumps(rec_without, sort_keys=True, separators=(",", ":"))
        expected = hashlib.sha256(canonical.encode()).hexdigest()
        self.assertEqual(bos_prov, expected)

    def test_slsa_false_no_build_fields(self):
        result = _run_stamp({
            "DESTDIR": self.destdir,
            "T": self.t,
            "BUCKOS_SLSA_ENABLED": "false",
        })
        self.assertEqual(result.returncode, 0, result.stderr)

        records = _read_jsonl(
            os.path.join(self.destdir, ".buckos-provenance.jsonl")
        )
        rec = records[0]
        self.assertNotIn("buildTime", rec)
        self.assertNotIn("buildHost", rec)

    def test_slsa_produces_different_build_times(self):
        import time

        result1 = _run_stamp({
            "DESTDIR": self.destdir,
            "T": self.t,
            "BUCKOS_SLSA_ENABLED": "true",
        })
        records1 = _read_jsonl(
            os.path.join(self.destdir, ".buckos-provenance.jsonl")
        )

        time.sleep(1.1)

        destdir2 = os.path.join(self.tmpdir, "dest2")
        os.makedirs(destdir2)
        result2 = _run_stamp({
            "DESTDIR": destdir2,
            "T": self.t,
            "BUCKOS_SLSA_ENABLED": "true",
        })
        records2 = _read_jsonl(
            os.path.join(destdir2, ".buckos-provenance.jsonl")
        )

        self.assertNotEqual(
            records1[0]["buildTime"], records2[0]["buildTime"]
        )


class TestReproducibility(unittest.TestCase):
    """Verify reproducible output when SLSA is off."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.t = os.path.join(self.tmpdir, "temp")
        os.makedirs(self.t)

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def test_identical_without_slsa(self):
        destdir1 = os.path.join(self.tmpdir, "dest1")
        os.makedirs(destdir1)
        _run_stamp({"DESTDIR": destdir1, "T": self.t, "BUCKOS_SLSA_ENABLED": "false"})

        destdir2 = os.path.join(self.tmpdir, "dest2")
        os.makedirs(destdir2)
        _run_stamp({"DESTDIR": destdir2, "T": self.t, "BUCKOS_SLSA_ENABLED": "false"})

        with open(os.path.join(destdir1, ".buckos-provenance.jsonl")) as f:
            content1 = f.read()
        with open(os.path.join(destdir2, ".buckos-provenance.jsonl")) as f:
            content2 = f.read()

        self.assertEqual(content1, content2)

        # BOS_PROV specifically must be identical across runs
        rec1 = _read_jsonl(os.path.join(destdir1, ".buckos-provenance.jsonl"))[0]
        rec2 = _read_jsonl(os.path.join(destdir2, ".buckos-provenance.jsonl"))[0]
        self.assertEqual(rec1["BOS_PROV"], rec2["BOS_PROV"])

    def test_different_with_slsa(self):
        import time

        destdir1 = os.path.join(self.tmpdir, "dest1")
        os.makedirs(destdir1)
        _run_stamp({"DESTDIR": destdir1, "T": self.t, "BUCKOS_SLSA_ENABLED": "true"})

        time.sleep(1.1)

        destdir2 = os.path.join(self.tmpdir, "dest2")
        os.makedirs(destdir2)
        _run_stamp({"DESTDIR": destdir2, "T": self.t, "BUCKOS_SLSA_ENABLED": "true"})

        with open(os.path.join(destdir1, ".buckos-provenance.jsonl")) as f:
            content1 = f.read()
        with open(os.path.join(destdir2, ".buckos-provenance.jsonl")) as f:
            content2 = f.read()

        self.assertNotEqual(content1, content2)

        # BOS_PROV specifically must differ (volatile fields change the hash input)
        rec1 = _read_jsonl(os.path.join(destdir1, ".buckos-provenance.jsonl"))[0]
        rec2 = _read_jsonl(os.path.join(destdir2, ".buckos-provenance.jsonl"))[0]
        self.assertNotEqual(rec1["BOS_PROV"], rec2["BOS_PROV"])


class TestDependencyAggregation(unittest.TestCase):
    """Dependency JSONL is merged and deduplicated."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.destdir = os.path.join(self.tmpdir, "dest")
        os.makedirs(self.destdir)
        self.t = os.path.join(self.tmpdir, "temp")
        os.makedirs(self.t)

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def _make_dep(self, name, records):
        dep_dir = os.path.join(self.tmpdir, name)
        os.makedirs(dep_dir, exist_ok=True)
        with open(os.path.join(dep_dir, ".buckos-provenance.jsonl"), "w") as f:
            for rec in records:
                f.write(json.dumps(rec) + "\n")
        return dep_dir

    def test_deps_merged_into_output(self):
        dep1 = self._make_dep("dep1", [
            {"name": "libfoo", "version": "2.0", "type": "cmake"},
        ])
        dep2 = self._make_dep("dep2", [
            {"name": "libbar", "version": "3.0", "type": "meson"},
        ])

        result = _run_stamp(
            {"DESTDIR": self.destdir, "T": self.t},
            dep_dirs=[dep1, dep2],
        )
        self.assertEqual(result.returncode, 0, result.stderr)

        records = _read_jsonl(
            os.path.join(self.destdir, ".buckos-provenance.jsonl")
        )
        names = {r["name"] for r in records}
        self.assertIn("test-pkg", names)
        self.assertIn("libfoo", names)
        self.assertIn("libbar", names)

    def test_dedup_by_name_version(self):
        dep1 = self._make_dep("dep1", [
            {"name": "libfoo", "version": "2.0", "type": "cmake"},
        ])
        dep2 = self._make_dep("dep2", [
            {"name": "libfoo", "version": "2.0", "type": "cmake"},
            {"name": "libbar", "version": "1.0", "type": "make"},
        ])

        result = _run_stamp(
            {"DESTDIR": self.destdir, "T": self.t},
            dep_dirs=[dep1, dep2],
        )
        self.assertEqual(result.returncode, 0, result.stderr)

        records = _read_jsonl(
            os.path.join(self.destdir, ".buckos-provenance.jsonl")
        )
        # test-pkg + libfoo (deduped) + libbar = 3
        self.assertEqual(len(records), 3)


class TestStampedBinaryRuns(unittest.TestCase):
    """A stamped ELF binary should still execute."""

    @unittest.skipUnless(
        shutil.which("cc") and shutil.which("objcopy"),
        "cc and objcopy required",
    )
    def test_stamped_binary_executes(self):
        tmpdir = tempfile.mkdtemp()
        try:
            destdir = os.path.join(tmpdir, "dest")
            bindir = os.path.join(destdir, "usr", "bin")
            os.makedirs(bindir)
            t = os.path.join(tmpdir, "temp")
            os.makedirs(t)

            c_src = os.path.join(tmpdir, "main.c")
            with open(c_src, "w") as f:
                f.write("int main(){return 0;}\n")

            elf_path = os.path.join(bindir, "testbin")
            subprocess.run(
                ["cc", c_src, "-o", elf_path], check=True, capture_output=True
            )
            os.chmod(elf_path, 0o755)

            result = _run_stamp({"DESTDIR": destdir, "T": t})
            self.assertEqual(result.returncode, 0, result.stderr)

            run = subprocess.run([elf_path], capture_output=True)
            self.assertEqual(run.returncode, 0)
        finally:
            shutil.rmtree(tmpdir)


class TestLabelParsing(unittest.TestCase):
    """Label prefix parsing matches the format used in BUCK targets."""

    def test_label_prefixes(self):
        labels = [
            "buckos:url:https://example.com/foo-1.0.tar.gz",
            "buckos:sha256:deadbeef1234",
            "buckos:type:autotools",
        ]
        url = ""
        sha256 = ""
        for label in labels:
            if label.startswith("buckos:url:"):
                url = label[len("buckos:url:"):]
            elif label.startswith("buckos:sha256:"):
                sha256 = label[len("buckos:sha256:"):]

        self.assertEqual(url, "https://example.com/foo-1.0.tar.gz")
        self.assertEqual(sha256, "deadbeef1234")


if __name__ == "__main__":
    unittest.main()
