"""
Multi-version package management system for BuckOs Linux.

Inspired by Gentoo's slot system, this provides:
- Multiple concurrent versions of packages
- Slot-based version grouping
- Subslot support for ABI compatibility tracking
- Default stable version selection
- Version constraint resolution
- Scalable version registry

Example usage:
    # Register versions in package BUCK file
    register_package_versions(
        name = "openssl",
        category = "dev-libs",
        versions = {
            "3.2.0": {"slot": "3", "subslot": "3.2", "keywords": ["stable"]},
            "3.1.4": {"slot": "3", "subslot": "3.1", "keywords": ["stable"]},
            "1.1.1w": {"slot": "1.1", "subslot": "1.1", "keywords": ["stable"]},
        },
        default_version = "3.2.0",
    )

    # Reference in dependencies
    deps = [
        version_dep("//packages/linux/dev-libs/openssl", ">=1.1.0"),
        slot_dep("//packages/linux/lang/python", "3"),
        # Subslot-aware dependency (rebuild when subslot changes)
        subslot_dep("//packages/linux/dev-libs/openssl", "3"),
    ]
"""

load("//defs:package.bzl", "package")

# ============================================================================
# VERSION COMPARISON UTILITIES
# ============================================================================

def _parse_version(version_str):
    """Parse version string into comparable components.

    Handles formats like: 1.2.3, 1.2.3a, 1.2.3_rc1, 1.2.3-beta1

    Returns a tuple of (numeric_parts, suffix_type, suffix_num)
    """
    # Remove common suffixes and track them
    suffix_type = 0  # 0=release, -1=rc, -2=beta, -3=alpha
    suffix_num = 0

    version = version_str.lower()

    # Handle suffixes
    for i, (pattern, stype) in enumerate([("_rc", -1), ("-rc", -1), ("rc", -1),
                                           ("_beta", -2), ("-beta", -2), ("beta", -2),
                                           ("_alpha", -3), ("-alpha", -3), ("alpha", -3)]):
        if pattern in version:
            parts = version.split(pattern)
            version = parts[0]
            if len(parts) > 1 and parts[1]:
                # Extract suffix number
                # In Starlark, we can't iterate over strings directly
                num_str = ""
                for i in range(len(parts[1])):
                    c = parts[1][i]
                    if c.isdigit():
                        num_str += c
                    else:
                        break
                suffix_num = int(num_str) if num_str else 0
            suffix_type = stype
            break

    # Parse main version components
    # In Starlark, we can't iterate over strings directly, so use range(len())
    components = []
    current = ""
    for i in range(len(version)):
        c = version[i]
        if c.isdigit():
            current += c
        elif c in "._-":
            if current:
                components.append(int(current))
                current = ""
        elif c.isalpha():
            if current:
                components.append(int(current))
                current = ""
            # Handle letter suffixes (e.g., 1.1.1w)
            components.append(ord(c) - ord('a') + 1)

    if current:
        components.append(int(current))

    return (tuple(components), suffix_type, suffix_num)

def version_compare(v1, v2):
    """Compare two version strings.

    Returns: -1 if v1 < v2, 0 if equal, 1 if v1 > v2
    """
    parsed1 = _parse_version(v1)
    parsed2 = _parse_version(v2)

    # Compare main version components
    for i in range(max(len(parsed1[0]), len(parsed2[0]))):
        c1 = parsed1[0][i] if i < len(parsed1[0]) else 0
        c2 = parsed2[0][i] if i < len(parsed2[0]) else 0
        if c1 < c2:
            return -1
        if c1 > c2:
            return 1

    # Compare suffix type (release > rc > beta > alpha)
    if parsed1[1] < parsed2[1]:
        return -1
    if parsed1[1] > parsed2[1]:
        return 1

    # Compare suffix number
    if parsed1[2] < parsed2[2]:
        return -1
    if parsed1[2] > parsed2[2]:
        return 1

    return 0

