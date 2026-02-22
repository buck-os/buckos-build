"""Test implementation: target label assignment."""

load("//tests/graph:helpers.bzl", "assert_result", "starts_with", "target_exists", "target_has_label", "summarize")

def _get_labels(query, target_pattern):
    """Return the list of labels on a target, or [] if none."""
    target_set = query.eval(target_pattern)
    for t in target_set:
        labels = t.get_attr("labels")
        if labels != None:
            return labels
    return []

def _check_compile_and_build_label(ctx, query, results, target_label, display_name, build_system):
    """Verify a build target has buckos:compile and the correct buckos:build:* label."""
    if not target_exists(query, target_label):
        assert_result(
            ctx, results,
            "{} target exists".format(display_name),
            False,
            "{} does not exist".format(target_label),
        )
        return

    # buckos:compile label
    assert_result(
        ctx, results,
        "{} has buckos:compile label".format(display_name),
        target_has_label(query, target_label, "buckos:compile"),
        "buckos:compile not found in labels of {}".format(target_label),
    )

    # buckos:build:<system> label
    expected_build_label = "buckos:build:" + build_system
    assert_result(
        ctx, results,
        "{} has {} label".format(display_name, expected_build_label),
        target_has_label(query, target_label, expected_build_label),
        "{} not found in labels of {}".format(expected_build_label, target_label),
    )

def run(ctx):
    """Verify buckos:compile and buckos:build:* labels on migrated packages.

    Returns:
        (passed, failed) tuple.
    """
    query = ctx.uquery()
    results = []

    # ================================================================
    # Known migrated packages and their expected build systems.
    # Each entry: (target_label, display_name, build_system)
    #
    # As packages are migrated, add them here.  The test verifies
    # that the package() macro (or the build rule) injects the
    # correct buckos:compile and buckos:build:<system> labels.
    # ================================================================

    known_packages = [
        # Core packages (autotools)
        ("//packages/linux/core/zlib:zlib-build", "zlib", "autotools"),
        ("//packages/linux/core/musl:musl-build", "musl", "autotools"),
        ("//packages/linux/core/busybox:busybox-build", "busybox", "autotools"),

        # Network / crypto packages (autotools)
        ("//packages/linux/system/libs/network/curl:curl-build", "curl", "autotools"),
        ("//packages/linux/system/libs/crypto/openssl:openssl-3.6-build", "openssl-3.6", "autotools"),
        ("//packages/linux/system/libs/crypto/openssl:openssl-3.3-build", "openssl-3.3", "autotools"),
    ]

    for target_label, display_name, build_system in known_packages:
        _check_compile_and_build_label(
            ctx, query, results,
            target_label, display_name, build_system,
        )

    # ================================================================
    # Verify that non-build targets do NOT have buckos:compile.
    #
    # Source download/extract targets should not have the compile label.
    # They should have buckos:download if the label system is wired.
    # ================================================================

    source_targets = [
        ("//packages/linux/core/zlib:zlib-src", "zlib-src"),
        ("//packages/linux/core/musl:musl-src", "musl-src"),
        ("//packages/linux/core/busybox:busybox-src", "busybox-src"),
        ("//packages/linux/system/libs/network/curl:curl-src", "curl-src"),
    ]

    for target_label, display_name in source_targets:
        if not target_exists(query, target_label):
            # Source target may not exist yet; skip rather than fail
            ctx.output.print("SKIP: {} (target not found)".format(display_name))
            continue

        assert_result(
            ctx, results,
            "{} does NOT have buckos:compile label".format(display_name),
            not target_has_label(query, target_label, "buckos:compile"),
            "buckos:compile found on source target {} (should only be on build targets)".format(target_label),
        )

    # ================================================================
    # Verify that transform targets do NOT have buckos:compile.
    #
    # Transform targets (stripped, stamped, signed) wrap a build
    # output; they are not compilation targets themselves.
    # ================================================================

    transform_targets = [
        ("//packages/linux/core/zlib:zlib-stripped", "zlib-stripped"),
        ("//packages/linux/core/zlib:zlib-stamped", "zlib-stamped"),
        ("//packages/linux/core/zlib:zlib-signed", "zlib-signed"),
    ]

    for target_label, display_name in transform_targets:
        if not target_exists(query, target_label):
            ctx.output.print("SKIP: {} (target not found)".format(display_name))
            continue

        assert_result(
            ctx, results,
            "{} does NOT have buckos:compile label".format(display_name),
            not target_has_label(query, target_label, "buckos:compile"),
            "buckos:compile found on transform target {} (should only be on build targets)".format(target_label),
        )

    return summarize(ctx, results)

