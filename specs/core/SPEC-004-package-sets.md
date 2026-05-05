---
id: "SPEC-004"
title: "Package Sets and System Profiles"
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
  - "package-sets"
  - "profiles"
  - "system-sets"
  - "collections"

related:
  - "SPEC-001"
  - "SPEC-002"

implementation:
  status: "complete"
  completeness: 80

compatibility:
  buck2_version: ">=2024.11.01"
  buckos_version: ">=1.0.0"
  breaking_changes: false

changelog:
  - version: "1.0.0"
    date: "2025-12-27"
    changes: "Migrated to formal specification system with lifecycle management"
---

# Package Sets and System Profiles

**Status**: approved | **Version**: 1.0.0 | **Last Updated**: 2025-11-20

## Abstract

This specification defines the package set system for BuckOS, which organizes packages into logical collections for different use cases. Package sets enable building complete systems (minimal, server, desktop) and task-specific collections, with support for set operations, inheritance, and customization.

Package sets provide a way to define and manage collections of packages for different use cases, similar to Gentoo's system profiles and sets. This document explains how to use and create package sets in BuckOs.

## Overview

Package sets solve the problem of selecting the right packages for a given use case. Instead of manually specifying dozens of individual packages, you can use a predefined set that includes everything needed for:

- **System profiles**: minimal, server, desktop, developer, hardened, embedded, container
- **Task-specific sets**: web-server, database-server, container-host, vpn-server
- **Desktop environments**: gnome-desktop, kde-desktop, sway-desktop, i3-desktop

Sets can inherit from other sets, be customized with additions/removals, and be combined using set operations.

## Quick Start

### Using a Predefined System Profile

```python
load("//defs:package_sets.bzl", "system_set")

# Create a server system with customizations
system_set(
    name = "my-server",
    profile = "server",
    additions = [
        "//packages/linux/net-vpn:wireguard-tools",
        "//packages/linux/www-servers:nginx",
    ],
    removals = [
        "//packages/linux/editors:emacs",
    ],
)
```

Build with:
```bash
buck2 build //:my-server
```

### Using a Task-Specific Set

```python
load("//defs:package_sets.bzl", "task_set")

# Web server with additional packages
task_set(
    name = "my-webserver",
    task = "web-server",
    additions = ["//packages/linux/dev-db:postgresql"],
)
```

### Combining Multiple Sets

```python
load("//defs:package_sets.bzl", "combined_set")

# Combine web, database, and monitoring
combined_set(
    name = "full-stack",
    sets = ["@web-server", "@database-server", "@monitoring"],
)
```

## Available Profiles

### System Profiles

| Profile | Description | Use Case |
|---------|-------------|----------|
| `minimal` | Bare essentials for bootable system | Embedded, rescue, base for custom builds |
| `server` | Headless server configuration | Production servers, VPS |
| `desktop` | Full desktop with multimedia | Workstations, laptops |
| `developer` | Development tools and languages | Software development |
| `hardened` | Security-focused configuration | Security-critical systems |
| `embedded` | Minimal footprint | IoT, embedded devices |
| `container` | Container base image | Docker/Podman base images |

### Task-Specific Sets

| Set | Description | Inherits From |
|-----|-------------|---------------|
| `web-server` | Web server packages | server |
| `database-server` | Database server packages | server |
| `container-host` | Container runtime and tools | server |
| `virtualization-host` | VM hypervisor setup | server |
| `vpn-server` | VPN server packages | server |
| `monitoring` | System monitoring tools | server |
| `benchmarking` | Performance testing tools | server |

### Desktop Environment Sets

| Set | Description | Display Server |
|-----|-------------|----------------|
| `gnome-desktop` | GNOME 3/4x | Wayland/X11 |
| `kde-desktop` | KDE Plasma | Wayland/X11 |
| `xfce-desktop` | XFCE | X11 |
| `sway-desktop` | Sway tiling | Wayland |
| `hyprland-desktop` | Hyprland | Wayland |
| `i3-desktop` | i3 tiling | X11 |

## Macro Reference

### `system_set`

Create a complete system based on a profile with customizations.

