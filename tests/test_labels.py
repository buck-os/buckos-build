from __future__ import annotations


def targets_with_label(labels_dict: dict[str, list[str]], prefix: str) -> set[str]:
    """Return targets that have any label starting with prefix."""
    return {t for t, labels in labels_dict.items() if any(l.startswith(prefix) for l in labels)}


def targets_matching(labels_dict: dict[str, list[str]], exact: str) -> set[str]:
    """Return targets that have an exact label match."""
    return {t for t, labels in labels_dict.items() if exact in labels}


# --- Auto-injected label categories (commits 3a1d1b1, 6647860) ---

def test_compile_targets_exist(all_target_labels: dict[str, list[str]]):
    """buckos:compile is auto-injected on all ebuild-based packages."""
    compile_targets = targets_matching(all_target_labels, "buckos:compile")
    assert len(compile_targets) > 100, (
        f"Expected >100 compile targets, got {len(compile_targets)}"
    )


def test_download_targets_exist(all_target_labels: dict[str, list[str]]):
    """buckos:download is auto-injected on source download targets."""
    download_targets = targets_matching(all_target_labels, "buckos:download")
    assert len(download_targets) > 100, (
        f"Expected >100 download targets, got {len(download_targets)}"
    )


def test_build_type_targets_exist(all_target_labels: dict[str, list[str]]):
    """buckos:build:* is auto-injected with the build system type."""
    build_targets = targets_with_label(all_target_labels, "buckos:build:")
    assert len(build_targets) > 100, (
        f"Expected >100 build-type targets, got {len(build_targets)}"
    )


def test_image_targets_exist(all_target_labels: dict[str, list[str]]):
    """buckos:image is auto-injected on rootfs/initramfs/iso/disk targets."""
    image_targets = targets_matching(all_target_labels, "buckos:image")
    assert len(image_targets) > 0, "No targets with buckos:image label found"


def test_bootscript_targets_exist(all_target_labels: dict[str, list[str]]):
    """buckos:bootscript is auto-injected on qemu/ch boot scripts."""
    boot_targets = targets_matching(all_target_labels, "buckos:bootscript")
    assert len(boot_targets) > 0, "No targets with buckos:bootscript label found"


def test_config_targets_exist(all_target_labels: dict[str, list[str]]):
    """buckos:config is auto-injected on kernel_config targets."""
    config_targets = targets_matching(all_target_labels, "buckos:config")
    assert len(config_targets) > 0, "No targets with buckos:config label found"


def test_prebuilt_targets_exist(all_target_labels: dict[str, list[str]]):
    """buckos:prebuilt is auto-injected on binary_package/precompiled_package."""
    prebuilt_targets = targets_matching(all_target_labels, "buckos:prebuilt")
    assert len(prebuilt_targets) > 10, (
        f"Expected >10 prebuilt targets, got {len(prebuilt_targets)}"
    )


# --- Manual label categories (commit 58bd881) ---

def test_firmware_targets_exist(all_target_labels: dict[str, list[str]]):
    """buckos:firmware is manually applied to firmware/microcode targets."""
    firmware_targets = targets_matching(all_target_labels, "buckos:firmware")
    assert len(firmware_targets) > 0, "No targets with buckos:firmware label found"


def test_hw_targets_exist(all_target_labels: dict[str, list[str]]):
    """buckos:hw:* labels exist for hardware-specific targets."""
    hw_targets = targets_with_label(all_target_labels, "buckos:hw:")
    assert len(hw_targets) > 0, "No targets with buckos:hw:* labels found"


# --- Compile targets must have build type ---

def test_compile_targets_have_build_type(all_target_labels: dict[str, list[str]]):
    """Every buckos:compile target should also have a buckos:build:* label."""
    compile_targets = {
        t: labels for t, labels in all_target_labels.items()
        if "buckos:compile" in labels
    }
    missing = [
        t for t, labels in compile_targets.items()
        if not any(l.startswith("buckos:build:") for l in labels)
    ]
    coverage = 1 - len(missing) / len(compile_targets) if compile_targets else 0
    assert coverage >= 0.95, (
        f"Only {coverage:.1%} of compile targets have buckos:build:* "
        f"({len(missing)} missing, e.g. {missing[:5]})"
    )


# --- Label format invariants ---

def test_no_empty_sha256_labels(all_target_labels: dict[str, list[str]]):
    """No target should have a bare 'buckos:sha256:' label (empty value)."""
    bad = [t for t, labels in all_target_labels.items() if "buckos:sha256:" in labels]
    assert not bad, f"Targets with empty buckos:sha256: label: {bad[:20]}"


def test_no_empty_url_labels(all_target_labels: dict[str, list[str]]):
    """No target should have a bare 'buckos:url:' label (empty value)."""
    bad = [t for t, labels in all_target_labels.items() if "buckos:url:" in labels]
    assert not bad, f"Targets with empty buckos:url: label: {bad[:20]}"


def test_no_empty_source_labels(all_target_labels: dict[str, list[str]]):
    """No target should have a bare 'buckos:source:' label (empty value)."""
    bad = [t for t, labels in all_target_labels.items() if "buckos:source:" in labels]
    assert not bad, f"Targets with empty buckos:source: label: {bad[:20]}"
