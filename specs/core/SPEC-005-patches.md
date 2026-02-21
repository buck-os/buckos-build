---
id: "SPEC-005"
title: "Patch System"
status: "approved"
version: "1.0.0"
created: "2025-11-20"
updated: "2025-11-20"

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

implementation:
  status: "complete"
  completeness: 75

compatibility:
  buck2_version: ">=2024.11.01"
  buckos_version: ">=1.0.0"
  breaking_changes: false

changelog:
  - version: "1.0.0"
    date: "2025-12-27"
    changes: "Migrated to formal specification system with lifecycle management"
---

# Patch System

**Status**: approved | **Version**: 1.0.0 | **Last Updated**: 2025-11-20

## Abstract

This specification defines the patch system for BuckOS, which allows users and distributions to customize package builds through multiple patch sources with clear precedence ordering. The system supports package patches, distribution patches, profile patches, USE flag conditional patches, and user patches.

BuckOs provides a comprehensive patch system that allows users and distributions to customize package builds. This document describes the design and usage of the patch system.

## Overview

The patch system supports multiple patch sources with a clear precedence order, enabling:
- Distribution-specific customizations
- Security fixes and backports
- Bug fixes for specific configurations
- User-specific modifications
- Conditional patches based on USE flags, platform, or version

## Patch Sources and Precedence

Patches are applied in the following order (later patches can override earlier ones):

1. **Package Patches** - Bundled with the package definition
2. **Distribution Patches** - Applied by the distribution/overlay
3. **Profile Patches** - Applied based on build profile (server, desktop, hardened)
4. **USE Flag Patches** - Applied conditionally based on USE flags
5. **User Patches** - Applied from user configuration

## Directory Structure

```
buckos-build/
├── patches/
│   ├── global/                    # Global patches applied to all builds
│   │   └── security/              # Security patches
│   ├── profiles/
│   │   ├── hardened/              # Hardened profile patches
│   │   ├── musl/                  # musl libc compatibility patches
│   │   └── cross/                 # Cross-compilation patches
│   └── packages/
│       └── <category>/
│           └── <package>/
│               ├── files/         # Static files (configs, scripts)
│               ├── *.patch        # Package-specific patches
│               └── series         # Patch application order
├── packages/
│   └── <category>/
│       └── <package>/
│           ├── BUCK               # Package definition
│           └── patches/           # Inline patches for the package
│               └── *.patch
└── user/
    └── patches/                   # User-specific patches
        └── <category>/
            └── <package>/
                └── *.patch
```

## Patch Definition in Buck Targets

### Basic Patch Application

Patches can be applied directly in package definitions:

```python
load("//defs:package.bzl", "package")

package(
    build_rule = "autotools",
    name = "mypackage",
    source = ":mypackage-src",
    version = "1.0",
    # Apply patches in pre_configure phase
    pre_configure = """
        patch -p1 < "$FILESDIR/fix-build.patch"
        patch -p1 < "$FILESDIR/security-fix.patch"
    """,
    deps = [...],
)
```

### Using the Patch Helpers

The `package.bzl` provides ebuild-style patch helpers:

```python
load("//defs:package.bzl", "epatch", "eapply", "eapply_user")

package(
    build_rule = "autotools",
    name = "mypackage",
    source = ":mypackage-src",
    version = "1.0",
    pre_configure = "\n".join([
        # Apply specific patches
        epatch(["fix-build.patch", "optimize.patch"]),

        # Apply directory of patches
        eapply(["${FILESDIR}/patches"]),

        # Apply user patches from /etc/portage/patches
        eapply_user(),
    ]),
)
```

### Conditional Patches with USE Flags

Apply patches based on USE flag settings:

```python
load("//defs:use_flags.bzl", "use_package")

use_package(
    name = "openssl",
    version = "3.2.0",
    url = "...",
    sha256 = "...",
    iuse = ["bindist", "ktls", "static-libs"],
    use_defaults = [],

    # Conditional patches based on USE flags
    use_patches = {
        "bindist": ["//patches/packages/dev-libs/openssl:ec-curves-bindist.patch"],
        "ktls": ["//patches/packages/dev-libs/openssl:ktls-support.patch"],
    },

    use_configure = {
        "bindist": "no-ec",
        "ktls": "enable-ktls",
    },
)
```

### Package Customization Patches

