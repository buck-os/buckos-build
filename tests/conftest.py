from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest


def _find_repo_root() -> Path:
    """Walk up from this file looking for .buckroot."""
    d = Path(__file__).resolve().parent
    while d != d.parent:
        if (d / ".buckroot").exists():
            return d
        d = d.parent
    pytest.fail("Could not find .buckroot in any parent directory")


def _parse_uquery_labels(stdout: str) -> dict[str, list[str]]:
    """Parse buck2 uquery --output-attribute labels output into {target: [labels]}."""
    # Strip non-JSON lines (e.g. Build ID on stderr mixed in)
    lines = stdout.strip().splitlines()
    json_start = next((i for i, l in enumerate(lines) if l.strip().startswith("{")), None)
    if json_start is None:
        return {}
    json_text = "\n".join(lines[json_start:])
    try:
        data = json.loads(json_text)
    except json.JSONDecodeError:
        # Fallback: regex extraction
        result: dict[str, list[str]] = {}
        for m in re.finditer(
            r'"(root//[^"]+)":\s*\{[^}]*"labels":\s*\[([^\]]*)\]',
            stdout,
            re.DOTALL,
        ):
            target = m.group(1)
            labels = [s.strip().strip('"') for s in m.group(2).split(",") if s.strip()]
            result[target] = labels
        return result

    result = {}
    for target, attrs in data.items():
        result[target] = attrs.get("labels", [])
    return result


@pytest.fixture(scope="session")
def repo_root() -> Path:
    return _find_repo_root()


@pytest.fixture(scope="session")
def buck2(repo_root: Path):
    """Callable wrapper: buck2("targets", "//...") -> CompletedProcess.

    Skips all tests if buck2 is not on PATH.
    """
    buck2_path = shutil.which("buck2")
    if buck2_path is None:
        pytest.skip("buck2 not found on PATH")

    def _run(*args: str, check: bool = True, timeout: int = 120) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["buck2", *args],
            cwd=repo_root,
            capture_output=True,
            text=True,
            check=check,
            timeout=timeout,
        )

    return _run


@pytest.fixture(scope="session")
def all_targets(buck2) -> list[str]:
    """Cached list of all targets from buck2 targets //..."""
    result = buck2("targets", "//...")
    targets = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    return targets


@pytest.fixture(scope="session")
def all_target_labels(buck2) -> dict[str, list[str]]:
    """Cached mapping of target -> labels from buck2 uquery."""
    result = buck2(
        "uquery", "//...", "--output-attribute", "labels", "--json",
        timeout=120,
    )
    return _parse_uquery_labels(result.stdout)


@pytest.fixture(scope="session")
def parsed_buck_targets(repo_root: Path):
    """AST-parsed target definitions from BUCK files under packages/."""
    from tests.buck_parser import parse_buck_files
    return parse_buck_files(repo_root / "packages")
