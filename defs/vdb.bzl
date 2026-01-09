"""
VDB (Installed Package Database) system for BuckOs.

This module provides tracking of installed packages, similar to Gentoo's
/var/db/pkg database. It enables:
- Tracking installed packages and their versions
- File ownership tracking
- Reverse dependency queries
- Package uninstallation
- Upgrade path detection

Example usage:
    load("//defs:vdb.bzl", "vdb_record", "vdb_query", "vdb_uninstall")

    # Record package installation
    vdb_record(
        name = "bash",
        version = "5.2.21",
        slot = "0",
        files = ["/usr/bin/bash", "/usr/share/man/man1/bash.1"],
        deps = ["//packages/core/readline"],
    )

    # Query installed packages
    packages = vdb_query(category = "core")

    # Find file owner
    owner = vdb_file_owner("/usr/bin/bash")
"""

# =============================================================================
# SET OPERATION HELPERS (Starlark doesn't have native sets)
# =============================================================================

def _make_set(items = None):
    """Create a dict-based set from a list."""
    if items == None:
        return {}
    return {item: True for item in items}

def _set_add(s, item):
    """Add an item to a dict-based set."""
    s[item] = True

def _set_difference(set1, set2):
    """Return difference of two dict-based sets (set1 - set2)."""
    return {k: True for k in set1 if k not in set2}

# =============================================================================
# VDB STORAGE STRUCTURE
# =============================================================================

# VDB entry structure
# Stored in /var/db/pkg/<category>/<package>-<version>/
VDB_ENTRY_FIELDS = [
    "CATEGORY",      # Package category
    "PF",            # Package name with version
    "SLOT",          # Package slot
    "SUBSLOT",       # Package subslot (for ABI tracking)
    "EAPI",          # EAPI version
    "KEYWORDS",      # Architecture keywords
    "LICENSE",       # Package license
    "DESCRIPTION",   # Package description
    "HOMEPAGE",      # Project homepage
    "IUSE",          # Available USE flags
    "USE",           # Enabled USE flags
    "DEPEND",        # Build dependencies
    "RDEPEND",       # Runtime dependencies
    "BDEPEND",       # Build-time dependencies
    "PDEPEND",       # Post dependencies
    "CONTENTS",      # Installed file list
    "COUNTER",       # Installation counter
    "BUILD_TIME",    # Build timestamp
    "SIZE",          # Installed size in bytes
    "CBUILD",        # Build host triplet
    "CHOST",         # Target host triplet
    "repository",    # Source repository
    "FEATURES",      # Build features used
    "CFLAGS",        # Compiler flags used
    "LDFLAGS",       # Linker flags used
    "DEFINED_PHASES", # Defined build phases
]

# Content types for CONTENTS file
CONTENT_TYPE_DIR = "dir"
CONTENT_TYPE_OBJ = "obj"
CONTENT_TYPE_SYM = "sym"

# =============================================================================
# VDB ENTRY CREATION
# =============================================================================

def vdb_entry(
        name,
        version,
        category,
        slot = "0",
        subslot = None,
        eapi = 8,
        license = "",
        description = "",
        homepage = "",
        iuse = [],
        use = [],
        depend = [],
        rdepend = [],
        bdepend = [],
        pdepend = [],
        contents = [],
        size = 0,
        build_time = None,
        chost = None,
        cflags = "",
        ldflags = "",
        repository = "buckos"):
    """
    Create a VDB entry for an installed package.

    Args:
        name: Package name
        version: Package version
        category: Package category
        slot: Package slot
        subslot: Package subslot (defaults to slot)
        eapi: EAPI version
        license: Package license
        description: Package description
        homepage: Project homepage
        iuse: Available USE flags
        use: Enabled USE flags
        depend: Build dependencies
        rdepend: Runtime dependencies
        bdepend: Build-time dependencies
        pdepend: Post dependencies
        contents: List of installed files (ContentEntry dicts)
        size: Installed size in bytes
        build_time: Build timestamp (Unix time)
        chost: Target host triplet
        cflags: Compiler flags used
        ldflags: Linker flags used
        repository: Source repository name

    Returns:
        Dictionary with VDB entry data
    """
    if subslot == None:
        subslot = slot

    return {
        "name": name,
        "version": version,
        "category": category,
        "slot": slot,
        "subslot": subslot,
        "slot_subslot": "{}/{}".format(slot, subslot) if slot != subslot else slot,
        "eapi": eapi,
        "license": license,
        "description": description,
        "homepage": homepage,
        "iuse": iuse,
        "use": use,
        "depend": depend,
        "rdepend": rdepend,
        "bdepend": bdepend,
        "pdepend": pdepend,
        "contents": contents,
        "size": size,
        "build_time": build_time,
        "chost": chost,
        "cflags": cflags,
        "ldflags": ldflags,
        "repository": repository,
        "pf": "{}-{}".format(name, version),
        "cpv": "{}/{}-{}".format(category, name, version),
    }

