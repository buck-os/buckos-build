from __future__ import annotations

import pytest


def test_all_targets_parse(all_targets: list[str]):
    """Listing all targets returns a reasonable count (catches silent breakage)."""
    assert len(all_targets) > 2000, (
        f"Expected >2000 targets, got {len(all_targets)}; "
        "buck2 targets //... may be silently broken"
    )


def test_no_duplicate_targets(all_targets: list[str]):
    """No target should appear more than once in buck2 targets output."""
    seen: set[str] = set()
    dupes: list[str] = []
    for t in all_targets:
        if t in seen:
            dupes.append(t)
        seen.add(t)
    assert not dupes, f"Duplicate targets: {dupes[:20]}"


def test_bzl_files_load(buck2):
    """Build rule definitions and toolchains parse without error."""
    result_defs = buck2("targets", "//defs:", check=False)
    assert result_defs.returncode == 0, f"//defs: failed:\n{result_defs.stderr}"

    result_tc = buck2("targets", "//toolchains/...")
    assert result_tc.returncode == 0, f"//toolchains/... failed:\n{result_tc.stderr}"


@pytest.mark.timeout(600)
def test_smoke_build_zlib(buck2):
    """Smoke test: zlib actually builds."""
    result = buck2("build",
                    "--config", "buckos.use_host_toolchain=true",
                    "//packages/linux/core/zlib:zlib", timeout=600)
    assert result.returncode == 0, f"zlib build failed:\n{result.stderr}"
