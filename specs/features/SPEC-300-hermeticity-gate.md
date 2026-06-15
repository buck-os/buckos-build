---
id: "SPEC-300"
title: "ELF Dependency-Closure Hermeticity Gate"
status: "approved"
version: "1.3.0"
created: "2026-06-15"
updated: "2026-06-15"

authors:
  - name: "BuckOS Team"
    email: "team@buckos.org"

maintainers:
  - "team@buckos.org"

category: "features"
tags:
  - "hermeticity"
  - "rootfs"
  - "elf"
  - "testing"
  - "ci"

related:
  - "SPEC-001"
  - "SPEC-004"
  - "SPEC-100"

implementation:
  status: "complete"
  completeness: 100

compatibility:
  buck2_version: ">=2024.11.01"
  buckos_version: ">=1.0.0"
  breaking_changes: false

changelog:
  - version: "1.3.0"
    date: "2026-06-15"
    changes: "Move the live KDE hermeticity gate to nightly alongside Sway: the per-PR KDE ISO build uses a different target-platform configuration, so the per-PR gate was not guaranteed to hit cache. Tighten the rootfs-target-CI-placement guidance to require same-platform PR cache hits. Also: extract rootfs tarballs with filter='fully_trusted' in verify_hermeticity.py — Python 3.12+'s default 'data' filter rejected legitimate rootfs constructs like absolute symlinks (/usr/bin/init -> /usr/lib/systemd/systemd)."
  - version: "1.2.0"
    date: "2026-06-15"
    changes: "Wire the live Sway hermeticity gate into a new nightly workflow (.github/workflows/nightly.yml, 06:00 UTC) rather than the per-PR test job, so Sway gets coverage without forcing a from-scratch rootfs build on every PR."
  - version: "1.1.0"
    date: "2026-06-15"
    changes: "Add three more hermeticity targets covering the shipped images: //tests:test-hermeticity-systemd-container, //tests:test-hermeticity-live-kde, //tests:test-hermeticity-live-sway. The first two are wired into CI; the Sway variant is runnable locally and ships with the BUCK definition, but is not wired into CI yet because the Sway ISO is not built in CI. All three run under //platforms:linux-target (systemd-on/pam-on), not the bare profile."
  - version: "1.0.0"
    date: "2026-06-15"
    changes: "Initial specification of //tests:test-hermeticity. Documents the ELF DT_NEEDED closure check, the //platforms:linux-target-bare platform, the SYSROOT_SONAMES allowlist, the ALLOW_UNRESOLVED escape hatch, and the CI wiring."
---

# ELF Dependency-Closure Hermeticity Gate

**Status**: approved | **Version**: 1.3.0 | **Last Updated**: 2026-06-15

## Abstract

The hermeticity gate (`//tests:test-hermeticity`) audits a built rootfs
for ELF closure: every `DT_NEEDED` soname referenced by a binary or
shared library in the image must be provided somewhere inside that
image, or come from the base-sysroot allowlist. The gate catches the
class of bug where a package lands in the rootfs without its transitive
runtime shared-lib dependencies — binaries that would silently fail at
runtime with `error while loading shared libraries: libfoo.so.N`.

## Motivation

BuckOS rootfs targets enumerate their contents as explicit package lists
rather than computing a transitive runtime-dep closure. Build-time deps
are correctly modelled by Buck2, but a package's *runtime* shared-library
deps are not automatically pulled into the rootfs by virtue of appearing
in `deps`. The closure must be maintained by hand in the rootfs target.

This is fragile. The gate exists to fail loud at build time when an
image's hand-maintained closure drifts away from its actual ELF needs.
The first run of the gate immediately found four real bugs in the base
`buckos-rootfs`:

* `grep` linked `libpcre2` but `pcre2` was not in the image.
* `curl` linked `libpsl` but `libpsl` was not in the image.
* `login`/`su`/`passwd` linked `libpam` but `linux-pam` was not in the image.
* A consumer linked `libbsd`/`libmd` but neither was in the image.
* `procps` linked `libsystemd` because the default target platform has
  `systemd-on`, even though the base image is non-systemd.