def content_entry(path, type, **kwargs):
    """
    Create a content entry for the CONTENTS file.

    Args:
        path: File path
        type: Content type (dir, obj, sym)
        **kwargs: Additional fields (md5, mtime for obj; target for sym)

    Returns:
        Dictionary with content entry data
    """
    entry = {
        "path": path,
        "type": type,
    }

    if type == CONTENT_TYPE_OBJ:
        entry["md5"] = kwargs.get("md5", "")
        entry["mtime"] = kwargs.get("mtime", 0)
    elif type == CONTENT_TYPE_SYM:
        entry["target"] = kwargs.get("target", "")

    return entry

# =============================================================================
# VDB QUERY FUNCTIONS
# =============================================================================

def vdb_get_installed(vdb_entries):
    """
    Get all installed packages from VDB.

    Args:
        vdb_entries: List of VDB entry dictionaries

    Returns:
        List of (category, name, version) tuples
    """
    return [(e["category"], e["name"], e["version"]) for e in vdb_entries]

def vdb_query_by_name(vdb_entries, name):
    """
    Query VDB for packages matching a name.

    Args:
        vdb_entries: List of VDB entry dictionaries
        name: Package name to search for

    Returns:
        List of matching VDB entries
    """
    return [e for e in vdb_entries if e["name"] == name]

def vdb_query_by_category(vdb_entries, category):
    """
    Query VDB for packages in a category.

    Args:
        vdb_entries: List of VDB entry dictionaries
        category: Category to search for

    Returns:
        List of matching VDB entries
    """
    return [e for e in vdb_entries if e["category"] == category]

def vdb_query_by_slot(vdb_entries, name, slot):
    """
    Query VDB for packages in a specific slot.

    Args:
        vdb_entries: List of VDB entry dictionaries
        name: Package name
        slot: Slot to search for

    Returns:
        List of matching VDB entries
    """
    return [e for e in vdb_entries if e["name"] == name and e["slot"] == slot]

def vdb_get_version(vdb_entries, category, name):
    """
    Get installed version of a package.

    Args:
        vdb_entries: List of VDB entry dictionaries
        category: Package category
        name: Package name

    Returns:
        Version string or None if not installed
    """
    for entry in vdb_entries:
        if entry["category"] == category and entry["name"] == name:
            return entry["version"]
    return None

# =============================================================================
# FILE OWNERSHIP TRACKING
# =============================================================================

def vdb_file_owner(vdb_entries, path):
    """
    Find which package owns a file.

    Args:
        vdb_entries: List of VDB entry dictionaries
        path: File path to search for

    Returns:
        VDB entry of owning package, or None
    """
    for entry in vdb_entries:
        for content in entry.get("contents", []):
            if content["path"] == path:
                return entry
    return None

def vdb_files_owned_by(vdb_entry):
    """
    Get all files owned by a package.

    Args:
        vdb_entry: VDB entry dictionary

    Returns:
        List of file paths
    """
    return [c["path"] for c in vdb_entry.get("contents", [])]

def vdb_check_collisions(vdb_entries, new_files):
    """
    Check for file collisions with existing packages.

    Args:
        vdb_entries: List of VDB entry dictionaries
        new_files: List of files to be installed

    Returns:
        List of (file, owning_package) tuples for collisions
    """
    collisions = []
    for path in new_files:
        owner = vdb_file_owner(vdb_entries, path)
        if owner:
            collisions.append((path, owner["cpv"]))
    return collisions

# =============================================================================
# DEPENDENCY QUERIES
# =============================================================================

