# BuckOS Build System Specification

## Project Overview

BuckOS is a Buck2-based Linux distribution. It defines packages as first-class
Buck2 `rule()` targets with typed providers, composable post-install transforms,
USE-flag selection via constraints, and BXL-driven SBOM/vendor/test tooling.

This document is the authoritative reference for what BuckOS *is today*. When
the spec disagrees with the code, treat that as a documentation bug to fix here
(not the other way around). Aspirational features are explicitly labeled as
**Future work** in the section where they would live.

---

## Architecture Principles

1. **rule() over genrule.** Every package type (autotools, cmake, meson, cargo,
   go, perl, python, mozbuild, binary, kernel) is a first-class Buck2 rule with
   typed attributes, not a macro wrapping a genrule shell command.

2. **Discrete cacheable actions.** Each build phase (extract, prepare,
   configure, compile, install) is a separate `ctx.actions.run()` call. Buck2
   skips phases whose inputs haven't changed. Separate actions also mean a
   configure failure can be debugged without re-extracting source, and BXL can
   introspect individual phase outputs.

3. **Python helpers over shell.** Action scripts live in `tools/*.py` (see
   *Python Helper Scripts* below). They take explicit argparse flags, fail
   loudly, and are independently testable.

4. **Typed providers.** Rules return `PackageInfo` with structured fields
   (include dirs, lib dirs, library names, SBOM metadata). Downstream rules
   consume typed data, not opaque output directories.

5. **Composable transforms.** Post-install operations (`strip_package`,
   `stamp_package`, `ima_sign_package`) are separate rules taking a
   `PackageInfo` and returning a new `PackageInfo`. They compose as an explicit
   target chain visible in the build graph, not hidden conditionals inside a
   rule impl.

6. **Three orthogonal axes.** Target platform (arch/OS), USE flags (feature
   selection), and toolchain mode (which compiler) are independent concerns
   composed at build time. Toolchain mode is encoded as a constraint on the
   target platform (see *Toolchains*), not a separate `--config` key.

7. **Three testing layers.** BXL scripts (`tests/graph/`) check graph
   structure. Python unit tests (`tests/test_*.py`) exercise helpers in
   isolation. `vm_test` rules boot QEMU and assert runtime behavior.

8. **select() for USE flags, never read_config().** USE flags are constraint
   values resolved via `select()` in rule attributes. `read_config()` values
   do not enter Buck2's configuration hashes (silent correctness bug), cannot
   be observed from BXL at analysis time, and don't compose with modifiers.
   `.buckconfig` MUST NOT contain `[use]` or `[use_expand]` sections.

---

## Directory Layout

```
buckos-build/
├── .buckconfig
├── .buckroot
├── BUCK                            # Root targets
├── PACKAGE                         # Default platform/modifiers for the tree
│
├── platforms/
│   └── BUCK                        # linux-x86_64, linux-aarch64,
│                                   # linux-target, linux-target-host,
│                                   # linux-aarch64-target,
│                                   # linux-aarch64-target-host, plus the
│                                   # toolchain_mode constraint
│
├── use/                            # USE flag constraints + profiles
│   ├── constraints/
│   │   ├── BUCK
│   │   └── defs.bzl                # use_flag(), use_expand(), use_expand_multi()
│   └── profiles/
│       └── BUCK                    # Named modifier groups
│
├── tc/                             # Toolchains (regular dir, NOT a cell)
│   ├── defs.bzl                    # buckos_execution_platforms() helper
│   ├── toolchain_rules.bzl         # buckos_* toolchain rules
│   ├── transitions.bzl
│   ├── exec/BUCK                   # :platforms aggregate + mode constraints
│   ├── host/BUCK                   # Host system toolchain
│   ├── prebuilt/BUCK               # Pre-exported toolchain tarball
│   ├── seed/                       # Hermetic seed toolchain (BUCK + defs.bzl)
│   └── bootstrap/                  # Self-hosted bootstrap chain
│       ├── BUCK
│       ├── sources/                # Source archives shared across stages
│       ├── host-tools/             # Wrappers around host PATH tools
│       ├── stage2/                 # Native compiler + libc built with seed
│       ├── go/                     # Bootstrap Go (Go can't bootstrap from C)
│       └── aarch64/                # aarch64-specific bootstrap pieces
│
├── defs/                           # Build definitions
│   ├── BUCK
│   ├── package.bzl                 # The package() macro (escape hatch)
│   ├── packages/                   # User-facing wrappers (thin shims)
│   │   ├── autotools.bzl           # autotools_package, make_package
│   │   ├── binary.bzl              # binary_package
│   │   ├── cargo.bzl               # cargo_package
│   │   ├── cmake.bzl               # cmake_package
│   │   ├── go.bzl                  # go_package
│   │   ├── meson.bzl               # meson_package
│   │   ├── mozbuild.bzl            # mozbuild_package
│   │   ├── perl.bzl                # perl_package
│   │   └── python.bzl              # python_package
│   ├── rules/                      # Underlying rule implementations
│   │   ├── _common.bzl             # COMMON_PACKAGE_ATTRS + shared phase logic
│   │   ├── autotools.bzl           # autotools_build
│   │   ├── binary.bzl              # binary_build
│   │   ├── cargo.bzl               # cargo_build
│   │   ├── cmake.bzl               # cmake_build
│   │   ├── go.bzl                  # go_build
│   │   ├── meson.bzl               # meson_build
│   │   ├── mozbuild.bzl            # mozbuild_build
│   │   ├── perl.bzl                # perl_build
│   │   ├── python.bzl              # python_build
│   │   ├── kernel.bzl              # kernel_build, kernel_config,
│   │   │                           # kernel_headers, kernel_btf_headers,
│   │   │                           # kernel_modules_install
│   │   ├── source.bzl              # extract_source
│   │   ├── transforms.bzl          # strip_package, stamp_package,
│   │   │                           # ima_sign_package
│   │   ├── rootfs.bzl              # rootfs
│   │   ├── initramfs.bzl           # initramfs, dracut_initramfs
│   │   ├── image.bzl               # raw_disk_image, iso_image, stage3_tarball
│   │   ├── boot.bzl                # qemu_boot_script, ch_boot_script
│   │   ├── bootstrap.bzl           # bootstrap_binutils, bootstrap_gcc,
│   │   │                           # bootstrap_glibc, bootstrap_linux_headers,
│   │   │                           # bootstrap_python, bootstrap_package
│   │   ├── stage2_wrapper.bzl      # stage2 compiler wrapper
│   │   ├── host_tools_exec.bzl     # host_tools_exec
│   │   ├── toolchain_export.bzl    # toolchain tarball export
│   │   ├── toolchain_import.bzl    # toolchain tarball import
│   │   ├── acct.bzl                # acct_group_package, acct_user_package
│   │   ├── runtime_env.bzl         # runtime_env
│   │   ├── test_host_env.bzl       # test_host_env
│   │   ├── buckos_test.bzl         # buckos_test (hermetic sh_test wrapper)
│   │   └── vm_test.bzl             # vm_test
│   ├── use_helpers.bzl             # use_bool, use_dep, use_configure_arg,
│   │                               # use_feature, use_expand_select,
│   │                               # use_expand_dep, use_expand_multi_deps,
│   │                               # use_versioned_dep
│   ├── package_sets.bzl            # system_set, package_set, combined_set,
│   │                               # task_set, desktop_set, language_set,
│   │                               # union_sets, intersection_sets,
│   │                               # difference_sets, plus USE_PROFILES dict
│   ├── providers.bzl               # PackageInfo and friends
│   ├── tsets.bzl                   # Transitive sets used by package rules
│   ├── toolchain_helpers.bzl       # TOOLCHAIN_ATTRS, toolchain_path_args
│   ├── host_tools.bzl              # _all_host_tools helpers
│   ├── download.bzl                # download_file (mirror-aware http_file)
│   ├── empty_registry.bzl          # PATCH_REGISTRY = {} default
│   ├── vendor_sources.bxl          # BXL: vendor sources for offline builds
│   ├── keys/                       # Test IMA keys
│   └── scripts/                    # Tracked shell helpers used by rules
│
├── tools/                          # Python action helpers + sbom BXL
│   ├── BUCK
│   ├── _env.py                     # clean_env, sysroot_lib_paths, etc.
│   ├── extract.py
│   ├── patch_helper.py
│   ├── configure_helper.py
│   ├── build_helper.py
│   ├── install_helper.py
│   ├── cargo_helper.py
│   ├── cmake_helper.py
│   ├── go_helper.py
│   ├── meson_helper.py
│   ├── mozbuild_helper.py
│   ├── perl_helper.py
│   ├── python_helper.py
│   ├── binary_install_helper.py
│   ├── kernel_build.py
│   ├── kernel_config.py
│   ├── kernel_headers.py
│   ├── kernel_btf_headers.py
│   ├── kernel_modules_install.py
│   ├── boot_script_helper.py
│   ├── disk_image_helper.py
│   ├── iso_helper.py
│   ├── initramfs_helper.py
│   ├── initramfs_builder.py
│   ├── dracut_initramfs_helper.py
│   ├── rootfs_helper.py
│   ├── stage3_helper.py
│   ├── stage2_wrapper_helper.py
│   ├── bootstrap_gcc_configure.py
│   ├── bootstrap_glibc_configure.py
│   ├── bootstrap_python_configure.py
│   ├── sysroot_merge.py
│   ├── toolchain_pack.py
│   ├── toolchain_unpack.py
│   ├── merge_host_tools.py
│   ├── strip_helper.py
│   ├── stamp_helper.py
│   ├── ima_helper.py
│   ├── acct_helper.py
│   ├── elf_audit.py
│   ├── rewrite_interps.py
│   ├── gen_runtime_env.py
│   ├── gen_test_host_env.py
│   ├── cache_stats.py
│   ├── verify_bootstrap.sh
│   ├── check_hermeticity.sh
│   ├── vm_test_runner.py
│   └── sbom.bxl                    # SBOM generation BXL script
│
├── patches/                        # Optional private patch registry (gitignored)
│   ├── BUCK                        # export_file targets
│   └── registry.bzl                # User-maintained PATCH_REGISTRY
│
├── packages/linux/                 # Packages by category
│   └── ...
│
└── tests/
    ├── graph/                      # BXL graph-structure tests
    │   ├── test_deps.bxl
    │   ├── test_use_flags.bxl
    │   ├── test_transforms.bxl
    │   ├── test_labels.bxl
    │   ├── test_versions.bxl
    │   ├── test_sources.bxl
    │   ├── test_provenance.bxl
    │   ├── test_dedup.bxl
    │   ├── test_hermiticity.bxl
    │   ├── test_targets.bxl
    │   ├── test_bootstrap_isolation.bxl
    │   ├── test_cloud_hypervisor.bxl
    │   ├── test_graph.bxl
    │   └── test_all.bxl
    ├── fixtures/
    └── test_*.py                   # Python unit tests for helpers
```

