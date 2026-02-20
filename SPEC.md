# BuckOS Build System Specification

## Project Overview

BuckOS is a Buck2-based Linux distribution. This specification describes the
target architecture: proper Buck2 rule() definitions, typed providers, composable
build phases, and first-class USE flag / toolchain / version management / patch
management / SBOM support using Buck2's native configuration, execution platform,
and BXL systems.

This document is the authoritative reference for BuckOS. When implementing any
part of BuckOS, follow this spec. When this spec and existing code disagree,
this spec wins. The migration strategy section describes how to incrementally
adopt this spec from whatever the current state of the codebase is.

---

## Architecture Principles

1. **rule() over genrule.** Every package type (autotools, cmake, meson, cargo,
   go, kernel) is a first-class Buck2 rule with typed attributes, not a macro
   wrapping a genrule shell command.

2. **Discrete cacheable actions.** Each build phase (unpack, prepare, configure,
   compile, install) is a separate ctx.actions.run() call. Buck2 can skip phases
   whose inputs haven't changed. Without this, changing a configure flag
   rebuilds from scratch (including re-extracting source and re-compiling
   unchanged files). Separate actions also mean you can debug a configure failure
   without re-downloading and re-extracting, and BXL can introspect individual
   phase outputs.

3. **Python helpers over shell.** Action scripts are Python (in tools/), never
   shell. Python has proper error handling, is testable in isolation, and avoids
   quoting/word-splitting bugs. The Buck2 docs explicitly recommend this.

4. **Typed providers.** Rules return PackageInfo with structured fields (include
   dirs, lib dirs, library names, SBOM metadata). Downstream rules consume typed
   data, not opaque output directories.

5. **Composable transforms.** Post-install operations (strip, stamp, IMA sign)
   are separate rules that take a PackageInfo and produce a new PackageInfo.
   They compose as an explicit target chain visible in the build graph, not
   hidden conditionals inside a rule impl. This matters because: BXL can
   introspect whether strip ran without building anything, you can independently
   rebuild the stripped output without re-compiling, different consumers can
   apply different transform chains to the same build output, and cache
   granularity is optimal (changing the IMA key doesn't invalidate strip).

6. **Three orthogonal axes.** Target platform (arch/OS), USE flags (feature
   selection), and toolchain (which compiler) are independent concerns in
   separate directories (use/, tc/, platforms/), composed at build time.

7. **Three testing layers.** BXL scripts test graph structure. genrule/test
   targets test action outputs. vm_test rules boot QEMU and test runtime
   behavior.

8. **select() for USE flags, never read_config().** USE flags are constraint
   values resolved via select() in rule attributes. They are NOT read_config()
   values. This is a critical architectural decision because: read_config values
   do not enter configuration hashes, so Buck2 will serve cached results from
   a different flag combination (silent correctness bugs); BXL scripts cannot
   observe read_config values at analysis time, making graph tests impossible;
   read_config values don't compose with modifiers (the ?//use/profiles:desktop
   syntax), requiring a parallel mechanism; and having both select() and
   read_config() for flags creates two sources of truth that inevitably
   diverge. The .buckconfig must NOT contain [use] or [use_expand] sections —
   all flag values flow through constraints and modifiers.

---

## Directory Layout

```
buckos-build/
├── .buckconfig              # Root config, cell registration
├── .buckroot
├── BUCK                     # Root targets (complete, etc)
├── PACKAGE                  # Default platform + modifier for whole tree
│
├── platforms/               # Target arch/OS only
│   └── BUCK                 # linux-x86_64, linux-aarch64
│
├── use/                     # USE flags (regular directory, NOT a cell — no .buckconfig here)
│   ├── constraints/
│   │   ├── BUCK             # constraint_settings + constraint_values
│   │   └── defs.bzl         # use_flag(), use_expand(), use_expand_multi()
│   └── profiles/
│       └── BUCK             # Named modifier groups: minimal, server, desktop, etc
│
├── tc/                      # Toolchains (regular directory, NOT a cell — no .buckconfig here)
│   ├── exec/
│   │   └── BUCK             # Execution platform definitions (host, cross, bootstrap, prebuilt)
│   ├── host/
│   │   └── BUCK             # Host system toolchain (use PATH cc/c++, host sysroot)
│   ├── cross/
│   │   └── BUCK             # Host compiler + buckos-built sysroot (monorepo mode)
│   ├── bootstrap/
│   │   ├── stage1/BUCK      # Host cc → cross binutils + cross gcc
│   │   ├── stage2/BUCK      # Cross gcc → native tools + native gcc
│   │   └── stage3/BUCK      # Native gcc → go, llvm, rust
│   └── prebuilt/
│       └── BUCK             # Pre-exported toolchain tarball
│
├── defs/                    # Build system definitions
│   ├── providers.bzl        # PackageInfo, BootstrapStageInfo
│   ├── use_helpers.bzl      # use_bool, use_dep, use_configure_arg, use_expand_*,
│   │                        # use_versioned_dep
│   ├── package.bzl          # Convenience macro: build rule + transform chain +
│   │                        # private patch merge
│   ├── empty_registry.bzl   # Fallback when patches/ dir doesn't exist
│   ├── integration.bzl      # Helpers for monorepo cell integration
│   └── rules/
│       ├── source.bzl       # extract_source rule
│       ├── autotools.bzl    # autotools_package rule
│       ├── cmake.bzl        # cmake_package rule
│       ├── meson.bzl        # meson_package rule
│       ├── cargo.bzl        # cargo_package rule
│       ├── go.bzl            # go_package rule
│       ├── kernel.bzl       # kernel_build rule
│       ├── rootfs.bzl       # rootfs assembly rule
│       ├── transforms.bzl   # strip_package, stamp_package, ima_sign_package
│       └── vm_test.bzl      # VM boot + assertion test rule
│
├── tools/                   # Python action helpers
│   ├── BUCK                 # python_binary targets for each tool
│   ├── extract.py           # Universal archive extractor
│   ├── patch_helper.py      # Apply patches in order
│   ├── configure_helper.py  # Autotools configure wrapper
│   ├── cmake_helper.py      # CMake wrapper
│   ├── meson_helper.py      # Meson wrapper
│   ├── build_helper.py      # make/ninja wrapper
│   ├── install_helper.py    # make install wrapper
│   ├── strip_helper.py      # Strip binaries
│   ├── stamp_helper.py      # Build provenance stamping
│   ├── ima_helper.py        # IMA signing
│   ├── initramfs_helper.py  # Build cpio initramfs from directory
│   ├── vm_test_runner.py    # QEMU boot + test execution
│   ├── verify_bootstrap.sh  # Bootstrap toolchain verification
│   └── sbom.bxl             # SBOM generation BXL script
│
├── patches/                 # Private patch registry (gitignored)
│   ├── BUCK                 # export_file targets for patch files
│   └── registry.bzl         # Package name → patches + overrides
│
├── packages/linux/          # Packages by category
│   ├── core/                # zlib, glibc, busybox, etc
│   │   └── zlib/
│   │       ├── BUCK
│   │       └── patches/
│   │           ├── 0001-fix-minizip-permissions.patch
│   │           └── 0002-cve-2024-XXXX.patch
│   ├── dev-libs/            # openssl, gmp, etc
│   │   └── openssl/
│   │       ├── BUCK         # Contains both :openssl-3 and :openssl-1.1
│   │       └── patches/
│   │           ├── 3/
│   │           │   ├── 0001-buckos-default-ciphers.patch
│   │           │   └── 0002-musl-compat.patch
│   │           └── 1.1/
│   │               └── 0001-backport-security-fix.patch
│   ├── dev-tools/           # gcc, binutils, etc
│   ├── kernel/              # Linux kernel
│   ├── network/             # curl, nghttp2, etc
│   ├── system/              # rootfs, qemu-boot, iso, vm tests
│   └── .../
│
└── tests/
    ├── graph/               # BXL graph structure tests
    │   ├── test_deps.bxl
    │   ├── test_use_flags.bxl
    │   ├── test_transforms.bxl
    │   ├── test_labels.bxl
    │   └── test_versions.bxl  # Audit version/sha256 completeness across targets
    └── vm/                  # Additional VM runtime tests
```

---

## .buckconfig

This is the complete .buckconfig. No other sections should exist — in particular,
no `[use]` or `[use_expand]` sections.

