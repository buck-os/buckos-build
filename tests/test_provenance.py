from __future__ import annotations

import re


def _compile_targets_with_url(labels_dict: dict[str, list[str]]) -> dict[str, list[str]]:
    """Return compile targets that have a buckos:url:* label."""
    result = {}
    for target, labels in labels_dict.items():
        is_compile = "buckos:compile" in labels
        has_url = any(l.startswith("buckos:url:") and len(l) > len("buckos:url:") for l in labels)
        if is_compile and has_url:
            result[target] = labels
    return result


def _has_provenance(labels: list[str]) -> bool:
    """Check that a target has full provenance: url, source, sha256|vendor, sig."""
    has_url = any(l.startswith("buckos:url:") and len(l) > len("buckos:url:") for l in labels)
    has_source = any(l.startswith("buckos:source:") and len(l) > len("buckos:source:") for l in labels)
    has_sha256 = any(l.startswith("buckos:sha256:") and len(l) > len("buckos:sha256:") for l in labels)
    has_vendor = any(l.startswith("buckos:vendor:") and len(l) > len("buckos:vendor:") for l in labels)
    has_sig = any(l.startswith("buckos:sig:") and len(l) > len("buckos:sig:") for l in labels)
    return has_url and has_source and (has_sha256 or has_vendor) and has_sig


def test_provenance_completeness(all_target_labels: dict[str, list[str]]):
    """Compile targets with a URL must also have source, sha256, and sig."""
    targets = _compile_targets_with_url(all_target_labels)
    missing = []
    for target, labels in targets.items():
        if not _has_provenance(labels):
            present = [l for l in labels if l.startswith("buckos:")]
            missing.append(f"{target}: has {present}")
    assert not missing, f"Compile targets with URL missing provenance:\n" + "\n".join(missing[:20])


def test_provenance_coverage(all_target_labels: dict[str, list[str]]):
    """At least 95% of compile targets should have full provenance."""
    compile_targets = {
        t: labels for t, labels in all_target_labels.items() if "buckos:compile" in labels
    }
    assert compile_targets, "No compile targets found — fixture may be broken"
    with_provenance = sum(1 for labels in compile_targets.values() if _has_provenance(labels))
    coverage = with_provenance / len(compile_targets)
    assert coverage >= 0.95, (
        f"Provenance coverage {coverage:.1%} < 95% "
        f"({with_provenance}/{len(compile_targets)} compile targets)"
    )


def test_download_targets_full_provenance(all_target_labels: dict[str, list[str]]):
    """100% of download targets must have url + sha256 + source + sig."""
    download_targets = {
        t: labels for t, labels in all_target_labels.items() if "buckos:download" in labels
    }
    missing = []
    for target, labels in download_targets.items():
        if not _has_provenance(labels):
            present = [l for l in labels if l.startswith("buckos:")]
            missing.append(f"{target}: has {present}")
    assert not missing, (
        f"Download targets missing full provenance:\n" + "\n".join(missing[:20])
    )


def test_sha256_labels_valid_hex(all_target_labels: dict[str, list[str]]):
    """All non-placeholder buckos:sha256:VALUE labels must be valid 64-char hex."""
    sha256_re = re.compile(r"^buckos:sha256:([0-9a-f]{64})$")
    # FIXME is a known placeholder for packages not yet fully configured
    placeholders = {"buckos:sha256:FIXME"}
    bad = []
    for target, labels in all_target_labels.items():
        for label in labels:
            if label.startswith("buckos:sha256:") and len(label) > len("buckos:sha256:"):
                if label in placeholders:
                    continue
                if not sha256_re.match(label):
                    bad.append(f"{target}: {label}")
    assert not bad, f"Invalid sha256 labels:\n" + "\n".join(bad[:20])


def test_url_labels_valid(all_target_labels: dict[str, list[str]]):
    """All buckos:url:VALUE labels must start with https:// or http://."""
    bad = []
    for target, labels in all_target_labels.items():
        for label in labels:
            if label.startswith("buckos:url:") and len(label) > len("buckos:url:"):
                url = label[len("buckos:url:"):]
                if not (url.startswith("https://") or url.startswith("http://")):
                    bad.append(f"{target}: {url}")
    assert not bad, f"Invalid URL labels:\n" + "\n".join(bad[:20])
