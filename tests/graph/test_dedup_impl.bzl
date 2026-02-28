"""Test implementation: configuration dedup for pinned rules.

Verifies that rules with cfg = strip_toolchain_mode produce exactly one
action-producing configuration in the seed-export dep graph, regardless
of how many configuration paths reach them.

cquery includes both action-producing nodes (in the <base> config from
the strip transition) and routing nodes (pre-transition nodes that
forward to the <base> config).  We assert on the <base>-labelled nodes
only — routing nodes don't produce actions.
"""

load("//tests/graph:helpers.bzl", "assert_result", "starts_with", "summarize")

# Stage 1 bootstrap targets pinned via cfg = strip_toolchain_mode.
# Each must have exactly one <base> configuration node — if zero,
# the transition was removed; if multiple, the transition is broken.
_PINNED_TARGETS = [
    # extract_source targets
    ":gcc-src",
    ":binutils-src",
    ":glibc-src",
    ":linux-src",
    ":gmp-src",
    ":mpfr-src",
    ":mpc-src",
    # bootstrap rule targets
    ":cross-binutils",
    ":gcc-pass1",
    ":gcc-pass2",
    ":glibc",
    ":linux-headers",
]

_STAGE1_PATH = "//tc/bootstrap/stage1"

def _normalize(label_str):
    """Strip cell prefix, leaving canonical '//path:name'."""
    idx = label_str.find("//")
    if idx > 0:
        return label_str[idx:]
    return label_str

def run(ctx):
    """Verify pinned stage 1 targets have exactly one <base> configuration.

    Returns:
        (passed, failed, details) tuple.
    """
    cquery = ctx.cquery()
    results = []

    all_deps = cquery.eval("deps(//tc/bootstrap:seed-export)")

    # Group configured labels by unconfigured target.
    # Separate <base> configs (action-producing) from routing nodes.
    base_configs = {}
    all_configs = {}
    for node in all_deps:
        raw = _normalize(str(node.label.raw_target()))
        full = str(node.label)
        if raw not in all_configs:
            all_configs[raw] = []
        all_configs[raw].append(full)

        if "<base>" in full:
            if raw not in base_configs:
                base_configs[raw] = []
            base_configs[raw].append(full)

    for suffix in _PINNED_TARGETS:
        target = _STAGE1_PATH + suffix
        short = suffix.lstrip(":")
        total = all_configs.get(target, [])
        base = base_configs.get(target, [])

        assert_result(
            ctx, results,
            short + " exists in dep graph",
            len(total) > 0,
            target + " not found in deps(//tc/bootstrap:seed-export)",
        )

        assert_result(
            ctx, results,
            short + " has <base> config",
            len(base) == 1,
            "expected 1 <base> config, got {}: {}".format(
                len(base), ", ".join(base) if base else ", ".join(total),
            ),
        )

    # ── Host-tools dedup ──────────────────────────────────────────────
    #
    # Host-tools targets (stage 2 packages) should appear in at most 2
    # distinct configurations: DEFAULT and stage3-transition.  More than
    # 2 means duplicate actions.
    host_tools_configs = {}
    for node in all_deps:
        raw = _normalize(str(node.label.raw_target()))
        full = str(node.label)
        if starts_with(raw, "//tc/bootstrap/host-tools"):
            if raw not in host_tools_configs:
                host_tools_configs[raw] = []
            host_tools_configs[raw].append(full)

    multi_config_violations = []
    for target, configs in host_tools_configs.items():
        if len(configs) > 2:
            multi_config_violations.append(
                "{} has {} configs".format(target, len(configs)),
            )

    assert_result(
        ctx, results,
        "host-tools targets have at most 2 configs",
        len(multi_config_violations) == 0,
        "{} target(s) with >2 configs: {}".format(
            len(multi_config_violations),
            ", ".join(multi_config_violations[:3]) if multi_config_violations else "n/a",
        ),
    )

    return summarize(ctx, results)
