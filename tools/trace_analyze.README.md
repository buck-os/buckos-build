# Build-debug mode: exec tracing + host-leak analysis

A prototype that generalizes the kernel capture tracer
(`libkbuild_trace.so`) into an opt-in **build-debug mode** for *any*
package build. It runs a build under an `LD_PRELOAD` exec shim, captures
every `exec()` the build performs, and analyzes the trace to flag
**host-tool leakage** (the build invoking a tool from host `/usr/bin`,
`/bin`, … instead of the hermetic buckos toolchain/deps) and to produce a
**tool-usage summary** (useful for figuring out the right `host_deps`).

This is the same bug class the hermeticity gate
(`tools/check_hermeticity.sh`, `tools/elf_audit.py`) guards against, but
caught at *build* time (which tool was exec'd) rather than only at *output*
time (which interpreter/soname an ELF ended up with).

## Pieces

| File | Role |
|---|---|
| `tools/kbuild_trace/trace.c` | (existing) `LD_PRELOAD` shim; logs one JSON line per `exec`/`posix_spawn` to `$KBUILD_TRACE_FILE`. Target `//tools/kbuild_trace:libkbuild_trace`. |
| `tools/_trace.py` | New. Helper used by build helpers: `enable_tracing(env, lib)` injects `LD_PRELOAD`+`KBUILD_TRACE_FILE`; `finalize_trace(...)` copies the JSONL to a declared output. |
| `tools/build_helper.py` | Changed (gated). Compile phase runs under the shim when `--trace-lib`/`--trace-out` are passed, then copies the trace out. |
| `defs/rules/trace.bzl` | New. `TRACE_ATTRS` + `trace_compile_args()` + `trace_subtargets()`. Gate baked into an attr default from `read_config("buckos","trace")`. |
| `defs/rules/autotools.bzl` | Changed (gated). Wires the trace output through `_src_compile` and exposes it as the `[trace]` sub-target. Covers `autotools_package` + `make_package`. |
| `tools/trace_analyze.py` | New. Standalone, stdlib-only analyzer. Reads the JSONL, reports host leaks + tool usage, exits non-zero on leaks. |

## How to use it

### 1. Capture a trace by building the package with the gate on

```bash
buck2 build //packages/linux/core/bash:bash \
    --target-platforms //platforms:linux-target-host \
    -c buckos.trace=true \
    --show-output
```

The captured trace is exposed as the `trace` sub-target of the build:

```bash
buck2 build '//packages/linux/core/bash:bash-build[trace]' \
    --target-platforms //platforms:linux-target-host \
    -c buckos.trace=true \
    --show-output
# -> buck-out/.../bash-trace.jsonl
```

(The trace lives on `:<name>-build`, the build-rule target in the chain;
`:<name>` is the final alias.) With the gate **off** (the default), nothing
changes: no `LD_PRELOAD`, no extra output, no sub-target — builds are
byte-for-byte identical.

### 2. Analyze the trace

```bash
python3 tools/trace_analyze.py path/to/bash-trace.jsonl \
    --allow-prefix "$PWD/buck-out"
```

`--allow-prefix` marks hermetic roots (buck-out, a toolchain prefix, …).
Anything resolving outside is reported. Exit code is non-zero when leaks
are found, so it can gate in CI.

Example (from the worktree proof run against a hand-rolled `make`):

```
== tool usage ==
       1  cc
       1  cc1
       1  echo  LEAK
       1  sed   LEAK
       1  sh    LEAK

== host-tool leaks (3 execs, 3 tools) ==
  sed  (1 exec(s))
    -> /usr/bin/sed
       argv: sed -n 1p foo.c
       cwd:  /tmp/.../proj  (line 4)
  ...
FAIL: 3 host-tool leak exec(s) found
```

### Useful flags

- `--allow-prefix-file FILE` — many hermetic prefixes, one per line.
- `--allow-tool NAME` — basename never counted as a leak (defaults: `env`,
  `unshare`).
- `--strict` — allowlist-authoritative: *anything* not under an
  `--allow-prefix` is a leak (also catches `/usr/libexec/.../cc1` etc.).
  Requires `--allow-prefix`.
- `--host-prefix DIR` — extra host dir to flag (defaults already cover
  `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`, `/usr/local/{bin,sbin}`,
  `/opt`).
- `--json` — machine-readable report.
- `--summary-only` — just the tool table.
- `--no-fail` — report only, always exit 0.

## What it catches

- A build that shells out to a host tool (`/bin/sh -c '… sed …'` →
  `/usr/bin/sed`) — i.e. a missing/undeclared `host_dep`.
- A tool the hermetic PATH didn't provide: it resolves on the *host* PATH
  (lenient mode) or is reported **UNRESOLVED** when not found at all —
  either way a leak signal.
- The full set of tools a build actually invokes, so you can pare
  `host_deps` to what's needed (or add what's missing).

## How resolution works

For each trace record the analyzer resolves the exec target to an absolute
binary path the way the kernel would:

- absolute path → as-is;
- relative (`./configure`, `sub/tool`) → resolved against the record's
  captured `cwd`;
- bare name (`gcc`) → searched along **that record's captured `PATH`**
  (each entry anchored to `cwd` if relative).

The resolved path is then classified against the allowed/host prefixes.

## Limitations (prototype)

- **Compile phase only.** Wired into `autotools_build`'s compile phase
  (the bulk of execs: gcc/ld/ar/host tools). The configure and install
  phases, and the other build systems (cmake/meson/cargo/go/python/perl),
  are not yet wired — the mechanism is identical (`enable_tracing` around
  their build subprocess), they just need the same small hook. `make_package`
  is covered since it shares the autotools rule.
- **Statically-linked / busybox-style multicall tools** appear under the
  name they were exec'd as; a static host tool with no DT_NEEDED won't be
  distinguishable from a hermetic one by *linking*, but it is still caught
  by *path* (where it was exec'd from).
- **Shell builtins** (e.g. `echo` when run as a bash builtin) are not
  exec'd, so they won't appear; only the `/usr/bin/echo` *exec* form is
  visible. This is fine for leak detection (builtins don't contaminate).
- **`cc1`/`cc1plus`/`collect2`** live under `/usr/libexec` or
  `/usr/lib/gcc`, not `/usr/bin`, so lenient mode does **not** flag them.
  Use `--strict` with the buck-out allowlist to catch a host *gcc*'s
  internal helpers.
- **Trace truncation:** the shim truncates per-exec lines that exceed its
  128 KiB buffer and marks them `"truncated":true`; the analyzer counts
  these and warns (argv/env may be incomplete for those lines).
- **Caching:** with `-c buckos.trace=true` the compile action's command
  changes (extra args + output), so it re-runs and caches under a distinct
  key. Turning the gate back off restores the original cache key. The shim
  works under `unshare --net` (it is only an `LD_PRELOAD`).

## Verification done in this prototype

- `trace_analyze.py` exercised on a synthetic JSONL and on a **real**
  captured trace from running `make` under the freshly-compiled shim via
  the actual `tools/_trace.py` code path (the same calls `build_helper.py`
  now makes). It correctly flagged host `sed`/`echo`/`sh`, allowed the
  hermetic `cc`, marked an unresolved tool, and gated (exit 1).
- All `.bzl`/`BUCK` edits parse; all touched Python compiles. (A full
  `buck2` analysis was not run — the `buck2` dotslash version-pin is absent
  in this environment, unrelated to these changes.)