The fix was twofold: add the missing libs to `buckos-rootfs`, and
introduce a `linux-target-bare` platform with `systemd-off` so procps
builds `--without-systemd` for the base image.

## Specification

### Targets

The gate is parameterized per-rootfs: one `buckos_test` per audited image.
Each target invokes the same `verify_hermeticity.py` runner; the
differences are the `deps`/`env` pair (which rootfs to audit) and the
target platform the test is invoked under (controls how the rootfs is
built).

| Target                                    | Rootfs target                                          | Platform                            |
|-------------------------------------------|--------------------------------------------------------|-------------------------------------|
| `//tests:test-hermeticity`                | `//packages/linux/system:buckos-rootfs`                | `//platforms:linux-target-bare`     |
| `//tests:test-hermeticity-systemd-container` | `//packages/linux/system:systemd-container-rootfs`  | `//platforms:linux-target`          |
| `//tests:test-hermeticity-live-kde`       | `//packages/linux/system:buckos-live-kde-rootfs`       | `//platforms:linux-target`          |
| `//tests:test-hermeticity-live-sway`      | `//packages/linux/system:buckos-live-sway-rootfs`      | `//platforms:linux-target`          |

All targets share these properties:

| Attribute | Value |
|-----------|-------|
| `test`    | `verify_hermeticity.py` |
| `labels`  | `["integration", "hermeticity", "heavy"]` |

The `heavy` label keeps each test out of the fast `buck2 test //tests:`
sweep used by the `test-seed` CI job; they must be invoked explicitly.

### Platforms

Each rootfs target **MUST** be invoked under the platform it was built
to ship under. The two platforms used:

* `//platforms:linux-target-bare` — `systemd-off` + `pam-on`. Used for
  `buckos-rootfs` (the non-systemd base) so `procps` builds
  `--without-systemd` and the image doesn't need to ship `libsystemd`.
* `//platforms:linux-target` — `systemd-on` + `pam-on`. Used for the
  three shipped images (systemd container, live KDE, live Sway), all of
  which run systemd as PID 1.

```bash
# Base (non-systemd)
buck2 test //tests:test-hermeticity \
    --target-platforms //platforms:linux-target-bare

# Shipped images (systemd)
buck2 test //tests:test-hermeticity-systemd-container \
    --target-platforms //platforms:linux-target
buck2 test //tests:test-hermeticity-live-kde \
    --target-platforms //platforms:linux-target
buck2 test //tests:test-hermeticity-live-sway \
    --target-platforms //platforms:linux-target
```

### Adding a new rootfs target

To wire a new rootfs into the gate, add a `buckos_test` modelled on the
existing ones:

```python
buckos_test(
    name = "test-hermeticity-<image>",
    test = "verify_hermeticity.py",
    deps = ["//packages/linux/system:<image>-rootfs"],
    env = {"ROOTFS": "$(location //packages/linux/system:<image>-rootfs)"},
    labels = ["integration", "hermeticity", "heavy"],
)
```

Then add a CI step under whichever platform the rootfs is built for.

### Audit algorithm

`tests/verify_hermeticity.py` is a thin shim: it resolves `$ROOTFS`
(directory or tarball — tarballs are extracted to a temp dir), then
shells out to `tools/elf_audit.py --prefix <rootfs>`.

`tools/elf_audit.py` is the worker. For each ELF file under `--prefix`:

1. Extract `DT_NEEDED` entries with `readelf -d`.
2. For each soname:
   * Pass if it's in `SYSROOT_SONAMES` (the curated base-sysroot
     allowlist).
   * Pass if the file `<soname>` exists anywhere recursively under any
     `--dep-prefix` (the rootfs itself is always added as the first
     dep-prefix).
   * Pass if it's in `--allow-unresolved` (the escape hatch).
   * Pass if `<soname>.split(".so")[0] + ".so"` is in `SYSROOT_SONAMES`
     (versioned-soname tolerance: `libasan.so.8` matches the
     allowlisted `libasan.so`).
