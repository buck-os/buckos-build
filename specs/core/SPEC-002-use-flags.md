---
id: "SPEC-002"
title: "USE Flag System"
status: "approved"
version: "2.0.0"
created: "2025-11-20"
updated: "2026-05-29"

authors:
  - name: "BuckOS Team"
    email: "team@buckos.org"

maintainers:
  - "team@buckos.org"

category: "core"
tags:
  - "use-flags"
  - "configuration"
  - "features"
  - "build-system"

related:
  - "SPEC-001"
  - "SPEC-004"
  - "SPEC-005"

implementation:
  status: "complete"
  completeness: 95

compatibility:
  buck2_version: ">=2024.11.01"
  buckos_version: ">=1.0.0"
  breaking_changes: true

changelog:
  - version: "2.0.0"
    date: "2026-05-29"
    changes: "Full rewrite against the current package() macro. Removes the use_package()/profile_package()/set_use_flags()/package_use() APIs (never landed) and documents the actual kwargs (use_deps, use_configure, use_features, use_transforms) plus the //defs:use_helpers.bzl primitives."
  - version: "1.0.0"
    date: "2025-12-27"
    changes: "Migrated to formal specification system with lifecycle management"
---

# USE Flag System

## Abstract

The USE flag system gives packages a way to declare optional features and to
gate dependencies, configure arguments, language-specific build features, and
post-build transforms on those features. Resolution is performed by Buck2's
native constraint/select mechanism — flags map to constraints under
`//use/constraints`, and the active platform determines which side of every
`select()` is taken.

Two surfaces are exposed:

1. **High-level kwargs on `package()`** (and therefore on every wrapper like
   `autotools_package`, `cmake_package`, `cargo_package`). This is what
   package authors use day-to-day.
2. **Low-level helpers in `//defs:use_helpers.bzl`** for cases the high-level
   kwargs don't cover (multi-value `USE_EXPAND`, slot-style selection, custom
   `select()` shapes).

## Architecture

### Flag declaration

Flags are declared in `//use/constraints:BUCK` using the `use_flag()` macro
(see `use/constraints/defs.bzl`). For every declared flag `<f>`, the macro
generates two constraint values:

* `//use/constraints:<f>-on`
* `//use/constraints:<f>-off`

A flag is "on" for a build iff the active target platform includes the
`<f>-on` constraint. End users select flags via Buck2 modifiers (see
`use/modifier_aliases.bzl` and `config/local_modifiers.bzl`); the modifier
plumbing lives outside this spec.

### Resolution flow inside `package()`

`defs/package.bzl:package()` (lines 130–599) consumes the four USE kwargs and
expands them into Buck2 selects bound to the constraints above:

| kwarg            | Expands into                                                              |
|------------------|---------------------------------------------------------------------------|
| `use_deps`       | `select()` appended to the rule's `deps` (lines 510–529)                  |
| `use_configure`  | `select()` appended to the rule's `configure_args` via `use_configure_arg` (lines 531–536) |
| `use_features`   | `select()` appended to the rule's `features` (cargo only) (lines 538–543) |
| `use_transforms` | One transform target per flag, gated on `use_bool(flag)` (lines 684–698)  |

The macro also:

* Auto-injects a `buckos:iuse:<flag>` label for every flag it sees in any of
  the four kwargs (lines 574–584). Tooling can use these labels to enumerate
  the IUSE set of a target via `buck2 cquery`.
* Auto-injects `USE_<FLAG>=1` or `USE_<FLAG>=0` env vars (via a `select()`)
  for every referenced flag (lines 589–599). Build/install scripts can branch
  on these directly without touching Starlark.

## High-Level API: `package()` kwargs

All four kwargs are dicts keyed by flag name.

### `use_deps`

Add dependencies conditionally on a USE flag.