Use the customization system for distribution-wide patches:

```python
load("//defs:package_customize.bzl", "package_config")

CUSTOMIZATIONS = package_config(
    profile = "hardened",

    # Per-package patches
    package_patches = {
        "glibc": [
            "//patches/packages/sys-libs/glibc:hardened-all.patch",
            "//patches/packages/sys-libs/glibc:stack-protector.patch",
        ],
        "gcc": [
            "//patches/packages/sys-devel/gcc:hardened-specs.patch",
        ],
        "openssh": [
            "//patches/packages/net-misc/openssh:hpn-performance.patch",
        ],
    },
)
```

## Patch Rule Definition

For complex patch management, define patches as Buck targets:

```python
# patches/packages/dev-libs/openssl/BUCK

# Define a patch set
filegroup(
    name = "security-patches",
    srcs = glob(["security/*.patch"]),
    visibility = ["PUBLIC"],
)

filegroup(
    name = "bindist-patches",
    srcs = [
        "ec-curves-bindist.patch",
        "no-gost.patch",
    ],
    visibility = ["PUBLIC"],
)

# Conditional patch target
genrule(
    name = "platform-patches",
    srcs = select({
        "//platforms:linux": glob(["linux/*.patch"]),
        "//platforms:bsd": glob(["bsd/*.patch"]),
    }),
    out = "patches",
    cmd = "mkdir -p $OUT && cp $SRCS $OUT/",
)
```

## Patch Application Order

### Series File

Control patch order with a `series` file:

```
# patches/packages/dev-libs/openssl/series
# Patches are applied in this order

# Core fixes
fix-build.patch
fix-tests.patch

# Feature patches
ktls-support.patch

# Platform-specific
linux-specific.patch -p2

# Security (apply last)
cve-2024-xxxx.patch
```

### Programmatic Ordering

Define patch order in Buck:

```python
load("//defs:package.bzl", "package")

PATCH_ORDER = [
    # Core patches first
    ("build-fixes", [
        "fix-makefile.patch",
        "fix-configure.patch",
    ]),
    # Feature patches
    ("features", [
        "add-feature-x.patch",
    ]),
    # Security patches last
    ("security", [
        "cve-fix.patch",
    ]),
]

def ordered_patches():
    """Generate patch application commands in order."""
    cmds = []
    for category, patches in PATCH_ORDER:
        cmds.append('echo "Applying {} patches..."'.format(category))
        for patch in patches:
            cmds.append('patch -p1 < "$FILESDIR/{}"'.format(patch))
    return "\n".join(cmds)

package(
    build_rule = "ebuild",
    name = "mypackage",
    version = "1.0",
    source = ":mypackage-src",
    src_prepare = ordered_patches(),
    # ...
)
```

## Patch Types

### Standard Patches (unified diff)

The most common format, created with `diff -u`:

```diff
--- a/src/main.c
+++ b/src/main.c
@@ -100,6 +100,7 @@
 int main(int argc, char *argv[]) {
+    init_security();
     init_app();
     // ...
 }
```

### Git Format Patches

Patches created with `git format-patch`:

```diff
From: Developer <dev@example.com>
Date: Mon, 1 Jan 2024 00:00:00 +0000
Subject: [PATCH] Fix security issue CVE-2024-XXXX

Description of the fix.

Signed-off-by: Developer <dev@example.com>
---
 src/main.c | 1 +
 1 file changed, 1 insertion(+)

diff --git a/src/main.c b/src/main.c
...
```

### Conditional Patches

Patches that check conditions before applying:

```python
def conditional_patch(condition, patch_file):
    """Apply patch only if condition is met."""
    return '''
if {condition}; then
    patch -p1 < "$FILESDIR/{patch}"
fi
'''.format(condition=condition, patch=patch_file)

# Usage
pre_configure = conditional_patch(
    '[ "$CHOST" = "x86_64-pc-linux-musl" ]',
    "musl-compat.patch"
)
```

## Profile-Based Patches

Apply patches based on build profiles:

```python
load("//defs:package_customize.bzl", "package_config")

# Hardened profile configuration
HARDENED_CONFIG = package_config(
    profile = "hardened",

    package_patches = {
        # Apply to all glibc builds with hardened profile
        "glibc": [
            "//patches/profiles/hardened/glibc:ssp-all.patch",
            "//patches/profiles/hardened/glibc:fortify-default.patch",
        ],

        # Kernel hardening patches
        "linux": [
            "//patches/profiles/hardened/kernel:grsecurity-lite.patch",
            "//patches/profiles/hardened/kernel:selinux-default.patch",
        ],
    },
)
```

### Profile Patch Directory Structure

```
patches/profiles/
├── hardened/
│   ├── glibc/
│   │   ├── ssp-all.patch
│   │   └── fortify-default.patch
│   ├── kernel/
│   │   └── grsecurity-lite.patch
│   └── gcc/
│       └── stack-clash.patch
├── musl/
│   ├── libc-compat/
│   │   └── glibc-compat.patch
│   └── apps/
│       └── fix-glibc-assumptions.patch
└── minimal/
    └── packages/
        └── reduce-features.patch
```

## User Patches

### Automatic User Patches

Patches in `/etc/portage/patches/<category>/<package>/` are applied automatically when using `eapply_user()`:

```bash
# Create user patch directory
mkdir -p /etc/portage/patches/sys-libs/glibc

# Add custom patch
cp my-custom-fix.patch /etc/portage/patches/sys-libs/glibc/
```

### User Patch Configuration

Configure user patches in the customization system:

```python
load("//defs:package_customize.bzl", "package_config")

USER_CONFIG = package_config(
    # User-specific patches
    package_patches = {
        "firefox": ["~/patches/firefox-custom-branding.patch"],
        "vim": ["~/patches/vim-custom-defaults.patch"],
    },
)
```

## Platform-Specific Patches

Apply patches based on target platform:

```python
load("//defs:platform_defs.bzl", "PLATFORM_LINUX", "PLATFORM_BSD", "platform_select")

package(
    build_rule = "autotools",
    name = "mypackage",
    source = ":mypackage-src",
    version = "1.0",

    # Platform-specific patches
    pre_configure = select(platform_select({
        PLATFORM_LINUX: """
            patch -p1 < "$FILESDIR/linux-specific.patch"
        """,
        PLATFORM_BSD: """
            patch -p1 < "$FILESDIR/bsd-compat.patch"
        """,
    }, default = "")),
)
```

## Version-Specific Patches

Apply patches based on package version:

```python
def version_patches(version, patches_map):
    """Select patches based on version."""
    for version_range, patches in patches_map.items():
        min_ver, max_ver = version_range
        if version >= min_ver and version < max_ver:
            return patches
    return []

# Usage
patches = version_patches("3.2.0", {
    ("3.0", "3.1"): ["fix-3.0.patch"],
    ("3.1", "3.2"): ["fix-3.1.patch"],
    ("3.2", "4.0"): ["fix-3.2.patch"],
})
```

## Creating Patches

### From Git Changes

```bash
# Create patch from commits
git format-patch -1 HEAD -o patches/

# Create patch from uncommitted changes
git diff > my-fix.patch

# Create patch from staged changes
git diff --cached > my-fix.patch
```

### From Directory Comparison

```bash
# Compare original and modified directories
diff -ruN original/ modified/ > my-fix.patch
```

### Patch Best Practices

1. **Use unified diff format** (`-u` flag)
2. **Include context** (at least 3 lines with `-U3`)
3. **Strip path prefixes appropriately** (`-p1` for standard patches)
4. **Name patches descriptively** (e.g., `fix-cve-2024-1234.patch`)
5. **Include description comments** at the top of the patch
6. **Test patches** on clean sources before committing

## Patch Validation

### Check Patch Validity

```python
load("//defs:package.bzl", "ebegin", "eend")

def validate_patches(patches):
    """Validate that patches apply cleanly."""
    cmds = []
    for patch in patches:
        cmds.append('''
{begin}
if ! patch -p1 --dry-run < "$FILESDIR/{patch}" >/dev/null 2>&1; then
    echo "Patch {patch} does not apply cleanly"
    exit 1
fi
{end}
'''.format(
            begin=ebegin("Validating {}".format(patch)),
            end=eend(),
            patch=patch
        ))
    return "\n".join(cmds)
```

### Fuzzy Patch Application

For patches that may have minor offset issues:

```python
def fuzzy_patch(patch_file, fuzz_level=2):
    """Apply patch with fuzzy matching."""
    return 'patch -p1 -F{} < "$FILESDIR/{}"'.format(fuzz_level, patch_file)
```

