"""Parse BUCK files with Python's ast module to extract target definitions."""
from __future__ import annotations

import ast
import dataclasses
import warnings
from pathlib import Path


@dataclasses.dataclass
class BuckTarget:
    buck_path: str
    cell_path: str
    rule_type: str
    name: str
    target: str
    labels: list[str]
    src_uri: str | None
    sha256: str | None


# Compile macros: rule name -> buckos:build:<type> (None = no build type)
COMPILE_RULES: dict[str, str | None] = {
    "cmake_package": "cmake",
    "meson_package": "meson",
    "autotools_package": "autotools",
    "make_package": "make",
    "cargo_package": "cargo",
    "go_package": "go",
    "ebuild_package": None,
    "perl_package": "perl",
    "ruby_package": "ruby",
    "font_package": "font",
    "npm_package": "npm",
    "python_package": "python",
    "java_package": "java",
    "maven_package": "maven",
    "qt6_package": "qt6",
}

PREBUILT_RULES = {"binary_package", "precompiled_package"}
IMAGE_RULES = {"rootfs", "initramfs", "iso_image", "raw_disk_image", "stage3_tarball"}
BOOTSCRIPT_RULES = {"qemu_boot_script", "ch_boot_script"}
CONFIG_RULES = {"kernel_config"}

LABELED_RULES = set(COMPILE_RULES) | PREBUILT_RULES | IMAGE_RULES | BOOTSCRIPT_RULES | CONFIG_RULES


def _get_str(node: ast.expr) -> str | None:
    """Extract a string value from an AST node, or None if not a simple constant."""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    return None


def _get_str_list(node: ast.expr) -> list[str] | None:
    """Extract a list of strings from an AST node, or None if not a simple list."""
    if isinstance(node, ast.List):
        result = []
        for elt in node.elts:
            s = _get_str(elt)
            if s is None:
                return None
            result.append(s)
        return result
    return None


def _parse_one(buck_path: Path, repo_root: Path) -> list[BuckTarget]:
    """Parse a single BUCK file and return its labeled targets."""
    source = buck_path.read_text()
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", SyntaxWarning)
        warnings.simplefilter("ignore", DeprecationWarning)
        try:
            tree = ast.parse(source, str(buck_path))
        except SyntaxError:
            return []

    cell_path = str(buck_path.parent.relative_to(repo_root))
    targets = []

    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        if not (isinstance(node.func, ast.Name) and node.func.id in LABELED_RULES):
            continue

        rule_type = node.func.id
        kwargs = {kw.arg: kw.value for kw in node.keywords if kw.arg is not None}

        name_node = kwargs.get("name")
        if name_node is None:
            continue
        name = _get_str(name_node)
        if name is None:
            continue

        labels_node = kwargs.get("labels")
        labels = _get_str_list(labels_node) if labels_node else []
        if labels is None:
            labels = []

        src_uri = _get_str(kwargs["src_uri"]) if "src_uri" in kwargs else None
        sha256 = _get_str(kwargs["sha256"]) if "sha256" in kwargs else None

        targets.append(BuckTarget(
            buck_path=str(buck_path.relative_to(repo_root)),
            cell_path=cell_path,
            rule_type=rule_type,
            name=name,
            target=f"root//{cell_path}:{name}",
            labels=labels,
            src_uri=src_uri,
            sha256=sha256,
        ))

    return targets


def parse_buck_files(packages_dir: Path) -> list[BuckTarget]:
    """Parse all BUCK files under packages_dir and return labeled target definitions."""
    repo_root = packages_dir.parent
    targets = []
    for buck_path in sorted(packages_dir.rglob("BUCK")):
        targets.extend(_parse_one(buck_path, repo_root))
    return targets
