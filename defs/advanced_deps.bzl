"""
Advanced dependency and USE flag features for BuckOs.

This module provides:
- Package blocker syntax (!package, !!package)
- SRC_URI advanced features (-> rename, mirror://)
- REQUIRED_USE complex syntax (^^, ??, ||)
- Package environment files (/etc/portage/env/)

Example usage:
    load("//defs:advanced_deps.bzl", "blocker", "hard_blocker", "src_uri_rename")

    deps = [
        blocker("//packages/core/old-package"),
        hard_blocker("//packages/core/incompatible"),
    ]
"""

# =============================================================================
# PACKAGE BLOCKERS
# =============================================================================

def blocker(package):
    """
    Create a soft blocker dependency.

    Soft blockers (!package) indicate that a package cannot be installed
    at the same time, but the blocker can be resolved by unmerging the
    blocking package after the new package is installed.

    Args:
        package: Package target to block

    Returns:
        Blocker specification string

    Example:
        deps = [
            blocker("//packages/core/old-ssl"),  # Can't coexist with old-ssl
        ]
    """
    return "!{}".format(package)

def hard_blocker(package):
    """
    Create a hard blocker dependency.

    Hard blockers (!!package) indicate that a package must be unmerged
    before the new package can be installed.

    Args:
        package: Package target to block

    Returns:
        Hard blocker specification string

    Example:
        deps = [
            hard_blocker("//packages/core/incompatible"),  # Must uninstall first
        ]
    """
    return "!!{}".format(package)

def parse_blocker(dep):
    """
    Parse a blocker dependency string.

    Args:
        dep: Dependency string

    Returns:
        Tuple of (is_blocker, is_hard, package) or (False, False, dep)
    """
    if dep.startswith("!!"):
        return (True, True, dep[2:])
    elif dep.startswith("!"):
        return (True, False, dep[1:])
    return (False, False, dep)

def get_blockers(deps):
    """
    Filter dependencies to get only blockers.

    Args:
        deps: List of dependency strings

    Returns:
        List of (is_hard, package) tuples for blockers
    """
    blockers = []
    for dep in deps:
        is_blocker, is_hard, package = parse_blocker(dep)
        if is_blocker:
            blockers.append((is_hard, package))
    return blockers

def check_blockers(installed_packages, new_package_blockers):
    """
    Check if any blockers prevent installation.

    Args:
        installed_packages: List of installed package targets
        new_package_blockers: List of blockers from the new package

    Returns:
        Dictionary with:
        - blocked: Boolean indicating if installation is blocked
        - hard_blockers: Packages that must be uninstalled first
        - soft_blockers: Packages that can be uninstalled after
    """
    result = {
        "blocked": False,
        "hard_blockers": [],
        "soft_blockers": [],
    }

    for is_hard, package in new_package_blockers:
        if package in installed_packages:
            result["blocked"] = True
            if is_hard:
                result["hard_blockers"].append(package)
            else:
                result["soft_blockers"].append(package)

    return result

# =============================================================================
# SRC_URI ADVANCED FEATURES
# =============================================================================

# Mirror definitions
MIRRORS = {
    "gentoo": [
        "https://distfiles.gentoo.org/distfiles/",
        "https://mirror.leaseweb.com/gentoo/distfiles/",
        "https://ftp.snt.utwente.nl/pub/os/linux/gentoo/distfiles/",
    ],
    "gnu": [
        "https://ftp.gnu.org/gnu/",
        "https://mirrors.kernel.org/gnu/",
        "https://mirror.us-midwest-1.nexcess.net/gnu/",
    ],
    "sourceforge": [
        "https://downloads.sourceforge.net/sourceforge/",
        "https://netcologne.dl.sourceforge.net/sourceforge/",
        "https://pilotfiber.dl.sourceforge.net/sourceforge/",
    ],
    "pypi": [
        "https://files.pythonhosted.org/packages/source/",
    ],
    "cpan": [
        "https://cpan.metacpan.org/",
        "https://www.cpan.org/",
    ],
    "apache": [
        "https://archive.apache.org/dist/",
        "https://downloads.apache.org/",
    ],
    "kernel": [
        "https://cdn.kernel.org/pub/",
        "https://mirrors.kernel.org/pub/",
    ],
    "github": [
        "https://github.com/",
    ],
    "gitlab": [
        "https://gitlab.com/",
    ],
}