**Why no [use] or [use_expand] sections:** If USE flags are read_config() values
in buckconfig, they do not participate in Buck2's configuration hashing. This
means `buck2 build :curl` with ssl=true and ssl=false produce the same
configuration hash — Buck2 will serve a cached ssl=false build when you ask for
ssl=true (or vice versa). This is a silent correctness bug, not a cache miss.
Additionally, BXL graph tests cannot observe read_config() values at analysis
time, modifiers (?//use/profiles:desktop) cannot set read_config() values, and
maintaining flags in both buckconfig and constraints creates two sources of truth
that diverge. USE flags are managed entirely through the constraint-based
select() system (see Architecture Principle 8). Any existing [use] or
[use_expand] sections in .buckconfig must be removed during migration and their
values converted to modifier/profile definitions in use/profiles/BUCK.

The `[mirror]` section is infrastructure configuration for source download
behavior. It is read at macro expansion time to construct the `urls` list on
`http_file` targets. Changing these values triggers a reparse (because target
attributes change), but since they are set once per environment and rarely
change, this is acceptable.

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
  target_platform_detector_spec = target:buckos//...->buckos//platforms:linux-x86_64

[project]
  ignore = .git, buck-out

[buckos]
  # Set to false to disable private patch registry
  patch_registry_enabled = true

[mirror]
  # mode: "upstream" (default) or "vendor"
  # upstream: download via http_file (mirror URL first if base_url set,
  #           then upstream URL as fallback)
  # vendor:   use local vendored archives via export_file (no network)
  mode = upstream

  # base_url: HTTP(S) base URL for mirrored sources.
  # Mirror URL is constructed as: base_url + "/" + filename
  # When set, mirror URL is tried before upstream URL (http_file tries
  # URLs in order, falling back on network failure).
  # Leave empty to download directly from upstream.
  # base_url = https://mirror.corp.example.com/sources

  # vendor_dir: Repo-relative path to vendored source archives.
  # Must be inside the repo tree (symlink or bind-mount is fine).
  # export_file does not support absolute paths outside the repo.
  # Vendor files are stored as: vendor_dir + "/" + filename
  # Only used when mode = vendor.
  # vendor_dir = vendor/distfiles
```

**Why `toolchains` is a cell, not an alias:** The prelude resolves toolchains
via `toolchains//:NAME` (hardcoded in `attrs.toolchain_dep` defaults). If
`toolchains` is a cell alias to `buckos`, then `toolchains//:python` resolves
to `buckos//:python` — the project root, not the toolchains directory. By
registering `toolchains = toolchains` as a proper cell, the prelude finds
`toolchains//:python` in `toolchains/BUCK` where the actual toolchain rules
live.

When buckos is a subcell, the monorepo's `[cells]` section defines
`toolchains` project-wide. Since cells are global, the monorepo's toolchains
take precedence. This is the desired behavior: the monorepo owns the compiler
toolchains, and buckos uses whatever the monorepo provides. Zero buckos code
changes between standalone and subcell modes — the only difference is which
`.buckconfig` is the project root.

The `toolchains/` directory has its own minimal `.buckconfig` for standalone
mode. In subcell mode this file is ignored because the monorepo root defines
the `toolchains` cell.

**Why `buckos` not `root` as the cell name:** Buck2 cell aliases are global
across the entire project. If buckos uses `root = .` and a monorepo also uses
`root = .`, the alias conflicts — `root` can't refer to two directories. By
naming the cell `buckos`, the alias is unique and works both standalone (where
`buckos = .` is the project root) and as a subcell (where the monorepo adds
`buckos = third-party/buckos`). All `//` paths inside BUCK and .bzl files are
unaffected — bare `//` resolves relative to the containing cell regardless of
cell name. Only explicit `buckos//` references appear in target_platform_detector_spec
and similar cross-cell contexts.

Only `buckos` and `prelude` are registered as cells. The `use/` and `tc/`
directories are NOT cells — they are regular directories within the buckos cell.
Do not add `use`, `tc`, `toolchains`, or `none` to the `[cells]` section.

---

## Providers

### PackageInfo

Every package rule returns this. It is the typed contract between packages.

```python
# defs/providers.bzl

PackageInfo = provider(fields = [
    # Identity
    "name",             # str
    "version",          # str

    # Build outputs
    "prefix",           # artifact: the install prefix directory
    "include_dirs",     # list[artifact]: paths to installed headers
    "lib_dirs",         # list[artifact]: paths to installed libraries
    "bin_dirs",         # list[artifact]: paths to installed binaries
    "libraries",        # list[str]: library names for -l flags
    "pkg_config_path",  # artifact | None: path to .pc files

    # Extra flags this package requires consumers to use
    "cflags",           # list[str]
    "ldflags",          # list[str]

    # SBOM metadata
    "license",          # str: SPDX expression ("MIT", "GPL-2.0-only", "Apache-2.0 OR MIT")
    "src_uri",          # str: upstream source URL
    "src_sha256",       # str: source archive checksum
    "homepage",         # str | None
    "supplier",         # str: default "Organization: BuckOS"
    "description",      # str
    "cpe",              # str | None: CPE identifier for vulnerability matching
])
```

### BuildToolchainInfo

Provided by toolchain rules in tc/ directory.

```python
BuildToolchainInfo = provider(fields = [
    "cc",               # RunInfo
    "cxx",              # RunInfo
    "ar",               # RunInfo
    "strip",            # RunInfo
    "make",             # RunInfo
    "pkg_config",       # RunInfo
    "target_triple",    # str
    "sysroot",          # artifact | None: buckos-built sysroot (glibc headers + libs)
])
```

### BootstrapStageInfo

Returned by bootstrap stage rules.

```python
BootstrapStageInfo = provider(fields = [
    "stage",            # int: 1, 2, or 3
    "cc",               # artifact: the C compiler binary
    "cxx",              # artifact: the C++ compiler binary
    "ar",               # artifact
    "sysroot",          # artifact
    "target_triple",    # str
])
```

---

## Rules

### extract_source

Extracts source archives. This is an extraction-only rule — downloading is
handled by the prelude's `http_file` rule or by `export_file` for vendored
archives. The package() macro creates both targets automatically.

Note: The rule is named `extract_source`, not `download_source`, because it
does not download anything. If existing code uses `download_source` as a name,
it should be renamed during migration to avoid confusion. Target names created
by the macro use the `-src` suffix (e.g. `:zlib-src`), which remains correct.

The two-target split (http_file → extract_source) preserves http_file's native
benefits: content-addressed CAS lookup by sha256, deferred execution, and
RE-native download handling. The extraction step is a normal ctx.actions.run()
with standard action caching.

**Why not use http_archive for common formats?** The prelude's `http_archive`
handles download + extraction in one rule for common formats (zip, tar, tar.gz,
tar.bz2, tar.xz, tar.zst). We could use `http_archive` for the 95% case and
fall back to `http_file` + `extract_source` for tar.lz/tar.lz4. However, this
creates two code paths with different graph structures, different caching
behavior, and different debugging workflows. A uniform `http_file` +
`extract_source` for all packages means one rule implementation, one set of
attributes, one graph shape, and predictable behavior. The cost (a thin Python
wrapper for extraction) is trivial compared to the maintenance burden of
conditional rule selection.

Attributes:
- source: dep (required) — the archive file (from http_file or export_file)
- strip_components: int (default 1)
- format: str | None (default None) — override auto-detection for archives
  without clean extensions. Valid values: "tar.gz", "tar.xz", "tar.bz2",
  "tar.zst", "tar.lz", "tar.lz4", "tar", "zip"

The format override exists because http_archive (prelude) only supports zip,
tar, tar.gz, tar.bz2, tar.xz, tar.zst. Our extract.py additionally handles
tar.lz and tar.lz4, which some GNU packages require.

Returns: DefaultInfo with extracted source directory.

### autotools_package

Builds autotools (./configure && make && make install) packages.

Rule impl has exactly five phases, each a separate action:
1. src_unpack — get source from the source dep
2. src_prepare — apply patches via tools/patch_helper.py (zero-cost passthrough
   when no patches — no action, no copy)
3. src_configure — run ./configure via tools/configure_helper.py
4. src_compile — run make via tools/build_helper.py
5. src_install — run make install DESTDIR=... via tools/install_helper.py

USE flags do NOT add or remove phases. Phases are structural — they are the
rule. USE flags affect the attrs that phases read: configure_args, deps, patches,
extra_cflags, extra_ldflags. These are resolved by select() before the rule impl
runs.

Attributes:
- source: dep (required)
- version: str (required)
- configure_args: list[str] (default []) — USE flags add to this via select()
- make_args: list[str] (default [])
- deps: list[dep with PackageInfo] (default []) — USE flags add to this via select()
- patches: list[source] (default []) — USE flags and arch can add via select()
- libraries: list[str] (default []) — library names (for -l flags)
- extra_cflags: list[str] (default [])
- extra_ldflags: list[str] (default [])
- license: str (default "UNKNOWN")
- src_uri: str (default "")
- src_sha256: str (default "")
- homepage: str | None (default None)
- description: str (default "")
- cpe: str | None (default None)

Returns: DefaultInfo + PackageInfo.

### cmake_package

Same principle as autotools but runs cmake/ninja. Phases: unpack, prepare,
cmake-configure, build, install.

### meson_package

Same principle. Phases: unpack, prepare, meson-setup, compile, install.

### cargo_package

For Rust packages. Phases: unpack, prepare, cargo-build, install.

### go_package

For Go packages. Phases: unpack, prepare, go-build, install.

### kernel_build

Builds a Linux kernel. Phases: unpack, prepare, configure (make defconfig or
copy config), build (make -j), install (copy bzImage + modules).

Returns: DefaultInfo with kernel image + KernelInfo provider.

### rootfs

Assembles packages into a root filesystem. Takes a list of PackageInfo deps,
merges their prefix directories into a single root.

### Transform rules

Each transform is an independent rule. It takes a dep with PackageInfo as input
and returns DefaultInfo + PackageInfo with a new prefix pointing at the
transformed output.

**strip_package**: Strips debug symbols from ELF binaries/libraries.
- Attribute: package (dep with PackageInfo)
- Attribute: enabled (bool, default True) — when False, passthrough (forwards
  input PackageInfo unchanged, no action runs)

**stamp_package**: Injects build provenance (.note.package ELF section or
metadata file).
- Attribute: package (dep with PackageInfo)
- Attribute: enabled (bool, default True) — passthrough when False
- Attribute: build_id (str)

**ima_sign_package**: IMA binary signing (evmctl ima_sign --sigfile).
- Attribute: package (dep with PackageInfo)
- Attribute: enabled (bool, default True) — passthrough when False
- Attribute: signing_key (source | None)

The enabled attr is how USE flags control transforms. The macro layer passes
`enabled = use_bool("strip")` which resolves via select() to True or False. The
target always exists in the graph. When disabled, it's a zero-cost passthrough.

### vm_test

Boots a kernel + rootfs in QEMU via KVM and runs commands inside the VM.

- Builds an initramfs from the rootfs with a test script injected
- Boots QEMU with -nographic -serial stdio
- Captures serial output, checks for success marker
- Returns ExternalRunnerTestInfo so `buck2 test` runs it

Attributes:
- kernel: dep (required)
- rootfs: dep (required)
- commands: list[str] (required) — commands to run inside VM
- inject_binaries: dict[str, dep] (default {}) — path-in-VM → buck target
  to copy into rootfs before boot
- timeout_secs: int (default 60)
- memory_mb: int (default 512)
- cpus: int (default 2)

---

## Python Helper Scripts (tools/)

All action logic lives in Python helpers, not shell. Each helper:
- Accepts explicit --flag arguments via argparse. No env-var soup.
- Exits non-zero with a clear error message on failure.
- Is independently testable: `python3 tools/extract.py --help`
- Is registered as a python_binary or export_file target in tools/BUCK so it's
  tracked in the build graph.

### tools/extract.py

Universal archive extractor. Supports: .tar.gz, .tgz, .tar.xz, .txz, .tar.bz2,
.tbz2, .tar.zst, .tar.lz, .tar.lz4, .tar, .zip

Auto-detects format from filename. --format flag overrides detection for URLs
without clean extensions.

Uses Python tarfile/zipfile for formats Python supports natively. Pipes through
external decompressors (zstd, lzip, lz4) for others, failing with a clear error
if the decompressor is not installed.

Args: --archive PATH --output DIR --strip-components N --format FMT

### tools/patch_helper.py

Applies patches in order to a source tree. Copies source to output dir, then
runs `patch -pN -i PATCHFILE` for each patch in the order given. Exits non-zero
with a clear error on first failure, identifying which patch failed.

Args: --source-dir DIR --output-dir DIR --patch FILE (repeatable) --strip N

### tools/configure_helper.py

Runs autotools ./configure with explicit args.

Args: --source-dir --output-dir --cc --cxx --configure-arg (repeatable)
      --cflags (repeatable) --ldflags (repeatable) --pkg-config-path (repeatable)

Copies source to output dir (out-of-tree build), sets env, runs configure,
exits non-zero on failure with stderr.

### tools/build_helper.py

Runs make (or ninja).

Args: --build-dir --output-dir --jobs N --make-arg (repeatable)
      --build-system {make,ninja}

### tools/install_helper.py

Runs make install DESTDIR=...

Args: --build-dir --prefix DIR --make-arg (repeatable)

### tools/strip_helper.py

Strips ELF binaries and shared libraries.

Args: --input DIR --output DIR --strip STRIP_BINARY

Copies input to output, finds ELF files, runs strip on them.

### tools/stamp_helper.py

Injects build provenance metadata.

Args: --input DIR --output DIR --name --version --build-id

### tools/ima_helper.py

IMA signing via evmctl.

Args: --input DIR --output DIR --key PATH

### tools/vm_test_runner.py

Boots QEMU, runs test, checks output.

Args: --kernel PATH --rootfs DIR --guest-script PATH --timeout SECS
      --memory MB --cpus N --success-marker STR --inject SRC:DEST (repeatable)

Builds initramfs from rootfs dir (with injected files), boots QEMU with
-enable-kvm -nographic -serial stdio, captures output, checks for success
marker string, exits 0 on pass / 1 on fail.

---

## USE Flags (use/ directory)

### Constraint Definitions

```python
# use/constraints/defs.bzl

def use_flag(name):
    """Simple on/off USE flag."""
    constraint_setting(name = name)
    constraint_value(name = name + "-on",  constraint_setting = ":" + name)
    constraint_value(name = name + "-off", constraint_setting = ":" + name)

def use_expand(name, values):
    """USE_EXPAND single-select: pick exactly one value.
    Example: use_expand("python_single_target", ["python3_11", "python3_12"])
    Creates one constraint_setting with N constraint_values."""
    constraint_setting(name = name)
    for v in values:
        constraint_value(name = name + "-" + v, constraint_setting = ":" + name)

def use_expand_multi(name, values):
    """USE_EXPAND multi-select: enable any combination of values.
    Example: use_expand_multi("python_targets", ["python3_11", "python3_12"])
    Creates N independent constraint_settings, each with on/off.
    This matches Gentoo's internal expansion: PYTHON_TARGETS="python3_11 python3_12"
    becomes USE="python_targets_python3_11 python_targets_python3_12"."""
    for v in values:
        flag_name = name + "_" + v
        constraint_setting(name = flag_name)
        constraint_value(name = flag_name + "-on",  constraint_setting = ":" + flag_name)
        constraint_value(name = flag_name + "-off", constraint_setting = ":" + flag_name)
```

### Helper Functions

```python
# defs/use_helpers.bzl

def use_bool(flag):
    """Resolve a USE flag to a bool via select(). For use in rule attrs.
    DEFAULT arm ensures builds don't fail when a platform doesn't set
    this constraint — unset flags default to off."""
    return select({
        "//use/constraints:{}-on".format(flag): True,
        "//use/constraints:{}-off".format(flag): False,
        "DEFAULT": False,
    })

def use_dep(flag, dep):
    """Conditional dependency based on a USE flag."""
    return select({
        "//use/constraints:{}-on".format(flag): [dep],
        "//use/constraints:{}-off".format(flag): [],
        "DEFAULT": [],
    })

def use_configure_arg(flag, on_arg, off_arg = None):
    """Conditional configure arg based on a USE flag."""
    return select({
        "//use/constraints:{}-on".format(flag): [on_arg],
        "//use/constraints:{}-off".format(flag): [off_arg] if off_arg else [],
        "DEFAULT": [off_arg] if off_arg else [],
    })

def use_expand_select(expand_name, value_map):
    """Single-select USE_EXPAND: map each possible value to a result.
    Example: use_expand_select("python_single_target", {
        "python3_11": "//third-party/python:3.11",
        "python3_12": "//third-party/python:3.12",
    })"""
    return select({
        "//use/constraints:{}-{}".format(expand_name, v): result
        for v, result in value_map.items()
    })

def use_expand_dep(expand_name, value, dep):
    """Conditional dep on a multi-select USE_EXPAND value."""
    flag = "{}_{}".format(expand_name, value)
    return use_dep(flag, dep)

def use_expand_multi_deps(expand_name, value_dep_map):
    """Conditional deps for all values of a multi-select USE_EXPAND."""
    result = []
    for value, dep in value_dep_map.items():
        result += use_expand_dep(expand_name, value, dep)
    return result

def use_versioned_dep(expand_name, version_map):
    """Select between package versions based on a USE_EXPAND slot.
    Example: use_versioned_dep("openssl_slot", {
        "3": "//packages/linux/dev-libs/openssl:openssl-3",
        "1.1": "//packages/linux/dev-libs/openssl:openssl-1.1",
    })
    No DEFAULT — a USE_EXPAND must always have a value set, so a missing
    constraint is a build error (the user must pick a slot)."""
    return select({
        "//use/constraints:{}-{}".format(expand_name, v): [dep]
        for v, dep in version_map.items()
    })
```

### Profiles

Profiles are named modifier groups. They set USE flag values in bulk.

```
buck2 build //packages/linux/core:curl ?//use/profiles:minimal
buck2 build //packages/linux/core:curl ?//use/profiles:server
buck2 build //packages/linux/core:curl ?//use/profiles:desktop
buck2 build //packages/linux/core:curl ?//use/profiles:developer
buck2 build //packages/linux/core:curl ?//use/profiles:hardened
```

| Profile | Description |
|---------|-------------|
| minimal | Bare minimum for a bootable system. Most flags off. |
| server | Headless server: ssl, http2, static, strip, stamp. |
| desktop | Full desktop: ssl, http2, plus GUI/audio/media flags. |
| developer | Like desktop but with debug symbols, no strip, extra dev tools. |
| hardened | Like server but with IMA, static linking, security-focused flags. |

Individual flags can be overridden on top of a profile:

```
buck2 build //packages/linux/core:curl ?//use/profiles:minimal ?//use/constraints:http2-on
```

---

## Toolchains (tc/ directory)

### Architecture

Target platform (what we're building FOR) and execution platform (what we're
building WITH) are separate Buck2 concepts.

- //platforms:linux-x86_64 is a target platform (arch + OS constraints)
- //tc/exec:host is an execution platform (host system compiler, host sysroot)
- //tc/exec:cross is an execution platform (host compiler, buckos-built sysroot)
- //tc/exec:bootstrap-stage2 is an execution platform (self-built compiler + sysroot)
- //tc/exec:prebuilt is an execution platform (pre-exported toolchain)

Package BUCK files never mention toolchains. The toolchain is selected by
execution platform resolution based on .buckconfig or --config flags.

### Toolchain Modes

| Mode | Compiler | Sysroot | When to Use |
|------|----------|---------|-------------|
| host | Host system | Host system | Quick dev/testing — binaries run on host but may not match target image libc |
| cross | Host system | Buckos-built (glibc) | **Cell in monorepo** — correct images using monorepo's compiler |
| bootstrap | Self-built GCC | Self-built | Standalone reproducible builds, release images |
| prebuilt | Pre-exported | Pre-exported | CI/CD after initial bootstrap |

Selection:
```
buck2 build //packages/linux/core:zlib --config tc.mode=host
buck2 build //packages/linux/core:zlib --config tc.mode=cross
buck2 build //packages/linux/core:zlib --config tc.mode=bootstrap
buck2 build //packages/linux/core:zlib --config tc.mode=prebuilt
```

### Load Paths in tc/ Files

Since tc/ is a regular directory (not a cell), all paths in tc/ BUCK and .bzl
files are relative to the buckos cell root, not to tc/ itself. This means:

- Loads: `load("//tc:toolchain_rules.bzl", ...)` — NOT `load("//:toolchain_rules.bzl", ...)`
- Targets: `"//tc/bootstrap/stage1:stage1"` — NOT `"//bootstrap/stage1:stage1"`
- Deps: `"//packages/linux/core/glibc:glibc"` — same as anywhere else in the cell

Example BUCK files showing correct paths:

```python
# tc/exec/BUCK
load("//tc:defs.bzl", "buckos_toolchain_select")
load("//defs:providers.bzl", "BuildToolchainInfo")

execution_platform(
    name = "platforms",
    platforms = [":host", ":cross", ":bootstrap", ":prebuilt"],
)
# ... platform definitions
```

```python
# tc/host/BUCK
load("//tc:toolchain_rules.bzl", "buckos_host_toolchain")
load("//defs:providers.bzl", "BuildToolchainInfo")

buckos_host_toolchain(
    name = "host-toolchain",
    target_triple = "x86_64-buckos-linux-gnu",
    visibility = ["PUBLIC"],
)
```

```python
# tc/cross/BUCK
load("//tc:toolchain_rules.bzl", "buckos_cross_toolchain")
load("//defs:providers.bzl", "BuildToolchainInfo")

buckos_cross_toolchain(
    name = "cross-toolchain",
    cc = "cc",
    cxx = "c++",
    ar = "ar",
    strip = "strip",
    sysroot = "//packages/linux/core/glibc:glibc",
    extra_cflags = ["--sysroot={sysroot}"],
    extra_ldflags = ["--sysroot={sysroot}", "-Wl,-rpath,/usr/lib"],
    target_triple = "x86_64-buckos-linux-gnu",
    visibility = ["PUBLIC"],
)
```

```python
# tc/bootstrap/BUCK
load("//tc:toolchain_rules.bzl", "buckos_bootstrap_toolchain")
load("//defs:providers.bzl", "BootstrapStageInfo")

buckos_bootstrap_toolchain(
    name = "bootstrap-toolchain",
    stage = "//tc/bootstrap/stage2:stage2",
    visibility = ["PUBLIC"],
)
```

```python
# tc/bootstrap/stage1/BUCK
load("//defs/rules:bootstrap.bzl", "bootstrap_gcc", "bootstrap_binutils", "bootstrap_glibc")
load("//defs/rules:source.bzl", "extract_source")

# Source targets for bootstrap packages follow the same http_file + extract_source
# pattern as regular packages. The package() macro is not used here because
# bootstrap packages use specialized build rules, not autotools_package.

http_file(
    name = "gcc-archive",
    urls = ["https://ftp.gnu.org/gnu/gcc/gcc-14.3.0/gcc-14.3.0.tar.xz"],
    sha256 = "...",
    out = "gcc-14.3.0.tar.xz",
)
extract_source(name = "gcc-src", source = ":gcc-archive")

# ... stage 1 build targets using :gcc-src, :binutils-src, etc.
```

### Cross Mode

Cross mode is the primary mode when buckos is used as a cell in a monorepo.
The compiler binary comes from the host (or the monorepo's toolchain) — it's
whatever `cc`/`c++` is on PATH or whatever the monorepo's execution platform
provides. What buckos owns is the **sysroot**: the libc headers and libraries
that the compiler links against.

The cross execution platform wraps the host compiler with `--sysroot` pointing
at the output of buckos's glibc package:

```python
# tc/exec/BUCK (cross mode)

execution_platform(
    name = "cross",
    # ...
)

# tc/cross/BUCK

buckos_cross_toolchain(
    name = "cross-toolchain",
    # Host compiler — inherited from PATH or monorepo
    cc = "cc",
    cxx = "c++",
    ar = "ar",
    strip = "strip",
    # Buckos-built sysroot — this is the critical part
    sysroot = "//packages/linux/core/glibc:glibc",
    # Extra flags injected into every compile
    extra_cflags = ["--sysroot={sysroot}"],
    extra_ldflags = ["--sysroot={sysroot}", "-Wl,-rpath,/usr/lib"],
    target_triple = "x86_64-buckos-linux-gnu",
)
```

This means:
- Binaries are compiled with the host's GCC/Clang (fast, no bootstrap needed)
- But linked against buckos's glibc (correct for the target image)
- The resulting rootfs has a self-consistent libc, independent of the host

If the monorepo's host has glibc 2.40 but the buckos image targets glibc 2.38,
cross mode ensures all packages see glibc 2.38 headers and link against
glibc 2.38 — not the host's newer version. This prevents binaries from gaining
symbol version dependencies that the target glibc can't satisfy.

### Bootstrap Chain (standalone only)

The bootstrap chain builds a self-hosted toolchain from scratch. This is only
needed for standalone buckos builds where you want full reproducibility and no
dependency on the host compiler.

Stage 1: Host GCC → cross-binutils + cross-GCC targeting x86_64-buckos-linux-gnu
Stage 2: Cross-GCC → native coreutils, bash, make, binutils, self-hosted native GCC
Stage 3: Native GCC → Go, LLVM, Rust

Each stage's output provides CcToolchainInfo so the next stage can use it as its
compiler. This uses Buck2 configuration transitions — a rule says "build this dep
in a different configuration" (using the previous stage's compiler).

### Independence

The three axes compose freely:

```
buck2 build //packages/linux/system:buckos-rootfs \
    --target-platforms //platforms:linux-x86_64 \
    ?//use/profiles:desktop \
    --config tc.mode=cross

buck2 build //packages/linux/system:buckos-rootfs \
    --target-platforms //platforms:linux-aarch64 \
    ?//use/profiles:server \
    --config tc.mode=bootstrap
```

Same package definitions, different configurations, separate output paths,
cached independently.

### Monorepo Integration

When buckos is a cell in a monorepo, the monorepo root registers one cell and
adds buckos's execution platforms:

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
  # The monorepo's detector must include buckos targets.
  # buckos's own detector_spec (buckos//...->buckos//platforms:...) is in
  # buckos's .buckconfig but target_platform_detector_spec is only read from
  # the root .buckconfig, so the monorepo must repeat it here.
  target_platform_detector_spec = \
    target:root//...->root//platforms:default \
    target:buckos//...->buckos//platforms:linux-x86_64
```

Because use/ and tc/ are regular directories (not subcells), the monorepo
registers a single buckos cell. All internal references resolve through
buckos's cell root — `buckos//use/constraints:ssl-on`, `buckos//tc/exec:host`,
etc. The `buckos` cell name matches what buckos uses for itself (`buckos = .`
in buckos's .buckconfig), so there is no alias conflict.

The `toolchains` cell is defined by the monorepo root, overriding buckos's
standalone `toolchains = toolchains`. This is the correct behavior: the
monorepo owns the compiler toolchains (C/C++, Python, genrule), and all cells
including buckos resolve `toolchains//:NAME` to the monorepo's toolchains.
Zero code changes needed inside buckos.

The prelude is similarly project-wide. No `.buckconfig.local` override is
needed — the monorepo root defines `prelude` for all cells.

Buckos package rules request `BuildToolchainInfo` (buckos-specific provider).
The monorepo's own C++ rules request the prelude's `CxxToolchainInfo`. Buck2's
execution platform resolution matches based on what the rule requests — buckos
targets resolve to buckos execution platforms, monorepo targets resolve to
monorepo execution platforms. No collision.

The typical monorepo workflow:

```bash
# From monorepo root — cross mode is the default for monorepo usage
buck2 build buckos//packages/linux/system:buckos-rootfs \
    ?buckos//use/profiles:desktop \
    --config tc.mode=cross
```

The `defs/integration.bzl` file provides helpers for monorepo integration:

```python
# defs/integration.bzl

def buckos_execution_platforms():
    """Returns buckos execution platform targets for monorepo registration.

    Usage in monorepo root .buckconfig:
        [build]
        execution_platforms = //exec:platforms, buckos//tc/exec:platforms
    """
    return [
        "buckos//tc/exec:host",
        "buckos//tc/exec:cross",
        "buckos//tc/exec:prebuilt",
    ]

def buckos_cell_config():
    """Documents required .buckconfig entries for monorepo integration.

    Only one cell registration needed — use/ and tc/ are regular directories,
    not subcells.
    """
    return {
        "cells": {
            "buckos": "<path-to-buckos>",
        },
        "buckos/.buckconfig.local": {
            "cells": {
                "prelude": "<relative-path-to-monorepo-prelude>",
            },
        },
    }
```

---

## Package Convenience Macro

Most packages follow the same pattern: download source + build rule + optional
transform chain. A thin macro wires this up while keeping all intermediate
targets visible, merging private patch registry entries, and auto-populating
mirror URLs from the `[mirror]` buckconfig section.

Version data (url, sha256, version, filename) lives in each package's BUCK file,
not in a central registry. Each BUCK file is self-contained and readable on its
own. BXL scripts discover version info by walking targets, not by reading a
shared dict.

```python
# defs/package.bzl

load("//defs/rules:source.bzl", "extract_source")

def package(
    name,
    build_rule,             # "autotools", "cmake", "meson", "cargo", "go"
    version,                # str: upstream version
    url,                    # str: upstream source URL
    sha256,                 # str: source archive sha256
    filename = None,        # str: archive filename (default: basename of url)
    strip_components = 1,   # int: tar strip-components
    format = None,          # str: override archive format auto-detection
    transforms = [],        # ["strip", "stamp", "ima"] — always applied
    use_transforms = {},    # {"strip": "strip"} — USE flag name → transform name
    use_deps = {},          # {"ssl": "//path:openssl"} — USE flag → dep target
    use_configure = {},     # {"ssl": ("--with-ssl", "--without-ssl")}
    patches = [],           # Public patches from the package dir
    configure_args = [],
    extra_cflags = [],
    **build_kwargs):
```

This macro:

1. Creates the source archive and extraction targets (unless `source` is
   explicitly provided in `build_kwargs`, in which case source creation is
   skipped). The macro reads `[mirror] mode` to decide whether to download
   or use vendored archives:

   ```python
   _filename = filename or url.rsplit("/", 1)[-1]

   if "source" not in build_kwargs:
       # Auto-create source targets
       _mode = read_config("mirror", "mode", "upstream")
       _mirror_base = read_config("mirror", "base_url", "")
       _vendor_dir = read_config("mirror", "vendor_dir", "")

       if _mode == "vendor" and _vendor_dir:
           # Vendor mode: use local archive, no network.
           # vendor_dir must be a repo-relative path (e.g. "vendor/" symlinked
           # or bind-mounted into the repo root). export_file does not support
           # absolute paths outside the repo.
           export_file(
               name = name + "-archive",
               src = "{}/{}".format(_vendor_dir, _filename),
           )
       else:
           # Upstream/mirror mode: download via http_file
           _urls = []
           if _mirror_base:
               _urls.append("{}/{}".format(_mirror_base, _filename))
           _urls.append(url)

           http_file(
               name = name + "-archive",
               urls = _urls,
               sha256 = sha256,
               out = _filename,
           )

       # Extract archive (handles all formats including tar.lz, tar.lz4)
       extract_source(
           name = name + "-src",
           source = ":" + name + "-archive",
           strip_components = strip_components,
           format = format,
       )
       build_kwargs["source"] = ":" + name + "-src"

   # Auto-populate SBOM fields unless explicitly overridden
   build_kwargs.setdefault("version", version)
   build_kwargs.setdefault("src_uri", url)
   build_kwargs.setdefault("src_sha256", sha256)
   ```

   In upstream mode with a mirror configured, `http_file` tries the mirror URL
   first, falling back to upstream on network failure. sha256 mismatch is a hard
   failure (correct behavior — see Source Mirrors and Vendoring section).

   In vendor mode, `export_file` provides the archive from a local directory.
   No network access. The extraction step is identical in both modes.

   **Why mirror URL first in the urls list:** Your mirror is the source of
   truth for the sha256 recorded in the BUCK file. Upstream is a best-effort
   fallback that works until they regenerate the tarball (different timestamps,
   different compression level → different sha256). When that happens, the
   build fails loudly at the upstream URL (sha256 mismatch = hard fail), which
   is the correct signal to update the BUCK file. This is the Gentoo model —
   distfile mirrors are authoritative, upstream is secondary.

2. Merges private patch registry entries (patches, extra_configure_args,
   extra_cflags) from patches/registry.bzl with the public arguments.

3. Creates the build target using the specified build rule:
   - `:name-build`

4. Creates transform targets in chain order, each depending on the previous:
   - `:name-stripped` (if strip in transforms or use_transforms)
   - `:name-stamped` (if stamp in transforms or use_transforms)
   - `:name-signed` (if ima in transforms or use_transforms)

5. Creates a final alias:
   - `:name` → last target in the chain

The complete target chain for a package with all transforms:
```
:name-archive  → http_file or export_file (the downloaded/vendored archive)
:name-src      → extract_source (extracted source directory)
:name-build    → autotools_package / cmake_package / etc (compiled + installed)
:name-stripped → strip_package (debug symbols removed)
:name-stamped  → stamp_package (build provenance injected)
:name-signed   → ima_sign_package (IMA signatures applied)
:name          → alias to the last target in the chain
```

Transform targets controlled by USE flags get `enabled = use_bool("flag")`,
making them a zero-cost passthrough when the flag is off. The target always
exists in the graph regardless.

All intermediate targets are visible and independently buildable for debugging.
For example, `buck2 build //packages/linux/core/zlib:zlib-archive` downloads
just the archive without extracting; `:zlib-src` extracts without building.

### Per-package source override

To override the source for a specific package (e.g. always vendor glibc even
when the global mode is upstream, or use a git checkout), create the source
targets manually and pass `source` explicitly:

```python
load("//defs:package.bzl", "package")
load("//defs/rules:source.bzl", "extract_source")

export_file(
    name = "glibc-archive",
    src = "vendor/distfiles/glibc-2.38.tar.xz",
)

extract_source(
    name = "glibc-src",
    source = ":glibc-archive",
)

package(
    name = "glibc",
    build_rule = "autotools",
    version = "2.38",
    url = "https://ftp.gnu.org/gnu/glibc/glibc-2.38.tar.xz",
    sha256 = "...",
    source = ":glibc-src",  # Explicit source skips auto-creation
    # ...
)
```

Similarly, to use a custom mirror layout or a git source, create the source
target manually. The macro skips auto-creating `:name-archive` and `:name-src`
when `source` is explicitly provided.

---

## Version Management

### Multi-version packages

Multiple versions of the same package are separate targets in the same BUCK file.
Slots are target name suffixes: `:openssl-3`, `:openssl-1.1`. A default alias
(`:openssl`) points to the preferred version. Each target carries its own
version data inline — no shared registry.

```python
# packages/linux/dev-libs/openssl/BUCK

load("//defs:package.bzl", "package")

package(
    name = "openssl-3",
    build_rule = "autotools",
    version = "3.2.0",
    url = "https://www.openssl.org/source/openssl-3.2.0.tar.gz",
    sha256 = "...",
    libraries = ["ssl", "crypto"],
    configure_args = ["--prefix=/usr", "--openssldir=/etc/ssl"],
    patches = glob(["patches/3/*.patch"]),
    transforms = ["strip", "stamp"],
    license = "Apache-2.0",
    # ...
)

package(
    name = "openssl-1.1",
    build_rule = "autotools",
    version = "1.1.1w",
    url = "https://www.openssl.org/source/openssl-1.1.1w.tar.gz",
    sha256 = "...",
    libraries = ["ssl", "crypto"],
    configure_args = ["--prefix=/usr/lib/openssl-1.1"],
    patches = glob(["patches/1.1/*.patch"]),
    transforms = ["strip", "stamp"],
    license = "OpenSSL",
    # ...
)

# Default slot — consumers that just say "openssl" get this
alias(name = "openssl", actual = ":openssl-3")
```

Consumers depend on the default alias unless they specifically need a version.
USE_EXPAND constraints allow profile-level or per-consumer version selection:

```python
# use/constraints/BUCK
use_expand("openssl_slot", ["3", "1.1"])
use_expand("python_slot", ["3.11", "3.12", "3.13"])
use_expand("llvm_slot", ["17", "18", "19"])
```

Consumer packages that need to select based on the slot:

```python
deps = use_versioned_dep("openssl_slot", {
    "3": "//packages/linux/dev-libs/openssl:openssl-3",
    "1.1": "//packages/linux/dev-libs/openssl:openssl-1.1",
})
```

### Version bumps

When openssl 3.2.1 comes out, update the version, url, and sha256 in that
package's BUCK file. The target name stays `:openssl-3`. Consumers don't change.
Buck2 detects the source changed and rebuilds the chain.

### Version data location

There is no central version registry. Version data (version, url, sha256) lives
in each package's BUCK file as arguments to the `package()` macro.

**Why not a central registry:** A single `registry.bzl` mapping every package
to its version/url/sha256 creates a merge-conflict magnet (every version bump
touches the same file), divorces version data from the package that uses it
(you can't read a BUCK file and understand it without also reading the registry),
and loads the entire dict into every BUCK file's evaluation even though each
file only needs its own entry. BXL scripts that need to audit versions across
the tree (vendor.bxl, test_versions.bxl) work by walking targets and reading
attributes — they don't need a central dict.

A BXL audit script (tests/graph/test_versions.bxl) walks all package targets
and verifies that every `http_file` target has a non-empty sha256 and url.

---

## Patch Management

### Patch storage

Patches live alongside the package in a patches/ subdirectory:

```
packages/linux/core/zlib/
├── BUCK
└── patches/
    ├── 0001-fix-minizip-permissions.patch
    └── 0002-cve-2024-XXXX.patch
```

For multi-version packages, version-specific patches go in subdirectories:

```
packages/linux/dev-libs/openssl/
├── BUCK
└── patches/
    ├── 3/
    │   ├── 0001-buckos-default-ciphers.patch
    │   └── 0002-musl-compat.patch
    └── 1.1/
        └── 0001-backport-security-fix.patch
```

BUCK files reference patches with glob():

```python
package(
    name = "zlib",
    patches = glob(["patches/*.patch"]),
    # ...
)

package(
    name = "openssl-3",
    patches = glob(["patches/3/*.patch"]),
    # ...
)
```

### Patch application

The src_prepare phase applies patches in order via tools/patch_helper.py. When
there are no patches, the phase is a zero-cost passthrough — no action runs, no
copy is made, the source artifact is passed directly to src_configure. This means
adding or removing patches only invalidates prepare + downstream phases; the
download and extract remain cached.

The rule's src_prepare implementation:

```python
def _src_prepare(ctx, source):
    """Apply patches. Separate action so unpatched source stays cached."""
    if not ctx.attrs.patches:
        return source  # No patches — zero-cost passthrough

    output = ctx.actions.declare_output("prepared", dir = True)
    cmd = cmd_args(ctx.attrs._patch_tool[RunInfo])
    cmd.add("--source-dir", source)
    cmd.add("--output-dir", output.as_output())
    for p in ctx.attrs.patches:
        cmd.add("--patch", p)

    ctx.actions.run(cmd, category = "prepare", identifier = ctx.attrs.version)
    return output
```

### Patch ordering

Patches apply in list order. Within a BUCK file, patches listed first apply first.
When the private patch registry adds patches, they are appended after the public
patches. This matches Gentoo's model where user patches apply after ebuild patches.

### Conditional patches

Patches can be conditional on USE flags, architecture, or any other constraint
via select():

```python
package(
    name = "glibc",
    patches = [
        # Always applied
        "patches/0001-buckos-paths.patch",
        "patches/0002-locale-gen.patch",
    ] + select({
        "//use/constraints:musl-on": ["patches/0003-musl-compat.patch"],
        "//use/constraints:musl-off": [],
    }) + select({
        "//platforms/arch:x86_64":  ["patches/arch/x86_64-optimize.patch"],
        "//platforms/arch:aarch64": ["patches/arch/aarch64-pagesize.patch"],
    }),
    # ...
)
```

### Private patch registry

The patches/ directory at the repo root (gitignored) provides user-specific
patches that aren't committed to the public repository. It contains:

- patches/BUCK — export_file targets for patch files
- patches/registry.bzl — maps package names to patches and overrides

```python
# patches/registry.bzl (gitignored, user-maintained)

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

The package() macro automatically merges private registry entries with the
package's public patches and args:

```python
# defs/package.bzl (relevant excerpt)

load("//patches:registry.bzl", "PATCH_REGISTRY")
# If patches/ doesn't exist, fall back:
# load("//defs:empty_registry.bzl", "PATCH_REGISTRY")

def package(name, patches = [], configure_args = [], extra_cflags = [], **kwargs):
    private = PATCH_REGISTRY.get(name, {})

    all_patches = list(patches) + private.get("patches", [])
    all_configure_args = list(configure_args) + private.get("extra_configure_args", [])
    all_cflags = list(extra_cflags) + private.get("extra_cflags", [])

    _do_build(
        name = name,
        patches = all_patches,
        configure_args = all_configure_args,
        extra_cflags = all_cflags,
        **kwargs,
    )
```

Disable the private registry via .buckconfig:

```ini
[buckos]
patch_registry_enabled = false
```

---

## Source Mirrors and Vendoring

### Design overview

Source downloads use the prelude's `http_file` rule, which provides native
content-addressed caching (CAS lookup by sha256), deferred execution, RE-native
download handling, and built-in URL-list fallback. Extraction is handled by a
thin `extract_source` rule wrapping `tools/extract.py` to support archive
formats beyond what the prelude's `http_archive` handles (notably tar.lz and
tar.lz4).

For vendor (air-gapped) builds, `export_file` replaces `http_file` — the
archive comes from a local directory instead of the network. The extraction
step is identical in both modes. The package() macro selects which target type
to create based on `[mirror] mode`.

### Design principles

1. **Use the right primitive for each source type.** `http_file` for network
   downloads (gets Buck2-native optimizations). `export_file` for local files
   (already instant — no optimizations needed). A unified `ctx.actions.run()`
   wrapper would lose the download primitive's benefits for no gain.

2. **Mirror is a URL, not a mode.** When `[mirror] base_url` is set, the
   mirror URL is prepended to the `http_file` `urls` list. `http_file` tries
   URLs in order, falling back on network failure. No separate "mirror mode" —
   just URL ordering.

3. **sha256 mismatch is a hard failure.** `http_file` does not try the next
   URL on validation failure, only on download failure. This is correct: a
   sha256 mismatch means the server served wrong content (upstream regenerated
   the tarball, mirror is corrupted, or supply chain attack). Silently falling
   back would mask the problem. The fix is operational: update the registry
   sha256 after verification, re-populate the mirror.

4. **Your mirror is the source of truth.** Once you record a sha256 in the
   registry, your mirror must preserve that exact archive. Upstream is a
   best-effort fallback that works until they regenerate. This is the same model
   Gentoo uses — distfile mirrors are authoritative, upstream is secondary.

### Rejected alternatives

**select() / constraints for source mode.** A constraint like `source-from-mirror`
vs `source-from-upstream` would use select() to choose between different
`http_file` URLs. This was rejected because: (a) all sources produce
byte-identical output (same sha256), so there is no reason for the choice to
affect configuration hashes or downstream action digests; (b) select() resolves
at analysis time and cannot express runtime fallback (if mirror is down, try
upstream); (c) it would double the number of configurations for every package.

**All three URLs in a single ctx.actions.run().** A custom `download_source`
rule receiving upstream URL, mirror URL, and vendor path as attributes, with a
Python download_helper.py that tries each in order. This was the initial design.
It was rejected because `ctx.actions.run()` is opaque to Buck2 — it loses
content-addressed CAS lookup by sha256 (downloads happen even when the content
is already cached), deferred execution (download happens even if the output
is never consumed), and RE-native handling. `http_file` gets all of these for
free.

**Using http_archive for common formats.** See the extract_source rule docs for
why a uniform http_file + extract_source is preferred over conditional rule
selection.

### How URLs are constructed

The package() macro constructs URLs from its arguments + buckconfig:

- **Upstream URL:** `url` argument to the package() macro (always present).
- **Mirror URL:** `[mirror] base_url` + "/" + `filename` (derived from url
  basename or explicit `filename` argument).
  Only included when `base_url` is set.
  Example: `https://mirror.corp/sources/zlib-1.3.1.tar.gz`

The `urls` list passed to `http_file` is ordered mirror-first (if configured),
then upstream. `http_file` tries them in order.

### Vendor files

Vendor files are stored as `[mirror] vendor_dir` + "/" + `filename` from
registry. The package() macro creates an `export_file` target pointing at this
path when `[mirror] mode = vendor`.

Because `export_file` requires a repo-relative path, `vendor_dir` must be
inside the repository tree. For builds using an external vendor directory (e.g.
`/opt/buckos/vendor`), symlink or bind-mount it into the repo:

```bash
# Symlink approach
ln -s /opt/buckos/vendor vendor/distfiles

# Or bind-mount (e.g. in a container)
mount --bind /opt/buckos/vendor vendor/distfiles
```

Then set `vendor_dir = vendor/distfiles` in .buckconfig.

### Populating a vendor directory

For air-gapped or offline builds, populate the vendor directory from the
registry:

```bash
buck2 bxl //tools:vendor.bxl -- --vendor-dir /opt/buckos/vendor
```

The BXL script walks all `http_file` targets in the package tree, reads their
`urls`, `sha256`, and `out` attributes, downloads each archive, verifies sha256,
and stores it as `vendor_dir/filename`.

To verify completeness without downloading:

```bash
buck2 bxl //tools:vendor.bxl -- --vendor-dir /opt/buckos/vendor --verify-only
```

### BXL source auditing

The `test_versions.bxl` audit script (see Testing section) walks all package
targets in the tree and verifies:
- Every `http_file` target has a non-empty `sha256`
- Every `http_file` target has a non-empty `urls` list
- Every package target has a non-empty `version`
- If `[mirror] base_url` is set, every `http_file` target's first URL starts
  with the mirror base URL (mirror-first ordering is maintained)

### Environments

Typical configurations:

**Developer workstation (default):**
```ini
[mirror]
  mode = upstream
```
Downloads directly from upstream. No mirror or vendor setup needed.

**Developer workstation with corporate mirror:**
```ini
[mirror]
  mode = upstream
  base_url = https://mirror.corp.example.com/sources
```
Mirror URL tried first (faster, on corporate network), upstream as fallback.

**CI with corporate mirror:**
```ini
[mirror]
  mode = upstream
  base_url = https://mirror.corp.example.com/sources
```
Same as above. `http_file`'s CAS means repeated CI runs skip downloads entirely
once the content is cached.

**Air-gapped build (strict vendor):**
```ini
[mirror]
  mode = vendor
  vendor_dir = vendor/distfiles
```
Uses local vendor directory via `export_file`. No network access. If vendor is
incomplete (file missing), `export_file` fails — which is the desired behavior
for air-gapped environments.

---

## SBOM Generation

SBOM data lives in PackageInfo provider fields (license, src_uri, src_sha256,
homepage, supplier, description, cpe). Every package BUCK file populates these.

A BXL script (tools/sbom.bxl) walks the configured dependency graph, extracts
PackageInfo from every node, and emits SPDX 2.3 or CycloneDX JSON.

```
buck2 bxl //tools:sbom.bxl -- --target //packages/linux/system:buckos-rootfs --format spdx
buck2 bxl //tools:sbom.bxl -- --target //packages/linux/network/curl:curl --format cyclonedx
```

Labels are NOT used for SBOM data. Labels are used for categorization/filtering
only (e.g., "buckos:firmware" to scope which packages appear in a firmware SBOM).

---

## Target Labels

BuckOS uses Buck2's `labels` attribute to tag targets with structured metadata.
Labels are queryable with `buck2 cquery 'attrfilter(labels, ...)'` and are used
by BXL scripts for filtering, CI target selection, and SBOM scoping.

### Naming convention

All labels follow the `buckos:<category>:<value>` convention. The `buckos:`
prefix avoids collisions when buckos is a cell in a monorepo.

### Auto-injected labels

These labels are applied automatically by the package() macro and build rules:

| Label | Applied To |
|-------|------------|
| `buckos:compile` | All packages built from source |
| `buckos:download` | Source download and extract targets |
| `buckos:prebuilt` | `binary_package` and pre-compiled targets |
| `buckos:image` | `rootfs`, initramfs, ISO, disk image targets |
| `buckos:config` | Kernel config targets |
| `buckos:build:autotools` | Packages using autotools_package |
| `buckos:build:cmake` | Packages using cmake_package |
| `buckos:build:meson` | Packages using meson_package |
| `buckos:build:cargo` | Packages using cargo_package |
| `buckos:build:go` | Packages using go_package |
| `buckos:stage:1` | Bootstrap stage 1 targets |
| `buckos:stage:2` | Bootstrap stage 2 targets |
| `buckos:stage:3` | Bootstrap stage 3 targets |
| `buckos:arch:x86_64` | Architecture-specific targets |
| `buckos:arch:aarch64` | Architecture-specific targets |

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
| `buckos:firmware` | Firmware blobs or microcode |
| `buckos:ci:skip` | Skip in CI |
| `buckos:ci:long` | Long build, sample in CI |

### Query examples

```bash
# All CMake packages
buck2 cquery 'attrfilter(labels, "buckos:build:cmake", //packages/...)'

# All firmware targets
buck2 cquery 'attrfilter(labels, "buckos:firmware", //packages/...)'

# All bootstrap stage 1 targets
buck2 cquery 'attrfilter(labels, "buckos:stage:1", //tc/...)'

# Everything except CI-skipped targets (useful for CI pipelines)
buck2 cquery 'except(//packages/..., attrfilter(labels, "buckos:ci:skip", //packages/...))'
```

### Implementation

The package() macro injects labels based on the build_rule argument:

```python
_auto_labels = ["buckos:compile"]
if build_rule == "autotools":
    _auto_labels.append("buckos:build:autotools")
elif build_rule == "cmake":
    _auto_labels.append("buckos:build:cmake")
# ... etc

# Merge with user-provided labels
_all_labels = _auto_labels + build_kwargs.pop("labels", [])
build_kwargs["labels"] = _all_labels
```

Build rules (autotools_package, etc.) pass labels through to the underlying
target definition. BXL test scripts (test_labels.bxl) verify that every
compiled package has the `buckos:compile` label and the correct
`buckos:build:*` label for its build system.

---

## Testing

### Layer 1: Graph Structure (BXL)

Tests the dependency graph, select() resolution, label assignment, transform
chain wiring, modifier effects, version registry completeness, and private patch
registry integration. Runs at analysis time — no building.

```
buck2 bxl //tests/graph:test_deps.bxl
buck2 bxl //tests/graph:test_use_flags.bxl
buck2 bxl //tests/graph:test_transforms.bxl
buck2 bxl //tests/graph:test_labels.bxl
buck2 bxl //tests/graph:test_versions.bxl
```

Example assertions:
- "zlib-build depends on zlib-src"
- "curl with ssl-on depends on openssl; curl with ssl-off does not"
- "zlib-stripped depends directly on zlib-build"
- "all packages have buckos:compile label"
- "every http_file target has a non-empty sha256"
- "openssl-3 patches include patches/3/*.patch but not patches/1.1/*.patch"

### Layer 2: Action Outputs (genrule / test rules)

Tests that built packages contain expected files.

```
buck2 build //packages/linux/core/zlib:zlib-test-outputs
```

Example assertions:
- "lib/libz.so exists"
- "include/zlib.h exists"
- "lib/pkgconfig/zlib.pc exists"

### Layer 3: Runtime Behavior (vm_test)

Boots kernel + rootfs in QEMU via KVM, runs commands, checks results.

```
buck2 test //packages/linux/system:test-boot
buck2 test //packages/linux/system:test-static-binary
buck2 test //packages/linux/system:test-fhs
buck2 test //tests/vm:test-sched-ext-binary
```

The vm_test rule supports inject_binaries to copy Buck2-built binaries into the
rootfs before boot. This enables testing sched_ext schedulers end-to-end:
build scheduler → build kernel → build rootfs → inject scheduler → boot → run.

### Bootstrap Verification

When using the bootstrap toolchain (tc.mode=bootstrap), the resulting binaries
must be verified to ensure they are self-consistent and independent of the host
system. This is implemented by `tools/verify_bootstrap.sh`, run as a test
target after the bootstrap chain completes.

Checks:
- **No host GLIBC symbol leakage.** For every ELF binary in the rootfs, verify
  that required GLIBC_* symbol versions do not exceed the buckos glibc version.
  If the host has glibc 2.40 but buckos targets 2.38, a binary requiring
  GLIBC_2.39 indicates it was linked against the host, not the buckos sysroot.
  Tool: `objdump -T <binary> | grep GLIBC_` parsed and compared to the target
  glibc version from the glibc package's BUCK file.
- **No host RPATH leakage.** ELF RPATH/RUNPATH entries must not contain host
  paths (e.g. `/usr/lib/x86_64-linux-gnu`). All RPATHs should be under `/usr/lib`
  or relative. Tool: `readelf -d <binary> | grep -E 'RPATH|RUNPATH'`.
- **No host sysroot strings.** Binaries should not contain hardcoded references
  to the host sysroot path. Tool: `strings <binary> | grep <host-sysroot-path>`.
- **Architecture consistency.** All ELF binaries in the rootfs match the target
  architecture. Tool: `readelf -h <binary>` checking Machine field.

```
buck2 test //tc/bootstrap:verify-bootstrap
```

This test should be included in CI for any change touching the bootstrap chain
or core packages (glibc, gcc, binutils).

---

## Migration Strategy

### Constraint: Never Break the Boot Test

The existing test — build kernel with host toolchain, boot in KVM, assert a
binary runs — must pass at every commit. Old macro-based packages and new
rule-based packages coexist during migration.

### Migration Order

Work from the bottom of the dependency tree up. Each step is a self-contained
task.

**Phase 1: Foundation (no existing packages touched)**
1. Write defs/providers.bzl
2. Write all tools/*.py helpers (extract, patch_helper, configure_helper,
   build_helper, install_helper, strip_helper, stamp_helper, ima_helper)
3. Register helpers as targets in tools/BUCK
4. Write defs/rules/source.bzl (extract_source extraction-only rule, uses
   http_file from prelude for downloads)
5. Write defs/rules/autotools.bzl (autotools_package rule)
6. Write defs/rules/transforms.bzl (strip, stamp, ima rules)
7. Write defs/package.bzl (convenience macro with http_file/export_file source
   creation, mirror URL population, label injection, and patch registry merge)
8. Write defs/use_helpers.bzl (all helper functions incl. use_versioned_dep)
9. Remove any [use] or [use_expand] sections from .buckconfig (see
   Architecture Principle 8 for why these must not exist)
10. Remove defs/registry.bzl if it exists — version data belongs in each
    package's BUCK file, not a central dict
11. Test: create a parallel zlib-new target using the new rules, verify output

**Phase 2: Migrate leaf packages one at a time**
1. zlib (zero deps, autotools, simple patches)
2. glibc (depends on linux-headers)
3. busybox (depends on glibc)
4. Run boot test after each package

**Phase 3: USE flags**
1. Set up use/ directory structure (constraints/ and profiles/ subdirs)
2. Define constraint_settings for all flags
3. Add select() to one package (curl is the poster child)
4. Create minimal and desktop profiles
5. Verify both profiles produce different outputs

**Phase 4: Transform chain**
1. Add strip_package / stamp_package to migrated packages
2. Wire USE-controlled transforms via use_bool("flag")
3. Verify intermediate targets are independently buildable

**Phase 5: Additional build rules**
1. cmake_package
2. meson_package
3. cargo_package
4. kernel_build (critical — must produce bootable kernel)
5. rootfs

**Phase 6: Testing infrastructure**
1. vm_test rule + tools/vm_test_runner.py
2. Migrate existing QEMU boot test to vm_test
3. BXL graph structure tests (deps, USE flags, transforms, labels, registry)
4. SBOM BXL script
5. tools/verify_bootstrap.sh + test target //tc/bootstrap:verify-bootstrap

**Phase 7: Toolchains**
1. Set up tc/ directory structure
2. Define //tc/host wrapping system compiler with host sysroot
3. Define //tc/cross wrapping system compiler with buckos-built sysroot
4. Wire as default execution platforms
5. Verify everything still builds (no-op refactor)
6. Write defs/integration.bzl for monorepo cell usage
7. Then implement bootstrap stages (standalone only)
8. Run bootstrap verification after bootstrap chain is complete

### Coexistence During Migration

Old packages use the existing macros from defs/package_defs.bzl. New packages
use rules from defs/rules/*.bzl. Both return artifacts in the same layout (files
installed under a prefix directory). The rootfs rule doesn't care which produced
a package — it just merges prefix directories.

When a new-style package replaces an old-style one, the BUCK file changes but
the target name and output contract stay the same. Downstream consumers are
unaffected.

### Testing During Migration

After migrating each package:
1. `buck2 build //packages/linux/<category>/<pkg>:<pkg>` succeeds
2. Output contains expected files (manual inspection or genrule test)
3. `buck2 build //packages/linux/system:qemu-boot --show-output` still produces
   a bootable image
4. The QEMU boot test passes

---

## Package BUCK File Template

The package() macro auto-creates `http_file` (`:PKGNAME-archive`) and
`extract_source` (`:PKGNAME-src`) targets from the version data passed inline.
Mirror URLs are populated from the `[mirror]` buckconfig section. Most packages
don't need to create source targets manually.

```python
load("//defs:package.bzl", "package")
load("//defs:use_helpers.bzl", "use_dep", "use_configure_arg")

package(
    name = "PKGNAME",
    build_rule = "autotools",  # or "cmake", "meson", "cargo", "go"
    version = "1.2.3",
    url = "https://example.com/PKGNAME-1.2.3.tar.gz",
    sha256 = "abc123...",
    libraries = ["LIBNAME"],
    configure_args = [
        "--prefix=/usr",
    ] + use_configure_arg("FEATURE", "--enable-FEATURE", "--disable-FEATURE"),
    deps = [
        "//packages/linux/core:zlib",
    ] + use_dep("ssl", "//packages/linux/dev-libs/openssl:openssl"),
    patches = glob(["patches/*.patch"]),
    transforms = ["strip", "stamp"],
    use_transforms = {"ima": "ima"},
    # SBOM (version, src_uri, src_sha256 auto-populated from above)
    license = "MIT",
    homepage = "https://example.com",
    description = "Description of the package",
    cpe = "cpe:2.3:a:vendor:product:*:*:*:*:*:*:*:*",
)
```

### Package with custom source

When the macro's auto-generated source doesn't fit (e.g. non-standard mirror
layout, git source, or multiple source archives), create the source targets
manually and pass via `source`:

```python
load("//defs:package.bzl", "package")
load("//defs/rules:source.bzl", "extract_source")

http_file(
    name = "PKGNAME-archive",
    urls = [
        "https://special-mirror.example.com/custom-path/PKGNAME-1.0.tar.gz",
        "https://example.com/PKGNAME-1.0.tar.gz",
    ],
    sha256 = "...",
    out = "PKGNAME-1.0.tar.gz",
)

extract_source(
    name = "PKGNAME-src",
    source = ":PKGNAME-archive",
)

package(
    name = "PKGNAME",
    build_rule = "autotools",
    version = "1.0",
    url = "https://example.com/PKGNAME-1.0.tar.gz",
    sha256 = "...",
    source = ":PKGNAME-src",  # Explicit source skips auto-creation
    # ...
)
```

### Multi-version Package BUCK File Template

Each version carries its own version data inline:

```python
load("//defs:package.bzl", "package")

# ── Slot A ──

package(
    name = "PKGNAME-A",
    build_rule = "autotools",
    version = "3.2.0",
    url = "https://example.com/PKGNAME-3.2.0.tar.gz",
    sha256 = "...",
    patches = glob(["patches/A/*.patch"]),
    # ...
)

# ── Slot B ──

package(
    name = "PKGNAME-B",
    build_rule = "autotools",
    version = "1.1.0",
    url = "https://example.com/PKGNAME-1.1.0.tar.gz",
    sha256 = "...",
    patches = glob(["patches/B/*.patch"]),
    # ...
)

# ── Default ──
alias(name = "PKGNAME", actual = ":PKGNAME-A")
```

---

## CLI Reference

```bash
# Build with defaults
buck2 build //packages/linux/core:zlib

# Build with specific profile
buck2 build //packages/linux/core:curl ?//use/profiles:desktop

# Override individual flag on top of profile
buck2 build //packages/linux/core:curl ?//use/profiles:minimal ?//use/constraints:http2-on

# Cross-compile
buck2 build //packages/linux/core:zlib --target-platforms //platforms:linux-aarch64

# Select toolchain mode
buck2 build //packages/linux/core:zlib --config tc.mode=host
buck2 build //packages/linux/core:zlib --config tc.mode=cross
buck2 build //packages/linux/core:zlib --config tc.mode=bootstrap
buck2 build //packages/linux/core:zlib --config tc.mode=prebuilt

# Full combination (standalone)
buck2 build //packages/linux/system:buckos-rootfs \
    --target-platforms //platforms:linux-x86_64 \
    ?//use/profiles:desktop \
    --config tc.mode=cross

# Full combination (from monorepo root, buckos as cell)
buck2 build buckos//packages/linux/system:buckos-rootfs \
    ?buckos//use/profiles:desktop \
    --config tc.mode=cross

# Run VM tests
buck2 test //packages/linux/system:test-boot
buck2 test //packages/linux/system:

# Source mirror/vendor configuration (set in .buckconfig.local, not usually CLI)
# buck2 build //... --config mirror.mode=vendor
# buck2 build //... --config mirror.base_url=https://mirror.corp/sources

# Populate vendor directory
buck2 bxl //tools:vendor.bxl -- --vendor-dir /opt/buckos/vendor
buck2 bxl //tools:vendor.bxl -- --vendor-dir /opt/buckos/vendor --verify-only

# Generate SBOM
buck2 bxl //tools:sbom.bxl -- --target //packages/linux/system:buckos-rootfs --format spdx

# Query graph
buck2 cquery 'deps(//packages/linux/network/curl:curl)' ?//use/profiles:desktop
buck2 cquery 'attrfilter(labels, "buckos:build:cmake", //packages/...)'

# BXL graph tests
buck2 bxl //tests/graph:test_deps.bxl
buck2 bxl //tests/graph:test_use_flags.bxl
buck2 bxl //tests/graph:test_labels.bxl
buck2 bxl //tests/graph:test_versions.bxl

# Bootstrap verification
buck2 test //tc/bootstrap:verify-bootstrap

# List all targets
buck2 targets //packages/linux/...

# Inspect intermediate build artifacts
buck2 build //packages/linux/core/zlib:zlib-archive  # downloaded archive
buck2 build //packages/linux/core/zlib:zlib-src      # extracted source
buck2 build //packages/linux/core/zlib:zlib-build    # before transforms
buck2 build //packages/linux/core/zlib:zlib-stripped  # after strip
buck2 build //packages/linux/core/zlib:zlib           # final
```
