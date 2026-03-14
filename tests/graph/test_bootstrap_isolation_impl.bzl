"""Test implementation: bootstrap isolation.

Verifies that packages in the seed-export dep graph are properly isolated
from bootstrap internals.  Stage 2 targets should appear in at most 2
configurations: <base> (action-producing from strip_toolchain_mode) and
default platform (routing node).
More than 2 configs means something is bypassing the transition.

Also verifies that the <base> config is always present (confirms the
strip_toolchain_mode transition is applied).
"""

load("//tests/graph:helpers.bzl", "assert_result", "starts_with", "summarize")

def _normalize(label_str):
    """Strip cell prefix, leaving canonical '//path:name'."""
    idx = label_str.find("//")
    if idx > 0:
        return label_str[idx:]
    return label_str

def run(ctx):
    """Verify bootstrap isolation in the seed-export dep graph.

    Returns:
        (passed, failed, details) tuple.
    """
    cquery = ctx.cquery()
    results = []

    all_deps = cquery.eval("deps(//tc/bootstrap:seed-export)")

    # Group bootstrap stage2 targets by unconfigured label.
    # Track configs per target.
    stage2_configs = {}
    stage2_has_base = {}

    for node in all_deps:
        raw = _normalize(str(node.label.raw_target()))
        full = str(node.label)

        if starts_with(raw, "//tc/bootstrap/stage2"):
            if raw not in stage2_configs:
                stage2_configs[raw] = []
            stage2_configs[raw].append(full)
            if "<base>" in full:
                stage2_has_base[raw] = True

    # Every stage2 BUILD target should have a <base> config.
    # Aggregator targets like :stage2 are routing-only (no cfg transition).
    _AGGREGATORS = {"//tc/bootstrap/stage2:stage2": True}
    missing_base = []
    for target in stage2_configs:
        if target in _AGGREGATORS:
            continue
        if target not in stage2_has_base:
            missing_base.append(target)

    assert_result(
        ctx, results,
        "all stage2 targets have <base> config",
        len(missing_base) == 0,
        "{} target(s) missing <base>: {}".format(
            len(missing_base),
            "; ".join(missing_base[:5]) if missing_base else "n/a",
        ),
    )

    # No stage2 target should appear in more than 2 configs
    # (<base>, default).  More means a new config path is reaching
    # bootstrap internals.
    over_limit = []
    for target, configs in stage2_configs.items():
        if len(configs) > 2:
            over_limit.append("{} has {} configs".format(target, len(configs)))

    assert_result(
        ctx, results,
        "stage2 targets have at most 2 configs",
        len(over_limit) == 0,
        "{} target(s) exceed 2 configs: {}".format(
            len(over_limit),
            "; ".join(over_limit[:5]) if over_limit else "n/a",
        ),
    )

    return summarize(ctx, results)