---

## .buckconfig

`.buckconfig` registers cells, the default target platform, the execution
platforms aggregate, and the source-mirror configuration. It does NOT (and
must not) contain `[use]` or `[use_expand]` sections — see Architecture
Principle 8.

```ini
[cells]
  buckos = .
  prelude = prelude
  toolchains = toolchains

[cell_aliases]
  config = prelude
  buck = buckos

[external_cells]
  prelude = bundled

[build]
  default_target_platform = //platforms:linux-x86_64
  execution_platforms = //tc/exec:platforms

[parser]
  target_platform_detector_spec = \
    target:buckos//...->buckos//platforms:linux-x86_64 \
    target:toolchains//...->buckos//platforms:linux-x86_64

[project]
  ignore = .git, buck-out, **/__pycache__, .claude, .buckos

[buckos]
  # Optional: prebuilt seed toolchain (skips source-mode tool build).
  # seed_path = /abs/path/to/seed.tar.zst
  # seed_url  = https://example.com/seed.tar.zst

  # Optional: default toolchain pointer used by some rules.
  default_toolchain = buckos//tc/seed:seed-toolchain

[buckos.cache]
  # ccache/sccache injection for package builds.
  mode = enabled            # enabled | disabled
  location = homedir        # homedir | projectdir
  ccache_size = 100G
  sccache_size = 100G

[mirror]
  # mode: "upstream" (default) downloads via http_file; "vendor" uses
  # export_file from a local directory (air-gapped builds).
  mode = upstream

  # base_url: prepended to http_file urls list (tried before upstream).
  # base_url = https://mirror.corp.example.com/sources

  # vendor_dir: repo-relative dir of vendored archives. Used when mode=vendor.
  # vendor_dir = vendor/distfiles

  # prefix / params: optional alternate mirror layout used by package.bzl
  # ({prefix}/{first_char}/{name}-{version}-{sha256[:12]}{ext}{params}).
  # prefix = https://mirror.corp.example.com/buckos
  # params =
```

Notes on the keys above:

- `[buckos] seed_path` / `seed_url` is the live switch between **source mode**
  (build every host tool from source) and **seed mode** (hermetic PATH from a
  prebuilt seed). See `defs/package.bzl:74-82`.
- `[buckos.cache]` is read by `defs/package.bzl::_cache_env` and injected as
  `CCACHE_*` env vars for configurable build rules.
- `[buckos] patch_registry_enabled` is **not** consulted anywhere in code; the
  registry is enabled by which `load()` line at the top of
  `defs/package.bzl` is active (see *Private Patch Registry*).
- `[buckos] default_toolchain` is read by a small number of rules; most
  toolchain selection flows through the target platform constraints.

**Why `toolchains` is a cell, not an alias:** The prelude resolves toolchains
via `toolchains//:NAME` (hardcoded in `attrs.toolchain_dep` defaults). If
`toolchains` is a cell alias to `buckos`, then `toolchains//:python` resolves
to `buckos//:python` — wrong directory. Registering `toolchains = toolchains`
as a proper cell makes the prelude find rules in `toolchains/BUCK`.

**Why `buckos` not `root`:** Cell aliases are global. Using `root = .` would
conflict with a monorepo that does the same. `buckos` is unique whether
buckos is standalone (`buckos = .`) or embedded (`buckos = third-party/buckos`).

`use/` and `tc/` are **regular directories within the `buckos` cell**, not
cells themselves. Do not add `use` or `tc` to `[cells]`.

---

## Providers

### PackageInfo

Every package rule returns this. It is the typed contract between packages.

```python
# defs/providers.bzl

PackageInfo = provider(fields = [
    # Identity
    "name",
    "version",

    # Build outputs
    "prefix",
    "include_dirs",
    "lib_dirs",
    "bin_dirs",
    "libraries",
    "pkg_config_path",

    # Extra flags consumers need
    "cflags",
    "ldflags",

    # SBOM metadata
    "license",
    "src_uri",
    "src_sha256",
    "homepage",
    "supplier",
    "description",
    "cpe",
])
```