def version_satisfies(version, constraint):
    """Check if version satisfies a constraint.

    Constraints can be:
    - "1.2.3" - exact match
    - ">=1.2.3" - greater than or equal
    - ">1.2.3" - greater than
    - "<=1.2.3" - less than or equal
    - "<1.2.3" - less than
    - "~>1.2" - pessimistic (>=1.2.0, <2.0.0)
    - "1.2.*" - wildcard match
    """
    if not constraint:
        return True

    # Exact match
    if constraint[0].isdigit():
        return version_compare(version, constraint) == 0

    # Operators
    if constraint.startswith(">="):
        return version_compare(version, constraint[2:]) >= 0
    if constraint.startswith("<="):
        return version_compare(version, constraint[2:]) <= 0
    if constraint.startswith(">"):
        return version_compare(version, constraint[1:]) > 0
    if constraint.startswith("<"):
        return version_compare(version, constraint[1:]) < 0

    # Pessimistic constraint (~>1.2 means >=1.2.0, <2.0.0)
    if constraint.startswith("~>"):
        base = constraint[2:]
        parts = base.split(".")
        if len(parts) >= 2:
            upper = str(int(parts[0]) + 1) + ".0.0"
            return version_compare(version, base) >= 0 and version_compare(version, upper) < 0

    # Wildcard
    if "*" in constraint:
        prefix = constraint.replace("*", "")
        return version.startswith(prefix.rstrip("."))

    return False

# ============================================================================
# VERSION REGISTRY
# ============================================================================

# Global version registry - maps package path to version info
# This is populated by register_package_versions calls
_VERSION_REGISTRY = {}

def _get_slot_from_version(version):
    """Extract default slot from version number.

    Default behavior: use major.minor for slot
    Examples: 3.2.0 -> "3.2", 1.1.1w -> "1.1"
    """
    parts = version.split(".")
    if len(parts) >= 2:
        return parts[0] + "." + parts[1]
    return parts[0] if parts else "0"

def _get_subslot_from_version(version):
    """Extract default subslot from version number.

    Default behavior: use major.minor.patch for subslot
    This tracks ABI compatibility - when subslot changes, dependents rebuild.
    Examples: 3.2.0 -> "3.2.0", 1.1.1w -> "1.1.1"
    """
    parts = version.split(".")
    if len(parts) >= 3:
        # Remove any suffix letters from patch version
        # In Starlark, we can't iterate over strings, so use a different approach
        patch_part = parts[2]
        patch = ""
        for i in range(len(patch_part)):
            c = patch_part[i]
            if c.isdigit():
                patch += c
            else:
                break
        return parts[0] + "." + parts[1] + "." + (patch if patch else "0")
    elif len(parts) >= 2:
        return parts[0] + "." + parts[1] + ".0"
    return parts[0] + ".0.0" if parts else "0.0.0"

def parse_slot_subslot(slot_str):
    """Parse a SLOT/SUBSLOT string into components.

    Gentoo format: "SLOT/SUBSLOT" (e.g., "3/3.2")
    If no subslot specified, subslot equals slot.

    Args:
        slot_str: Slot string like "3" or "3/3.2"

    Returns:
        Tuple of (slot, subslot)
    """
    if "/" in slot_str:
        parts = slot_str.split("/", 1)
        return (parts[0], parts[1])
    return (slot_str, slot_str)

def format_slot_subslot(slot, subslot = None):
    """Format slot and subslot into a string.

    Args:
        slot: Slot identifier
        subslot: Subslot identifier (defaults to slot)

    Returns:
        String in format "SLOT/SUBSLOT" or just "SLOT" if same
    """
    if subslot and subslot != slot:
        return "{}/{}".format(slot, subslot)
    return slot

def subslot_changed(old_subslot, new_subslot):
    """Check if a subslot change requires rebuild of dependents.

    Args:
        old_subslot: Previous subslot value
        new_subslot: New subslot value

    Returns:
        True if dependents should be rebuilt
    """
    return old_subslot != new_subslot