def src_uri_rename(uri, filename):
    """
    Create a SRC_URI entry with a renamed output file.

    Similar to Gentoo's "URI -> filename" syntax.

    Args:
        uri: Download URI
        filename: Local filename to save as

    Returns:
        Dictionary with URI and filename

    Example:
        src_uri_rename(
            "https://github.com/project/archive/v1.0.tar.gz",
            "project-1.0.tar.gz"
        )
    """
    return {
        "uri": uri,
        "filename": filename,
    }

def mirror_uri(mirror_name, path):
    """
    Create a mirror:// URI that will try multiple mirrors.

    Args:
        mirror_name: Name of the mirror group
        path: Path within the mirror

    Returns:
        List of URIs to try

    Example:
        uris = mirror_uri("gnu", "bash/bash-5.2.tar.gz")
        # Returns list of mirror URLs for the file
    """
    if mirror_name not in MIRRORS:
        fail("Unknown mirror: {}. Available: {}".format(
            mirror_name, ", ".join(MIRRORS.keys())))

    return [base + path for base in MIRRORS[mirror_name]]

def expand_src_uri(src_uri):
    """
    Expand SRC_URI entries into download specifications.

    Handles:
    - Simple URIs: "https://example.com/file.tar.gz"
    - Renamed URIs: {"uri": "...", "filename": "..."}
    - Mirror URIs: "mirror://gnu/bash/bash-5.2.tar.gz"

    Args:
        src_uri: SRC_URI value (string, dict, or list)

    Returns:
        List of download specifications
    """
    if type(src_uri) == "string":
        # Handle mirror:// syntax
        if src_uri.startswith("mirror://"):
            parts = src_uri[9:].split("/", 1)
            if len(parts) == 2:
                return [{"uri": u, "filename": parts[1].split("/")[-1]}
                        for u in mirror_uri(parts[0], parts[1])]
        # Simple URI
        return [{"uri": src_uri, "filename": src_uri.split("/")[-1]}]

    elif type(src_uri) == "dict":
        # Renamed URI
        return [src_uri]

    elif type(src_uri) == "list":
        # Multiple URIs
        result = []
        for entry in src_uri:
            result.extend(expand_src_uri(entry))
        return result

    return []

def generate_fetch_script(src_uris, output_dir = ".", proxy = ""):
    """
    Generate script to fetch sources with mirror fallback.

    Args:
        src_uris: Expanded SRC_URI list
        output_dir: Directory to save files
        proxy: HTTP proxy URL (optional)

    Returns:
        Shell script string
    """
    # Build wget proxy args
    wget_proxy = ""
    if proxy:
        wget_proxy = "-e http_proxy={} -e https_proxy={} ".format(proxy, proxy)

    script = '''#!/bin/sh
# Fetch sources with mirror fallback

set -e
OUTPUT_DIR="{}"

'''.format(output_dir)

    # Group by filename
    by_filename = {}
    for spec in src_uris:
        filename = spec["filename"]
        if filename not in by_filename:
            by_filename[filename] = []
        by_filename[filename].append(spec["uri"])

    for filename, uris in by_filename.items():
        script += '''
# Fetch {}
'''.format(filename)

        for i, uri in enumerate(uris):
            if i == 0:
                script += '''if wget {}-O "$OUTPUT_DIR/{}" "{}"; then
    echo "Downloaded {}"
'''.format(wget_proxy, filename, uri, filename)
            else:
                script += '''elif wget {}-O "$OUTPUT_DIR/{}" "{}"; then
    echo "Downloaded {} from mirror"
'''.format(wget_proxy, filename, uri, filename)

        script += '''else
    echo "Failed to download {}"
    exit 1
fi
'''.format(filename)

    return script

# =============================================================================
# REQUIRED_USE COMPLEX SYNTAX
# =============================================================================

def exactly_one_of(*flags):
    """
    Create a REQUIRED_USE constraint: exactly one of the flags must be enabled.

    Similar to Gentoo's ^^ ( flag1 flag2 flag3 ) syntax.

    Args:
        *flags: USE flags where exactly one must be enabled

    Returns:
        Constraint dictionary

    Example:
        required_use = [
            exactly_one_of("ssl", "gnutls", "libressl"),  # Pick one SSL impl
        ]
    """
    return {
        "type": "exactly_one",
        "flags": list(flags),
    }

def at_most_one_of(*flags):
    """
    Create a REQUIRED_USE constraint: at most one of the flags can be enabled.

    Similar to Gentoo's ?? ( flag1 flag2 flag3 ) syntax.

    Args:
        *flags: USE flags where at most one can be enabled

    Returns:
        Constraint dictionary

    Example:
        required_use = [
            at_most_one_of("gtk", "qt5", "qt6"),  # Pick at most one toolkit
        ]
    """
    return {
        "type": "at_most_one",
        "flags": list(flags),
    }

