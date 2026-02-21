"""Test implementation: Cloud Hypervisor target validation."""

load("//tests/graph:helpers.bzl", "assert_result", "starts_with", "summarize")

CH_TARGET = "buckos//packages/linux/emulation/utilities/cloud-hypervisor:cloud-hypervisor"

BOOT_SCRIPT_NAMES = [
    "ch-boot-debug",
    "ch-boot-direct",
    "ch-boot-direct-full",
    "ch-boot-direct-minimal",
    "ch-boot-firmware-pvh",
    "ch-boot-firmware-uefi",
    "ch-boot-virtiofs",
    "ch-boot-virtiofs-full",
]

SYSTEM_IMAGE_NAMES = [
    "ch-minimal-rootfs",
    "ch-base-rootfs",
    "ch-full-rootfs",
    "ch-initramfs",
    "ch-initramfs-virtiofs",
    "ch-minimal-disk",
    "ch-base-disk",
    "ch-full-disk",
    "ch-full-disk-gpt",
]

def _has_match(haystack, needle):
    for item in haystack:
        if needle in item:
            return True
    return False

def _has_suffix(haystack, suffix):
    for item in haystack:
        if item.endswith(suffix):
            return True
    return False

def run(ctx):
    """Verify Cloud Hypervisor targets, labels, and USE flags.

    Returns:
        (passed, failed) tuple.
    """
    results = []

    all_nodes = ctx.uquery().eval("buckos//packages/linux/...")
    all_targets = [str(t.label) for t in all_nodes]

    # -- CH binary target exists --
    ch_found = False
    for t in all_targets:
        if t.endswith(":cloud-hypervisor") and ":cloud-hypervisor-" not in t:
            ch_found = True
            break
    assert_result(ctx, results,
        "cloud-hypervisor binary target exists",
        ch_found,
        "cloud-hypervisor binary target not found")

    # -- Boot script targets --
    boot_targets = [t for t in all_targets if "cloud-hypervisor-boot:" in t and ":ch-boot-" in t]
    for name in BOOT_SCRIPT_NAMES:
        assert_result(ctx, results,
            "boot script {} exists".format(name),
            _has_match(boot_targets, name),
            "Missing boot script target: " + name)

    # -- System image targets --
    sys_targets = [t for t in all_targets if "system/cloud-hypervisor:" in t]
    for name in SYSTEM_IMAGE_NAMES:
        assert_result(ctx, results,
            "system image {} exists".format(name),
            _has_match(sys_targets, name),
            "Missing system image target: " + name)

    # -- Kernel targets --
    assert_result(ctx, results,
        "buckos-kernel-ch target exists",
        _has_suffix(all_targets, ":buckos-kernel-ch"),
        "buckos-kernel-ch not found")
    assert_result(ctx, results,
        "buckos-ch-guest target exists",
        _has_suffix(all_targets, ":buckos-ch-guest"),
        "buckos-ch-guest not found")

    # -- Labels on CH target --
    ch_nodes = ctx.uquery().eval(CH_TARGET)
    for node in ch_nodes:
        labels_attr = node.get_attr("labels")
        labels = list(labels_attr) if labels_attr != None else []
        assert_result(ctx, results,
            "CH target has buckos:compile label",
            "buckos:compile" in labels,
            "CH target missing buckos:compile label")
        assert_result(ctx, results,
            "CH target has buckos:build:cargo label",
            "buckos:build:cargo" in labels,
            "CH target missing buckos:build:cargo label")

        # Provenance labels
        has_url = False
        has_sha = False
        for l in labels:
            if starts_with(l, "buckos:url:") and len(l) > len("buckos:url:"):
                has_url = True
            if starts_with(l, "buckos:sha256:") and len(l) > len("buckos:sha256:"):
                has_sha = True
        assert_result(ctx, results,
            "CH target has buckos:url:* provenance label",
            has_url,
            "CH target missing buckos:url:* provenance label")
        assert_result(ctx, results,
            "CH target has buckos:sha256:* provenance label",
            has_sha,
            "CH target missing buckos:sha256:* provenance label")

    # -- Boot script labels --
    boot_nodes = ctx.uquery().eval("buckos//packages/linux/boot/cloud-hypervisor-boot/...")
    boot_with_label = 0
    for node in boot_nodes:
        target = str(node.label)
        if ":ch-boot-" not in target:
            continue
        labels_attr = node.get_attr("labels")
        labels = list(labels_attr) if labels_attr != None else []
        assert_result(ctx, results,
            "{} has buckos:bootscript label".format(target),
            "buckos:bootscript" in labels,
            target + " missing buckos:bootscript label")
        boot_with_label += 1

    assert_result(ctx, results,
        ">=8 boot scripts have buckos:bootscript label",
        boot_with_label >= 8,
        "Expected >=8 labeled boot targets, got {}".format(boot_with_label))

    # -- System image labels --
    image_names = [
        "ch-minimal-rootfs", "ch-base-rootfs", "ch-full-rootfs",
        "ch-initramfs", "ch-initramfs-virtiofs",
        "ch-minimal-disk", "ch-base-disk", "ch-full-disk", "ch-full-disk-gpt",
    ]
    image_nodes = ctx.uquery().eval("buckos//packages/linux/system/cloud-hypervisor/...")
    for node in image_nodes:
        target = str(node.label)
        name = target.split(":")[-1] if ":" in target else ""
        if name not in image_names:
            continue
        labels_attr = node.get_attr("labels")
        labels = list(labels_attr) if labels_attr != None else []
        assert_result(ctx, results,
            "{} has buckos:image label".format(name),
            "buckos:image" in labels,
            target + " missing buckos:image label")

    # -- USE flag defaults --
    ch_nodes_2 = ctx.uquery().eval(CH_TARGET)
    for node in ch_nodes_2:
        use_flags_attr = node.get_attr("use_flags")
        if use_flags_attr != None:
            flags = sorted(list(use_flags_attr))
            assert_result(ctx, results,
                "CH default USE flags are [io-uring, kvm]",
                flags == ["io-uring", "kvm"],
                "CH default USE flags: expected [io-uring, kvm], got " + str(flags))

    return summarize(ctx, results)
