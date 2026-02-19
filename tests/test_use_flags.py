"""Tests for .buckconfig-based USE flag resolution.

Verifies the resolution order:
  1. Package use_defaults
  2. Global [use] section
  3. Per-package [use.PKGNAME] section

Uses buck2 uquery with --config/--config-file overrides to exercise each layer.
Tests run sequentially; buck2 is killed before the first test to avoid
stale daemons.
"""
from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path

import pytest

TARGET = "//tests/fixtures/use-flags:test-use-flags"


@pytest.fixture(scope="module", autouse=True)
def _kill_buck2():
    """Kill any lingering buck2 daemons before running this module."""
    subprocess.run(["killall", "buck2"], capture_output=True)


def _uquery_use_flags(buck2, *extra_args: str) -> list[str]:
    """Run buck2 uquery and extract the use_flags attribute."""
    result = buck2(
        "uquery",
        TARGET,
        "--output-attribute", "use_flags",
        "--json",
        *extra_args,
        check=True,
    )
    data = json.loads(result.stdout)
    # buck2 uquery keys are prefixed with cell name (e.g. "root//...")
    for key, attrs in data.items():
        if key.endswith(TARGET.lstrip("/")) or key == TARGET:
            return sorted(attrs.get("use_flags", []))
    return []


def _uquery_with_config_file(buck2, ini_content: str) -> list[str]:
    """Write a temp buckconfig file and query with --config-file."""
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".buckconfig", delete=False
    ) as f:
        f.write(ini_content)
        f.flush()
        return _uquery_use_flags(buck2, "--config-file", f.name)


def test_target_count(buck2):
    """Smoke test: the migration must not break target parsing."""
    result = buck2("targets", "//...", timeout=300)
    targets = [l for l in result.stdout.splitlines() if l.strip()]
    assert len(targets) > 7000, (
        f"Expected >7000 targets, got {len(targets)}"
    )


class TestUseDefaults:
    """Layer 1: package use_defaults with no buckconfig overrides."""

    def test_defaults_only(self, buck2):
        """With all [use] flags unset, only use_defaults should be active."""
        flags = _uquery_use_flags(
            buck2,
            "--config", "use.ssl=",
            "--config", "use.ipv6=",
            "--config", "use.threads=",
            "--config", "use.unicode=",
        )
        # use_defaults = ["ssl"]; empty [use] ssl = no override → ssl stays
        assert "ssl" in flags


class TestGlobalEnable:
    """Layer 2: global [use] section enables a flag."""

    def test_global_enable_zstd(self, buck2):
        """[use] zstd = true should add zstd to effective flags."""
        flags = _uquery_use_flags(
            buck2,
            "--config", "use.zstd=true",
        )
        assert "zstd" in flags

    def test_global_enable_debug(self, buck2):
        """[use] debug = true should add debug."""
        flags = _uquery_use_flags(
            buck2,
            "--config", "use.debug=true",
        )
        assert "debug" in flags


class TestGlobalDisable:
    """Layer 2: global [use] section disables a flag from use_defaults."""

    def test_global_disable_ssl(self, buck2):
        """[use] ssl = false should remove ssl despite use_defaults."""
        flags = _uquery_use_flags(
            buck2,
            "--config", "use.ssl=false",
        )
        assert "ssl" not in flags


class TestPerPackageOverride:
    """Layer 3: [use.PKGNAME] overrides global [use].

    Per-package sections have dots in section names ([use.test-use-flags])
    which can't be expressed via --config key=val. We use --config-file.
    """

    def test_per_package_enable(self, buck2):
        """[use] ssl = false + [use.test-use-flags] ssl = true -> ssl enabled."""
        flags = _uquery_with_config_file(buck2, "\n".join([
            "[use]",
            "  ssl = false",
            "[use.test-use-flags]",
            "  ssl = true",
        ]))
        assert "ssl" in flags

    def test_per_package_disable(self, buck2):
        """[use] ssl = true + [use.test-use-flags] ssl = false -> ssl disabled."""
        flags = _uquery_with_config_file(buck2, "\n".join([
            "[use]",
            "  ssl = true",
            "[use.test-use-flags]",
            "  ssl = false",
        ]))
        assert "ssl" not in flags


class TestUnsetPassthrough:
    """Unset keys in [use.PKGNAME] fall through to global [use]."""

    def test_unset_falls_through(self, buck2):
        """[use] zstd = true, no [use.test-use-flags] zstd -> zstd enabled."""
        flags = _uquery_use_flags(
            buck2,
            "--config", "use.zstd=true",
        )
        assert "zstd" in flags