def any_of_flags(*flags):
    """
    Create a REQUIRED_USE constraint: at least one of the flags must be enabled.

    Similar to Gentoo's || ( flag1 flag2 flag3 ) syntax.

    Args:
        *flags: USE flags where at least one must be enabled

    Returns:
        Constraint dictionary

    Example:
        required_use = [
            any_of_flags("python", "perl", "ruby"),  # Need at least one binding
        ]
    """
    return {
        "type": "any_of",
        "flags": list(flags),
    }

def use_conditional(flag, then_constraint):
    """
    Create a conditional REQUIRED_USE constraint.

    Similar to Gentoo's flag? ( constraint ) syntax.

    Args:
        flag: Condition flag
        then_constraint: Constraint to apply if flag is enabled

    Returns:
        Constraint dictionary

    Example:
        required_use = [
            use_conditional("gui", any_of_flags("gtk", "qt5")),  # GUI needs toolkit
        ]
    """
    return {
        "type": "conditional",
        "condition": flag,
        "then": then_constraint,
    }

def check_required_use(constraints, enabled_flags):
    """
    Check if USE flags satisfy REQUIRED_USE constraints.

    Args:
        constraints: List of constraint dictionaries
        enabled_flags: Set of enabled USE flags

    Returns:
        Dictionary with:
        - valid: Boolean indicating if constraints are satisfied
        - errors: List of error messages
    """
    result = {"valid": True, "errors": []}

    for constraint in constraints:
        ctype = constraint["type"]

        if ctype == "exactly_one":
            flags = constraint["flags"]
            enabled_count = sum(1 for f in flags if f in enabled_flags)
            if enabled_count != 1:
                result["valid"] = False
                result["errors"].append(
                    "Exactly one of [{}] must be enabled, but {} are".format(
                        ", ".join(flags), enabled_count))

        elif ctype == "at_most_one":
            flags = constraint["flags"]
            enabled_count = sum(1 for f in flags if f in enabled_flags)
            if enabled_count > 1:
                result["valid"] = False
                enabled = [f for f in flags if f in enabled_flags]
                result["errors"].append(
                    "At most one of [{}] can be enabled, but [{}] are".format(
                        ", ".join(flags), ", ".join(enabled)))

        elif ctype == "any_of":
            flags = constraint["flags"]
            enabled_count = sum(1 for f in flags if f in enabled_flags)
            if enabled_count == 0:
                result["valid"] = False
                result["errors"].append(
                    "At least one of [{}] must be enabled".format(
                        ", ".join(flags)))

        elif ctype == "conditional":
            condition = constraint["condition"]
            if condition in enabled_flags:
                # Check the nested constraint
                nested_result = check_required_use([constraint["then"]], enabled_flags)
                if not nested_result["valid"]:
                    result["valid"] = False
                    for error in nested_result["errors"]:
                        result["errors"].append(
                            "{} requires: {}".format(condition, error))

    return result

# =============================================================================
# PACKAGE ENVIRONMENT FILES
# =============================================================================

def package_env(package, env_name):
    """
    Assign a package to use a specific environment file.

    Similar to /etc/portage/package.env entries.

    Args:
        package: Package identifier
        env_name: Environment file name

    Returns:
        Package environment mapping

    Example:
        package_envs = [
            package_env("media-video/ffmpeg", "no-lto"),
            package_env("dev-lang/rust", "high-memory"),
        ]
    """
    return {
        "package": package,
        "env": env_name,
    }

# Standard environment definitions
ENV_DEFINITIONS = {
    "no-lto": {
        "description": "Disable Link-Time Optimization",
        "filter_flags": ["-flto*", "-fuse-linker-plugin"],
        "env": {},
    },
    "no-lto-pgo": {
        "description": "Disable LTO and PGO",
        "filter_flags": ["-flto*", "-fprofile-*"],
        "env": {},
    },
    "high-memory": {
        "description": "Build requires high memory - reduce parallelism",
        "env": {
            "MAKEOPTS": "-j2",
        },
    },
    "single-job": {
        "description": "Build with single job",
        "env": {
            "MAKEOPTS": "-j1",
        },
    },
    "no-graphite": {
        "description": "Disable Graphite optimizations",
        "filter_flags": ["-fgraphite*", "-floop-*"],
        "env": {},
    },
    "clang": {
        "description": "Build with Clang instead of GCC",
        "env": {
            "CC": "clang",
            "CXX": "clang++",
        },
    },
    "debug": {
        "description": "Build with debug flags",
        "env": {
            "CFLAGS": "-O0 -g3 -ggdb",
            "CXXFLAGS": "-O0 -g3 -ggdb",
        },
    },
    "optimize-size": {
        "description": "Optimize for size",
        "env": {
            "CFLAGS": "-Os -s",
            "CXXFLAGS": "-Os -s",
        },
    },
    "optimize-speed": {
        "description": "Optimize for speed",
        "env": {
            "CFLAGS": "-O3 -march=native",
            "CXXFLAGS": "-O3 -march=native",
        },
    },
}

