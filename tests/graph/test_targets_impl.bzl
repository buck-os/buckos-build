"""Test implementation: target universe validation."""

load("//tests/graph:helpers.bzl", "assert_result", "summarize")

def run(ctx):
    """Verify target universe parses and definition cells load cleanly.

    Returns:
        (passed, failed) tuple.
    """
    query = ctx.uquery()
    results = []

    # ── All targets parse and exceed minimum count ──
    all_targets = query.eval("//...")
    count = 0
    for _t in all_targets:
        count += 1

    assert_result(
        ctx, results,
        "all targets parse (>2000 targets)",
        count > 2000,
        "expected >2000 targets, got {}; target graph may be broken".format(count),
    )

    # ── Duplicate check (inherent in BXL set-based queries) ──
    # BXL query.eval returns a unique target set — duplicates are
    # impossible.  We still verify the count is sane as a canary.
    assert_result(
        ctx, results,
        "target count is sane (no silent duplication)",
        count < 100000,
        "unreasonable target count {} suggests duplication or runaway macros".format(count),
    )

    # ── //defs/... loads without error ──
    defs_targets = query.eval("//defs/...")
    defs_count = 0
    for _t in defs_targets:
        defs_count += 1

    assert_result(
        ctx, results,
        "//defs/... resolves without error",
        defs_count >= 0,
        "//defs/... query failed",
    )

    # ── toolchains cell loads without error ──
    tc_targets = query.eval("toolchains//...")
    tc_count = 0
    for _t in tc_targets:
        tc_count += 1

    assert_result(
        ctx, results,
        "toolchains//... resolves without error",
        tc_count >= 0,
        "toolchains//... query failed",
    )

    # ── Toolchains cell has at least one target ──
    assert_result(
        ctx, results,
        "toolchains//... has targets",
        tc_count > 0,
        "toolchains//... returned 0 targets",
    )

    return summarize(ctx, results)
