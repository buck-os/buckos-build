"""Test implementation: hermiticity check.

Verifies that targets in the seed-export dep graph have correct
configuration constraints: bootstrap-mode-true should NOT be present
(which would mean the host PATH escape hatch is active).
"""

load("//tests/graph:helpers.bzl", "assert_result", "starts_with", "summarize")

def _normalize(label_str):
    """Strip cell prefix, leaving canonical '//path:name'."""
    idx = label_str.find("//")
    if idx > 0:
        return label_str[idx:]
    return label_str

def run(ctx):
    """Verify host-tools targets have correct constraints.

    Uses cquery (configured) to inspect configuration labels.

    Returns:
        (passed, failed, details) tuple.
    """
    cquery = ctx.cquery()
    results = []

    all_deps = cquery.eval("deps(//tc/bootstrap:seed-export)")

    # Find any targets with bootstrap-mode-true (escape hatch leak)
    bootstrap_leaked = []

    for node in all_deps:
        full = str(node.label)
        raw = _normalize(str(node.label.raw_target()))

        # Only check host-tools targets
        if not starts_with(raw, "//tc/bootstrap/host-tools"):
            continue

        # Verify bootstrap-mode is NOT active
        if "bootstrap-mode-true" in full:
            bootstrap_leaked.append("{} ({})".format(raw, full))

    assert_result(
        ctx, results,
        "no host-tools target has bootstrap-mode-true",
        len(bootstrap_leaked) == 0,
        "{} target(s) with bootstrap-mode-true leak: {}".format(
            len(bootstrap_leaked),
            "; ".join(bootstrap_leaked[:3]) if bootstrap_leaked else "n/a",
        ),
    )

    return summarize(ctx, results)