Toolchain rules return a `BuildToolchainInfo` provider and bootstrap stages
return a `BootstrapStageInfo` provider; see `defs/providers.bzl` for the exact
field list as it currently stands.

---

## Build Rules

All package rules accept the attrs in `COMMON_PACKAGE_ATTRS` (see
`defs/rules/_common.bzl`) plus rule-specific attrs. Common attrs include
`source`, `version`, `configure_args`, `pre_configure_cmds`,
`post_install_cmds`, `env`, `use_env`, `deps`, `host_deps`, `runtime_deps`,
`patches`, `extra_cflags`, `extra_ldflags`, `linker`, `libraries`, `labels`,
and the SBOM fields (`license`, `src_uri`, `src_sha256`, `homepage`,
`description`, `cpe`).

### extract_source

Extracts source archives. Downloading is handled by the prelude's `http_file`
(or `export_file` for vendored archives). The `package()` macro creates both
targets automatically.

Attributes: `source` (dep, required), `strip_components` (default 1),
`format` (override auto-detection — supports `tar.gz`, `tar.xz`, `tar.bz2`,
`tar.zst`, `tar.lz`, `tar.lz4`, `tar`, `zip`), `exclude_patterns`
(list of glob patterns to drop during extraction).

### autotools_build (`autotools_package`, `make_package`)

`./configure && make && make install` packages. The rule's implementation
runs the following discrete actions:

1. **`src_prepare`** — apply patches via `tools/patch_helper.py` and run
   `pre_configure_cmds`. Zero-cost passthrough when there are no patches or
   pre-configure commands (no action runs).
2. **`src_configure`** — run `./configure` via `tools/configure_helper.py`.
3. **`src_compile`** — run `make` via `tools/build_helper.py`.
4. **`src_install`** — run `make install DESTDIR=...` via
   `tools/install_helper.py`, then any `post_install_cmds`.

Extraction is **not** a phase of this rule. The package() macro creates a
`:name-src` `extract_source` target, and the build rule receives the already-
extracted directory through its `source` attr. This means re-extracting only
re-runs the cheap `extract_source` action; the build rule's action hash
depends on the extracted-source artifact.

`make_package` is the same rule with `skip_configure=True` by default.

USE flags do NOT add or remove phases. They affect attrs that the phases read
(`configure_args`, `deps`, `patches`, `extra_cflags`, `extra_ldflags`,
`use_env`); these are resolved by `select()` before the rule impl runs.

### cmake_build (`cmake_package`)

Phases: `src_prepare`, `cmake_configure`, `src_compile`, `src_install`. Uses
`tools/cmake_helper.py` and `tools/build_helper.py`.

### meson_build (`meson_package`)

Phases: `src_prepare`, `meson_setup`, `src_compile`, `src_install`. Uses
`tools/meson_helper.py`.

### cargo_build (`cargo_package`)

Rust/Cargo packages. Phases: `src_prepare`, `cargo_build`, install. Uses
`tools/cargo_helper.py`. Rule-specific attrs: `features`, `cargo_args`,
`bins`, `vendor_deps`. The `vendor_deps` attr is interpreted by the
`package()` macro (see *vendor_deps semantics* below).

### go_build (`go_package`)

Go packages. Phases: `src_prepare`, `go_build`, install. Uses
`tools/go_helper.py`. Rule-specific attrs: `go_args`, `ldflags`, `bins`,
`packages`, `vendor_deps`, `lib_only`.

### perl_build (`perl_package`)

Perl packages built with `perl Makefile.PL && make && make install`. Uses
`tools/perl_helper.py`.

### python_build (`python_package`)

Python packages built with `pip install` (or `setup.py install`). Uses
`tools/python_helper.py`. Rule-specific attrs: `use_setup_py`, `pip_args`.

### mozbuild_build (`mozbuild_package`)

Firefox / mach-based builds. Uses `tools/mozbuild_helper.py`.

### binary_build (`binary_package`)

Custom `install_script` for prebuilt or unusual packages. The script is run
by `tools/binary_install_helper.py`, which injects the same dep paths,
env vars, and use_env as the structured build rules. Used both for genuine
"opaque" packages and as the implicit dispatch target when a caller passes
`src_compile` / `src_install` to `autotools_package()` (see
`defs/package.bzl:614-637`).

### Kernel rules

In `defs/rules/kernel.bzl`:

- `kernel_config` — produce a `.config` (merge fragments, run defconfig, etc.)
- `kernel_build` — full kernel build. Accepts `patches` and `modules` for
  external module sources.
- `kernel_headers` — install `make headers_install` output.
- `kernel_btf_headers` — extract BTF-derived headers.
- `kernel_modules_install` — install modules into a separate prefix.

### Image / boot / rootfs rules

- `rootfs` (`defs/rules/rootfs.bzl`) — assembles packages into a root
  filesystem by merging their `prefix` directories. Driven by
  `tools/rootfs_helper.py`.
- `initramfs`, `dracut_initramfs` (`defs/rules/initramfs.bzl`) — build an
  initramfs from a rootfs (CPIO or dracut).
- `raw_disk_image`, `iso_image`, `stage3_tarball` (`defs/rules/image.bzl`).
- `qemu_boot_script`, `ch_boot_script` (`defs/rules/boot.bzl`) — generate
  invocable boot scripts for QEMU and Cloud Hypervisor.

### Account rules

`acct_group_package`, `acct_user_package` (`defs/rules/acct.bzl`) — pure
metadata packages that contribute entries to `/etc/passwd` and `/etc/group`
at rootfs assembly time. Driven by `tools/acct_helper.py`.

### Transform rules (`defs/rules/transforms.bzl`)

Each transform takes a dep with `PackageInfo` and returns a new
`DefaultInfo + PackageInfo` whose `prefix` is the transformed output.

- **`strip_package`** — strip ELF debug symbols. Attrs: `package`, `enabled`.
- **`stamp_package`** — inject build provenance (`.note.package`). Attrs:
  `package`, `enabled`, `build_id`.
- **`ima_sign_package`** — IMA signatures via `evmctl`. Attrs: `package`,
  `enabled`, `signing_key`.

When `enabled=False`, transforms are a zero-cost passthrough that re-emits
the input `PackageInfo` unchanged (`_passthrough(pkg)`), so the target
always exists in the graph regardless of USE flag values.

### Test rules

- `buckos_test` (`defs/rules/buckos_test.bzl`) — hermetic `sh_test` wrapper.
- `vm_test` (`defs/rules/vm_test.bzl`) — boot kernel + rootfs in QEMU via KVM
  and run commands. Attrs: `kernel`, `rootfs`, `commands`,
  `inject_binaries` (path-in-VM → buck target), `timeout_secs`, `memory_mb`,
  `cpus`. Driven by `tools/vm_test_runner.py`. Returns `ExternalRunnerTestInfo`
  so `buck2 test` runs it.

### Bootstrap rules (`defs/rules/bootstrap.bzl`)

Specialised rules used inside `tc/bootstrap/`: `bootstrap_binutils`,
`bootstrap_linux_headers`, `bootstrap_gcc`, `bootstrap_glibc`,
`bootstrap_python`, and a generic `bootstrap_package`. These bypass the
package() macro because they need precise control over the
chicken-and-egg ordering of the self-hosted toolchain build.

### Helper rules

- `host_tools_exec` (`defs/rules/host_tools_exec.bzl`) — execution-platform
  glue for the seed/host-tools modes.