```python
system_set(
    name = "string",           # Required: Target name
    profile = "string",        # Required: Profile name
    additions = [],            # Optional: Extra packages to add
    removals = [],             # Optional: Packages to remove
    description = "",          # Optional: Human-readable description
    visibility = ["PUBLIC"],   # Optional: Buck visibility
)
```

**Example:**
```python
system_set(
    name = "secure-server",
    profile = "hardened",
    additions = [
        "//packages/linux/net-vpn:wireguard-tools",
        "system//apps:fail2ban",
    ],
    description = "Hardened server with VPN and fail2ban",
)
```

### `package_set`

Create a custom package set with explicit packages.

```python
package_set(
    name = "string",           # Required: Target name
    packages = [],             # Required: List of package targets
    inherits = [],             # Optional: Sets to inherit from
    description = "",          # Optional: Description
    visibility = ["PUBLIC"],   # Optional: Visibility
)
```

**Example:**
```python
package_set(
    name = "my-tools",
    packages = [
        "//packages/linux/editors:neovim",
        "system//apps:tmux",
        "//packages/linux/shells:zsh",
    ],
    inherits = ["@minimal"],
    description = "My essential command-line tools",
)
```

### `combined_set`

Combine multiple sets into one.

```python
combined_set(
    name = "string",           # Required: Target name
    sets = [],                 # Required: List of set names (use @name)
    additions = [],            # Optional: Extra packages
    removals = [],             # Optional: Packages to remove
    description = "",          # Optional: Description
    visibility = ["PUBLIC"],   # Optional: Visibility
)
```

**Example:**
```python
combined_set(
    name = "devops-workstation",
    sets = [
        "@developer",
        "@container-host",
        "@monitoring",
    ],
    additions = [
        "//packages/linux/net-vpn:wireguard-tools",
    ],
    description = "DevOps workstation with containers and monitoring",
)
```

### `task_set`

Create a set based on a predefined task.

```python
task_set(
    name = "string",           # Required: Target name
    task = "string",           # Required: Task name
    additions = [],            # Optional: Extra packages
    removals = [],             # Optional: Packages to remove
    description = "",          # Optional: Description
    visibility = ["PUBLIC"],   # Optional: Visibility
)
```

### `desktop_set`

Create a desktop environment set with customizations.

```python
desktop_set(
    name = "string",           # Required: Target name
    environment = "string",    # Required: Desktop environment name
    additions = [],            # Optional: Extra packages
    removals = [],             # Optional: Packages to remove
    description = "",          # Optional: Description
    visibility = ["PUBLIC"],   # Optional: Visibility
)
```

**Example:**
```python
desktop_set(
    name = "developer-gnome",
    environment = "gnome-desktop",
    additions = [
        "//packages/linux/editors:vscode",
        "//packages/linux/dev-tools:git-gui",
    ],
    description = "GNOME desktop for developers",
)
```

## Set Operations

The package_sets module provides set arithmetic operations for programmatic use.

### Union

Combine packages from multiple sets:

```python
load("//defs:package_sets.bzl", "union_sets")

# Get all packages from server and desktop
all_packages = union_sets("server", "desktop")
```

### Intersection

Find packages common to multiple sets:

```python
load("//defs:package_sets.bzl", "intersection_sets")

# Find packages in both server and desktop
common = intersection_sets("server", "desktop")
```

### Difference

Get packages in one set but not in others:

```python
load("//defs:package_sets.bzl", "difference_sets")

# Get desktop-only packages (not in server)
desktop_only = difference_sets("desktop", "server")
```

## Query Functions

### Get Set Packages

```python
load("//defs:package_sets.bzl", "get_set_packages")

# Get all packages in the server profile
packages = get_set_packages("server")
```

### Get Set Information

```python
load("//defs:package_sets.bzl", "get_set_info")

info = get_set_info("server")
# Returns: {
#   "description": "Server-optimized package set without GUI",
#   "packages": [...],
#   "inherits": [],
#   "use_profile": "server",
# }
```

### List Available Sets

