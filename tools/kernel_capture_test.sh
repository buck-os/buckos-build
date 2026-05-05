#!/bin/bash
# Phase 1 byte-identical validation harness for capture-and-replay.
#
# Usage:
#   tools/kernel_capture_test.sh [SOURCE_DIR] [WORK_DIR]
#
# Defaults to ~/local/linux + /tmp/kernel-cap-test.  Performs:
#   1. tinyconfig kernel build (baseline)        → record vmlinux sha
#   2. capture under shim (separate tree)        → record vmlinux sha
#   3. fresh replay of plan (separate tree)      → record vmlinux sha
#   4. assert (1) == (2) == (3)
#
# tinyconfig is the smallest possible kernel build (~1–2 min on
# a fast box), so iteration is cheap.  Once this passes, scale up
# to buckos-minimal and full configs.

set -euo pipefail

SRC=${1:-$HOME/local/linux}
WORK=${2:-/tmp/kernel-cap-test}
TRACE_LIB="$(cd "$(dirname "$0")"/kbuild_trace && pwd)/libkbuild_trace.so"
CAPTURE="$(cd "$(dirname "$0")" && pwd)/kernel_capture.py"
REPLAY="$(cd "$(dirname "$0")" && pwd)/kernel_replay.py"
ARCH=x86_64
JOBS=${JOBS:-$(nproc)}

if [[ ! -d "$SRC" ]]; then
    echo "error: kernel source not found at $SRC" >&2
    exit 1
fi
if [[ ! -f "$TRACE_LIB" ]]; then
    echo "error: trace lib not built; run: make -C tools/kbuild_trace" >&2
    exit 1
fi

log() { printf '\033[1;36m[test]\033[0m %s\n' "$*" >&2; }
say() { printf '       %s\n' "$*" >&2; }

mkdir -p "$WORK"
BASE="$WORK/baseline"
CAP="$WORK/capture"
REP="$WORK/replay"

# ── Stage 1: baseline (no shim, plain make tinyconfig + vmlinux) ─────
log "stage 1: baseline build (tinyconfig)"
rm -rf "$BASE"
mkdir -p "$BASE/build"
cp -a "$SRC"/. "$BASE/build/"
( cd "$BASE/build" && make ARCH=x86_64 mrproper >/dev/null 2>&1 )
( cd "$BASE/build" && make ARCH=x86_64 tinyconfig >/dev/null 2>&1 )
cp "$BASE/build/.config" "$BASE/tinyconfig.config"
( cd "$BASE/build" && make ARCH=x86_64 -j"$JOBS" \
    KBUILD_BUILD_TIMESTAMP="Thu Jan  1 00:00:00 UTC 1970" \
    KBUILD_BUILD_USER=buckos KBUILD_BUILD_HOST=buckos \
    vmlinux >/dev/null 2>"$BASE/build.log" )
SHA_BASE=$(sha256sum "$BASE/build/vmlinux" | awk '{print $1}')
say "baseline vmlinux: $SHA_BASE"

# ── Stage 2: capture under shim, separate build tree ────────────────
log "stage 2: capture build under LD_PRELOAD shim"
rm -rf "$CAP"
mkdir -p "$CAP"
python3 "$CAPTURE" \
    --source-dir "$SRC" \
    --config "$BASE/tinyconfig.config" \
    --arch x86_64 \
    --output-dir "$CAP" \
    --trace-lib "$TRACE_LIB" \
    --jobs "$JOBS" \
    --phase compile \
    >"$CAP/capture.log" 2>&1
SHA_CAP=$(sha256sum "$CAP/build-tree/vmlinux" | awk '{print $1}')
TRACE_LINES=$(wc -l < "$CAP/trace.jsonl")
PLAN_ACTIONS=$(python3 -c 'import json; print(len(json.load(open("'"$CAP"'/build_plan.json"))["actions"]))')
say "capture vmlinux:  $SHA_CAP"
say "trace lines:      $TRACE_LINES"
say "plan actions:     $PLAN_ACTIONS"

# ── Stage 3: fresh replay from plan ─────────────────────────────────
log "stage 3: fresh replay from plan"
python3 "$REPLAY" \
    --plan "$CAP/build_plan.json" \
    --source-dir "$SRC" \
    --config "$BASE/tinyconfig.config" \
    --fresh \
    >"$CAP/replay.log" 2>&1
SHA_REP=$(sha256sum "$CAP/build-tree/vmlinux" | awk '{print $1}')
say "replay vmlinux:   $SHA_REP"

# ── Stage 4: compare ─────────────────────────────────────────────────
log "stage 4: compare"
status=0
if [[ "$SHA_BASE" == "$SHA_CAP" ]]; then
    say "baseline == capture: OK"
else
    say "baseline != capture: FAIL"
    status=1
fi
if [[ "$SHA_CAP" == "$SHA_REP" ]]; then
    say "capture  == replay:  OK"
else
    say "capture  != replay:  FAIL"
    status=1
fi

if [[ "$status" -ne 0 ]]; then
    echo
    echo "DIVERGENCE DETECTED. Logs:"
    echo "  baseline:  $BASE/build.log"
    echo "  capture:   $CAP/capture.log"
    echo "  replay:    $CAP/replay.log"
    exit 1
fi

log "PASS — vmlinux byte-identical across baseline, capture, and replay"