- `toolchain_export` / `toolchain_import` — pack and unpack toolchain tarballs.
- `stage2_wrapper` — wraps the stage2 compiler with the correct lib paths.
- `runtime_env`, `test_host_env` — generated environment files for test/run.

---

## Python Helper Scripts (`tools/`)

All non-trivial action logic lives in Python helpers, not shell. Each helper:

- accepts argparse flags (no env-var soup),
- exits non-zero with a clear error on failure,
- is independently runnable for debugging,
- is registered as a `python_binary` or `export_file` target in `tools/BUCK`.

Build-system helpers, one per rule:

| Helper | Used by |
|---|---|
| `tools/extract.py` | `extract_source` (universal archive extractor) |
| `tools/patch_helper.py` | `src_prepare` in every package rule |
| `tools/configure_helper.py` | `autotools_build` configure phase |
| `tools/build_helper.py` | autotools/cmake/meson compile phase |
| `tools/install_helper.py` | autotools install phase |
| `tools/cmake_helper.py` | `cmake_build` |
| `tools/meson_helper.py` | `meson_build` |
| `tools/cargo_helper.py` | `cargo_build` |
| `tools/go_helper.py` | `go_build` |
| `tools/perl_helper.py` | `perl_build` |
| `tools/python_helper.py` | `python_build` |
| `tools/mozbuild_helper.py` | `mozbuild_build` |
| `tools/binary_install_helper.py` | `binary_build` and the autotools macro's `src_install` shortcut |
| `tools/strip_helper.py` | `strip_package` |
| `tools/stamp_helper.py` | `stamp_package` |
| `tools/ima_helper.py` | `ima_sign_package` |
| `tools/acct_helper.py` | `acct_*_package` |

Kernel:

| Helper | Used by |
|---|---|
| `tools/kernel_build.py` | `kernel_build` |
| `tools/kernel_config.py` | `kernel_config` |
| `tools/kernel_headers.py` | `kernel_headers` |
| `tools/kernel_btf_headers.py` | `kernel_btf_headers` |
| `tools/kernel_modules_install.py` | `kernel_modules_install` |

Images / boot / rootfs:

| Helper | Used by |
|---|---|
| `tools/rootfs_helper.py` | `rootfs` |
| `tools/initramfs_helper.py`, `tools/initramfs_builder.py` | `initramfs` |
| `tools/dracut_initramfs_helper.py` | `dracut_initramfs` |
| `tools/disk_image_helper.py` | `raw_disk_image` |
| `tools/iso_helper.py` | `iso_image` |
| `tools/stage3_helper.py` | `stage3_tarball` |
| `tools/boot_script_helper.py` | `qemu_boot_script`, `ch_boot_script` |
| `tools/vm_test_runner.py` | `vm_test` |

Bootstrap / toolchain plumbing:

| Helper | Used by |
|---|---|
| `tools/bootstrap_gcc_configure.py` | `bootstrap_gcc` |
| `tools/bootstrap_glibc_configure.py` | `bootstrap_glibc` |
| `tools/bootstrap_python_configure.py` | `bootstrap_python` |
| `tools/stage2_wrapper_helper.py` | `stage2_wrapper` |
| `tools/sysroot_merge.py` | merge sysroot artifacts |
| `tools/toolchain_pack.py`, `tools/toolchain_unpack.py` | toolchain tarball I/O |
| `tools/merge_host_tools.py` | seed/host-tools merge |
| `tools/elf_audit.py` | bootstrap verification |
| `tools/rewrite_interps.py` | rewrite ELF interpreters in rootfs |

Shared modules / verifiers:

- `tools/_env.py` — `clean_env`, `sysroot_lib_paths`, `derive_lib_paths`,
  and other env primitives used by every helper.
- `tools/gen_runtime_env.py`, `tools/gen_test_host_env.py` — generate env
  files consumed by `runtime_env` / `test_host_env` rules.
- `tools/cache_stats.py` — ccache/sccache stats reporting.
- `tools/verify_bootstrap.sh` — bootstrap-toolchain hermeticity checks.
- `tools/check_hermeticity.sh` — generic per-build hermeticity check.

BXL scripts:

- `tools/sbom.bxl` — SBOM generation (see *SBOM Generation*).
- `defs/vendor_sources.bxl` — vendor sources for offline builds (see
  *Source Mirrors and Vendoring*).

---

## USE Flags (`use/` directory)

### Constraint definitions

```python
# use/constraints/defs.bzl

def use_flag(name):
    """Simple on/off USE flag."""
    constraint_setting(name = name)
    constraint_value(name = name + "-on",  constraint_setting = ":" + name)
    constraint_value(name = name + "-off", constraint_setting = ":" + name)

def use_expand(name, values):
    """USE_EXPAND single-select: pick exactly one value."""
    constraint_setting(name = name)
    for v in values:
        constraint_value(name = name + "-" + v, constraint_setting = ":" + name)

def use_expand_multi(name, values):
    """USE_EXPAND multi-select: enable any combination of values."""
    for v in values:
        flag_name = name + "_" + v
        constraint_setting(name = flag_name)
        constraint_value(name = flag_name + "-on",  constraint_setting = ":" + flag_name)
        constraint_value(name = flag_name + "-off", constraint_setting = ":" + flag_name)
```

### Helper functions (`defs/use_helpers.bzl`)

```python
def use_bool(flag): ...                                # bool select()
def use_dep(flag, dep): ...                            # [dep] / []
def use_configure_arg(flag, on_arg, off_arg = None): ...  # arg lists
def use_feature(flag, feature): ...                    # cargo features
def use_expand_select(expand_name, value_map): ...
def use_expand_dep(expand_name, value, dep): ...
def use_expand_multi_deps(expand_name, value_dep_map): ...
def use_versioned_dep(expand_name, version_map): ...   # slot-style version pick
```

All of these return `select()` expressions resolved at analysis time.

### Profiles

Profiles are named modifier groups. They set USE flag values in bulk and are
applied as `?//use/profiles:NAME` on the command line or via PACKAGE files.

```
buck2 build //packages/linux/network/curl:curl ?//use/profiles:minimal
buck2 build //packages/linux/network/curl:curl ?//use/profiles:server
buck2 build //packages/linux/network/curl:curl ?//use/profiles:desktop
buck2 build //packages/linux/network/curl:curl ?//use/profiles:developer
buck2 build //packages/linux/network/curl:curl ?//use/profiles:hardened
```

| Profile | Description |
|---------|-------------|
| minimal | Bare minimum for a bootable system. Most flags off. |
| server | Headless server: ssl, http2, static, strip, stamp. |
| desktop | Full desktop: ssl, http2, plus GUI/audio/media flags. |
| developer | Like desktop but with debug symbols, no strip, extra dev tools. |
| hardened | Like server but with IMA, static linking, security-focused flags. |

Individual flags can override the profile:

```
buck2 build //packages/linux/network/curl:curl \
    ?//use/profiles:minimal ?//use/constraints:http2-on
```

`defs/package_sets.bzl` also exports a `USE_PROFILES` dict used by
`system_set` to materialize profile-driven USE flag lists.

### Modifier resolution order

Buck2 resolves modifiers in this order (highest priority first):

1. **CLI modifiers** (`buck2 build ... -m flag`) — one-shot, all targets
2. **Target modifiers** (`modifiers` attr on rule)
3. **PACKAGE modifiers** (`set_cfg_modifiers()` in PACKAGE files)
4. **Platform defaults**

Mapped to Gentoo:

