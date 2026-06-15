---
id: "SPEC-100"
title: "Toolchain Bootstrap and Seed"
status: "approved"
version: "1.0.0"
created: "2026-06-15"
updated: "2026-06-15"

authors:
  - name: "BuckOS Team"
    email: "team@buckos.org"

maintainers:
  - "team@buckos.org"

category: "bootstrap"
tags:
  - "toolchain"
  - "bootstrap"
  - "seed"
  - "cross-compile"
  - "patchelf"

related:
  - "SPEC-001"

implementation:
  status: "complete"
  completeness: 100

compatibility:
  buck2_version: ">=2024.11.01"
  buckos_version: ">=1.0.0"
  breaking_changes: false

changelog:
  - version: "1.0.0"
    date: "2026-06-15"
    changes: "Initial specification covering the staged bootstrap (stage 2 cross-compiler, stage 3 hermetic toolchain), the patch_compiler ELF interpreter rewrite with cross-arch skip, the seed-export archive format, and the seed resolution priority (seed_path > seed_url > source bootstrap)."
---

# Toolchain Bootstrap and Seed

**Status**: approved | **Version**: 1.0.0 | **Last Updated**: 2026-06-15

## Abstract

BuckOS builds every package against a hermetic toolchain rooted at
`//tc/seed:seed-toolchain`. That toolchain resolves to one of three
sources in priority order: a local pre-built seed archive
(`buckos.seed_path`), a remote archive (`buckos.seed_url`), or a from-source
bootstrap that derives a cross-compiler from the host `gcc`. This
specification fixes the staging boundaries, the compiler-binary patching
contract (including the cross-arch behaviour added for aarch64 seed
builds), the seed-archive format, and the visible Buck2 targets.

## Motivation

Distribution build systems either trust the host toolchain (fast, but
non-reproducible across hosts) or carry a fully pre-built toolchain (small
trust surface, but a chicken-and-egg problem for new architectures).
BuckOS does both: a source bootstrap exists for any supported host/target
combination, and once a seed archive has been published, every subsequent
build can short-circuit to the unpacked archive without rebuilding GCC.
The contract between those two modes — what targets, what layout, what
guarantees — needs to be normative because:

* Package rules depend on the resolved toolchain having a predictable
  binary layout (`tools/bin/<triple>-gcc`, sysroot under
  `tools/<triple>/sys-root`).
* The seed archive is a release artifact. Its filename, content, and
  metadata must be stable so consumers can pin against it.
* Cross-arch seed builds (e.g. an aarch64 seed produced on an x86_64
  host) must not patch the cross-compiler's ELF interpreter to a target
  ld-linux that won't run on the host.

## Stages

The bootstrap pipeline lives entirely under `tc/bootstrap/`. Stages are
numbered to match the Gentoo bootstrap convention; stage 1 is the host
system and is not modelled in BUCK.

| Stage | Buck target                                   | Built with                  | Output |
|-------|-----------------------------------------------|-----------------------------|--------|
| 1     | *(host)*                                      | distro `gcc` + `binutils`   | implicit |
| 2     | `//tc/bootstrap/stage2:stage2`                | stage 1 + sources           | cross-compiler with sysroot glibc |
| 3     | `//tc/bootstrap:stage3-toolchain`             | stage 2 + per-rule host deps| hermetic toolchain for package builds |
| seed  | `//tc/bootstrap:seed-export`                  | stage 2 + host-tools        | distributable `tar.zst` archive |

### Stage 2 — cross-compiler

`//tc/bootstrap/stage2:stage2` is the canonical source-mode toolchain.
It builds the following chain, each step using the previous as its
compiler, with the target triple selected from the target platform:

```
host gcc + host binutils
  → cross-binutils
  → linux-headers           (kernel_arch select on platforms:is_aarch64)
  → gcc-pass1               (C only, --without-headers)
  → glibc                   (full build, lib_dir + dynamic_linker selected)
  → gcc-pass2               (C + C++, with sysroot, stage_number=2)
  → stage2_aggregator
```