## Integration with Multi-Version Support

Apply different patches based on package version slots:

```python
load("//defs:versions.bzl", "multi_version_package")

multi_version_package(
    name = "openssl",
    versions = {
        "3.2.0": {
            "slot": "3",
            "url": "...",
            "sha256": "...",
            # Version-specific patches
            "patches": [
                "//patches/packages/dev-libs/openssl:3.2-ktls.patch",
            ],
        },
        "1.1.1w": {
            "slot": "1.1",
            "url": "...",
            "sha256": "...",
            # Different patches for older version
            "patches": [
                "//patches/packages/dev-libs/openssl:1.1-backport-fix.patch",
            ],
        },
    },
)
```

## Querying Patches

### Find All Patches for a Package

```bash
# Find patches in patch directories
buck2 query 'deps(//packages/linux/dev-libs:openssl)' | grep patches

# List patch files
find patches/packages/dev-libs/openssl -name "*.patch"
```

### Check Which Patches Are Applied

Add patch logging to track applied patches:

```python
def logged_patch(patch_file):
    """Apply patch with logging."""
    return '''
echo "PATCH: Applying {patch}"
patch -p1 < "$FILESDIR/{patch}"
echo "{patch}" >> "${{T}}/applied-patches.log"
'''.format(patch=patch_file)
```

## Troubleshooting

### Patch Doesn't Apply

1. **Check strip level**: Try `-p0`, `-p1`, or `-p2`
2. **Verify paths**: Ensure paths in patch match source tree
3. **Check version**: Patch may be for different version
4. **Use dry-run**: `patch -p1 --dry-run < patch.patch`

### Conflicting Patches

```bash
# Reverse a patch to try a different approach
patch -R -p1 < problematic.patch

# Apply with reject files for manual fixing
patch -p1 --reject-file=rejected.rej < patch.patch
```

### Patch Order Issues

1. Check `series` file for correct ordering
2. Ensure dependent patches are applied first
3. Consider splitting large patches into smaller ones

## Examples

### Example: Security Patch for OpenSSL

```python
# patches/packages/dev-libs/openssl/BUCK
filegroup(
    name = "cve-2024-0727",
    srcs = ["cve-2024-0727-pkcs12-fix.patch"],
    visibility = ["PUBLIC"],
)

# In packages/linux/dev-libs/openssl/BUCK
package(
    build_rule = "autotools",
    name = "openssl",
    source = ":openssl-src",
    version = "3.2.0",
    pre_configure = """
        # Apply security patches
        patch -p1 < "$(location //patches/packages/dev-libs/openssl:cve-2024-0727)"
    """,
    # ...
)
```

### Example: Musl Compatibility Patches

```python
load("//defs:package_customize.bzl", "package_config")

MUSL_CONFIG = package_config(
    profile = "minimal",

    package_patches = {
        # Common packages needing musl compatibility
        "util-linux": [
            "//patches/profiles/musl:util-linux-musl.patch",
        ],
        "iproute2": [
            "//patches/profiles/musl:iproute2-musl.patch",
        ],
        "procps": [
            "//patches/profiles/musl:procps-musl.patch",
        ],
    },
)
```

### Example: Custom Distribution Patches

```python
# myoverlay/packages/www-servers/nginx/BUCK
load("//defs:package.bzl", "package", "download_source", "epatch")

download_source(
    name = "nginx-src",
    url = "https://nginx.org/download/nginx-1.25.3.tar.gz",
    sha256 = "...",
)

package(
    build_rule = "autotools",
    name = "nginx",
    source = ":nginx-src",
    version = "1.25.3",

    pre_configure = "\n".join([
        # Distribution-specific branding
        epatch(["branding.patch"]),

        # Performance optimizations
        epatch(["tcp-fastopen.patch"]),

        # Custom modules
        epatch(["add-custom-module.patch"]),
    ]),

    configure_args = [
        "--with-http_ssl_module",
        "--with-http_v2_module",
    ],
)
```

## See Also

- [USE_FLAGS.md](USE_FLAGS.md) - USE flag system documentation
- [PACKAGE_SETS.md](PACKAGE_SETS.md) - Package set definitions
- [VERSIONING.md](VERSIONING.md) - Multi-version support