```python
load("//defs:package_sets.bzl", "list_all_sets", "list_sets_by_type")

# All sets
all_sets = list_all_sets()

# Only profile sets
profiles = list_sets_by_type("profile")

# Only task sets
tasks = list_sets_by_type("task")

# Only desktop sets
desktops = list_sets_by_type("desktop")
```

### Compare Sets

```python
load("//defs:package_sets.bzl", "compare_sets")

comparison = compare_sets("server", "desktop")
# Returns: {
#   "only_in_first": [...],   # Packages only in server
#   "only_in_second": [...],  # Packages only in desktop
#   "common": [...],          # Packages in both
# }
```

## Integration with USE Flags

Package sets integrate with the USE flag system. Each profile has recommended USE flags:

```python
load("//defs:package_sets.bzl", "get_recommended_use_flags")

flags = get_recommended_use_flags("server")
# Returns: {
#   "enabled": ["ipv6", "ssl", "http2", ...],
#   "disabled": ["X", "wayland", "gtk", ...],
# }
```

When using a profile, apply the recommended USE flags for optimal results:

```python
load("//defs:package_sets.bzl", "system_set", "get_profile_use_flags")
load("//defs:use_flags.bzl", "set_profile")

# Get the USE profile for server
use_profile = get_profile_use_flags("server")  # Returns "server"

# Apply it
set_profile("server")

# Create the system set
system_set(
    name = "my-server",
    profile = "server",
)
```

## Hierarchical Inheritance

Sets can inherit from other sets, creating a hierarchy:

```
minimal
    |
    +-- base (adds core libraries, shell, compression, networking)
          |
          +-- server (adds SSH, editors, admin tools, init system)
          |     |
          |     +-- web-server (adds nginx)
          |     +-- database-server (adds postgresql, sqlite)
          |     +-- container-host (adds podman, buildah, skopeo)
          |
          +-- desktop (adds GUI libraries, terminals, shells)
                |
                +-- gnome-desktop (adds GNOME)
                +-- kde-desktop (adds KDE Plasma)
                +-- sway-desktop (adds Sway)
```

When you use a set, all inherited packages are automatically included.

## Best Practices

### 1. Start with a Profile

Always start with the closest matching profile, then customize:

```python
# Good: Start with server, add what you need
system_set(
    name = "my-system",
    profile = "server",
    additions = ["//packages/linux/net-vpn:wireguard-tools"],
)

# Avoid: Building everything from scratch
package_set(
    name = "my-system",
    packages = [...50+ packages...],  # Error-prone, hard to maintain
)
```

### 2. Use Task Sets for Specific Use Cases

If your system has a well-defined purpose, use a task set:

```python
# Good: Use the predefined task set
task_set(
    name = "my-webserver",
    task = "web-server",
)

# Then customize if needed
task_set(
    name = "my-webserver",
    task = "web-server",
    additions = ["//packages/linux/dev-db:redis"],
)
```

### 3. Combine Sets for Complex Systems

For systems that serve multiple purposes:

```python
combined_set(
    name = "production-server",
    sets = [
        "@web-server",
        "@database-server",
        "@monitoring",
        "@vpn-server",
    ],
)
```

### 4. Keep Removals Minimal

Only remove packages when necessary. The base sets are designed to work together:

```python
# Good: Remove specific unwanted package
system_set(
    name = "my-server",
    profile = "server",
    removals = ["//packages/linux/editors:emacs"],  # Only if you really don't want it
)

# Avoid: Aggressive removals that might break dependencies
system_set(
    name = "my-server",
    profile = "server",
    removals = [
        "//packages/linux/core:readline",  # Might break bash!
    ],
)
```

### 5. Document Your Custom Sets

Always add descriptions to help future maintainers:

```python
system_set(
    name = "production-web",
    profile = "hardened",
    additions = [...],
    description = "Production web server for api.example.com - hardened with nginx and WAF",
)
```

## Examples

### Minimal Container Base Image

```python
system_set(
    name = "container-base",
    profile = "container",
    additions = [
        "//packages/linux/dev-libs/misc/ca-certificates:ca-certificates",
    ],
    description = "Minimal container base image with CA certificates",
)
```

