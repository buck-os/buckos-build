---
id: "SPEC-005"
title: "Patch System"
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
  - "patches"
  - "customization"
  - "build-system"
  - "source-modification"

related:
  - "SPEC-001"
  - "SPEC-002"
  - "SPEC-004"

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
    changes: "Full rewrite against the current package() macro. Removes the ebuild-flavoured epatch()/eapply()/eapply_user() helpers (never landed), the use_patches kwarg, $FILESDIR substitution, series files, and the package_customize.package_patches API. Documents the actual two-source model: the patches= kwarg plus the PATCH_REGISTRY override."
  - version: "1.0.0"
    date: "2025-12-27"
    changes: "Migrated to formal specification system with lifecycle management"
---

# Patch System

## Abstract

The patch system applies unified-diff patches to a package's extracted source
tree during the `src_prepare` build phase. There are exactly two patch
sources, applied in order:

1. **Public patches** — the `patches = […]` kwarg on `package()` (or any
   wrapper that forwards it).
2. **Private patches** — entries in `PATCH_REGISTRY`, an optional dict loaded
   at the top of `defs/package.bzl`. Default is the empty dict from
   `defs/empty_registry.bzl`; users override by editing the load to point at
   their own (gitignored) `patches/registry.bzl`.

There are no profile-patch overlays, no `$FILESDIR` shell substitution, no
`series` files, no `eapply_user()` hook, and no `package_customize` config
object. Patches are plain Buck targets (typically `export_file`s under
`//patches`) referenced by label.

## Patch Application

### Where it happens

For every configurable build rule (`autotools`, `cmake`, `meson`, `cargo`,
`go`, `python`, …), the `src_prepare` phase reads the `patches` attribute
and applies each entry with `patch -p1` in a freshly-extracted copy of the
source tree. When `patches` is empty, the phase is a zero-cost passthrough
that aliases the unpatched source — so the cache key of an unpatched build
does not change when patches are added to a sibling target.

Reference implementation: `defs/rules/autotools.bzl:_src_prepare()`
(lines 35–50). Other rule modules share the same shape.

```python
def _src_prepare(ctx, source):
    if not ctx.attrs.patches:
        return source  # Zero-cost passthrough
    output = ctx.actions.declare_output("prepared", dir = True)
    cmd = cmd_args(ctx.attrs._patch_tool[RunInfo])
    cmd.add("--source-dir", source)
    cmd.add("--output-dir", output.as_output())
    for p in ctx.attrs.patches:
        cmd.add("--patch", p)
    ...
```

### Order

`package()` merges public patches first, then appends private-registry
patches:

```python
all_patches = list(patches) + private.get("patches", [])
```

(see `defs/package.bzl:_merge_private_registry()`, lines 109–127). Each
patch is applied with `patch -p1` in the order it appears in the merged
list.

## Source 1: The `patches` kwarg

A flat list of Buck labels pointing at patch files. Anything that resolves
to an artifact is acceptable — typically `export_file()` targets in a
`patches/` subdirectory next to the BUCK file, or a `glob()`.

### Sibling glob

```python
# packages/linux/core/musl/BUCK
autotools_package(
    name      = "musl",
    version   = "1.2.5",
    url       = "...",
    sha256    = "...",
    patches   = glob(["patches/*.patch"]),
    transforms = ["strip"],
    ...
)
```

Real examples: `packages/linux/core/musl/BUCK`,
`packages/linux/core/zlib/BUCK`,
`packages/linux/core/busybox/BUCK`,
`packages/linux/system/libs/cpio/BUCK`.

### Explicit labels (cross-package patches)

```python
patches = [
    "//patches:fix-build.patch",
    "//patches/security:cve-2026-0001.patch",
],
```

The targets on the right are `export_file()`s in the corresponding `BUCK`
file.

### USE-conditional patches

There is no dedicated `use_patches` kwarg. Use a standard Buck2 `select()`
keyed on the USE constraints from SPEC-002:

```python
patches = glob(["patches/*.patch"]) + select({
    "//use/constraints:hardened-on": ["//patches:hardening.patch"],
    "DEFAULT":                       [],
}),
```

Any `select()` on any constraint (USE flag, platform, target arch) is
acceptable — the kwarg ultimately becomes the rule's `patches` attribute,
which is a normal `attrs.list(attrs.source())`.

