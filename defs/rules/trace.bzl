"""Build-debug exec tracing wiring for package rules.

Generalizes the kernel capture-and-replay tracer (libkbuild_trace.so) into
an opt-in "build-debug mode" for ordinary packages.  When enabled, the
compile phase runs under LD_PRELOAD=libkbuild_trace.so and the captured
exec trace (JSONL) is exposed as a Buck sub-target output that
tools/trace_analyze.py can scan for host-tool leakage.

Gate: OFF by default.  Enabled only when:

    buck2 build //pkg:foo -c buckos.trace=true

mirroring how kernel.bzl gates its dynamic capture path on
read_config("buckos", ...).  With the gate off, trace_enabled() returns
False and the rules add nothing — no shim, no extra output, no env
change, so normal builds are unaffected.

Usage from a build rule:

    load("//defs/rules:trace.bzl", "TRACE_ATTRS", "trace_enabled", "trace_compile_args")

    rule(attrs = COMMON_PACKAGE_ATTRS | { ... } | TRACE_ATTRS)

    # inside _src_compile, after building `cmd`:
    trace_out = trace_compile_args(ctx, cmd)   # returns the output or None

    # expose it as a sub-target so it's retrievable:
    return [DefaultInfo(default_output = installed,
                        sub_targets = trace_subtargets(trace_out))]
"""

# Resolved once at .bzl load time.  read_config is a macro/load-layer API
# and is NOT available inside rule analysis, so the gate is baked into an
# attr default here (same pattern as the toolchain select in
# defs/toolchain_helpers.bzl, which calls read_config when building its
# attr default).  The rule impl then just reads ctx.attrs._trace_enabled.
_TRACE_ENABLED = read_config("buckos", "trace", "false") == "true"

# Merge into a rule's attrs dict via:  attrs = { ... } | TRACE_ATTRS
TRACE_ATTRS = {
    "_trace_enabled": attrs.default_only(attrs.bool(default = _TRACE_ENABLED)),
    "_trace_lib": attrs.default_only(
        attrs.dep(default = "//tools/kbuild_trace:libkbuild_trace"),
    ),
}

def trace_enabled():
    """True when build-debug tracing is requested (-c buckos.trace=true).

    Load-time only — call from macros / attr defaults, not rule impls.
    """
    return _TRACE_ENABLED

def trace_compile_args(ctx, cmd):
    """Wire the trace shim into a compile-phase command, if enabled.

    Declares a `<name>-trace.jsonl` output, adds --trace-lib/--trace-out to
    `cmd`, and returns the declared output artifact.  Returns None when
    tracing is disabled — callers should treat None as "no trace output".

    The build helper (tools/build_helper.py) sets LD_PRELOAD +
    KBUILD_TRACE_FILE around the make/ninja subprocess and copies the
    captured JSONL to --trace-out.
    """
    if not ctx.attrs._trace_enabled:
        return None
    trace_out = ctx.actions.declare_output(ctx.attrs.name + "-trace.jsonl")
    cmd.add("--trace-lib", ctx.attrs._trace_lib[DefaultInfo].default_outputs[0])
    cmd.add("--trace-out", trace_out.as_output())
    return trace_out

def trace_subtargets(trace_out):
    """Return a sub_targets dict exposing the trace output (or empty).

    Exposed as the `trace` sub-target so a captured trace is fetchable:

        buck2 build //pkg:foo[trace] -c buckos.trace=true --show-output
    """
    if not trace_out:
        return {}
    return {"trace": [DefaultInfo(default_output = trace_out)]}