```python
use_deps = {
    # Single dep when the flag is on; nothing when off.
    "ssl": "//packages/linux/system/libs/crypto/openssl:openssl",

    # Multiple deps gated on a single flag.
    "readline": [
        "//packages/linux/system/terminal/readline:readline",
        "//packages/linux/system/terminal/ncurses:ncurses",
    ],

    # Different dep when on vs. off.  Either side may be a string or list.
    "ssl": ("//.../openssl:openssl", "//.../gnutls:gnutls"),
}
```

Real example: `packages/linux/core/bash/BUCK` gates the `readline` /
`ncurses` pair on the `readline` flag.

### `use_configure`

Append flag-gated arguments to the package's `configure` invocation
(autotools/cmake/meson — interpretation depends on the rule).

```python
use_configure = {
    # Tuple form: on-arg vs. off-arg.
    "ssl":   ("--with-ssl",      "--without-ssl"),
    "ipv6":  ("--enable-ipv6",   "--disable-ipv6"),

    # String/list form: argument appears only when the flag is on.
    "lto":   "-DENABLE_LTO=ON",
    "extra": ["--enable-foo", "--enable-bar"],
}
```

Real example: `packages/linux/core/bash/BUCK` declares ten flags this way
(`afs`, `bashlogger`, `examples`, `nls`, `pgo`, `plugins`, `readline`, …).

### `use_features`

Cargo-only. Adds a flag-gated entry to the Rust `features` list passed to the
cargo build rule.

```python
use_features = {
    "io-uring":    "io_uring",
    "kvm":         "kvm",
    "guest-debug": "guest_debug",
}
```

Real example: `packages/linux/emulation/utilities/cloud-hypervisor/BUCK`.

### `use_transforms`

Gate a post-build transform on a USE flag. The transform target is always
created in the graph; when the flag is off, the transform is a zero-cost
passthrough.

```python
transforms       = ["strip", "stamp"],   # always applied
use_transforms   = {"ima": "ima"},       # only applied when USE=ima
```

Valid transform names: `"strip"`, `"stamp"`, `"ima"` (see
`_TRANSFORM_MAP` in `defs/package.bzl`).

Real example: `packages/linux/core/zlib/BUCK`,
`packages/linux/system/libs/crypto/openssl/BUCK`.

### Build/install script env vars

Inside any phase script the user supplies (e.g. `post_install_cmds`,
`pre_configure_cmds`, `install_script`), USE flags are visible as
`USE_<FLAG>` environment variables set to `"1"` or `"0"`:

```python
post_install_cmds = ["""
if [ "$USE_DOC" = "1" ]; then
    install -d "$DESTDIR/usr/share/doc/foo"
    cp -r doc/* "$DESTDIR/usr/share/doc/foo/"
fi
"""],
```

## Low-Level API: `//defs:use_helpers.bzl`

For cases the high-level kwargs don't cover, `defs/use_helpers.bzl` exposes
the `select()` constructors directly. These return Starlark `select()`
expressions intended to be concatenated with `+` into the target's attrs.

| Helper                                                  | Returns                                                                 |
|---------------------------------------------------------|-------------------------------------------------------------------------|
| `use_bool(flag)`                                        | `True` when on, `False` otherwise.                                      |
| `use_dep(flag, dep)`                                    | `[dep]` when on, `[]` otherwise.                                        |
| `use_configure_arg(flag, on_arg, off_arg = None)`       | List of args. `on_arg`/`off_arg` may be a string or list.               |
| `use_feature(flag, feature)`                            | `[feature]` when on, `[]` otherwise (cargo features).                   |
| `use_expand_select(expand_name, value_map)`             | Returns the value mapped to the currently selected `USE_EXPAND` value.  |
| `use_expand_dep(expand_name, value, dep)`               | `[dep]` when `<expand>_<value>` is on.                                  |
| `use_expand_multi_deps(expand_name, value_dep_map)`     | Concatenation of `use_expand_dep` over every value.                     |
| `use_versioned_dep(expand_name, version_map)`           | `[dep]` corresponding to the active version-slot value.                 |