3. Otherwise record as unresolved.

Exit codes:

* `0` — all NEEDED entries resolve.
* `1` — at least one unresolved soname; the failure prints each
  unresolved soname plus up to five binaries that reference it.
* `2` — usage error.

### Allowlist (SYSROOT_SONAMES)

The base allowlist in `tools/elf_audit.py` covers libraries the
toolchain's glibc + GCC runtime universally provide:

```
libc.so.6        libm.so.6       libdl.so.2       libpthread.so.0
librt.so.1       libutil.so.1    libresolv.so.2   libnss_dns.so.2
libnss_files.so.2 libcrypt.so.1  libcrypt.so.2    libmvec.so.1
libnsl.so.1      ld-linux-x86-64.so.2             linux-vdso.so.1
libstdc++.so.6   libgcc_s.so.1   libatomic.so.1   libgomp.so.1
libquadmath.so.0 libasan.so      libtsan.so       libubsan.so
```

New sysroot libraries that are universally available (e.g. an
aarch64-specific ld-linux name) **SHOULD** be added to this list rather
than allowlisted per-test. Per-image carve-outs use
`ALLOW_UNRESOLVED`, never an edit to `SYSROOT_SONAMES`.

### Escape hatch (ALLOW_UNRESOLVED)

```bash
ALLOW_UNRESOLVED="libfoo.so.1 libbar.so.2" \
    buck2 test //tests:test-hermeticity \
    --target-platforms //platforms:linux-target-bare
```

`ALLOW_UNRESOLVED` is a space-separated list of sonames to tolerate as
unresolved. **Use only when:**

* The dependency is known to come from a runtime overlay outside the
  rootfs (e.g. a host-injected library on a container target).
* A package is in transition and adding the lib to the rootfs is being
  done as a follow-up.

In both cases the carve-out **MUST** be temporary; the alternative is
to add the lib to the rootfs target's package list.

### CI integration

The two cheap gates run on every PR in the `test` job of
`.github/workflows/ci.yml`. They run before the build step that
consumes the rootfs so the rootfs is built once (by the test) and
reused (by the build step):

```yaml
- name: Hermeticity gate (base rootfs ELF dependency closure)
  run: buck2 test //tests:test-hermeticity \
       --target-platforms //platforms:linux-target-bare
- name: Hermeticity gate (systemd-container rootfs)
  run: buck2 test //tests:test-hermeticity-systemd-container \
       --target-platforms //platforms:linux-target
- name: Build systemd container rootfs
  run: buck2 build //packages/linux/system:systemd-container-rootfs ...
```

The two live-desktop gates (`test-hermeticity-live-kde`,
`test-hermeticity-live-sway`) run on a nightly schedule at 06:00 UTC
in `.github/workflows/nightly.yml`. Both are heavy: the Sway ISO is
not otherwise built in CI, and the KDE rootfs — though built per-PR
for the KDE ISO step — uses a different target-platform configuration
there, so a per-PR gate is not guaranteed to hit cache. Nightly bounds
the worst-case rebuild cost to once a day; regression-detection latency
is at most 24h.

Run either locally before publishing changes that affect those
images:

```bash
buck2 test //tests:test-hermeticity-live-kde \
    --target-platforms //platforms:linux-target
buck2 test //tests:test-hermeticity-live-sway \
    --target-platforms //platforms:linux-target
```

New shipped rootfs targets **SHOULD** land with a matching
`test-hermeticity-<image>` target. Wire the CI step into the per-PR
`test` job only when the rootfs is already built by an existing PR
step **under the same target-platform** (true cache hit); otherwise
wire it into the nightly workflow to bound per-PR cost.

## Extending the gate

### Auditing a new rootfs target

1. Build the target so a directory or tarball exists.
2. Run the audit ad-hoc:

   ```bash
   ROOTFS=$(buck2 build //packages/linux/system:my-rootfs --show-output \
            | awk '{print $2}') \
       python3 tests/verify_hermeticity.py
   ```

