"""Transitive set definitions for package dependency propagation.

Four tsets replace the manual flag accumulation loops in package rules:

  CompileInfoTSet — include dirs and cflags from deps
  LinkInfoTSet    — library dirs, rpath-link, and ldflags from deps
  PathInfoTSet    — bin/lib/cmake prefix paths from deps
  RuntimeDepTSet  — transitive runtime dep closure for rootfs assembly

Each tset defines projections that flatten into cmd_args for the Python
helpers.  The projection functions return a list of cmd_args that get
joined by the tset reduction.
"""

# ── Value structs ────────────────────────────────────────────────────
#
# Each tset node holds one of these as its value.  The projections
# extract cmd_args from them.

CompileInfoValue = record(
    prefix = field(Artifact),
    cflags = field(list[str], default = []),
)

LinkInfoValue = record(
    prefix = field(Artifact),
    ldflags = field(list[str], default = []),
    libraries = field(list[str], default = []),
)

PathInfoValue = record(
    prefix = field(Artifact),
)

RuntimeDepValue = record(
    name = field(str),
    version = field(str),
    prefix = field(Artifact),
)

# ── Projection functions ─────────────────────────────────────────────

def _compile_cflags_projection(value):
    """Project include dirs and per-package cflags."""
    args = []
    args.append(cmd_args(value.prefix, format = "-I{}/usr/include"))
    for f in value.cflags:
        args.append(cmd_args(f))
    return args

def _compile_pkg_config_projection(value):
    """Project pkg-config search paths."""
    return [
        cmd_args(value.prefix, format = "{}/usr/lib64/pkgconfig"),
        cmd_args(value.prefix, format = "{}/usr/lib/pkgconfig"),
        cmd_args(value.prefix, format = "{}/usr/share/pkgconfig"),
    ]

def _link_ldflags_projection(value):
    """Project -L, -Wl,-rpath-link, and per-package ldflags."""
    args = [
        cmd_args(value.prefix, format = "-L{}/usr/lib64"),
        cmd_args(value.prefix, format = "-L{}/usr/lib"),
        cmd_args(value.prefix, format = "-Wl,-rpath-link,{}/usr/lib64"),
        cmd_args(value.prefix, format = "-Wl,-rpath-link,{}/usr/lib"),
    ]
    for f in value.ldflags:
        args.append(cmd_args(f))
    return args

def _link_libs_projection(value):
    """Project -l flags for declared libraries."""
    return [cmd_args("-l" + name) for name in value.libraries]

def _path_bin_dirs_projection(value):
    """Project bin directories."""
    return [
        cmd_args(value.prefix, format = "{}/usr/bin"),
        cmd_args(value.prefix, format = "{}/usr/sbin"),
    ]

def _path_lib_dirs_projection(value):
    """Project lib directories (for LD_LIBRARY_PATH)."""
    return [
        cmd_args(value.prefix, format = "{}/usr/lib64"),
        cmd_args(value.prefix, format = "{}/usr/lib"),
    ]

def _path_cmake_prefix_projection(value):
    """Project cmake prefix paths."""
    return [cmd_args(value.prefix, format = "{}/usr")]

def _runtime_prefixes_projection(value):
    """Project prefix artifacts for rootfs assembly."""
    return [value.prefix]

def _runtime_manifest_projection(value):
    """Project name:version strings for auditing/SBOM."""
    return [cmd_args("{}={}".format(value.name, value.version))]

# ── Tset definitions ─────────────────────────────────────────────────

CompileInfoTSet = transitive_set(
    args_projections = {
        "cflags": _compile_cflags_projection,
        "pkg_config_paths": _compile_pkg_config_projection,
    },
)

LinkInfoTSet = transitive_set(
    args_projections = {
        "ldflags": _link_ldflags_projection,
        "libs": _link_libs_projection,
    },
)

PathInfoTSet = transitive_set(
    args_projections = {
        "bin_dirs": _path_bin_dirs_projection,
        "lib_dirs": _path_lib_dirs_projection,
        "cmake_prefix_paths": _path_cmake_prefix_projection,
    },
)

RuntimeDepTSet = transitive_set(
    args_projections = {
        "prefixes": _runtime_prefixes_projection,
        "manifest": _runtime_manifest_projection,
    },
)