The aggregator forwards `BootstrapStageInfo` from `gcc-pass2`. All four
intermediate targets are public so callers can request individual outputs
for debugging. Target triple, library subdir (`lib` vs `lib64`), and
dynamic linker (`ld-linux-aarch64.so.1` vs `ld-linux-x86-64.so.2`) are
chosen by `select()` on `//platforms:is_aarch64`; the same stage2 rules
build either architecture without code duplication.

### Stage 3 — hermetic package toolchain

`//tc/bootstrap:stage3-toolchain` wraps stage 2 in a
`buckos_bootstrap_toolchain` that exposes a `BuildToolchainInfo`
provider to the rest of the graph. There are two stage-3 toolchains
in the file, distinguished by whether `host_tools` is wired in:

* `bootstrap-toolchain` — `host_tools = None`, `allows_host_path =
  True`. Used by the host-tools aggregator and by exec-deps that have
  not yet been promoted into the hermetic PATH. The cycle-breaker.
* `stage3-toolchain` — `host_tools = None`, `allows_host_path = True`,
  with `-march=x86-64-v3` on x86_64 builds. PATH is assembled per rule
  via `host_tools_transition` rather than from a single mega target.
* `seed-toolchain` (source mode) — `host_tools =
  //tc/bootstrap:host-tools-exec`, `allows_host_path = False`. Fully
  hermetic; used as the default toolchain for package builds.

### Seed export

`//tc/bootstrap:seed-export` is a `toolchain_export` over stage 2 plus
`//tc/bootstrap/host-tools:host-tools`. The resulting archive contains:

```
tools/                                  # stage 2 cross-compiler + sysroot
  bin/<triple>-{gcc,g++,ar,ranlib,strip,...}
  lib/gcc/<triple>/<version>/{cc1,cc1plus,specs,libgcc.a,...}
  <triple>/
    bin/{ld,as,...}
    include/ ...
    lib/  or  lib64/                    # gcc runtime libs
    sys-root/
      usr/{include,lib,lib64}/ ...      # glibc + linux-headers
      lib(64)?/ld-linux-*.so.*
host-tools/                             # buckos-native host tools (FHS-like)
  bin/{bash,coreutils,make,perl,...}
  lib/, lib64/, share/, ...
metadata.json                           # gcc_version, glibc_version, triple, ...
```

The archive name embeds the triple
(`buckos-toolchain-<triple>.tar.zst`); release jobs rename to
`seed-toolchain.tar.zst` (x86_64) or `seed-toolchain-aarch64.tar.zst`
when publishing. Compression defaults to `zst`; the `compression`
attribute on `toolchain_export` can change it but is unused in tree.

## Compiler patching

After stage 2 builds, both source-mode stage-3 toolchains and the seed's
unpacked toolchain run a `patch_compiler` action implemented in
`tools/rewrite_interps.py`. It does three things:

1. **Copy** the stage tree into a declared output, hardlinking unmodified
   files and `cp -a`ing files that will be edited (ELFs, scripts with
   `buck-out` shebangs).
2. **Rewrite ELF interpreters** of compiler binaries from the standard
   host interpreter (e.g. `/lib64/ld-linux-x86-64.so.2`) to the
   sysroot's ld-linux, and **set RPATH** to the sysroot lib dirs. This
   lets `CC` be a single path with no `--sysroot` / `-specs` on the
   command line, so naïve `Makefile`s that do `type $(CC)` keep working.
3. **Install a GCC auto-loaded specs file** at
   `tools/lib/gcc/<triple>/<version>/specs`. The specs use GCC's `%R`
   sysroot substitution to embed a *padded* dynamic-linker path
   (`///…///lib64/ld-linux-*`) plus RPATH entries, so output binaries
   the compiler produces find the sysroot's libc and the GCC runtime
   libs without `LD_LIBRARY_PATH`. The padding lets `rewrite_interps.py`
   later overwrite the path in-place for relocatable seeds. The built-in
   `*libgcc:` spec is preserved alongside, because the mere presence
   of an auto-loaded specs file makes GCC drop `-lgcc_s` from the link
   line unless `*libgcc:` is explicitly present.

### Cross-arch skip

