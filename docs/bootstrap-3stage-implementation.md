# 3-Stage Bootstrap Implementation Guide

**Status:** Phase 1 Complete - Bootstrap scripts and infrastructure ready
**Date:** 2025-12-09
**Next:** Update bootstrap/BUCK to use stage-specific scripts

---

## What Was Implemented

### 1. Three Bootstrap Scripts Created ✅

**Location:** `defs/scripts/`

- `ebuild-bootstrap-stage1.sh` - Build cross-toolchain using host compiler
- `ebuild-bootstrap-stage2.sh` - Build core utilities using cross-compiler (strict isolation)
- `ebuild-bootstrap-stage3.sh` - Verification and final system (complete isolation)

Each script has:
- Detailed isolation levels
- Comprehensive verification
- Clear documentation
- Error handling and validation

### 2. Package Definitions Updated ✅

**File:** `defs/package_defs.bzl`

Added `bootstrap_stage` parameter to `ebuild_package`:
```python
ebuild_package(
    name = "my-package",
    bootstrap_stage = "stage1",  # or "stage2", "stage3", or "" for regular
    ...
)
```

Logic automatically selects correct ebuild script based on stage.

### 3. Build System Integration ✅

**File:** `defs/scripts/BUCK`

All three bootstrap scripts exported and available for use.

---

## How to Use Bootstrap Stages

### Stage 1: Cross-Compilation Toolchain

**Purpose:** Build initial cross-compiler
**Uses:** Host GCC and libraries
**Isolation:** PARTIAL (host tools accessible)

**Packages:**
- cross-binutils
- cross-gcc-pass1
- linux-headers
- cross-glibc
- cross-libstdc++
- cross-gcc-pass2

**Example:**
```python
ebuild_package(
    name = "cross-gcc-pass1",
    source = ":gcc-src",
    version = "15.2.0",
    bootstrap_stage = "stage1",  # Uses ebuild-bootstrap-stage1.sh
    bdepend = [":cross-binutils", ":gmp-src", ":mpfr-src", ":mpc-src"],
    ...
)
```

### Stage 2: Core System Utilities

**Purpose:** Build core tools with strict isolation
**Uses:** Stage 1 cross-compiler ONLY
**Isolation:** STRONG (no host fallback)

**Packages:**
- ncurses, readline
- bash, coreutils, make
- sed, gawk, grep
- findutils, diffutils
- tar, gzip, xz
- perl, python3 (NEW)
- pkg-config, m4, autoconf, automake (NEW)

**Example:**
```python
ebuild_package(
    name = "bootstrap-bash",
    source = ":bash-src",
    version = "5.3",
    bootstrap_stage = "stage2",  # Uses ebuild-bootstrap-stage2.sh
    bdepend = [":cross-gcc-pass2", ":cross-glibc", ":bootstrap-readline"],
    ...
)
```

### Stage 3: Verification & Final System

**Purpose:** Rebuild toolchain with itself, verify isolation
**Uses:** Stage 2 toolchain (native, not cross)
**Isolation:** COMPLETE (100% self-hosting)

**Packages:**
- gcc-stage3 (rebuilt, compared with stage2)
- glibc-stage3 (rebuilt)
- Final system packages

**Example:**
```python
ebuild_package(
    name = "bootstrap-gcc-stage3",
    source = ":gcc-src",
    version = "15.2.0",
    bootstrap_stage = "stage3",  # Uses ebuild-bootstrap-stage3.sh
    bdepend = [":bootstrap-toolchain-stage2"],  # All of stage 2
    ...
)
```

---

## Isolation Levels Explained

### Stage 1: PARTIAL Isolation
```
HOST System              Stage 1 Output
┌─────────────┐         ┌──────────────────┐
│ gcc (host)  │ ──────> │ /tools/          │
│ glibc (host)│         │   x86_64-buckos- │
│ libraries   │         │   linux-gnu-gcc  │
│ tools       │         │   glibc          │
└─────────────┘         └──────────────────┘
  Used to build           Cross-compiler
```

**PATH:** `$TOOLCHAIN_PATH:$DEP_PATH:$HOST_PATH`
**Libraries:** Host libraries accessible
**Compiler:** Host GCC with C17/C++17 flags

### Stage 2: STRONG Isolation
```
Stage 1 Output           Stage 2 Output
┌──────────────────┐    ┌──────────────────┐
│ cross-gcc-pass2  │──> │ /tools/          │
│ cross-glibc      │    │   bash           │
│ cross-binutils   │    │   coreutils      │
└──────────────────┘    │   make           │
  ONLY source            │   gcc (native)   │
                        └──────────────────┘
```

