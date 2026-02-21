"""Test implementation: version data audit."""

load("//tests/graph:helpers.bzl", "assert_result", "summarize")

def _check_archive_target(ctx, query, results, target_label, display_name):
    """Verify an http_file archive target has non-empty urls, sha256, and out."""
    target_set = query.eval(target_label)

    found = False
    for t in target_set:
        found = True

        urls = t.get_attr("urls")
        sha256 = t.get_attr("sha256")
        out = t.get_attr("out")

        assert_result(
            ctx, results,
            "{} has non-empty urls".format(display_name),
            urls != None and str(urls) != "[]",
            "urls is empty or missing on {}".format(target_label),
        )

        assert_result(
            ctx, results,
            "{} has non-empty sha256".format(display_name),
            sha256 != None and sha256 != "",
            "sha256 is empty or missing on {}".format(target_label),
        )

        assert_result(
            ctx, results,
            "{} sha256 is 64 hex chars".format(display_name),
            sha256 != None and len(sha256) == 64,
            "sha256 length is {} (expected 64) on {}".format(
                len(sha256) if sha256 != None else "None",
                target_label,
            ),
        )

        assert_result(
            ctx, results,
            "{} has non-empty out (filename)".format(display_name),
            out != None and out != "",
            "out is empty or missing on {}".format(target_label),
        )

    if not found:
        assert_result(
            ctx, results,
            "{} target exists".format(display_name),
            False,
            "{} does not exist".format(target_label),
        )

def run(ctx):
    """Audit version data via http_file archive target attributes.

    Returns:
        (passed, failed) tuple.
    """
    query = ctx.uquery()
    results = []

    # ── Core packages ──
    _check_archive_target(
        ctx, query, results,
        "//packages/linux/core/zlib:zlib-archive",
        "zlib",
    )

    _check_archive_target(
        ctx, query, results,
        "//packages/linux/core/musl:musl-archive",
        "musl",
    )

    _check_archive_target(
        ctx, query, results,
        "//packages/linux/core/busybox:busybox-archive",
        "busybox",
    )

    # ── Network packages ──
    _check_archive_target(
        ctx, query, results,
        "//packages/linux/system/libs/network/curl:curl-archive",
        "curl",
    )

    # ── Multi-version: openssl ──
    _check_archive_target(
        ctx, query, results,
        "//packages/linux/system/libs/crypto/openssl:openssl-3.6-archive",
        "openssl-3.6",
    )
    _check_archive_target(
        ctx, query, results,
        "//packages/linux/system/libs/crypto/openssl:openssl-3.3-archive",
        "openssl-3.3",
    )

    # ── Verify openssl slots have distinct URLs ──
    ossl36_set = query.eval("//packages/linux/system/libs/crypto/openssl:openssl-3.6-archive")
    ossl33_set = query.eval("//packages/linux/system/libs/crypto/openssl:openssl-3.3-archive")
    urls_36 = None
    urls_33 = None
    for t in ossl36_set:
        urls_36 = str(t.get_attr("urls"))
    for t in ossl33_set:
        urls_33 = str(t.get_attr("urls"))

    assert_result(
        ctx, results,
        "openssl 3.6 and 3.3 have distinct URLs",
        urls_36 != None and urls_33 != None and urls_36 != urls_33,
        "openssl slots should have different source URLs",
    )

    # ── Verify openssl slots have distinct sha256 ──
    sha_36 = None
    sha_33 = None
    for t in query.eval("//packages/linux/system/libs/crypto/openssl:openssl-3.6-archive"):
        sha_36 = t.get_attr("sha256")
    for t in query.eval("//packages/linux/system/libs/crypto/openssl:openssl-3.3-archive"):
        sha_33 = t.get_attr("sha256")

    assert_result(
        ctx, results,
        "openssl 3.6 and 3.3 have distinct sha256",
        sha_36 != None and sha_33 != None and sha_36 != sha_33,
        "openssl slots should have different sha256 values",
    )

    return summarize(ctx, results)