def register_package_versions(
    name,
    category,
    versions,
    default_version = None,
    default_slot = None,
    iuse = [],
    use_configure = {},
    use_deps = {}):
    """Register available versions for a package.

    Args:
        name: Package name
        category: Package category path (e.g., "dev-libs/openssl")
        versions: Dict mapping version string to metadata:
            {
                "3.2.0": {
                    "slot": "3",           # Version slot for co-installation
                    "keywords": ["stable"], # stable, testing, unstable
                    "eapi": "8",           # Optional: ebuild API version
                    "src_uri": "...",      # Optional: override source URI
                    "sha256": "...",       # Optional: override checksum
                },
            }
        default_version: Version to use when no constraint specified
        default_slot: Slot to use as default
        iuse: List of USE flags this package supports
        use_configure: Dict mapping USE flag to configure arguments
        use_deps: Dict mapping USE flag to conditional dependencies

    Returns:
        Dict with version resolution helpers
    """
    package_path = "//packages/linux/{}/{}".format(category, name)

    # Process versions and extract metadata
    version_list = []
    slots = {}

    for ver, meta in versions.items():
        slot = meta.get("slot", _get_slot_from_version(ver))
        subslot = meta.get("subslot", _get_subslot_from_version(ver))
        keywords = meta.get("keywords", ["testing"])

        version_info = {
            "version": ver,
            "slot": slot,
            "subslot": subslot,
            "slot_subslot": format_slot_subslot(slot, subslot),
            "keywords": keywords,
            "src_uri": meta.get("src_uri", ""),
            "sha256": meta.get("sha256", ""),
            "deps": meta.get("deps", []),
            "soname": meta.get("soname", ""),  # Library soname for ABI tracking
        }

        version_list.append(version_info)

        # Track best version per slot
        if slot not in slots:
            slots[slot] = []
        slots[slot].append(ver)

    # Sort versions in each slot (newest first)
    # Create new dict to avoid mutating while iterating
    sorted_slots = {}
    for slot in slots.keys():
        sorted_slots[slot] = sorted(slots[slot], key=lambda v: _parse_version(v), reverse=True)
    slots = sorted_slots

    # Determine default version
    if not default_version:
        # Pick newest stable version
        for vi in sorted(version_list, key=lambda x: _parse_version(x["version"]), reverse=True):
            if "stable" in vi["keywords"]:
                default_version = vi["version"]
                break
        if not default_version and version_list:
            default_version = version_list[0]["version"]

    # Determine default slot
    if not default_slot and default_version:
        for vi in version_list:
            if vi["version"] == default_version:
                default_slot = vi["slot"]
                break

    registry_entry = {
        "name": name,
        "category": category,
        "path": package_path,
        "versions": {v["version"]: v for v in version_list},
        "slots": slots,
        "default_version": default_version,
        "default_slot": default_slot,
        "iuse": iuse,
        "use_configure": use_configure,
        "use_deps": use_deps,
    }

    return registry_entry

# ============================================================================
# VERSION-AWARE PACKAGE RULES
# ============================================================================

def versioned_package(
    name,
    version,
    slot = None,
    keywords = None,
    source = None,
    src_uri = None,
    sha256 = None,
    create_slot_alias = True,
    **kwargs):
    """Define a versioned package with slot support.

    This creates multiple targets:
    - {name}-{version}: The specific version
    - {name}:{slot}: Alias to latest in slot
    - {name}: Alias to default version (if this is default)

    Args:
        name: Package name
        version: Package version
        slot: Version slot (defaults to major.minor)
        keywords: List of keywords (stable, testing, unstable)
        source: Pre-defined source target
        src_uri: Source download URI
        sha256: Source checksum
        **kwargs: Additional args passed to configure_make_package
    """
    if not slot:
        slot = _get_slot_from_version(version)

    if not keywords:
        keywords = ["testing"]

    # Version-specific target name
    versioned_name = "{}-{}".format(name, version)

    # Build package kwargs
    pkg_kwargs = {
        "name": versioned_name,
        "build_rule": "autotools",
        "version": version,
        "description": kwargs.get("description", ""),
        "homepage": kwargs.get("homepage", ""),
        "license": kwargs.get("license", ""),
        "visibility": kwargs.get("visibility", ["PUBLIC"]),
    }

    # Source: url+sha256 or pre-built source target
    if src_uri and sha256:
        pkg_kwargs["url"] = src_uri
        pkg_kwargs["sha256"] = sha256
    elif source:
        pkg_kwargs["source"] = source

    # Configure and make args
    if kwargs.get("configure_args"):
        pkg_kwargs["configure_args"] = kwargs["configure_args"]
    if kwargs.get("make_args"):
        pkg_kwargs["make_args"] = kwargs["make_args"]

    # Pre-configure commands
    pre_configure = kwargs.get("pre_configure", "")
    if pre_configure:
        pkg_kwargs["pre_configure_cmds"] = [pre_configure]

    # Post-install commands
    post_install = kwargs.get("post_install", "")
    if post_install:
        pkg_kwargs["post_install_cmds"] = [post_install]

    # Dependencies (merge deps and bdepend)
    deps = list(kwargs.get("deps", []))
    bdeps = kwargs.get("bdepend", kwargs.get("build_deps", []))
    if bdeps:
        deps = deps + list(bdeps)
    if deps:
        pkg_kwargs["deps"] = deps

    package(**pkg_kwargs)

    # Create slot alias (if requested)
    # Note: Buck target names can't contain ':', so we use '-slot-' as separator
    if create_slot_alias:
        native.alias(
            name = "{}-slot-{}".format(name, slot.replace(".", "_")),
            actual = ":" + versioned_name,
            visibility = ["PUBLIC"],
        )

    return versioned_name