**PATH:** `$TOOLCHAIN_PATH:$DEP_PATH` (NO $HOST_PATH)
**Libraries:** ONLY Stage 1 libraries
**Compiler:** Cross-compiler (x86_64-buckos-linux-gnu-gcc)

### Stage 3: COMPLETE Isolation
```
Stage 2 Output           Stage 3 Output
┌──────────────────┐    ┌──────────────────┐
│ Native gcc       │──> │ /usr/            │
│ bash, make       │    │   gcc (verified) │
│ all tools        │    │   glibc          │
└──────────────────┘    │   Final system   │
  100% bootstrap         └──────────────────┘
```

**PATH:** `$TOOLCHAIN_PATH:$DEP_PATH` (NO $HOST_PATH)
**Libraries:** ONLY Stage 2 libraries
**Compiler:** Native gcc from Stage 2
**Verification:** Binary comparison, ldd checks

---

## Next Steps

### Phase 2: Add Missing Stage 2 Packages

Add to `toolchains/bootstrap/BUCK`:

1. **perl** - Required by many configure scripts
2. **python3** - Required by meson, other build systems
3. **pkg-config** - Required to find libraries
4. **m4** - Required by autoconf
5. **autoconf** - Required for autogen.sh
6. **automake** - Required for autogen.sh
7. **bison** - Required by parsers
8. **flex** - Required by lexers
9. **file** - Required for file type detection
10. **patch** - Required for applying patches

### Phase 3: Add Stage 3 Verification Targets

Create in `toolchains/bootstrap/BUCK`:

```python
ebuild_package(
    name = "bootstrap-gcc-stage3",
    source = ":gcc-src",
    version = "15.2.0",
    bootstrap_stage = "stage3",
    bdepend = [":bootstrap-toolchain"],  # All of stage2
    ...
)

# Comparison target
genrule(
    name = "verify-bootstrap",
    cmd = """
        # Compare stage2 vs stage3 gcc
        if diff -r $(location :cross-gcc-pass2)/tools \
                   $(location :bootstrap-gcc-stage3)/usr; then
            echo "VERIFICATION PASSED: Stage 2 and Stage 3 are identical"
        else
            echo "VERIFICATION FAILED: Stage 2 and Stage 3 differ"
            exit 1
        fi
    """,
    ...
)
```

### Phase 4: Create Verification Scripts

Create `scripts/verify-bootstrap-isolation.sh`:

```bash
#!/bin/bash
# Verify that packages don't depend on host libraries

PACKAGE_DIR="$1"

find "$PACKAGE_DIR" -type f -executable | while read binary; do
    if file "$binary" | grep -q "ELF"; then
        # Check for host library dependencies
        if ldd "$binary" | grep -E "(/lib64/|/usr/lib/)" | grep -v "buckos" | grep -v "/tools/"; then
            echo "ERROR: $binary links to host libraries"
            exit 1
        fi
    fi
done

echo "VERIFICATION PASSED: No host dependencies found"
```

### Phase 5: Update Bootstrap BUCK File

Update `toolchains/bootstrap/BUCK` to use:
- `bootstrap_stage = "stage1"` for cross-toolchain packages
- `bootstrap_stage = "stage2"` for core utilities
- `bootstrap_stage = "stage3"` for verification builds

---

## Testing the 3-Stage Bootstrap

### Full Clean Build

```bash
# Clean everything
buck2 kill && buck2 clean

# Build Stage 1 (cross-toolchain)
buck2 build //tc/bootstrap/stage1:gcc-pass2

# Build Stage 2 (core utilities)
buck2 build toolchains//bootstrap:bootstrap-toolchain

# Build Stage 3 (verification)
buck2 build toolchains//bootstrap:bootstrap-gcc-stage3

# Verify isolation
./scripts/verify-bootstrap-isolation.sh \
    buck-out/v2/gen/toolchains/.../bootstrap-toolchain
```

### Expected Output

```
Stage 1 Complete:
  ✓ cross-gcc-pass2 built with host GCC
  ✓ cross-glibc built with cross-gcc-pass1
  ✓ Tools installed to /tools

Stage 2 Complete:
  ✓ All utilities built with cross-gcc-pass2
  ✓ No host library dependencies detected
  ✓ Strong isolation verified

Stage 3 Complete:
  ✓ GCC rebuilt with itself
  ✓ Stage 2 vs Stage 3 binaries identical
  ✓ Complete isolation verified
  ✓ System is fully self-hosting
```