Step 2 — the interpreter rewrite — only makes sense when the host and
target architectures match. When they differ (e.g. cross-building an
aarch64 seed on an x86_64 host), the compiler binary is a host-arch
ELF; rewriting its interpreter to the target sysroot's `ld-linux-aarch64.so.1`
makes it unrunnable.

`rewrite_interps.py` detects the mismatch by sampling an ELF in
`tools/bin/` (or `bin/`), comparing its `e_machine` against the
architecture implied by `--ld-linux`. On mismatch, the patchelf loop
is **skipped entirely**; the compiler keeps its original host
interpreter and runs natively. The GCC specs install (step 3) still
runs — specs only affect the output binaries the compiler produces,
which correctly target the target arch.

Supported `e_machine` values: `EM_X86_64 = 0x3E`, `EM_AARCH64 = 0xB7`.
Adding a new architecture requires extending `_ld_linux_to_machine()`
and the `_STANDARD_INTERPS` tuple.

## Seed resolution

`//tc/seed:seed-toolchain` is the default toolchain
(`default_toolchain = buckos//tc/seed:seed-toolchain` in `.buckconfig`).
`tc/seed/defs.bzl:seed_toolchain()` resolves it from these sources, in
priority order:

| Priority | Source                | Mechanism                                               |
|----------|-----------------------|---------------------------------------------------------|
| 1        | `buckos.seed_path`    | `export_file` at the repo root, wired by `toolchain_import` |
| 2        | `buckos.seed_url`     | `http_file` (with `buckos.seed_sha256`), wired by `toolchain_import` |
| 3        | *(neither set)*       | `buckos_bootstrap_toolchain` over `//tc/bootstrap/stage2:stage2` + `//tc/bootstrap:host-tools-exec` |

Two toolchains are declared at the same priority:

* `seed-toolchain` — used by package builds.
* `seed-exec-toolchain` — used as exec_toolchain by exec-deps (tools
  that run on the build host). In source mode it has the same
  configuration as `seed-toolchain`; in prebuilt mode it uses the same
  archive with `exec_mode = True`.

In prebuilt-seed mode, the archive's host-tools directory is also
exposed at `//tc/seed:seed-archive-ref`, used by tests that need a
stable label for the seed.

## Target platforms and triples

| Constraint                             | Triple                          | Library subdir | ld-linux             |
|----------------------------------------|---------------------------------|----------------|----------------------|
| `prelude//cpu/constraints:x86_64`      | `x86_64-buckos-linux-gnu`       | `lib64`        | `ld-linux-x86-64.so.2` |
| `prelude//cpu/constraints:arm64`       | `aarch64-buckos-linux-gnu`      | `lib`          | `ld-linux-aarch64.so.1` |

The `//platforms:is_aarch64` config-setting drives every architecture
select in `tc/bootstrap/stage2/BUCK` and `tc/seed/defs.bzl`. The x86_64
path also passes `-march=x86-64-v3` and the cf-protection-disable flags
that BuckOS's glibc was patched for. The aarch64 path passes neither.

## Building a seed

```bash
# Build the seed for the host architecture
buck2 build //tc/bootstrap:seed-export --out seed-toolchain.tar.zst

# Build an aarch64 seed (runs natively on aarch64 hosts; on x86_64 hosts
# the cross-arch patchelf skip is required and the per-package
# cross-compile support is still incomplete -- prefer native ARM hosts).
buck2 build //tc/bootstrap:seed-export \
    --target-platforms //platforms:linux-aarch64-target \
    --out seed-toolchain-aarch64.tar.zst

# Consume a prebuilt seed
cat >> .buckconfig.local <<'EOF'
[buckos]
seed_path = seed-toolchain.tar.zst
EOF
buck2 build //packages/linux/system:buckos-rootfs
```

## Implementation references

* `tc/bootstrap/BUCK` — `bootstrap-toolchain`, `stage3-toolchain`,
  `host-tools-exec`, `seed-export`, `patchelf-host`.
* `tc/bootstrap/stage2/BUCK` — Stage 2 chain
  (`cross-binutils` → `linux-headers` → `gcc-pass1` → `glibc` →
  `gcc-pass2` → `stage2`).