| Buck2 | Gentoo equivalent |
|-------|-------------------|
| CLI `-m` | `emerge --use` (one-shot) |
| PACKAGE modifiers (per-package) | `package.use` |
| PACKAGE modifiers (global) | `make.conf USE=` |
| Platform defaults | Profile defaults |

**Future work — local/per-package modifier installer tooling.** A
`config/local_modifiers.bzl` (loaded by the root PACKAGE), and a
buckos CLI that materializes `set_cfg_modifiers()` PACKAGE files per
package were specified in earlier drafts but are not implemented today.

---

## Toolchains (`tc/` directory)

### Architecture

Target platform (what we're building FOR) and execution platform (what we're
building WITH) are separate Buck2 concepts.

Targets live under `//platforms`:

- `//platforms:linux-x86_64`, `//platforms:linux-aarch64` — bare arch+OS.
- `//platforms:linux-target` — x86_64 + `bootstrap-toolchain` + systemd-on.
- `//platforms:linux-target-host` — x86_64 + `host-toolchain` + systemd-on.
- `//platforms:linux-aarch64-target` / `linux-aarch64-target-host` — aarch64
  variants.

Execution platforms live under `//tc/exec:platforms` (the aggregate set
in `[build] execution_platforms`) and select between host, seed, prebuilt,
and the bootstrap chain. The mode constraints `:bootstrap-mode-true`,
`:bootstrap-mode-false`, `:host-target-mode`, and `:host-tools-mode` (with
the corresponding `config_setting`s `:is-bootstrap-mode`, `:is-host-target`,
`:is-host-tools-mode`) live in `tc/exec/BUCK` and are queried from
`defs/package.bzl` to gate auto-injected host tools and exec deps.

### Selecting a toolchain

The toolchain comes from the **target platform**, not a `--config` key:

```
# Bootstrap (self-hosted) toolchain — the default for reproducible builds
buck2 build //packages/linux/core/zlib:zlib \
    --target-platforms //platforms:linux-target

# Host toolchain — faster dev iteration
buck2 build //packages/linux/core/zlib:zlib \
    --target-platforms //platforms:linux-target-host

# aarch64 equivalents
buck2 build //packages/linux/core/zlib:zlib \
    --target-platforms //platforms:linux-aarch64-target
buck2 build //packages/linux/core/zlib:zlib \
    --target-platforms //platforms:linux-aarch64-target-host
```

The `bootstrap-toolchain` / `host-toolchain` constraint values on each
`linux-*-target*` platform feed into the `select()` inside `TOOLCHAIN_ATTRS`
(`defs/toolchain_helpers.bzl`), which picks the right compiler.

### Source mode vs seed mode

Independent of target platform, BuckOS supports two ways to obtain the host
build tools (`bash`, `make`, `perl`, `python`, `cmake`, `meson`, `ninja`,
`pkg-config`, …):

- **Source mode (default):** every host tool is built from source as part of
  the graph. Selected when `[buckos] seed_path` and `seed_url` are both
  unset (`_SOURCE_MODE = True` in `defs/package.bzl`).
- **Seed mode:** a prebuilt seed tarball is unpacked into a hermetic PATH.
  `defs/package.bzl::_HAS_PREBUILT_SEED` becomes true when either
  `seed_path` or `seed_url` is set. In this mode the macro skips
  auto-injecting host-tool exec deps and gates explicit `host_deps` against
  `tc/bootstrap/host-tools:packages.bzl::HOST_TOOL_PACKAGES`.

### Bootstrap chain layout

The current bootstrap tree (`tc/bootstrap/`):

- `sources/` — shared source archives.
- `host-tools/` — wrappers over PATH tools used during seed bootstrap.
- `stage2/` — native compiler + libc built using the seed.
- `go/` — bootstrap Go (Go can't bootstrap purely from C, so it's its own
  pipeline).
- `aarch64/` — aarch64-specific bootstrap pieces.

There is **no `tc/cross/`, no `tc/bootstrap/stage1/`, and no
`tc/bootstrap/stage3/`** at present. Earlier drafts of the spec described a
three-stage chain (stage1 cross compiler → stage2 native → stage3 Go/LLVM/
Rust); the implemented layout uses a single self-hosting stage2 driven by the
seed.

**Future work — cross mode.** A dedicated execution platform that pairs the
host compiler with a buckos-built sysroot (for "monorepo" usage where the
host owns the compiler but buckos owns libc) was specified previously and
remains a desirable feature, but is not implemented today.

### Monorepo integration

When buckos is a cell in a monorepo, register a single `buckos` cell and
include `buckos//tc/exec:platforms` in the monorepo's
`execution_platforms` list:

```ini
# monorepo/.buckconfig
[cells]
  root = .
  buckos = third-party/buckos
  toolchains = toolchains       # monorepo's toolchains — buckos uses these
  prelude = prelude

[build]
  execution_platforms = //exec:platforms, buckos//tc/exec:platforms

[parser]
  target_platform_detector_spec = \
    target:root//...->root//platforms:default \
    target:buckos//...->buckos//platforms:linux-x86_64
```

Because `use/` and `tc/` are regular directories (not subcells), only the
`buckos` cell needs to be registered. The `toolchains` cell defined by the
monorepo overrides buckos's standalone `toolchains = toolchains`, so all
cells (including buckos) resolve `toolchains//:NAME` to the monorepo's
rules. No code changes inside buckos.

`tc/defs.bzl::buckos_execution_platforms()` is the only buckos-side helper
used by monorepo integration; it builds the `:platforms` aggregate from the
mode-specific platforms in `tc/exec`.

**Future work — `defs/integration.bzl`.** A higher-level integration module
exposing helpers like `buckos_execution_platforms()` and
`buckos_cell_config()` to monorepo callers does not exist today.

---

## Package Convenience Macro (`defs/package.bzl`)

Most package BUCK files call one of the thin wrappers in `defs/packages/*.bzl`
(`autotools_package`, `cmake_package`, `meson_package`, `cargo_package`,
`go_package`, `perl_package`, `python_package`, `mozbuild_package`,
`binary_package`, plus `make_package`). Each wrapper is a ~3-line shim:

```python
# defs/packages/cmake.bzl
load("//defs:package.bzl", "package")

def cmake_package(name, **kwargs):
    package(name = name, build_rule = "cmake", **kwargs)
```

All cross-cutting behavior lives in `package()`:

1. **Validate** `url` / `sha256` / `local_only` / explicit `source`.
2. **Merge private patch registry** entries with the public `patches`,
   `configure_args`, and `extra_cflags`.
3. **Auto-create source targets** (`:name-archive` + `:name-src`) using the
   mirror configuration:
   - `mirror.mode = vendor` and `mirror.vendor_dir` set → `export_file`
     from the local vendor directory.
   - `mirror.prefix` set → `http_file` with the `{prefix}/{first_char}/
     {name}-{version}-{sha256[:12]}{ext}{params}` layout.
   - Otherwise → `http_file` with the optional `mirror.base_url` prepended
     before `url`.
   The macro skips the auto-creation if the caller passes `source=` directly.
4. **Auto-wire vendor deps for cargo/go** when `vendor_deps` is a sha256
   string (mirror-hosted vendor tarball) or `True` (vendor dir bundled inside
   the source tarball); when in `mirror.mode = vendor` it also picks the
   vendor tarball out of the local mirror.