---

## Architecture Diagram

```
┌────────────────────────────────────────────────────────────────┐
│                        HOST SYSTEM                              │
│  (gcc 15.2, glibc 2.42, binutils 2.44, bash, coreutils, etc.)  │
└────────────────────────────────────────────────────────────────┘
                              │
                              │ ebuild-bootstrap-stage1.sh
                              ▼
┌────────────────────────────────────────────────────────────────┐
│                     STAGE 1: Cross-Toolchain                    │
│  /tools/x86_64-buckos-linux-gnu-{gcc,g++,as,ld,...}            │
│  /tools/lib64/ld-linux-x86-64.so.2 (dynamic linker)            │
│  Glibc 2.42 (target), Libstdc++ (target)                       │
│                                                                  │
│  Isolation: PARTIAL (uses host compiler/libraries)              │
└────────────────────────────────────────────────────────────────┘
                              │
                              │ ebuild-bootstrap-stage2.sh
                              ▼
┌────────────────────────────────────────────────────────────────┐
│                    STAGE 2: Core Utilities                      │
│  /tools/{bash,make,sed,awk,grep,find,tar,gzip,xz,...}          │
│  /tools/{perl,python3,pkg-config,autoconf,automake,...}        │
│  Native GCC (gcc, not x86_64-buckos-linux-gnu-gcc)             │
│                                                                  │
│  Isolation: STRONG (ZERO host fallback, cross-compiler only)   │
└────────────────────────────────────────────────────────────────┘
                              │
                              │ ebuild-bootstrap-stage3.sh
                              ▼
┌────────────────────────────────────────────────────────────────┐
│                STAGE 3: Verification & Final System             │
│  /usr/{gcc,g++,make,bash,coreutils,...}                        │
│  GCC rebuilt (should match Stage 2)                             │
│  Glibc rebuilt                                                   │
│  ldd verification: NO /lib64 dependencies                        │
│                                                                  │
│  Isolation: COMPLETE (100% self-hosting, verified)              │
└────────────────────────────────────────────────────────────────┘
```

---

## Key Features of Each Script

### ebuild-bootstrap-stage1.sh

- ✅ Uses host compiler (gcc, g++)
- ✅ Host PATH included as fallback
- ✅ Builds cross-compilation tools
- ✅ C17/C++17 flags for GCC 15 compat
- ✅ FOR_BUILD uses host compiler
- ✅ Output to /tools with target prefix

### ebuild-bootstrap-stage2.sh

- ✅ Uses cross-compiler ONLY
- ✅ NO host PATH fallback
- ✅ Strict library isolation
- ✅ Sysroot enforcement
- ✅ Binary contamination checking
- ✅ FOR_BUILD still uses host (for helper tools)
- ✅ Output to /tools without prefix

### ebuild-bootstrap-stage3.sh

- ✅ Uses Stage 2 native compiler
- ✅ Absolute isolation (zero host)
- ✅ Native compilation (not cross)
- ✅ Tool availability verification
- ✅ Comprehensive contamination checking
- ✅ FOR_BUILD uses bootstrap toolchain
- ✅ Output to /usr (final system)

---

## Benefits

1. **Clear separation** - Each stage has explicit purpose and isolation level
2. **Verification** - Stage 3 proves correctness through comparison
3. **Maintainability** - Easy to debug, understand, and modify
4. **Reproducibility** - Identical inputs → identical outputs
5. **Security** - Full provenance, no hidden dependencies
6. **Standards compliance** - Follows LFS, Gentoo, and GCC best practices

---

## Status Summary

| Component | Status | Notes |
|-----------|--------|-------|
| Stage 1 script | ✅ Complete | Tested structure, ready to use |
| Stage 2 script | ✅ Complete | Strict isolation, verification |
| Stage 3 script | ✅ Complete | Full verification, contamination checks |
| package_defs.bzl | ✅ Complete | bootstrap_stage parameter added |
| defs/scripts/BUCK | ✅ Complete | All scripts exported |
| bootstrap/BUCK | ⏳ TODO | Need to add bootstrap_stage to packages |
| Stage 2 packages | ⏳ TODO | Add perl, python3, pkg-config, etc. |
| Stage 3 targets | ⏳ TODO | Add verification rebuild |
| Verification script | ⏳ TODO | Create isolation checker |
| Testing | ⏳ TODO | Full 3-stage build test |

---

**Next Action:** Update `toolchains/bootstrap/BUCK` to use `bootstrap_stage` parameter for existing packages.
