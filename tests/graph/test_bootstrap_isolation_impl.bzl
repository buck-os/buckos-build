"""Test implementation: bootstrap isolation.

Verifies that packages in the seed-export dep graph are properly isolated
from bootstrap internals.  Stage 1 targets should appear in at most 3
configurations: <base> (action-producing from strip_toolchain_mode),
default platform (routing node), and stage3-transition (routing node).
More than 3 configs means something is bypassing the transition.

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

    # Group bootstrap stage1 targets by unconfigured label.
    # Track configs per target.
    stage1_configs = {}
    stage1_has_base = {}

    for node in all_deps:
        raw = _normalize(str(node.label.raw_target()))
        full = str(node.label)

        if starts_with(raw, "//tc/bootstrap/stage1"):
            if raw not in stage1_configs:
                stage1_configs[raw] = []
            stage1_configs[raw].append(full)
            if "<base>" in full:
                stage1_has_base[raw] = True

    # Every stage1 BUILD target should have a <base> config.
    # Aggregator targets like :stage1 are routing-only (no cfg transition).
    _AGGREGATORS = {"//tc/bootstrap/stage1:stage1": True}
    missing_base = []
    for target in stage1_configs:
        if target in _AGGREGATORS:
            continue
        if target not in stage1_has_base:
            missing_base.append(target)

    assert_result(
        ctx, results,
        "all stage1 targets have <base> config",
        len(missing_base) == 0,
        "{} target(s) missing <base>: {}".format(
            len(missing_base),
            "; ".join(missing_base[:5]) if missing_base else "n/a",
        ),
    )

    # No stage1 target should appear in more than 3 configs
    # (<base>, default, stage3-transition).  More means a new
    # config path is reaching bootstrap internals.
    over_limit = []
    for target, configs in stage1_configs.items():
        if len(configs) > 3:
            over_limit.append("{} has {} configs".format(target, len(configs)))

    assert_result(
        ctx, results,
        "stage1 targets have at most 3 configs",
        len(over_limit) == 0,
        "{} target(s) exceed 3 configs: {}".format(
            len(over_limit),
            "; ".join(over_limit[:5]) if over_limit else "n/a",
        ),
    )

    return summarize(ctx, results)