## Source 2: `PATCH_REGISTRY` (private overrides)

`PATCH_REGISTRY` is a dict loaded at the top of `defs/package.bzl`:

```python
load("//defs:empty_registry.bzl", "PATCH_REGISTRY")
```

The default registry (`defs/empty_registry.bzl`) is the empty dict.
Distributions or downstream forks that need to inject patches without
modifying upstream `BUCK` files maintain their own gitignored
`patches/registry.bzl` and replace the load statement to point at it:

```python
load("//patches:registry.bzl", "PATCH_REGISTRY")
```

### Format

```python
# patches/registry.bzl
PATCH_REGISTRY = {
    "package-name": {
        "patches":               ["//patches:my-private.patch", ...],
        "extra_configure_args":  ["--enable-internal-foo"],
        "extra_cflags":          ["-DDOWNSTREAM_BUILD=1"],
    },
    ...
}
```

The lookup key is the package's `name` attribute. For every entry,
`package()` appends:

| Registry key             | Appended to            |
|--------------------------|------------------------|
| `patches`                | `patches` kwarg        |
| `extra_configure_args`   | `configure_args` kwarg |
| `extra_cflags`           | `extra_cflags` kwarg   |

All three are simple list concatenations; private values always come after
public ones. See `_merge_private_registry()` in `defs/package.bzl`.

### Disabling

There is no separate "off" switch — to disable a private patch, edit the
load at the top of `defs/package.bzl` back to `//defs:empty_registry.bzl`,
or remove the package's entry from `patches/registry.bzl`.

## Patch Format

Patches are standard unified diffs applied with `patch -p1`. Any tool that
produces this format works (`git diff`, `git format-patch`, `diff -ruN`,
`quilt refresh`).

* All patches are applied at `-p1`. Patches that need a different strip
  level must be regenerated.
* No fuzz tolerance is configured at the Starlark layer; the underlying
  `patch` invocation uses its default fuzz behaviour.
* The patch tool runs inside the hermetic build sandbox with no network
  access (see SPEC-001 for the sandbox model). The source tree lives in a
  declared output, so changes do not leak between rebuilds.

## Wiring `export_file()` for cross-package patches

When a patch lives outside the consuming package's directory, declare it as
an `export_file()` so it has a Buck label:

```python
# patches/BUCK
export_file(
    name       = "my-patch.patch",
    src        = "my-patch.patch",
    visibility = ["PUBLIC"],
)
```

For directories of patches use `glob` + a generator loop, or `filegroup` +
the `srcs` of the package — the `patches` attr accepts any artifact.

## Out of Scope (Removed APIs)

The v1 spec described an ebuild-flavoured patch system that **was never
implemented**. The following are removed:

* `epatch()`, `eapply()`, `eapply_user()` helpers
* `pre_configure = "patch -p1 < $FILESDIR/foo.patch"` — there is no
  `$FILESDIR` substitution; pre-configure shell hooks use the
  `pre_configure_cmds = ["..."]` attribute on autotools and run in the
  *source* directory, not a patch directory
* `use_patches = {...}` kwarg — use `select()` in the `patches` list
* `package_customize.bzl`, `package_config(package_patches = …)`
* `series` files for ordering — order is the literal list order in `patches`
* `multi_version_package(versions = {... "patches": [...]})` — each
  versioned slot is a normal `package()` call with its own `patches` kwarg
* `/etc/portage/patches/` filesystem patch overlay
* `platform_select()` helper — use Buck2's native `select()` directly

## References

* `defs/package.bzl` — `package()` macro, `_merge_private_registry()`
  (lines 109–127, 196–202)
* `defs/empty_registry.bzl` — default empty `PATCH_REGISTRY`
* `defs/rules/autotools.bzl:_src_prepare()` (lines 35–50) — applier; mirror
  implementations live in `defs/rules/{cmake,meson,cargo,go,python,...}.bzl`
* `packages/linux/core/musl/BUCK`, `packages/linux/core/zlib/BUCK`,
  `packages/linux/core/busybox/BUCK` — `patches = glob(...)` examples
* SPEC-001 — Package Manager Integration (build-phase pipeline)
* SPEC-002 — USE Flag System (constraints used by `select()`-keyed patches)
* SPEC-004 — Package Sets and System Profiles