* `tc/bootstrap/aarch64/BUCK` — alternate hand-rolled aarch64
  cross-toolchain (predates the `select()`-aware stage 2; kept for
  cross-compile experiments that don't go through the target-platform
  switch).
* `tc/bootstrap/host-tools/packages.bzl` — `HOST_TOOL_PACKAGES`, the
  set of packages bundled into the seed's `host-tools/` tree.
* `tc/seed/defs.bzl` — `seed_toolchain()`, the three-way resolver.
* `tc/toolchain_rules.bzl` — `buckos_bootstrap_toolchain` rule,
  `_buckos_bootstrap_toolchain_impl` (declares the `patch_compiler`
  action, lines 140–256).
* `defs/rules/toolchain_import.bzl` — unpacks a prebuilt seed archive.
* `defs/rules/toolchain_export.bzl` — produces the seed archive
  (`buckos-toolchain-<triple>.tar.zst`).
* `defs/rules/host_tools_exec.bzl` — `host_tools_exec`, the
  source-mode host-tools rewriter (patches interpreters in already-built
  host tools to point at the sysroot ld-linux).
* `tools/rewrite_interps.py` — `patch_compiler` worker. Hosts the
  cross-arch skip in the `--patch-standard` branch (`_elf_machine`,
  `_ld_linux_to_machine`).
* `tools/toolchain_pack.py` — packs a stage into the seed archive.
* `tools/toolchain_unpack.py` — extracts and prepares a seed archive
  on the consuming side.

## Test surface

* `//tests:test-toolchain-unpack` — unit tests for archive extraction.
* `//tests:test-bootstrap-helpers` — unit tests for stage helpers.
* `//tests:test-stage3-strip` — verifies stage 3 stripping behaviour.
* `//tests:test-sysroot-merge` — verifies sysroot merging.
* `//tests:test-seed-isolation` — end-to-end seed bootstrap test.
* CI: `build` job (x86_64) and `build-aarch64-seed` job (aarch64)
  in `.github/workflows/ci.yml` exercise the full
  `//tc/bootstrap:seed-export` path and publish the archives as
  release artifacts.

## Security considerations

* The seed archive is the trust anchor for every downstream build. Both
  `seed_url` consumers must pin `seed_sha256`. Releases publish the
  archive alongside its SHA-256 in the GitHub release notes.
* `patch_compiler` writes RPATH entries that point into `buck-out/`
  paths. These are local-only paths; the action is declared
  `local_only = True` and `allow_cache_upload = False` to prevent
  remote-cache pollution with host-specific paths.
* The host bootstrap (`gcc-pass1`, `glibc`, `gcc-pass2`) trusts the
  host `gcc` to produce correct code. Reproducibility across hosts is
  validated by content-hashing the seed archive after build, not by
  bit-for-bit equality of intermediate artifacts.

## Alternatives considered

### Single-stage native build with no patching

**Why rejected**: GCC needs to know its sysroot at compile time so that
`<stdio.h>` and friends come from BuckOS glibc rather than the host's.
Configuring with `--with-sysroot=<absolute-path>` bakes in a path that
breaks once `buck-out/` paths change. The patched-binary + auto-loaded
specs pattern lets GCC find its sysroot via `%R` without absolute path
substitutions.

### Always cross-compile through a canadian cross

**Why rejected**: A canadian cross would require three host environments
per build (build → host → target) and would not let a native aarch64
runner short-circuit the cross step. The current `select()`-driven
stage 2 produces a native-or-cross compiler with one rule path.

### Distribute the seed via Buck2 remote cache

**Why rejected**: The seed archive is consumed by the seed-resolution
code at *parse* time (the archive label feeds an `http_file`/`export_file`).
Buck2's remote cache is action-cache only; a seed download has to be
an `http_file` action, not a cache lookup.

## References

* SPEC-001 — Package Manager Integration (toolchain consumer API)
* `CLAUDE.md` — Developer guide (mirror & seed configuration section)
* `tools/rewrite_interps.py` — Implementation of the patching contract