5. **Auto-inject host tools** (`bash`, `coreutils`, `findutils`, `sed`,
   `gawk`, `grep`, `diffutils`, `patch`, `tar`, `gzip`, `xz`, `bzip2`,
   `python-host`, `perl`, `m4`, `make`, `pkg-config`, plus `meson`/`ninja`
   for meson/mozbuild, `cmake`/`ninja` for cmake) as `exec_deps`. A
   blocklist prevents the tools themselves from cycling back on themselves.
   In seed mode the macro skips these because the seed's hermetic PATH
   already provides them; in bootstrap/host-tools mode the auto-injection is
   `select`-gated to empty to avoid circular deps back to the not-yet-built
   seed.
6. **Inject `ccache`** as an exec dep for configurable rules when
   `[buckos.cache] mode = enabled`, again with a blocklist that skips
   ccache's own deps.
7. **Resolve USE-conditional `deps`, `configure_args`, and `features`** from
   the `use_deps`, `use_configure`, and `use_features` dicts into `select()`
   expressions on the build target.
8. **Auto-inject labels:** `buckos:compile`, `buckos:build:<rule>`,
   `buckos:source:<host>`, `buckos:url:<url>`, `buckos:sha256:<sha>`,
   `buckos:iuse:<flag>` for every declared USE flag, plus `buckos:local_only`
   when `local_only=True`. User-supplied `labels` are merged on top.
9. **Expose USE flags as env vars** (`USE_<FLAG>=1|0`) via `use_env` so
   install scripts can branch on them.
10. **Inject `CCACHE_*` env vars** when caching is enabled.
11. **Dispatch to the build rule** via `_BUILD_RULES`. The macro also
    auto-converts an `autotools_package(src_compile=..., src_install=...)`
    call into a `binary_build` target with a combined install script.
12. **Build the transform chain** (`strip_package`, `stamp_package`,
    `ima_sign_package`) from the `transforms` list (always on) and the
    `use_transforms` dict (USE-gated via `use_bool`).
13. **Emit a final `alias`** from `:name` to the last target in the chain.

Resulting target chain:

```
:name-archive    http_file or export_file (downloaded/vendored archive)
:name-src        extract_source (extracted source directory)
:name-build      build rule output
:name-stripped   strip transform
:name-stamped    stamp transform
:name-signed     ima sign transform
:name            alias to the last target in the chain
```

All intermediate targets are independently buildable for debugging:
`:name-archive` downloads without extracting, `:name-src` extracts without
building, etc.

### Per-package source override

To override the source for a specific package (e.g. a git checkout, an
unusual mirror layout, or multiple source archives) create the targets
manually and pass `source` explicitly:

```python
load("//defs/packages:autotools.bzl", "autotools_package")
load("//defs/rules:source.bzl", "extract_source")

export_file(
    name = "glibc-archive",
    src = "vendor/distfiles/glibc-2.38.tar.xz",
)
extract_source(
    name = "glibc-src",
    source = ":glibc-archive",
)

autotools_package(
    name = "glibc",
    version = "2.38",
    url = "https://ftp.gnu.org/gnu/glibc/glibc-2.38.tar.xz",
    sha256 = "...",
    source = ":glibc-src",
    # ...
)
```

### Direct use of `package()`

`package()` is exported and can be called directly for one-offs (any
`build_rule` from the dispatch table works), but the wrappers in
`defs/packages/` are preferred because they make BUCK files easier to read.

---

## Multi-version Packages

Multiple versions of the same package live in the same BUCK file as separate
targets with version-suffixed names. A default alias picks the preferred
version. Each target carries its own version data inline; there is no shared
registry.

```python
# packages/linux/system/libs/crypto/openssl/BUCK
load("//defs/packages:autotools.bzl", "autotools_package")

autotools_package(
    name = "openssl-3.6",
    version = "3.6.1",
    url = "https://github.com/openssl/openssl/releases/download/openssl-3.6.1/openssl-3.6.1.tar.gz",
    sha256 = "...",
    configure_script = "Configure",
    skip_host_arg = True,
    libraries = ["ssl", "crypto"],
    configure_args = ["--prefix=/usr", "--openssldir=/etc/ssl", "--libdir=lib"],
    pre_build_cmds = ["make || true"],
    deps = ["//packages/linux/core/zlib:zlib"],
    patches = glob(["patches/3.6/*.patch"]),
    transforms = ["strip", "stamp"],
    use_transforms = {"ima": "ima"},
    license = "Apache-2.0",
    # ...
)

autotools_package(
    name = "openssl-3.3",
    version = "3.3.2",
    # ...
)

alias(name = "openssl", actual = ":openssl-3.6")
```

Consumers reference `:openssl` for the default, or a specific slot like
`:openssl-3.6` when needed. To switch consumers by USE_EXPAND value, use
`use_versioned_dep` from `defs/use_helpers.bzl`:

```python
deps = use_versioned_dep("openssl_slot", {
    "3.6": "//packages/linux/system/libs/crypto/openssl:openssl-3.6",
    "3.3": "//packages/linux/system/libs/crypto/openssl:openssl-3.3",
})
```

**Future work — `multi_version_package` macro.** A higher-level macro that
generates the slot targets and default alias from a single `versions = {...}`
dict was specified previously but is not implemented today. Use the manual
pattern above (`autotools_package` per slot + an `alias`) instead.

---

## Patch Management

### Per-package patches

Patches live alongside the package in a `patches/` subdirectory:

```
packages/linux/core/zlib/
├── BUCK
└── patches/
    ├── 0001-fix-minizip-permissions.patch
    └── 0002-cve-2024-XXXX.patch
```

For multi-version packages, version-specific patches go in subdirectories
(e.g. `patches/3.6/*.patch` for openssl-3.6).

BUCK files reference patches with `glob()`:

```python
autotools_package(
    name = "zlib",
    patches = glob(["patches/*.patch"]),
    # ...
)
```

Patches apply in list order during `src_prepare`, run via
`tools/patch_helper.py`. With no patches, the phase is a zero-cost
passthrough — no action runs, the source artifact flows directly to
`src_configure`.

### Conditional patches

`patches` is a normal attribute, so `select()` composes naturally:

```python
patches = [
    "patches/0001-buckos-paths.patch",
    "patches/0002-locale-gen.patch",
] + select({
    "//use/constraints:musl-on": ["patches/0003-musl-compat.patch"],
    "//use/constraints:musl-off": [],
}) + select({
    "//platforms:is_x86_64":  ["patches/arch/x86_64-optimize.patch"],
    "//platforms:is_aarch64": ["patches/arch/aarch64-pagesize.patch"],
}),
```

### Private patch registry

`defs/empty_registry.bzl` ships an empty `PATCH_REGISTRY = {}` that
`defs/package.bzl` loads by default. To enable a private patch registry,
create `patches/registry.bzl` (gitignored) with `export_file()` targets in
`patches/BUCK`, and **replace the load line at the top of
`defs/package.bzl`** so it points at your private registry:

```python
# defs/package.bzl  (change THIS line)
load("//defs:empty_registry.bzl", "PATCH_REGISTRY")
# becomes
load("//patches:registry.bzl", "PATCH_REGISTRY")
```

Registry entries have the following fields (no `env` field):

```python
# patches/registry.bzl
PATCH_REGISTRY = {
    "zlib": {
        "patches": ["//patches:zlib-custom-fix.patch"],
        "extra_configure_args": ["--with-custom-option"],
        "extra_cflags": ["-DCUSTOM_FLAG"],
    },
    "curl": {
        "patches": [
            "//patches:curl-internal-ca.patch",
            "//patches:curl-proxy-defaults.patch",
        ],
    },
}
```

