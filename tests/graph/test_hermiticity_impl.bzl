"""Test implementation: hermiticity check.

Verifies that stage3-mode targets in the seed-export dep graph have the
correct configuration constraints: stage3-mode-true should be present,
and bootstrap-mode-true should NOT be present (which would mean the
host PATH escape hatch is active).
"""

load("//tests/graph:helpers.bzl", "assert_result", "starts_with", "summarize")

def _normalize(label_str):
    """Strip cell prefix, leaving canonical '//path:name'."""
    idx = label_str.find("//")
    if idx > 0:
        return label_str[idx:]
    return label_str

def run(ctx):
    """Verify stage3-mode targets have correct constraints.

    Uses cquery (configured) to inspect configuration labels.

    Returns:
        (passed, failed, details) tuple.
    """
    cquery = ctx.cquery()
    results = []

    all_deps = cquery.eval("deps(//tc/bootstrap:seed-export)")

    # Find all targets in stage3-transition configuration
    stage3_targets = []
    bootstrap_leaked = []

    for node in all_deps:
        full = str(node.label)
        raw = _normalize(str(node.label.raw_target()))

        # Only check host-tools targets (stage3 candidates)
        if not starts_with(raw, "//tc/bootstrap/host-tools"):
            continue

        # Check for stage3 transition marker in config
        if "stage3-transition" in full or "stage3-mode-true" in full:
            stage3_targets.append(raw)

            # Verify bootstrap-mode is NOT active in stage3 targets
            if "bootstrap-mode-true" in full:
                bootstrap_leaked.append("{} ({})".format(raw, full))

    assert_result(
        ctx, results,
        "stage3-mode targets exist in seed-export graph",
        len(stage3_targets) > 0,
        "no stage3-transition targets found in deps(//tc/bootstrap:seed-export)",
    )

    assert_result(
        ctx, results,
        "no stage3 target has bootstrap-mode-true",
        len(bootstrap_leaked) == 0,
        "{} target(s) with bootstrap-mode-true leak: {}".format(
            len(bootstrap_leaked),
            "; ".join(bootstrap_leaked[:3]) if bootstrap_leaked else "n/a",
        ),
    )

    return summarize(ctx, results)