def get_package_env(package, package_env_mappings):
    """
    Get the environment configuration for a package.

    Args:
        package: Package identifier
        package_env_mappings: List of package_env() entries

    Returns:
        Environment definition dictionary or None
    """
    for mapping in package_env_mappings:
        if mapping["package"] == package:
            env_name = mapping["env"]
            if env_name in ENV_DEFINITIONS:
                return ENV_DEFINITIONS[env_name]
            return {"env": {}, "description": "Custom: " + env_name}
    return None

def apply_env_filter_flags(flags, filter_patterns):
    """
    Filter out flags matching patterns.

    Args:
        flags: Space-separated flags string
        filter_patterns: List of glob patterns to filter

    Returns:
        Filtered flags string
    """
    result = []
    for flag in flags.split():
        filtered = False
        for pattern in filter_patterns:
            # Simple glob matching
            if pattern.endswith("*"):
                if flag.startswith(pattern[:-1]):
                    filtered = True
                    break
            elif flag == pattern:
                filtered = True
                break
        if not filtered:
            result.append(flag)
    return " ".join(result)

def generate_package_env_script(package, env_def):
    """
    Generate script to set up package-specific environment.

    Args:
        package: Package identifier
        env_def: Environment definition dictionary

    Returns:
        Shell script string
    """
    script = '''# Package environment for {}
# {}

'''.format(package, env_def.get("description", ""))

    # Apply filter flags
    if "filter_flags" in env_def:
        script += '''# Filter flags
CFLAGS=$(echo "$CFLAGS" | tr ' ' '\\n' | grep -v -E '{}' | tr '\\n' ' ')
CXXFLAGS=$(echo "$CXXFLAGS" | tr ' ' '\\n' | grep -v -E '{}' | tr '\\n' ' ')
'''.format(
            "|".join(p.replace("*", ".*") for p in env_def["filter_flags"]),
            "|".join(p.replace("*", ".*") for p in env_def["filter_flags"])
        )

    # Apply environment overrides
    for var, value in env_def.get("env", {}).items():
        script += 'export {}="{}"\n'.format(var, value)

    return script

def generate_all_package_envs(package_env_mappings):
    """
    Generate complete package.env configuration.

    Args:
        package_env_mappings: List of package_env() entries

    Returns:
        String in package.env format
    """
    lines = ["# BuckOs package.env configuration", ""]

    for mapping in package_env_mappings:
        lines.append("{} {}".format(mapping["package"], mapping["env"]))

    return "\n".join(lines)

# =============================================================================
# DOCUMENTATION
# =============================================================================

"""
## Advanced Dependencies Usage

### Package Blockers

```python
from defs.advanced_deps import blocker, hard_blocker

deps = [
    "//packages/core/openssl",
    blocker("//packages/core/libressl"),     # Soft blocker
    hard_blocker("//packages/core/old-ssl"), # Hard blocker
]
```

### SRC_URI Features

```python
from defs.advanced_deps import src_uri_rename, mirror_uri

# Rename downloaded file
src = src_uri_rename(
    "https://github.com/project/archive/v1.0.tar.gz",
    "project-1.0.tar.gz"
)

# Use mirror
src_uris = mirror_uri("gnu", "bash/bash-5.2.tar.gz")
```

### REQUIRED_USE Constraints

```python
from defs.advanced_deps import exactly_one_of, at_most_one_of, any_of_flags

required_use = [
    exactly_one_of("ssl", "gnutls", "libressl"),
    at_most_one_of("gtk", "qt5", "qt6"),
    any_of_flags("python", "perl", "ruby"),
]

result = check_required_use(required_use, {"ssl", "gtk", "python"})
```

### Package Environment

```python
from defs.advanced_deps import package_env, ENV_DEFINITIONS

envs = [
    package_env("media-video/ffmpeg", "no-lto"),
    package_env("dev-lang/rust", "high-memory"),
]
```
"""
