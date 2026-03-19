"""Test implementation: dependency edges."""

load("//tests/graph:helpers.bzl", "assert_result", "fmt_actual", "get_dep_strings", "has_dep_matching", "summarize")

def run(ctx):
    """Verify dependency edges in migrated packages.

    Returns:
        (passed, failed) tuple.
    """
    query = ctx.uquery()
    results = []

    # ── zlib-build depends on zlib-src (via source attr) ──
    zlib_deps = get_dep_strings(query, "//packages/linux/core/zlib:zlib-build")
    assert_result(
        ctx, results,
        "zlib-build depends on zlib-src",
        has_dep_matching(zlib_deps, "zlib-src"),
        "zlib-src not found in attrs of zlib-build; got: [{}]".format(fmt_actual(zlib_deps)),
    )

    # ── musl-build depends on musl-src (via source attr) ──
    musl_deps = get_dep_strings(query, "//packages/linux/core/musl:musl-build")
    assert_result(
        ctx, results,
        "musl-build depends on musl-src",
        has_dep_matching(musl_deps, "musl-src"),
        "musl-src not found in attrs of musl-build; got: [{}]".format(fmt_actual(musl_deps)),
    )

    # ── curl-build depends on zlib (via deps attr, may be in select) ──
    curl_deps = get_dep_strings(query, "//packages/linux/system/libs/network/curl:curl-build")
    assert_result(
        ctx, results,
        "curl-build depends on zlib",
        has_dep_matching(curl_deps, "//packages/linux/core/zlib:zlib"),
        "zlib not found in attrs of curl-build; got: [{}]".format(fmt_actual(curl_deps)),
    )

    # ── curl-build depends on libpsl ──
    assert_result(
        ctx, results,
        "curl-build depends on libpsl",
        has_dep_matching(curl_deps, "libpsl"),
        "libpsl not found in attrs of curl-build; got: [{}]".format(fmt_actual(curl_deps)),
    )

    # ── openssl-3.6 depends on openssl-3.6-src (via source attr) ──
    ossl36_deps = get_dep_strings(query, "//packages/linux/system/libs/crypto/openssl:openssl-3.6-build")
    assert_result(
        ctx, results,
        "openssl-3.6-build depends on openssl-3.6-src",
        has_dep_matching(ossl36_deps, "openssl-3.6-src"),
        "openssl-3.6-src not found in attrs of openssl-3.6-build; got: [{}]".format(fmt_actual(ossl36_deps)),
    )

    # ── openssl-3.3 depends on openssl-3.3-src (via source attr) ──
    ossl33_deps = get_dep_strings(query, "//packages/linux/system/libs/crypto/openssl:openssl-3.3-build")
    assert_result(
        ctx, results,
        "openssl-3.3-build depends on openssl-3.3-src",
        has_dep_matching(ossl33_deps, "openssl-3.3-src"),
        "openssl-3.3-src not found in attrs of openssl-3.3-build; got: [{}]".format(fmt_actual(ossl33_deps)),
    )

    # ── openssl-3.6-src and openssl-3.3-src are independent ──
    assert_result(
        ctx, results,
        "openssl-3.6-build does not depend on openssl-3.3-src",
        not has_dep_matching(ossl36_deps, "openssl-3.3-src"),
        "openssl-3.3-src found in attrs of openssl-3.6-build (should be independent); got: [{}]".format(fmt_actual(ossl36_deps)),
    )
    assert_result(
        ctx, results,
        "openssl-3.3-build does not depend on openssl-3.6-src",
        not has_dep_matching(ossl33_deps, "openssl-3.6-src"),
        "openssl-3.6-src found in attrs of openssl-3.3-build (should be independent); got: [{}]".format(fmt_actual(ossl33_deps)),
    )

    # ── openssl default alias points to openssl-3.6 (via actual attr) ──
    ossl_alias_deps = get_dep_strings(query, "//packages/linux/system/libs/crypto/openssl:openssl")
    assert_result(
        ctx, results,
        "openssl alias depends on openssl-3.6",
        has_dep_matching(ossl_alias_deps, "openssl-3.6"),
        "openssl-3.6 not found in attrs of openssl alias; got: [{}]".format(fmt_actual(ossl_alias_deps)),
    )

    # ── both openssl slots depend on zlib (via deps attr) ──
    assert_result(
        ctx, results,
        "openssl-3.6-build depends on zlib",
        has_dep_matching(ossl36_deps, "//packages/linux/core/zlib:zlib"),
        "zlib not found in attrs of openssl-3.6-build; got: [{}]".format(fmt_actual(ossl36_deps)),
    )
    assert_result(
        ctx, results,
        "openssl-3.3-build depends on zlib",
        has_dep_matching(ossl33_deps, "//packages/linux/core/zlib:zlib"),
        "zlib not found in attrs of openssl-3.3-build; got: [{}]".format(fmt_actual(ossl33_deps)),
    )

    # ── busybox-build depends on busybox-src (via source attr) ──
    bb_deps = get_dep_strings(query, "//packages/linux/core/busybox:busybox-build")
    assert_result(
        ctx, results,
        "busybox-build depends on busybox-src",
        has_dep_matching(bb_deps, "busybox-src"),
        "busybox-src not found in attrs of busybox-build; got: [{}]".format(fmt_actual(bb_deps)),
    )

    return summarize(ctx, results)