def multi_version_package(
    name,
    versions,
    default_version = None,
    common_args = None,
    **kwargs):
    """Define multiple versions of a package.

    This is the main entry point for multi-version packages.

    Args:
        name: Package name
        versions: Dict mapping version to version-specific config:
            {
                "3.2.0": {
                    "slot": "3",
                    "keywords": ["stable"],
                    "src_uri": "https://...",
                    "sha256": "...",
                    "configure_args": [...],  # Optional overrides
                },
            }
        default_version: Version to use as default
        common_args: Args applied to all versions
        **kwargs: Default args for all versions
    """
    if not common_args:
        common_args = {}

    created_targets = []
    slots = {}

    # Determine default version
    if not default_version:
        for ver, meta in versions.items():
            if "stable" in meta.get("keywords", []):
                if not default_version or version_compare(ver, default_version) > 0:
                    default_version = ver
        if not default_version:
            default_version = sorted(versions.keys(), key=lambda v: _parse_version(v), reverse=True)[0]

    # Create each version
    for version, meta in versions.items():
        slot = meta.get("slot", _get_slot_from_version(version))

        # Merge args: kwargs < common_args < version-specific
        merged_args = dict(kwargs)
        merged_args.update(common_args)

        # Version-specific overrides
        for key in ["configure_args", "make_args", "deps", "build_deps", "env",
                    "pre_configure", "post_install"]:
            if key in meta:
                merged_args[key] = meta[key]

        versioned_name = versioned_package(
            name = name,
            version = version,
            slot = slot,
            keywords = meta.get("keywords", ["testing"]),
            src_uri = meta.get("src_uri"),
            sha256 = meta.get("sha256"),
            create_slot_alias = False,  # multi_version_package will create slot aliases
            **merged_args
        )

        created_targets.append(versioned_name)

        # Track slots for alias creation
        if slot not in slots:
            slots[slot] = []
        slots[slot].append((version, versioned_name))

    # Create default alias
    default_target = "{}-{}".format(name, default_version)
    native.alias(
        name = name,
        actual = ":" + default_target,
        visibility = ["PUBLIC"],
    )

    # Create slot aliases pointing to newest version in each slot
    for slot, versions_in_slot in slots.items():
        sorted_versions = sorted(versions_in_slot, key=lambda x: _parse_version(x[0]), reverse=True)
        newest = sorted_versions[0][1]

        # Create slot alias
        native.alias(
            name = "{}-slot-{}".format(name, slot.replace(".", "_")),
            actual = ":" + newest,
            visibility = ["PUBLIC"],
        )

    return created_targets

# ============================================================================
# DEPENDENCY RESOLUTION HELPERS
# ============================================================================

def version_dep(package_path, constraint = None):
    """Create a dependency with version constraint.

    Args:
        package_path: Full package path (e.g., "//packages/linux/core/openssl")
        constraint: Version constraint (e.g., ">=1.1.0", "<3.0")

    Returns:
        Target string for the resolved dependency

    Example:
        deps = [
            version_dep("//packages/linux/dev-libs/openssl", ">=3.0"),
            version_dep("//packages/linux/core/zlib", "~>1.2"),
        ]
    """
    if constraint:
        # For Buck2, we encode the constraint in the target name
        # The actual resolution happens at build time
        # Format: package_path:version_constraint
        safe_constraint = constraint.replace(">", "gt").replace("<", "lt").replace("=", "eq").replace("~", "tilde").replace("*", "star")
        return "{}:{}".format(package_path, safe_constraint)
    return package_path

