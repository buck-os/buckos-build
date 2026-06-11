"""Build-phase exec tracing helper (build-debug mode).

Shared glue used by the per-language build helpers (currently
tools/build_helper.py) to run a build phase under the libkbuild_trace.so
LD_PRELOAD shim and capture the resulting JSON-lines exec trace.

This mirrors the kernel capture path (tools/kernel_capture.capture_env):
set LD_PRELOAD to the shim and KBUILD_TRACE_FILE to a writable file, run
the build, then copy the trace to a Buck-declared output so it survives
as a cacheable artifact.

The whole mechanism is OFF by default.  The Buck rule only passes
``--trace-lib``/``--trace-out`` when ``[buckos] trace = true`` is set
(see defs/rules/trace.bzl), so normal builds are byte-for-byte
unaffected — no LD_PRELOAD, no extra outputs, no behavior change.

Why this lives in the helper rather than a pure host-env wrapper:
the helpers build their subprocess env from _env.clean_env(), which
whitelists env vars and therefore *drops* any LD_PRELOAD/KBUILD_TRACE_FILE
inherited from the caller.  To trace a real build phase the shim must be
re-injected into that clean env from inside the helper.
"""

import os
import shutil


def add_trace_args(parser):
    """Register the standard build-debug trace arguments on a parser.

    Both default to None, so a helper that never gets them behaves
    exactly as before.
    """
    parser.add_argument(
        "--trace-lib",
        default=None,
        help="Path to libkbuild_trace.so.  When set (build-debug mode), the "
        "build phase runs under LD_PRELOAD=<lib> and every exec is logged.",
    )
    parser.add_argument(
        "--trace-out",
        default=None,
        help="Declared output path for the captured exec trace (JSONL).  "
        "Required for the trace to be retained; ignored if --trace-lib unset.",
    )


def trace_scratch_file():
    """Return a writable scratch path for the live trace.

    The shim appends with O_APPEND from every exec'd process, so this
    must live somewhere writable by the whole build subtree — scratch,
    not the read-only buck-out output.
    """
    scratch = os.environ.get("BUCK_SCRATCH_PATH", os.environ.get("TMPDIR", "/tmp"))
    return os.path.join(os.path.abspath(scratch), "buckos-build-trace.jsonl")


def enable_tracing(env, trace_lib):
    """Inject the LD_PRELOAD shim into a prepared build env dict.

    Returns the scratch trace-file path the shim will write to, or None
    when tracing is not enabled (trace_lib falsy or missing on disk).

    LD_PRELOAD is *appended* to any existing value so a toolchain that
    already preloads something keeps working.  Safe under unshare --net:
    it's only an LD_PRELOAD, no network involved.
    """
    if not trace_lib:
        return None
    trace_lib = os.path.abspath(trace_lib)
    if not os.path.isfile(trace_lib):
        return None
    trace_file = trace_scratch_file()
    # Start from an empty trace so stale records from a previous phase in
    # the same scratch dir don't bleed in.
    try:
        with open(trace_file, "w"):
            pass
    except OSError:
        return None
    existing = env.get("LD_PRELOAD", "")
    env["LD_PRELOAD"] = (existing + " " + trace_lib).strip() if existing else trace_lib
    env["KBUILD_TRACE_FILE"] = trace_file
    return trace_file


def finalize_trace(trace_file, trace_out):
    """Copy the captured scratch trace to the Buck-declared output.

    Tolerant of a missing scratch file (e.g. the build exec'd nothing or
    failed before any exec): writes an empty trace so the declared output
    always exists and the action doesn't fail on a missing artifact.
    """
    if not trace_out:
        return
    trace_out = os.path.abspath(trace_out)
    os.makedirs(os.path.dirname(trace_out), exist_ok=True)
    if trace_file and os.path.isfile(trace_file):
        shutil.copyfile(trace_file, trace_out)
    else:
        with open(trace_out, "w"):
            pass