def vdb_get_rdeps(vdb_entries, package_cpv):
    """
    Get reverse dependencies of a package.

    Finds all packages that depend on the specified package.

    Args:
        vdb_entries: List of VDB entry dictionaries
        package_cpv: CPV of the package (category/name-version)

    Returns:
        List of VDB entries that depend on the package
    """
    rdeps = []
    package_name = package_cpv.split("/")[-1].rsplit("-", 1)[0]

    for entry in vdb_entries:
        all_deps = entry.get("rdepend", []) + entry.get("depend", [])
        for dep in all_deps:
            # Simple matching - a real implementation would use version constraints
            if package_name in dep:
                rdeps.append(entry)
                break

    return rdeps

def vdb_get_deps(vdb_entry):
    """
    Get all dependencies of a package.

    Args:
        vdb_entry: VDB entry dictionary

    Returns:
        Dictionary with dependency types as keys
    """
    return {
        "depend": vdb_entry.get("depend", []),
        "rdepend": vdb_entry.get("rdepend", []),
        "bdepend": vdb_entry.get("bdepend", []),
        "pdepend": vdb_entry.get("pdepend", []),
    }

def vdb_check_can_uninstall(vdb_entries, package_cpv):
    """
    Check if a package can be safely uninstalled.

    Args:
        vdb_entries: List of VDB entry dictionaries
        package_cpv: CPV of the package to check

    Returns:
        Dictionary with:
        - can_uninstall: Boolean
        - blockers: List of packages that depend on this one
    """
    rdeps = vdb_get_rdeps(vdb_entries, package_cpv)

    return {
        "can_uninstall": len(rdeps) == 0,
        "blockers": [e["cpv"] for e in rdeps],
    }

# =============================================================================
# VDB SERIALIZATION
# =============================================================================

def vdb_to_contents_format(contents):
    """
    Convert contents list to Gentoo CONTENTS file format.

    Args:
        contents: List of content entry dictionaries

    Returns:
        String in CONTENTS file format
    """
    lines = []
    for entry in contents:
        if entry["type"] == CONTENT_TYPE_DIR:
            lines.append("dir {}".format(entry["path"]))
        elif entry["type"] == CONTENT_TYPE_OBJ:
            lines.append("obj {} {} {}".format(
                entry["path"],
                entry.get("md5", ""),
                entry.get("mtime", 0)
            ))
        elif entry["type"] == CONTENT_TYPE_SYM:
            lines.append("sym {} -> {}".format(
                entry["path"],
                entry.get("target", "")
            ))
    return "\n".join(lines)

def vdb_from_contents_format(contents_str):
    """
    Parse Gentoo CONTENTS file format to contents list.

    Args:
        contents_str: String in CONTENTS file format

    Returns:
        List of content entry dictionaries
    """
    contents = []
    for line in contents_str.strip().split("\n"):
        if not line:
            continue

        parts = line.split(" ", 1)
        entry_type = parts[0]

        if entry_type == "dir":
            contents.append(content_entry(parts[1], CONTENT_TYPE_DIR))
        elif entry_type == "obj":
            obj_parts = parts[1].rsplit(" ", 2)
            contents.append(content_entry(
                obj_parts[0],
                CONTENT_TYPE_OBJ,
                md5 = obj_parts[1] if len(obj_parts) > 1 else "",
                mtime = int(obj_parts[2]) if len(obj_parts) > 2 else 0
            ))
        elif entry_type == "sym":
            sym_parts = parts[1].split(" -> ", 1)
            contents.append(content_entry(
                sym_parts[0],
                CONTENT_TYPE_SYM,
                target = sym_parts[1] if len(sym_parts) > 1 else ""
            ))

    return contents

# =============================================================================
# VDB GENERATION SCRIPTS
# =============================================================================