def slot_dep(package_path, slot):
    """Create a dependency on a specific slot.

    Args:
        package_path: Full package path
        slot: Slot identifier (e.g., "3", "1.1")

    Returns:
        Target string for the slot dependency

    Example:
        deps = [
            slot_dep("//packages/linux/lang/python", "3"),
            slot_dep("//packages/linux/dev-libs/openssl", "1.1"),
        ]
    """
    return "{}:{}".format(package_path, slot)

def subslot_dep(package_path, slot, operator = "="):
    """Create a subslot-aware dependency that triggers rebuild on ABI changes.

    This is similar to Gentoo's := operator for slot dependencies.
    When the package's subslot changes, dependents will be rebuilt.

    Args:
        package_path: Full package path
        slot: Slot identifier
        operator: Dependency operator:
            "=" - rebuild when subslot changes (like := in Gentoo)
            "*" - don't rebuild on subslot changes (like :* in Gentoo)

    Returns:
        Target string for the subslot-aware dependency

    Example:
        deps = [
            # Rebuild when openssl's ABI changes
            subslot_dep("//packages/linux/dev-libs/openssl", "3", "="),

            # Don't rebuild on ABI changes (build-time only)
            subslot_dep("//packages/linux/dev-util/cmake", "3", "*"),
        ]
    """
    if operator == "=":
        # Subslot-aware: rebuild when subslot changes
        return "{}:{}=".format(package_path, slot)
    elif operator == "*":
        # Subslot-unaware: don't rebuild on subslot changes
        return "{}:{}*".format(package_path, slot)
    else:
        return "{}:{}".format(package_path, slot)

def get_subslot_deps(deps):
    """Filter dependencies to only subslot-aware ones.

    Args:
        deps: List of dependency targets

    Returns:
        List of subslot-aware dependency targets
    """
    return [d for d in deps if d.endswith("=")]

def check_abi_compatibility(old_version_info, new_version_info):
    """Check if upgrading between versions maintains ABI compatibility.

    Args:
        old_version_info: Version info dict for old version
        new_version_info: Version info dict for new version

    Returns:
        Dictionary with:
        - compatible: Boolean indicating if ABI is compatible
        - reason: Explanation if not compatible
        - rebuild_required: List of packages that need rebuilding
    """
    result = {
        "compatible": True,
        "reason": "",
        "rebuild_required": [],
    }

    # Check slot change
    if old_version_info["slot"] != new_version_info["slot"]:
        result["compatible"] = False
        result["reason"] = "Slot changed from {} to {}".format(
            old_version_info["slot"], new_version_info["slot"])
        return result

    # Check subslot change
    if old_version_info.get("subslot") != new_version_info.get("subslot"):
        result["compatible"] = False
        result["reason"] = "Subslot changed from {} to {} (ABI change)".format(
            old_version_info.get("subslot", "unknown"),
            new_version_info.get("subslot", "unknown"))
        # Dependents with := dependencies need rebuilding
        result["rebuild_required"].append("packages with := dependencies")
        return result

    # Check soname change (library ABI)
    old_soname = old_version_info.get("soname", "")
    new_soname = new_version_info.get("soname", "")
    if old_soname and new_soname and old_soname != new_soname:
        result["compatible"] = False
        result["reason"] = "Library soname changed from {} to {}".format(
            old_soname, new_soname)
        result["rebuild_required"].append("all dependent packages")
        return result

    return result

def any_of(*packages):
    """Specify alternative dependencies (virtual packages).

    The first available package is selected.

    Example:
        deps = [
            any_of(
                "//packages/linux/core/musl",
                "//packages/linux/core/glibc",
            ),
        ]
    """
    # Return the first one as default
    # Actual resolution would need build-time logic
    return packages[0] if packages else None

# ============================================================================
# VERSION MANIFEST GENERATION
# ============================================================================