Default behaviour (every helper): when the platform doesn't pin either side
of the flag's constraint, the "off" branch is taken (see the `DEFAULT`
arms in `defs/use_helpers.bzl`).

Use the helpers when:

* You need a USE flag to drive a non-standard attribute that `package()`
  doesn't surface (e.g. `make_args`, `env`, `pre_configure_cmds`).
* You're using a `USE_EXPAND`-style multi-valued flag (Python ABI slot, GPU
  vendor, …) where the high-level kwargs don't apply.

```python
load("//defs:use_helpers.bzl", "use_bool", "use_dep")

autotools_package(
    name = "foo",
    ...,
    deps = ["//packages/linux/core/zlib:zlib"]
         + use_dep("ssl", "//packages/linux/system/libs/crypto/openssl:openssl"),
    env = select({
        "//use/constraints:debug-on":  {"CFLAGS": "-O0 -g3"},
        "DEFAULT":                     {"CFLAGS": "-O2"},
    }),
)
```

## Resolution Order

USE flags resolve through Buck2's normal platform/modifier resolution.
Highest priority wins:

1. CLI modifiers (`buck2 build … -m <modifier>`).
2. PACKAGE-file modifiers (per-directory `set_cfg_modifiers()`).
3. Target platform default modifiers (`//platforms:linux-target`).
4. Constraint `DEFAULT` branch in each `select()` — currently "off".

There is no Starlark-level concept of an `iuse` list or `use_defaults`
beyond what each package author writes into the constraint `DEFAULT`
branches. Per-package defaults are an open extension.

## Labels and Querying

For every flag referenced via any of the four kwargs, `package()` attaches a
`buckos:iuse:<flag>` label to the build target. To enumerate the USE
interface of a package:

```bash
buck2 cquery 'attrfilter(labels, "buckos:iuse:", //packages/linux/core/bash/...)' \
    --output-attribute labels
```

To list every USE flag known to the tree:

```bash
buck2 cquery 'attrregexfilter(labels, "buckos:iuse:.*", //packages/...)' \
    --output-attribute labels | grep -oE 'buckos:iuse:[a-z0-9_-]+' | sort -u
```

## Out of Scope (Removed APIs)

The following APIs from the v1 spec **do not exist** and have been removed.
None of them ever landed in `master`:

* `use_package()`, `profile_package()`, `use_ebuild_package()`
* `set_use_flags()`, `package_use()`, `iuse=`, `use_defaults=`, `global_use=`
* `package_customize.bzl`, `package_config()`, `get_env_preset()`,
  `use_patches=`, `package_env=`, `package_mask=`
* `tooling.bzl`, `generate_system_config()`, `export_config_*()`,
  `cmd_list_use_flags()`
* `buckos detect`, `buckos configure` CLI subcommands

Authors who want any of these behaviours today should compose the high-level
kwargs with the low-level helpers above. End-user CLI tooling for selecting
flags is provided by Buck2 modifiers, not by Starlark macros.

## References

* `defs/package.bzl` — `package()` macro (USE handling at lines 142–148,
  510–599, 684–698)
* `defs/use_helpers.bzl` — low-level helpers
* `use/constraints/BUCK` — declared flag set
* `use/constraints/defs.bzl` — `use_flag()`, `use_expand()`, constraint
  generation
* `packages/linux/core/bash/BUCK` — large `use_configure` example
* `packages/linux/core/zlib/BUCK` — `transforms` + `use_transforms`
* `packages/linux/emulation/utilities/cloud-hypervisor/BUCK` — `use_features`
* SPEC-001 — Package Manager Integration (the `package()` macro itself)
* SPEC-004 — Package Sets and System Profiles (how profiles select flag sets)
* SPEC-005 — Patch System (USE-conditional patches via `select()`)