def generate_vdb_record_script(entry):
    """
    Generate shell script to record package in VDB.

    Args:
        entry: VDB entry dictionary

    Returns:
        Shell script string
    """
    vdb_dir = "/var/db/pkg/{}/{}".format(entry["category"], entry["pf"])

    script = '''
# Create VDB directory
mkdir -p "{vdb_dir}"

# Write package metadata
cat > "{vdb_dir}/CATEGORY" << 'EOF'
{category}
EOF

cat > "{vdb_dir}/PF" << 'EOF'
{pf}
EOF

cat > "{vdb_dir}/SLOT" << 'EOF'
{slot_subslot}
EOF

cat > "{vdb_dir}/EAPI" << 'EOF'
{eapi}
EOF

cat > "{vdb_dir}/LICENSE" << 'EOF'
{license}
EOF

cat > "{vdb_dir}/DESCRIPTION" << 'EOF'
{description}
EOF

cat > "{vdb_dir}/IUSE" << 'EOF'
{iuse}
EOF

cat > "{vdb_dir}/USE" << 'EOF'
{use}
EOF

cat > "{vdb_dir}/RDEPEND" << 'EOF'
{rdepend}
EOF

cat > "{vdb_dir}/DEPEND" << 'EOF'
{depend}
EOF

cat > "{vdb_dir}/BDEPEND" << 'EOF'
{bdepend}
EOF

cat > "{vdb_dir}/SIZE" << 'EOF'
{size}
EOF

cat > "{vdb_dir}/BUILD_TIME" << 'EOF'
{build_time}
EOF

cat > "{vdb_dir}/repository" << 'EOF'
{repository}
EOF
'''.format(
        vdb_dir = vdb_dir,
        category = entry["category"],
        pf = entry["pf"],
        slot_subslot = entry.get("slot_subslot", entry["slot"]),
        eapi = entry["eapi"],
        license = entry.get("license", ""),
        description = entry.get("description", ""),
        iuse = " ".join(entry.get("iuse", [])),
        use = " ".join(entry.get("use", [])),
        rdepend = "\n".join(entry.get("rdepend", [])),
        depend = "\n".join(entry.get("depend", [])),
        bdepend = "\n".join(entry.get("bdepend", [])),
        size = entry.get("size", 0),
        build_time = entry.get("build_time", ""),
        repository = entry.get("repository", "buckos"),
    )

    return script

def generate_vdb_uninstall_script(entry):
    """
    Generate shell script to uninstall package from VDB.

    Args:
        entry: VDB entry dictionary

    Returns:
        Shell script string
    """
    script = '''
# Uninstall {cpv}

# Remove installed files (in reverse order)
'''.format(cpv = entry["cpv"])

    # Sort contents in reverse order (files before directories)
    contents = sorted(entry.get("contents", []),
                     key = lambda c: c["path"],
                     reverse = True)

    for content in contents:
        if content["type"] == CONTENT_TYPE_DIR:
            script += 'rmdir "{}" 2>/dev/null || true\n'.format(content["path"])
        else:
            script += 'rm -f "{}"\n'.format(content["path"])

    # Remove VDB entry
    vdb_dir = "/var/db/pkg/{}/{}".format(entry["category"], entry["pf"])
    script += '''
# Remove VDB entry
rm -rf "{}"
'''.format(vdb_dir)

    return script

# =============================================================================
# VDB STATISTICS
# =============================================================================

def vdb_get_stats(vdb_entries):
    """
    Get statistics about installed packages.

    Args:
        vdb_entries: List of VDB entry dictionaries

    Returns:
        Dictionary with statistics
    """
    total_size = sum(e.get("size", 0) for e in vdb_entries)
    total_files = sum(len(e.get("contents", [])) for e in vdb_entries)

    categories = {}
    for entry in vdb_entries:
        cat = entry["category"]
        if cat not in categories:
            categories[cat] = 0
        categories[cat] += 1

    return {
        "package_count": len(vdb_entries),
        "total_size": total_size,
        "total_files": total_files,
        "by_category": categories,
    }

def vdb_get_orphans(vdb_entries):
    """
    Find packages that are not depended on by anything.

    Args:
        vdb_entries: List of VDB entry dictionaries

    Returns:
        List of VDB entries that are orphans
    """
    orphans = []
    for entry in vdb_entries:
        rdeps = vdb_get_rdeps(vdb_entries, entry["cpv"])
        if not rdeps:
            orphans.append(entry)
    return orphans

# =============================================================================
# VDB VERIFICATION
# =============================================================================

