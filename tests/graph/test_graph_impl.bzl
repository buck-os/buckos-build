"""Test implementation: cross-reference label assignment."""

load("//tests/graph:helpers.bzl", "assert_result", "starts_with", "target_exists", "target_has_label", "summarize")

def _target_has_label_prefix(query, target_pattern, prefix):
    """Check whether a target has any label starting with prefix (with non-empty value)."""
    target_set = query.eval(target_pattern)
    for t in target_set:
        labels = t.get_attr("labels")
        if labels != None:
            for l in labels:
                if starts_with(l, prefix) and len(l) > len(prefix):
                    return True
    return False

def _check_compile_labels(ctx, query, results, target_label, display_name, build_system):
    """Verify a build target has buckos:compile and buckos:build:<system>."""
    if not target_exists(query, target_label):
        assert_result(
            ctx, results,
            "{} target exists".format(display_name),
            False,
            "{} does not exist".format(target_label),
        )
        return

    assert_result(
        ctx, results,
        "{} has buckos:compile label".format(display_name),
        target_has_label(query, target_label, "buckos:compile"),
        "buckos:compile not found on {}".format(target_label),
    )

    expected = "buckos:build:" + build_system
    assert_result(
        ctx, results,
        "{} has {} label".format(display_name, expected),
        target_has_label(query, target_label, expected),
        "{} not found on {}".format(expected, target_label),
    )

def run(ctx):
    """Cross-reference label assignment on compile, prebuilt, image, bootscript, and config targets.

    Returns:
        (passed, failed) tuple.
    """
    query = ctx.uquery()
    results = []

    # ================================================================
    # Compile targets have expected labels.
    #
    # Extends test_labels.bxl with additional known compile targets
    # to cross-reference the label system.
    # ================================================================

    compile_targets = [
        # Core
        ("//packages/linux/core/zlib:zlib-build", "zlib", "autotools"),
        ("//packages/linux/core/musl:musl-build", "musl", "autotools"),
        ("//packages/linux/core/busybox:busybox-build", "busybox", "autotools"),
        # Network / crypto
        ("//packages/linux/system/libs/network/curl:curl-build", "curl", "autotools"),
        ("//packages/linux/system/libs/crypto/openssl:openssl-3.6-build", "openssl-3.6", "autotools"),
        ("//packages/linux/system/libs/crypto/openssl:openssl-3.3-build", "openssl-3.3", "autotools"),
    ]

    for target_label, display_name, build_system in compile_targets:
        _check_compile_labels(ctx, query, results, target_label, display_name, build_system)

    # ================================================================
    # Prebuilt targets have buckos:prebuilt label.
    # ================================================================

    # Query all targets and check for prebuilt label presence
    all_targets = query.eval("//...")
    prebuilt_count = 0
    for t in all_targets:
        labels = t.get_attr("labels")
        if labels != None:
            for l in labels:
                if l == "buckos:prebuilt":
                    prebuilt_count += 1

    # TODO: enable once prebuilt targets exist
    # assert_result(
    #     ctx, results,
    #     "prebuilt targets exist in graph",
    #     prebuilt_count > 0,
    #     "no targets with buckos:prebuilt label found",
    # )

    # ================================================================
    # Image, bootscript, and config targets have their labels.
    # ================================================================

    image_count = 0
    bootscript_count = 0
    config_count = 0

    all_targets_2 = query.eval("//...")
    for t in all_targets_2:
        labels = t.get_attr("labels")
        if labels != None:
            for l in labels:
                if l == "buckos:image":
                    image_count += 1
                if l == "buckos:bootscript":
                    bootscript_count += 1
                if l == "buckos:config":
                    config_count += 1

    assert_result(
        ctx, results,
        "image targets exist (buckos:image)",
        image_count > 0,
        "no targets with buckos:image found",
    )

    assert_result(
        ctx, results,
        "bootscript targets exist (buckos:bootscript)",
        bootscript_count > 0,
        "no targets with buckos:bootscript found",
    )

    assert_result(
        ctx, results,
        "config targets exist (buckos:config)",
        config_count > 0,
        "no targets with buckos:config found",
    )

    # ================================================================
    # Provenance from src_uri: compile targets with url labels must
    # also have source and sig labels.
    # ================================================================

    provenance_missing = []
    all_targets_3 = query.eval("//...")
    for t in all_targets_3:
        labels = t.get_attr("labels")
        if labels == None:
            continue

        is_compile = False
        has_url = False
        has_source = False
        has_sig = False

        for l in labels:
            if l == "buckos:compile":
                is_compile = True
            if starts_with(l, "buckos:url:") and len(l) > len("buckos:url:"):
                has_url = True
            if starts_with(l, "buckos:source:") and len(l) > len("buckos:source:"):
                has_source = True
            if starts_with(l, "buckos:sig:") and len(l) > len("buckos:sig:"):
                has_sig = True

        if is_compile and has_url:
            if not (has_source and has_sig):
                provenance_missing.append(str(t.label))

    assert_result(
        ctx, results,
        "compile+url targets have source and sig labels",
        len(provenance_missing) == 0,
        "{} target(s) with url but missing source/sig (first: {})".format(
            len(provenance_missing),
            provenance_missing[0] if provenance_missing else "n/a",
        ),
    )

    # ================================================================
    # Known package patterns resolve to targets.
    #
    # Verifies that querying common package subtrees returns results,
    # confirming the BUCK files are loadable.
    # ================================================================

    package_patterns = [
        "//packages/linux/core/...",
        "//packages/linux/system/...",
    ]

    for pattern in package_patterns:
        pattern_targets = query.eval(pattern)
        pattern_count = 0
        for _t in pattern_targets:
            pattern_count += 1

        assert_result(
            ctx, results,
            "{} returns targets".format(pattern),
            pattern_count > 0,
            "{} returned 0 targets".format(pattern),
        )

    return summarize(ctx, results)