### Development Workstation

```python
combined_set(
    name = "dev-workstation",
    sets = [
        "@developer",
        "@gnome-desktop",
    ],
    additions = [
        "//packages/linux/editors:vscode",
        "//packages/linux/dev-tools:git-gui",
        "//packages/linux/net-vpn:wireguard-tools",
    ],
    description = "Full development workstation with GNOME",
)
```

### High-Security Server

```python
system_set(
    name = "secure-server",
    profile = "hardened",
    additions = [
        "system//apps:aide",
        "system//apps:fail2ban",
        "//packages/linux/net-vpn:wireguard-tools",
    ],
    removals = [
        "//packages/linux/editors:vim",  # Use minimal vi only
    ],
    description = "High-security server with IDS and fail2ban",
)
```

### Embedded IoT Gateway

```python
system_set(
    name = "iot-gateway",
    profile = "embedded",
    additions = [
        "//packages/linux/net-vpn:wireguard-tools",
        "//packages/linux/network:mosquitto",  # MQTT broker
    ],
    description = "IoT gateway with MQTT and WireGuard",
)
```

### CI/CD Runner

```python
combined_set(
    name = "ci-runner",
    sets = [
        "@container-host",
        "@developer",
    ],
    additions = [
        "//packages/linux/dev-tools:git-lfs",
    ],
    removals = [
        "//packages/linux/editors:emacs",
        "system//docs:texinfo",
    ],
    description = "CI/CD runner with container support",
)
```

## Comparison with Gentoo

| Gentoo Concept | BuckOs Equivalent |
|----------------|-------------------|
| `/etc/portage/make.profile` | `system_set(profile = "...")` |
| `@system` | `SYSTEM_PACKAGES` constant |
| `@world` | Custom `package_set()` |
| `@selected` | `additions` parameter |
| Profile parent | `inherits` parameter |
| `/etc/portage/package.use` | USE flag integration via `get_recommended_use_flags()` |
| `eselect profile` | Choosing different `profile` parameter |

## Troubleshooting

### "Unknown profile" Error

```
Error: Unknown profile: myprofile. Available: minimal, server, desktop, developer, hardened, embedded, container
```

**Solution**: Use one of the available profile names.

### "Circular inheritance detected" Error

```
Error: Circular inheritance detected in package set: @set-a
```

**Solution**: Check your set definitions for circular references where set A inherits from set B which inherits from set A.

### Package Not Found in Set

If a package you expect isn't in a set:

```python
load("//defs:package_sets.bzl", "get_set_packages")

# Debug: List all packages in the set
packages = get_set_packages("server")
for pkg in packages:
    print(pkg)
```

### Missing Dependencies

If your built system is missing expected packages:

1. Check you're using the right profile
2. Verify the package is in the set with `get_set_packages()`
3. Check if it was removed via `removals`
4. Ensure the package path is correct

## API Summary

### Macros (Create Targets)

- `system_set()` - System based on profile
- `package_set()` - Custom package collection
- `combined_set()` - Union of multiple sets
- `task_set()` - Task-based set
- `desktop_set()` - Desktop environment set

### Functions (Query/Compute)

- `get_set_packages(name)` - Get all packages in set
- `get_set_info(name)` - Get set metadata
- `list_all_sets()` - List all set names
- `list_sets_by_type(type)` - List sets by category
- `union_sets(*names)` - Union of sets
- `intersection_sets(*names)` - Intersection of sets
- `difference_sets(base, *remove)` - Difference of sets
- `compare_sets(set1, set2)` - Compare two sets
- `get_recommended_use_flags(name)` - Get USE flags for set
- `get_profile_use_flags(name)` - Get USE profile name
- `set_stats()` - Registry statistics

### Constants

- `SYSTEM_PACKAGES` - Absolute minimum for bootable system
- `BASE_PACKAGES` - Standard base installation
- `PROFILE_PACKAGE_SETS` - Profile definitions
- `TASK_PACKAGE_SETS` - Task definitions
- `DESKTOP_ENVIRONMENT_SETS` - Desktop definitions
- `PACKAGE_SETS` - Combined registry