def vdb_verify_package(vdb_entry, root = "/"):
    """
    Generate script to verify installed package files.

    Args:
        vdb_entry: VDB entry dictionary
        root: Root filesystem path

    Returns:
        Shell script for verification
    """
    script = '''#!/bin/sh
# Verify {cpv}

ERRORS=0

'''.format(cpv = vdb_entry["cpv"])

    for content in vdb_entry.get("contents", []):
        path = root.rstrip("/") + content["path"]

        if content["type"] == CONTENT_TYPE_DIR:
            script += '''
if [ ! -d "{path}" ]; then
    echo "Missing directory: {path}"
    ERRORS=$((ERRORS + 1))
fi
'''.format(path = path)
        elif content["type"] == CONTENT_TYPE_OBJ:
            script += '''
if [ ! -f "{path}" ]; then
    echo "Missing file: {path}"
    ERRORS=$((ERRORS + 1))
elif [ -n "{md5}" ]; then
    ACTUAL_MD5=$(md5sum "{path}" | cut -d' ' -f1)
    if [ "$ACTUAL_MD5" != "{md5}" ]; then
        echo "Modified file: {path}"
        ERRORS=$((ERRORS + 1))
    fi
fi
'''.format(path = path, md5 = content.get("md5", ""))
        elif content["type"] == CONTENT_TYPE_SYM:
            script += '''
if [ ! -L "{path}" ]; then
    echo "Missing symlink: {path}"
    ERRORS=$((ERRORS + 1))
fi
'''.format(path = path)

    script += '''
if [ $ERRORS -eq 0 ]; then
    echo "Package {cpv} verified OK"
    exit 0
else
    echo "Package {cpv} has $ERRORS errors"
    exit 1
fi
'''.format(cpv = vdb_entry["cpv"])

    return script

# =============================================================================
# PRESERVED LIBRARIES
# =============================================================================

def vdb_get_preserved_libs(vdb_entries, old_entry, new_entry):
    """
    Find libraries that need to be preserved during upgrade.

    Args:
        vdb_entries: List of all VDB entries
        old_entry: VDB entry being replaced
        new_entry: New VDB entry

    Returns:
        List of library paths that need preservation
    """
    old_libs = _make_set()
    new_libs = _make_set()

    # Find .so files in old package
    for content in old_entry.get("contents", []):
        if content["type"] == CONTENT_TYPE_OBJ and ".so" in content["path"]:
            _set_add(old_libs, content["path"])

    # Find .so files in new package
    for content in new_entry.get("contents", []):
        if content["type"] == CONTENT_TYPE_OBJ and ".so" in content["path"]:
            _set_add(new_libs, content["path"])

    # Libraries in old but not in new need preservation
    removed_libs = _set_difference(old_libs, new_libs)

    # Check if any other package depends on these
    preserved = []
    for lib in removed_libs:
        for entry in vdb_entries:
            if entry["cpv"] == old_entry["cpv"]:
                continue
            # Check if this package links to the library
            # (simplified - real implementation would check ELF NEEDED)
            for dep in entry.get("rdepend", []):
                if old_entry["name"] in dep:
                    preserved.append(lib)
                    break

    return preserved

# =============================================================================
# DOCUMENTATION
# =============================================================================

"""
## VDB System Usage

### Recording Package Installation

```python
# Create VDB entry
entry = vdb_entry(
    name = "bash",
    version = "5.2.21",
    category = "core",
    slot = "0",
    license = "GPL-3+",
    description = "The Bourne Again Shell",
    iuse = ["readline", "nls", "plugins"],
    use = ["readline", "nls"],
    rdepend = ["//packages/core/readline"],
    contents = [
        content_entry("/usr/bin/bash", "obj", md5="abc123", mtime=1234567890),
        content_entry("/usr/share/man/man1/bash.1", "obj"),
        content_entry("/usr/share/doc/bash", "dir"),
    ],
    size = 1234567,
)

# Generate installation script
script = generate_vdb_record_script(entry)
```

### Querying Installed Packages

```python
# Get all installed packages
installed = vdb_get_installed(vdb_entries)

# Query by name
bash_entries = vdb_query_by_name(vdb_entries, "bash")

# Find file owner
owner = vdb_file_owner(vdb_entries, "/usr/bin/bash")

# Get reverse dependencies
rdeps = vdb_get_rdeps(vdb_entries, "core/bash-5.2.21")
```

### Uninstallation

```python
# Check if safe to uninstall
result = vdb_check_can_uninstall(vdb_entries, "core/bash-5.2.21")
if result["can_uninstall"]:
    script = generate_vdb_uninstall_script(entry)
else:
    print("Blocked by:", result["blockers"])
```

### Package Verification

```python
# Verify installed files
script = vdb_verify_package(entry)
```

## VDB File Locations

- `/var/db/pkg/<category>/<name>-<version>/` - Package directory
- `CATEGORY` - Package category
- `PF` - Package name with version
- `SLOT` - Package slot
- `CONTENTS` - List of installed files
- `USE` - Enabled USE flags
- `RDEPEND` - Runtime dependencies
- etc.
"""