def generate_version_manifest(registry_entries):
    """Generate a manifest of all package versions.

    This creates a JSON-like structure for package managers
    and tooling to consume.

    Args:
        registry_entries: List of register_package_versions results

    Returns:
        Manifest structure
    """
    manifest = {
        "schema_version": "1.0",
        "packages": {},
    }

    for entry in registry_entries:
        pkg_id = "{}/{}".format(entry["category"], entry["name"])
        manifest["packages"][pkg_id] = {
            "name": entry["name"],
            "category": entry["category"],
            "default_version": entry["default_version"],
            "default_slot": entry["default_slot"],
            "slots": entry["slots"],
            "versions": entry["versions"],
        }

    return manifest

# ============================================================================
# SLOT CONFLICT DETECTION
# ============================================================================

def check_slot_conflicts(deps):
    """Check for slot conflicts in dependencies.

    Two packages with the same name but different slots can coexist.
    Two packages with the same name and slot cannot.

    Args:
        deps: List of dependency targets

    Returns:
        List of conflict warnings
    """
    seen = {}  # package_path -> set of slots
    conflicts = []

    for dep in deps:
        # Parse dependency target
        if ":" in dep:
            parts = dep.rsplit(":", 1)
            path = parts[0]
            slot_or_constraint = parts[1]
        else:
            path = dep
            slot_or_constraint = "default"

        if path not in seen:
            seen[path] = {}

        # Check for duplicate slots
        if slot_or_constraint in seen[path]:
            conflicts.append("Duplicate slot {} for package {}".format(slot_or_constraint, path))

        seen[path][slot_or_constraint] = True

    return conflicts

# ============================================================================
# CONVENIENCE MACROS FOR COMMON PATTERNS
# ============================================================================

def library_package_versions(
    name,
    versions,
    default_version = None,
    **kwargs):
    """Multi-version package with library-specific defaults.

    Sets up proper soname versioning and parallel slot installation.
    """
    # Add library-specific configure args
    common_args = {
        "configure_args": ["--enable-shared", "--disable-static"],
    }

    return multi_version_package(
        name = name,
        versions = versions,
        default_version = default_version,
        common_args = common_args,
        **kwargs
    )

def interpreter_package_versions(
    name,
    versions,
    default_version = None,
    **kwargs):
    """Multi-version package for language interpreters.

    Sets up versioned binary names (e.g., python3.11, python3.12).
    """
    common_args = {
        "post_install": """
# Create versioned symlinks
cd "$DESTDIR/usr/bin"
for bin in *; do
    if [ -f "$bin" ] && [ ! -L "$bin" ]; then
        # Don't rename if already versioned
        case "$bin" in
            *[0-9]) ;;
            *) mv "$bin" "${bin}${VERSION}" 2>/dev/null || true ;;
        esac
    fi
done
""",
    }

    return multi_version_package(
        name = name,
        versions = versions,
        default_version = default_version,
        common_args = common_args,
        **kwargs
    )

# ============================================================================
# VIRTUAL PACKAGES
# ============================================================================

def virtual_package(name, providers, default = None):
    """Define a virtual package satisfied by multiple providers.

    Similar to Gentoo's virtual packages.

    Example:
        virtual_package(
            name = "libc",
            providers = [
                "//packages/linux/core/musl",
                "//packages/linux/core/glibc",
            ],
            default = "//packages/linux/core/musl",
        )

    Args:
        name: Virtual package name
        providers: List of packages that satisfy this virtual
        default: Default provider
    """
    if not default and providers:
        default = providers[0]

    native.alias(
        name = name,
        actual = default,
        visibility = ["PUBLIC"],
    )

    # Create a filegroup with metadata about providers
    # This can be queried to find alternatives
    native.filegroup(
        name = name + "-providers",
        srcs = providers,
        visibility = ["PUBLIC"],
    )

# ============================================================================
# PACKAGE SET HELPERS
# ============================================================================

def version_set(name, packages):
    """Create a named set of specific package versions.

    Useful for reproducible builds and release management.

    Example:
        version_set(
            name = "stable-2024.01",
            packages = [
                "//packages/linux/core/openssl:openssl-3.2.0",
                "//packages/linux/lang/python:python-3.12.1",
                "//packages/linux/core/zlib:zlib-1.3.1",
            ],
        )
    """
    native.filegroup(
        name = name,
        srcs = packages,
        visibility = ["PUBLIC"],
    )