3. If clean, wire a `buckos_test` modelled on `test-hermeticity` with
   `deps` and `env` pointing at the new target, and add a CI step that
   invokes it under whichever platform the rootfs is built for.

### Auditing a single package's installed prefix

`tools/elf_audit.py` accepts `--dep-prefix` repeatedly. This is the
intended single-package mode:

```bash
python3 tools/elf_audit.py \
    --prefix  buck-out/v2/gen/.../coreutils/__coreutils-build__/installed \
    --dep-prefix buck-out/v2/gen/.../glibc/...installed \
    --dep-prefix buck-out/v2/gen/.../zlib/...installed
```

### Adding a new architecture

When the gate is run against an aarch64 rootfs, `SYSROOT_SONAMES`
needs `ld-linux-aarch64.so.1`. Add it to the set; do not gate by
target arch — the soname can only be a real DT_NEEDED on an aarch64
ELF, so the extra entry is harmless on x86_64 audits.

## Out of scope

The gate explicitly does **not**:

* Verify rpath/runpath correctness (it only checks soname resolution).
* Verify exec dependencies (interpreters for `#!`-scripts, helper
  binaries fork-exec'd at runtime). Those failures need a separate
  test surface.
* Verify that the *right* version of a soname is provided. If
  `libfoo.so.1` is needed and `libfoo.so.2` is shipped, the gate
  passes; `ldconfig` would refuse to satisfy the link.
* Verify packaged libraries with unusual soname suffixes (`.so.0.1.2`
  with no plain `.so`). These are accepted as providers based on the
  basename check.

## Implementation references

* `tests/verify_hermeticity.py` — test entrypoint (resolves `$ROOTFS`,
  shells out to `elf_audit.py`, surfaces the pass/fail line).
* `tools/elf_audit.py` — audit worker (ELF discovery, NEEDED
  extraction, soname resolution, sysroot allowlist).
* `tests/BUCK` — `test-hermeticity` target.
* `platforms/BUCK` — `linux-target-bare` platform.
* `.github/workflows/ci.yml` — `test` job hermeticity step
  (commit `846aa116d` introduced both the gate and the platform).
* `packages/linux/system/BUCK` — `buckos-rootfs` package list
  (pcre2, libpsl, linux-pam, libbsd, libmd added in `846aa116d` so
  the base passes closure).

## Security considerations

The gate is a build-time correctness check, not a security boundary.
A malicious package can still ship a stub `libfoo.so.1` to satisfy the
closure check without providing the real symbols — closure says nothing
about ABI. The protection the gate provides is against accidental
omissions, not against intentional misdirection.

`ALLOW_UNRESOLVED` is permissive by design (it's an escape hatch).
Reviewers **SHOULD** treat additions to `ALLOW_UNRESOLVED` as fixes
that need a TODO/issue link in the surrounding context, not as a
permanent solution.

## Alternatives considered

### Use `ldd` instead of `readelf`

**Why rejected**: `ldd` resolves against the *host* dynamic linker's
search path, which is meaningless when auditing a foreign rootfs.
`readelf -d` extracts the static DT_NEEDED list, which is what we
actually want to validate against the image's contents.

### Compute the closure with `chroot` + `ldconfig -p`

**Why rejected**: Requires root or unshare-with-user-ns, won't work on
read-only mounts in CI, and adds chroot tooling as a test dependency.
The pure-`readelf` approach has no privilege requirements.

### Make rootfs targets compute their own closure (transitive runtime deps)

**Why considered**: This is the structural fix — eliminate the
hand-maintained package list. **Why deferred**: BuckOS packages do not
yet distinguish build-time deps from runtime deps in their attributes;
adding a `runtime_deps` channel is a separate larger change. The gate
catches drift in the meantime and gives the eventual restructuring a
regression test it can run against the old hand-list image to verify
behavioural equivalence.

## References

* SPEC-001 — Package Manager Integration (rootfs assembly model)
* SPEC-004 — Package Sets and System Profiles
* SPEC-100 — Toolchain Bootstrap and Seed (where `SYSROOT_SONAMES`
  libraries come from)
* Commit `846aa116d` — original implementation + fixes