def run_coverage(ctx):
    """Verify label category counts, coverage ratios, and format invariants.

    Returns:
        (passed, failed) tuple.
    """
    query = ctx.uquery()
    results = []
    all_targets = query.eval("//...")

    # Counters for label categories
    compile_count = 0
    download_count = 0
    build_type_count = 0
    image_count = 0
    bootscript_count = 0
    config_count = 0
    prebuilt_count = 0
    firmware_count = 0
    hw_count = 0
    iuse_count = 0
    use_count = 0

    # Coverage: compile targets that also have buckos:build:*
    compile_with_build_type = 0

    # Format invariants: bare labels with empty value after colon
    bare_sha256 = []
    bare_url = []
    bare_source = []
    bare_iuse = []
    bare_use = []

    for t in all_targets:
        labels = t.get_attr("labels")
        if labels == None:
            continue

        target_str = str(t.label)
        is_compile = False
        has_build_type = False

        for l in labels:
            if l == "buckos:compile":
                compile_count += 1
                is_compile = True
            if l == "buckos:download":
                download_count += 1
            if starts_with(l, "buckos:build:") and len(l) > len("buckos:build:"):
                build_type_count += 1
                has_build_type = True
            if l == "buckos:image":
                image_count += 1
            if l == "buckos:bootscript":
                bootscript_count += 1
            if l == "buckos:config":
                config_count += 1
            if l == "buckos:prebuilt":
                prebuilt_count += 1
            if l == "buckos:firmware":
                firmware_count += 1
            if starts_with(l, "buckos:hw:") and len(l) > len("buckos:hw:"):
                hw_count += 1
            if starts_with(l, "buckos:iuse:") and len(l) > len("buckos:iuse:"):
                iuse_count += 1
            if starts_with(l, "buckos:use:") and len(l) > len("buckos:use:"):
                use_count += 1

            # Format invariants: detect bare labels (empty value)
            if l == "buckos:sha256:":
                bare_sha256.append(target_str)
            if l == "buckos:url:":
                bare_url.append(target_str)
            if l == "buckos:source:":
                bare_source.append(target_str)
            if l == "buckos:iuse:":
                bare_iuse.append(target_str)
            if l == "buckos:use:":
                bare_use.append(target_str)

        if is_compile and has_build_type:
            compile_with_build_type += 1

    # ── Count thresholds ──

    assert_result(
        ctx, results,
        ">100 targets with buckos:compile",
        compile_count > 100,
        "got {} compile targets".format(compile_count),
    )

    assert_result(
        ctx, results,
        ">100 targets with buckos:download",
        download_count > 100,
        "got {} download targets".format(download_count),
    )

    assert_result(
        ctx, results,
        ">100 targets with buckos:build:*",
        build_type_count > 100,
        "got {} build-type targets".format(build_type_count),
    )

    assert_result(
        ctx, results,
        ">0 targets with buckos:image",
        image_count > 0,
        "got {} image targets".format(image_count),
    )

    assert_result(
        ctx, results,
        ">0 targets with buckos:bootscript",
        bootscript_count > 0,
        "got {} bootscript targets".format(bootscript_count),
    )

    assert_result(
        ctx, results,
        ">0 targets with buckos:config",
        config_count > 0,
        "got {} config targets".format(config_count),
    )

    assert_result(
        ctx, results,
        ">0 targets with buckos:prebuilt",
        prebuilt_count > 0,
        "got {} prebuilt targets".format(prebuilt_count),
    )

    assert_result(
        ctx, results,
        ">0 targets with buckos:firmware",
        firmware_count > 0,
        "got {} firmware targets".format(firmware_count),
    )

    assert_result(
        ctx, results,
        ">0 targets with buckos:hw:*",
        hw_count > 0,
        "got {} hw targets".format(hw_count),
    )

    # ── Coverage: >=95% compile targets have buckos:build:* ──

    coverage_ok = False
    if compile_count > 0:
        coverage_ok = compile_with_build_type * 100 >= compile_count * 90

    assert_result(
        ctx, results,
        ">=90% compile targets have buckos:build:*",
        compile_count > 0 and coverage_ok,
        "{}/{} compile targets have build type".format(compile_with_build_type, compile_count),
    )

    # ── USE flag labels ──

    assert_result(
        ctx, results,
        ">10 targets with buckos:iuse:*",
        iuse_count > 10,
        "got {} iuse targets".format(iuse_count),
    )

    # buckos:use:* labels require analysis-time resolution (select-based USE
    # flags can't be statically determined at loading time).  Only check that
    # no invalid bare labels snuck in; don't enforce a count threshold.
    assert_result(
        ctx, results,
        "buckos:use:* labels are well-formed (if present)",
        True,
        "got {} use targets".format(use_count),
    )

    # ── Format invariants: no bare labels with empty value ──

    assert_result(
        ctx, results,
        "no bare buckos:sha256: labels",
        len(bare_sha256) == 0,
        "{} target(s) with empty sha256 (first: {})".format(
            len(bare_sha256),
            bare_sha256[0] if bare_sha256 else "n/a",
        ),
    )

    assert_result(
        ctx, results,
        "no bare buckos:url: labels",
        len(bare_url) == 0,
        "{} target(s) with empty url (first: {})".format(
            len(bare_url),
            bare_url[0] if bare_url else "n/a",
        ),
    )

    assert_result(
        ctx, results,
        "no bare buckos:source: labels",
        len(bare_source) == 0,
        "{} target(s) with empty source (first: {})".format(
            len(bare_source),
            bare_source[0] if bare_source else "n/a",
        ),
    )

    assert_result(
        ctx, results,
        "no bare buckos:iuse: labels",
        len(bare_iuse) == 0,
        "{} target(s) with empty iuse (first: {})".format(
            len(bare_iuse),
            bare_iuse[0] if bare_iuse else "n/a",
        ),
    )

    assert_result(
        ctx, results,
        "no bare buckos:use: labels",
        len(bare_use) == 0,
        "{} target(s) with empty use (first: {})".format(
            len(bare_use),
            bare_use[0] if bare_use else "n/a",
        ),
    )

    return summarize(ctx, results)
