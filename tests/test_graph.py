"""Cross-reference AST-parsed BUCK files against buck2 uquery output."""
from __future__ import annotations

from tests.buck_parser import COMPILE_RULES, PREBUILT_RULES, IMAGE_RULES, BOOTSCRIPT_RULES, CONFIG_RULES, BuckTarget


def test_parser_coverage(parsed_buck_targets: list[BuckTarget]):
    """AST parser should find a substantial number of labeled targets."""
    assert len(parsed_buck_targets) > 1500, (
        f"Parser found only {len(parsed_buck_targets)} targets, expected >1500"
    )


def test_explicit_labels_in_buck2(
    parsed_buck_targets: list[BuckTarget],
    all_target_labels: dict[str, list[str]],
):
    """Every explicit label in a BUCK file must appear in buck2 output."""
    missing = []
    for t in parsed_buck_targets:
        if not t.labels:
            continue
        buck2_labels = all_target_labels.get(t.target, [])
        if not buck2_labels:
            continue  # target existence checked separately
        for label in t.labels:
            if label not in buck2_labels:
                missing.append(f"{t.target}: BUCK has {label!r}, not in buck2")
    assert not missing, "Explicit labels dropped:\n" + "\n".join(missing[:30])


def test_compile_targets_have_expected_labels(
    parsed_buck_targets: list[BuckTarget],
    all_target_labels: dict[str, list[str]],
):
    """Compile macros must inject buckos:compile + buckos:build:<type>."""
    missing = []
    for t in parsed_buck_targets:
        if t.rule_type not in COMPILE_RULES:
            continue
        buck2_labels = all_target_labels.get(t.target, [])
        if not buck2_labels:
            continue
        if "buckos:compile" not in buck2_labels:
            missing.append(f"{t.target} ({t.rule_type}): missing buckos:compile")
        build_type = COMPILE_RULES[t.rule_type]
        if build_type:
            expected = f"buckos:build:{build_type}"
            if expected not in buck2_labels:
                missing.append(f"{t.target} ({t.rule_type}): missing {expected}")
    assert not missing, "Auto-injected compile labels missing:\n" + "\n".join(missing[:30])


def test_prebuilt_targets_have_label(
    parsed_buck_targets: list[BuckTarget],
    all_target_labels: dict[str, list[str]],
):
    """binary_package / precompiled_package must get buckos:prebuilt."""
    missing = []
    for t in parsed_buck_targets:
        if t.rule_type not in PREBUILT_RULES:
            continue
        buck2_labels = all_target_labels.get(t.target, [])
        if buck2_labels and "buckos:prebuilt" not in buck2_labels:
            missing.append(t.target)
    assert not missing, f"Prebuilt targets missing buckos:prebuilt: {missing[:20]}"


def test_image_bootscript_config_labels(
    parsed_buck_targets: list[BuckTarget],
    all_target_labels: dict[str, list[str]],
):
    """Image/bootscript/config macros must get their respective labels."""
    rule_to_label: dict[str, str] = {}
    for r in IMAGE_RULES:
        rule_to_label[r] = "buckos:image"
    for r in BOOTSCRIPT_RULES:
        rule_to_label[r] = "buckos:bootscript"
    for r in CONFIG_RULES:
        rule_to_label[r] = "buckos:config"

    missing = []
    for t in parsed_buck_targets:
        expected = rule_to_label.get(t.rule_type)
        if not expected:
            continue
        buck2_labels = all_target_labels.get(t.target, [])
        if buck2_labels and expected not in buck2_labels:
            missing.append(f"{t.target} ({t.rule_type}): missing {expected}")
    assert not missing, "Category labels missing:\n" + "\n".join(missing[:20])


def test_provenance_from_src_uri(
    parsed_buck_targets: list[BuckTarget],
    all_target_labels: dict[str, list[str]],
):
    """Targets with src_uri in BUCK should have provenance labels in buck2."""
    missing = []
    for t in parsed_buck_targets:
        if not t.src_uri or t.rule_type not in COMPILE_RULES:
            continue
        buck2_labels = all_target_labels.get(t.target, [])
        if not buck2_labels:
            continue
        has_url = any(l.startswith("buckos:url:") for l in buck2_labels)
        has_source = any(l.startswith("buckos:source:") for l in buck2_labels)
        has_sig = any(l.startswith("buckos:sig:") for l in buck2_labels)
        if not (has_url and has_source and has_sig):
            missing.append(f"{t.target}: src_uri in BUCK but missing url/source/sig")
    assert not missing, "Provenance labels missing:\n" + "\n".join(missing[:20])


def test_buck_targets_exist_in_buck2(
    parsed_buck_targets: list[BuckTarget],
    all_targets: list[str],
):
    """Every target defined in a BUCK file should exist in buck2 output."""
    buck2_set = set(all_targets)
    missing = [t.target for t in parsed_buck_targets if t.target not in buck2_set]
    assert not missing, (
        f"Targets in BUCK but not in buck2 ({len(missing)}):\n"
        + "\n".join(missing[:30])
    )
