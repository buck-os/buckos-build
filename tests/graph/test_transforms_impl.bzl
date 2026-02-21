"""Test implementation: transform chain wiring."""

load("//tests/graph:helpers.bzl", "assert_result", "get_dep_strings", "has_dep_matching", "summarize")

def _target_exists_in_pkg(query, pkg_path, target_name):
    """Return True if target_name exists in the package.

    Queries all targets in the package (e.g. "//pkg:") to avoid
    query.eval() errors on missing individual targets.
    """
    target_set = query.eval(pkg_path + ":")
    for t in target_set:
        label = str(t.label)
        if label.endswith(":" + target_name):
            return True
    return False

def run(ctx):
    """Verify transform chain wiring in migrated packages.

    Returns:
        (passed, failed) tuple.
    """
    query = ctx.uquery()
    results = []

    # ================================================================
    # zlib transform chain: build -> stripped -> stamped -> (signed) -> alias
    # From zlib BUCK:
    #   transforms = ["strip", "stamp"]
    #   use_transforms = {"ima": "ima"}
    # ================================================================

    pkg = "//packages/linux/core/zlib"

    # ── All expected targets exist ──
    for suffix in ["zlib-src", "zlib-build", "zlib-stripped", "zlib-stamped", "zlib-signed", "zlib"]:
        assert_result(
            ctx, results,
            "target {} exists".format(suffix),
            _target_exists_in_pkg(query, pkg, suffix),
            "{}:{} does not exist".format(pkg, suffix),
        )

    # ── zlib-stripped depends on zlib-build (via package attr) ──
    stripped_deps = get_dep_strings(query, "{}:zlib-stripped".format(pkg))
    assert_result(
        ctx, results,
        "zlib-stripped depends on zlib-build",
        has_dep_matching(stripped_deps, "zlib-build"),
        "zlib-build not in attrs of zlib-stripped",
    )

    # ── zlib-stamped depends on zlib-stripped (via package attr) ──
    stamped_deps = get_dep_strings(query, "{}:zlib-stamped".format(pkg))
    assert_result(
        ctx, results,
        "zlib-stamped depends on zlib-stripped",
        has_dep_matching(stamped_deps, "zlib-stripped"),
        "zlib-stripped not in attrs of zlib-stamped",
    )

    # ── zlib-signed depends on zlib-stamped (via package attr) ──
    signed_deps = get_dep_strings(query, "{}:zlib-signed".format(pkg))
    assert_result(
        ctx, results,
        "zlib-signed depends on zlib-stamped",
        has_dep_matching(signed_deps, "zlib-stamped"),
        "zlib-stamped not in attrs of zlib-signed",
    )

    # ── zlib alias depends on the last transform (zlib-signed) via actual attr ──
    alias_deps = get_dep_strings(query, "{}:zlib".format(pkg))
    assert_result(
        ctx, results,
        "zlib alias depends on zlib-signed (last transform)",
        has_dep_matching(alias_deps, "zlib-signed"),
        "zlib-signed not in attrs of zlib alias",
    )

    # ================================================================
    # musl transform chain: build -> stripped -> alias
    # From musl BUCK:
    #   transforms = ["strip"]
    #   (no use_transforms)
    # ================================================================

    musl_pkg = "//packages/linux/core/musl"

    # ── musl-stripped depends on musl-build (via package attr) ──
    musl_stripped_deps = get_dep_strings(query, "{}:musl-stripped".format(musl_pkg))
    assert_result(
        ctx, results,
        "musl-stripped depends on musl-build",
        has_dep_matching(musl_stripped_deps, "musl-build"),
        "musl-build not in attrs of musl-stripped",
    )

    # ── musl alias depends on musl-stripped (last transform) via actual attr ──
    musl_alias_deps = get_dep_strings(query, "{}:musl".format(musl_pkg))
    assert_result(
        ctx, results,
        "musl alias depends on musl-stripped (last transform)",
        has_dep_matching(musl_alias_deps, "musl-stripped"),
        "musl-stripped not in attrs of musl alias",
    )

    # ── musl has no -signed target (no use_transforms for ima) ──
    musl_signed_exists = _target_exists_in_pkg(query, musl_pkg, "musl-signed")
    assert_result(
        ctx, results,
        "musl-signed does not exist (no ima use_transform)",
        not musl_signed_exists,
        "musl-signed exists but musl has no use_transforms for ima",
    )

    # ================================================================
    # openssl-3.6 transform chain: build -> stripped -> stamped -> signed -> alias
    # From openssl BUCK:
    #   transforms = ["strip", "stamp"]
    #   use_transforms = {"ima": "ima"}
    # ================================================================

    ossl_pkg = "//packages/linux/system/libs/crypto/openssl"

    ossl_stripped_deps = get_dep_strings(query, "{}:openssl-3.6-stripped".format(ossl_pkg))
    assert_result(
        ctx, results,
        "openssl-3.6-stripped depends on openssl-3.6-build",
        has_dep_matching(ossl_stripped_deps, "openssl-3.6-build"),
        "openssl-3.6-build not in attrs of openssl-3.6-stripped",
    )

    ossl_stamped_deps = get_dep_strings(query, "{}:openssl-3.6-stamped".format(ossl_pkg))
    assert_result(
        ctx, results,
        "openssl-3.6-stamped depends on openssl-3.6-stripped",
        has_dep_matching(ossl_stamped_deps, "openssl-3.6-stripped"),
        "openssl-3.6-stripped not in attrs of openssl-3.6-stamped",
    )

    ossl_signed_deps = get_dep_strings(query, "{}:openssl-3.6-signed".format(ossl_pkg))
    assert_result(
        ctx, results,
        "openssl-3.6-signed depends on openssl-3.6-stamped",
        has_dep_matching(ossl_signed_deps, "openssl-3.6-stamped"),
        "openssl-3.6-stamped not in attrs of openssl-3.6-signed",
    )

    # ================================================================
    # busybox transform chain: build -> stripped -> stamped -> signed -> alias
    # From busybox BUCK:
    #   transforms = ["strip", "stamp"]
    #   use_transforms = {"ima": "ima"}
    # ================================================================

    bb_pkg = "//packages/linux/core/busybox"

    bb_stripped_deps = get_dep_strings(query, "{}:busybox-stripped".format(bb_pkg))
    assert_result(
        ctx, results,
        "busybox-stripped depends on busybox-build",
        has_dep_matching(bb_stripped_deps, "busybox-build"),
        "busybox-build not in attrs of busybox-stripped",
    )

    bb_stamped_deps = get_dep_strings(query, "{}:busybox-stamped".format(bb_pkg))
    assert_result(
        ctx, results,
        "busybox-stamped depends on busybox-stripped",
        has_dep_matching(bb_stamped_deps, "busybox-stripped"),
        "busybox-stripped not in attrs of busybox-stamped",
    )

    return summarize(ctx, results)