`package()` appends private patches **after** public patches, so user
patches always apply on top of the package's own patches (matching the
Gentoo model). The `[buckos] patch_registry_enabled` `.buckconfig` key is
**not** read anywhere in the current code — leaving it in `.buckconfig` is
harmless but has no effect. Toggling the registry is done by swapping the
`load()` line as described above.

---

## Source Mirrors and Vendoring

### Design overview

- **Network downloads** use the prelude's `http_file` rule: content-addressed
  CAS lookup by sha256, deferred execution, RE-native downloads, and
  built-in URL-list fallback.
- **Air-gapped/vendor builds** use `export_file` from a local directory.
  The extraction step (`extract_source`) is identical in both modes.
- The `package()` macro picks `http_file` vs `export_file` based on
  `[mirror] mode`. There is no constraint-driven source mode.

### `[mirror]` config

| Key | Meaning |
|-----|---------|
| `mode` | `upstream` (default — `http_file`) or `vendor` (`export_file`) |
| `base_url` | Optional. When set, prepended to the `http_file` urls list (tried before upstream). |
| `vendor_dir` | Required in `vendor` mode. Repo-relative directory of vendored archives. |
| `prefix`, `params` | Optional alternate mirror layout: `{prefix}/{first_char}/{name}-{version}-{sha256[:12]}{ext}{params}`. Overrides `base_url` when set. |

`http_file` does **not** try the next URL on sha256 mismatch — only on
network failure. A sha256 mismatch is treated as a hard failure, which is
the correct signal that the mirror or upstream regenerated the tarball.

### Why mirror URL first

Your mirror is the source of truth for the sha256 recorded in the BUCK file.
Upstream is a best-effort fallback that works until they regenerate the
tarball (different timestamps, different compression level → different
sha256). When upstream changes, the build fails loudly at the upstream URL,
which is the correct signal to update the BUCK file. This is the Gentoo
model — distfile mirrors are authoritative.

### Vendor directory

When `mode = vendor` and `vendor_dir` is set, the macro emits:

```python
export_file(name = "<pkg>-archive", src = "<vendor_dir>/<filename>")
```

`export_file` requires a repo-relative path, so `vendor_dir` must live
inside the repository tree. For external vendor directories
(`/opt/buckos/vendor`), symlink or bind-mount into the repo:

```bash
ln -s /opt/buckos/vendor vendor/distfiles
# Then in .buckconfig: vendor_dir = vendor/distfiles
```

### Populating / verifying the vendor directory

Vendoring lives in `defs/vendor_sources.bxl`:

```bash
# Vendor a target and all its dependencies
buck2 bxl //defs:vendor_sources -- --target //packages/linux/core/bash:bash

# Vendor multiple targets at once
buck2 bxl //defs:vendor_sources -- \
    --target //packages/linux/core/bash:bash \
    --target //packages/linux/network/curl:curl

# Show what would be vendored without downloading
buck2 bxl //defs:vendor_sources -- --target //packages/linux/core/bash:bash --dry-run

# Verify existing vendored sources
buck2 bxl //defs:vendor_sources -- --verify

# Clean (uses manifest)
buck2 bxl //defs:vendor_sources -- --clean
```

### BXL source auditing

`tests/graph/test_sources.bxl` and `test_versions.bxl` walk all package
targets and verify:

- Every `http_file` target has a non-empty `sha256`.
- Every `http_file` target has a non-empty `urls` list.
- Every package target has a non-empty `version`.
- When `mirror.base_url` is set, every `http_file` first URL starts with
  the mirror base (mirror-first ordering preserved).

---

## SBOM Generation

SBOM data lives in `PackageInfo` provider fields (`license`, `src_uri`,
`src_sha256`, `homepage`, `supplier`, `description`, `cpe`). Every package
BUCK file populates these (the macro auto-populates `version`, `src_uri`,
`src_sha256` from the inline params).

`tools/sbom.bxl` walks the configured dependency graph, extracts
`PackageInfo` from every node, and emits SPDX or CycloneDX JSON:

```
buck2 bxl //tools:sbom.bxl -- --target //packages/linux/system:buckos-rootfs --format spdx
buck2 bxl //tools:sbom.bxl -- --target //packages/linux/network/curl:curl --format cyclonedx
```

Labels are **not** used for SBOM data — they are used for filtering only
(e.g. `buckos:firmware` to scope which packages appear in a firmware SBOM).

---

## Target Labels

BuckOS uses Buck2's `labels` attribute for structured metadata, queryable
with `buck2 cquery 'attrfilter(labels, ...)'`.

All labels follow `buckos:<category>:<value>`. The `buckos:` prefix avoids
collisions when buckos is a cell in a monorepo.

### Auto-injected labels

These are applied by `defs/package.bzl`:

| Label | Applied To |
|-------|------------|
| `buckos:compile` | Every package |
| `buckos:download` | Source download/extract targets |
| `buckos:local_only` | `local_only=True` packages |
| `buckos:build:autotools` | `autotools_package` (and `make_package`) |
| `buckos:build:cmake` | `cmake_package` |
| `buckos:build:meson` | `meson_package` |
| `buckos:build:cargo` | `cargo_package` |
| `buckos:build:go` | `go_package` |
| `buckos:build:perl` | `perl_package` |
| `buckos:build:python` | `python_package` |
| `buckos:build:mozbuild` | `mozbuild_package` |
| `buckos:build:binary` | `binary_package` and macro-converted binary builds |
| `buckos:build:make` | `make_package` |
| `buckos:source:<host>` | URL host extracted from `url` |
| `buckos:url:<url>` | Full upstream URL |
| `buckos:sha256:<sha>` | Source sha256 |
| `buckos:sig:none` | Currently always emitted (no GPG verification yet) |
| `buckos:iuse:<flag>` | One per declared USE flag (`use_deps`/`use_configure`/`use_features`/`use_transforms`) |

The kernel/image rules also emit category labels (`buckos:image`,
`buckos:config`, etc.) via the macros in their respective files.

### Manual labels

Set per-target in BUCK files via `labels = [...]`. User-provided labels are
merged with auto-injected labels by the macro.

| Label | Description |
|-------|-------------|
| `buckos:hw:cuda` | Requires NVIDIA CUDA |
| `buckos:hw:rocm` | Requires AMD ROCm |
| `buckos:hw:vulkan` | Requires Vulkan |
| `buckos:hw:gpu` | General GPU drivers/tools |
| `buckos:hw:dpdk` | Requires DPDK |
| `buckos:hw:rdma` | Requires RDMA/InfiniBand |
| `buckos:firmware` | Firmware blobs / microcode |
| `buckos:ci:skip` | Skip in CI |
| `buckos:ci:long` | Long build, sample in CI |

### Query examples

```bash
buck2 cquery 'attrfilter(labels, "buckos:build:cmake", //packages/...)'
buck2 cquery 'attrfilter(labels, "buckos:firmware", //packages/...)'
buck2 cquery 'except(//packages/..., attrfilter(labels, "buckos:ci:skip", //packages/...))'
```

---

## Testing

### Layer 1: Graph structure (BXL)

`tests/graph/` contains BXL scripts that exercise the dependency graph,
select() resolution, label assignment, transform chain wiring, modifier
effects, version data, and source registry completeness. They run at
analysis time — no actions execute.

```
buck2 bxl //tests/graph:test_deps.bxl
buck2 bxl //tests/graph:test_use_flags.bxl
buck2 bxl //tests/graph:test_transforms.bxl
buck2 bxl //tests/graph:test_labels.bxl
buck2 bxl //tests/graph:test_versions.bxl
buck2 bxl //tests/graph:test_sources.bxl
buck2 bxl //tests/graph:test_provenance.bxl
buck2 bxl //tests/graph:test_dedup.bxl
buck2 bxl //tests/graph:test_hermiticity.bxl
buck2 bxl //tests/graph:test_targets.bxl
buck2 bxl //tests/graph:test_bootstrap_isolation.bxl
buck2 bxl //tests/graph:test_cloud_hypervisor.bxl
buck2 bxl //tests/graph:test_graph.bxl
buck2 bxl //tests/graph:test_all.bxl
```

### Layer 2: Python helper unit tests

`tests/test_*.py` exercise individual helpers in isolation:
`test_env_unit.py`, `test_extract_unit.py`, `test_patch_acct.py`,
`test_rootfs_unit.py`, `test_sysroot_merge.py`, `test_iso_config.py`,
`test_vm_helpers.py`, `test_lang_helpers.py`, `test_build_install.py`,
`test_kernel_helpers.py`, `test_path_resolution.py`,
`test_provenance_stamp.py`, `test_merge_and_hash.py`,
`test_bootstrap_helpers.py`, `test_small_helpers.py`,
`test_stage3_strip.py`, `test_toolchain_unpack.py`.

### Layer 3: Runtime behavior (vm_test + verify scripts)

`vm_test` rules boot kernel + rootfs in QEMU via KVM, run commands, check
results. The rule supports `inject_binaries` to copy Buck2-built binaries
into the rootfs before boot, enabling end-to-end tests like building a
sched_ext scheduler, kernel, and rootfs in one graph.

```
buck2 test //packages/linux/system:test-boot
buck2 test //tests/vm:test-sched-ext-binary
```

`tests/verify_*.py` are operator-driven verification scripts
(`verify_build_smoke.py`, `verify_iso_boot.py`, `verify_ch_vm_boot.py`,
`verify_ima_qemu.py`, etc.) that run buck commands + manual checks.

### Bootstrap verification

`tools/verify_bootstrap.sh` checks that bootstrap output is hermetic:

- No host GLIBC symbol leakage (`objdump -T` compared to target glibc).
- No host RPATH/RUNPATH leakage (`readelf -d`).
- No host sysroot path leakage (`strings`).
- Architecture consistency across all ELF binaries (`readelf -h`).

`tools/check_hermeticity.sh` is the per-build hermeticity check used by
build rules' wrapping scripts.

---

## Package BUCK File Template

The `package()` macro (via any wrapper) auto-creates `:PKGNAME-archive`
(`http_file` or `export_file`) and `:PKGNAME-src` (`extract_source`) from
the inline version data. Mirror URLs come from `[mirror]`.

```python
load("//defs/packages:autotools.bzl", "autotools_package")
load("//defs:use_helpers.bzl", "use_dep", "use_configure_arg")

autotools_package(
    name = "PKGNAME",
    version = "1.2.3",
    url = "https://example.com/PKGNAME-1.2.3.tar.gz",
    sha256 = "abc123...",
    libraries = ["LIBNAME"],
    configure_args = [
        "--prefix=/usr",
    ] + use_configure_arg("FEATURE", "--enable-FEATURE", "--disable-FEATURE"),
    deps = [
        "//packages/linux/core/zlib:zlib",
    ] + use_dep("ssl", "//packages/linux/system/libs/crypto/openssl:openssl"),
    patches = glob(["patches/*.patch"]),
    transforms = ["strip", "stamp"],
    use_transforms = {"ima": "ima"},
    # SBOM
    license = "MIT",
    homepage = "https://example.com",
    description = "Description of the package",
    cpe = "cpe:2.3:a:vendor:product:*:*:*:*:*:*:*:*",
)
```

### Package with custom source

```python
load("//defs/packages:autotools.bzl", "autotools_package")
load("//defs/rules:source.bzl", "extract_source")

http_file(
    name = "PKGNAME-archive",
    urls = [
        "https://special-mirror.example.com/PKGNAME-1.0.tar.gz",
        "https://example.com/PKGNAME-1.0.tar.gz",
    ],
    sha256 = "...",
    out = "PKGNAME-1.0.tar.gz",
)
extract_source(name = "PKGNAME-src", source = ":PKGNAME-archive")

autotools_package(
    name = "PKGNAME",
    version = "1.0",
    url = "https://example.com/PKGNAME-1.0.tar.gz",
    sha256 = "...",
    source = ":PKGNAME-src",   # Explicit source skips auto-creation
    # ...
)
```

### Multi-version

```python
load("//defs/packages:autotools.bzl", "autotools_package")

autotools_package(name = "PKGNAME-3.6", version = "3.6.1", url = "...", sha256 = "...", patches = glob(["patches/3.6/*.patch"]), ...)
autotools_package(name = "PKGNAME-3.3", version = "3.3.2", url = "...", sha256 = "...", patches = glob(["patches/3.3/*.patch"]), ...)

alias(name = "PKGNAME", actual = ":PKGNAME-3.6")
```

---

## CLI Reference

```bash
# Build with defaults (no platform → uses default_target_platform)
buck2 build //packages/linux/core/zlib:zlib

# Build with bootstrap toolchain (reproducible)
buck2 build //packages/linux/core/zlib:zlib \
    --target-platforms //platforms:linux-target

# Build with host toolchain (faster dev iteration)
buck2 build //packages/linux/core/zlib:zlib \
    --target-platforms //platforms:linux-target-host

# Cross-arch via the aarch64 target platforms
buck2 build //packages/linux/core/zlib:zlib \
    --target-platforms //platforms:linux-aarch64-target

# USE-flag profiles
buck2 build //packages/linux/network/curl:curl ?//use/profiles:desktop
buck2 build //packages/linux/network/curl:curl \
    ?//use/profiles:minimal ?//use/constraints:http2-on

# Full combination
buck2 build //packages/linux/system:buckos-rootfs \
    --target-platforms //platforms:linux-target \
    ?//use/profiles:desktop

# From a monorepo root (buckos as cell)
buck2 build buckos//packages/linux/system:buckos-rootfs \
    --target-platforms buckos//platforms:linux-target \
    ?buckos//use/profiles:desktop

# Run VM tests
buck2 test //packages/linux/system:test-boot

# Source mirror / vendor configuration (set in .buckconfig, not usually CLI)
# buck2 build //... --config mirror.mode=vendor
# buck2 build //... --config mirror.base_url=https://mirror.corp/sources

# Populate / verify the vendor directory
buck2 bxl //defs:vendor_sources -- --target //packages/linux/core/bash:bash
buck2 bxl //defs:vendor_sources -- --verify

# Generate SBOM
buck2 bxl //tools:sbom.bxl -- --target //packages/linux/system:buckos-rootfs --format spdx

# Query the graph
buck2 cquery 'deps(//packages/linux/network/curl:curl)' ?//use/profiles:desktop
buck2 cquery 'attrfilter(labels, "buckos:build:cmake", //packages/...)'

# BXL graph tests
buck2 bxl //tests/graph:test_deps.bxl
buck2 bxl //tests/graph:test_versions.bxl

# List targets
buck2 targets //packages/linux/...

# Inspect intermediate artifacts
buck2 build //packages/linux/core/zlib:zlib-archive   # downloaded archive
buck2 build //packages/linux/core/zlib:zlib-src       # extracted source
buck2 build //packages/linux/core/zlib:zlib-build     # before transforms
buck2 build //packages/linux/core/zlib:zlib-stripped  # after strip
buck2 build //packages/linux/core/zlib:zlib           # final alias
```
