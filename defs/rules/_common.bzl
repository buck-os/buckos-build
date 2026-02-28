"""Shared helpers for package rules."""

load("//defs:providers.bzl", "PackageInfo")
load("//defs:tsets.bzl",
     "CompileInfoTSet", "CompileInfoValue",
     "LinkInfoTSet", "LinkInfoValue",
     "PathInfoTSet", "PathInfoValue",
     "RuntimeDepTSet", "RuntimeDepValue",
)

def collect_runtime_lib_dirs(deps, installed):
    """Collect lib dirs from installed prefix and all deps (transitive).

    Deprecated: use tsets instead.  Kept for bootstrap rule compat.
    """
    dirs = []
    for dep in deps:
        if PackageInfo in dep:
            dirs.extend(dep[PackageInfo].runtime_lib_dirs)
    dirs.append(cmd_args(installed, format = "{}/usr/lib64"))
    dirs.append(cmd_args(installed, format = "{}/usr/lib"))
    return dirs

# ── Tset construction ────────────────────────────────────────────────

def build_package_tsets(ctx, installed):
    """Build transitive sets from deps and this package's installed prefix.

    Collects tset children from ctx.attrs.deps (compile + link + path + runtime)
    and ctx.attrs.runtime_deps (runtime only).  Does NOT collect from
    ctx.attrs.host_deps (build-only, no tset propagation).

    Returns (compile_tset, link_tset, path_tset, runtime_tset).
    """
    # Collect children from deps (build+runtime)
    compile_children = []
    link_children = []
    path_children = []
    runtime_children = []
    for dep in ctx.attrs.deps:
        if PackageInfo in dep:
            pkg = dep[PackageInfo]
            if pkg.compile_info:
                compile_children.append(pkg.compile_info)
            if pkg.link_info:
                link_children.append(pkg.link_info)
            if pkg.path_info:
                path_children.append(pkg.path_info)
            if pkg.runtime_deps:
                runtime_children.append(pkg.runtime_deps)

    # Collect runtime-only children from runtime_deps
    if hasattr(ctx.attrs, "runtime_deps"):
        for dep in ctx.attrs.runtime_deps:
            if PackageInfo in dep:
                pkg = dep[PackageInfo]
                if pkg.runtime_deps:
                    runtime_children.append(pkg.runtime_deps)

    # Create this package's own tset nodes
    compile_tset = ctx.actions.tset(
        CompileInfoTSet,
        value = CompileInfoValue(
            prefix = installed,
            cflags = list(getattr(ctx.attrs, "extra_cflags", [])),
        ),
        children = compile_children,
    )
    link_tset = ctx.actions.tset(
        LinkInfoTSet,
        value = LinkInfoValue(
            prefix = installed,
            ldflags = list(getattr(ctx.attrs, "extra_ldflags", [])),
            libraries = list(getattr(ctx.attrs, "libraries", [])),
        ),
        children = link_children,
    )
    path_tset = ctx.actions.tset(
        PathInfoTSet,
        value = PathInfoValue(prefix = installed),
        children = path_children,
    )
    runtime_tset = ctx.actions.tset(
        RuntimeDepTSet,
        value = RuntimeDepValue(
            name = ctx.attrs.name,
            version = ctx.attrs.version,
            prefix = installed,
        ),
        children = runtime_children,
    )

    return compile_tset, link_tset, path_tset, runtime_tset

# ── Dep-only tset collection ────────────────────────────────────────
#
# collect_dep_tsets gathers tset children from ctx.attrs.deps for use
# in build phases.  Unlike build_package_tsets, these do NOT include
# this package's own prefix — only dep contributions.

def collect_dep_tsets(ctx):
    """Collect dep-only tsets (no value for this package).

    Returns (compile_tset, link_tset, path_tset) for use in build phases.
    These contain only flag contributions from deps, not this package.
    Returns None for any tset type with no contributing deps.
    """
    compile_children = []
    link_children = []
    path_children = []
    for dep in ctx.attrs.deps:
        if PackageInfo in dep:
            pkg = dep[PackageInfo]
            if pkg.compile_info:
                compile_children.append(pkg.compile_info)
            if pkg.link_info:
                link_children.append(pkg.link_info)
            if pkg.path_info:
                path_children.append(pkg.path_info)

    if not compile_children and not link_children and not path_children:
        return None, None, None

    compile_tset = ctx.actions.tset(CompileInfoTSet, children = compile_children) if compile_children else None
    link_tset = ctx.actions.tset(LinkInfoTSet, children = link_children) if link_children else None
    path_tset = ctx.actions.tset(PathInfoTSet, children = path_children) if path_children else None

    return compile_tset, link_tset, path_tset

# ── Flag file writers ────────────────────────────────────────────────
#
# These write tset projections to files via ctx.actions.write with
# allow_args=True.  That call returns (artifact, hidden_artifacts);
# each writer unpacks and returns the same pair.  Callers must add
# the hidden list to their run command so Buck2 materializes the
# artifacts whose paths are embedded in the file.
#
# Use add_flag_file(cmd, flag, result) to add a writer result to a
# command — it handles None and unpacks the tuple automatically.

def _write_tset_file(ctx, filename, projection):
    artifact, hidden = ctx.actions.write(
        filename,
        projection,
        allow_args = True,
    )
    return artifact, hidden

def write_compile_flags(ctx, compile_tset):
    """Write cflags (one per line) from compile tset projection."""
    if not compile_tset:
        return None
    return _write_tset_file(ctx, "tset_cflags.txt", compile_tset.project_as_args("cflags"))

def write_link_flags(ctx, link_tset):
    """Write ldflags (one per line) from link tset projection."""
    if not link_tset:
        return None
    return _write_tset_file(ctx, "tset_ldflags.txt", link_tset.project_as_args("ldflags"))

def write_pkg_config_paths(ctx, compile_tset):
    """Write pkg-config paths (one per line) from compile tset projection."""
    if not compile_tset:
        return None
    return _write_tset_file(ctx, "tset_pkg_config_paths.txt", compile_tset.project_as_args("pkg_config_paths"))

def write_bin_dirs(ctx, path_tset):
    """Write bin directories (one per line) from path tset projection."""
    if not path_tset:
        return None
    return _write_tset_file(ctx, "tset_bin_dirs.txt", path_tset.project_as_args("bin_dirs"))

def write_lib_dirs(ctx, path_tset):
    """Write lib directories (one per line) from path tset projection."""
    if not path_tset:
        return None
    return _write_tset_file(ctx, "tset_lib_dirs.txt", path_tset.project_as_args("lib_dirs"))

def write_cmake_prefix_paths(ctx, path_tset):
    """Write cmake prefix paths (one per line) from path tset projection."""
    if not path_tset:
        return None
    return _write_tset_file(ctx, "tset_cmake_prefix_paths.txt", path_tset.project_as_args("cmake_prefix_paths"))

def write_link_libs(ctx, link_tset):
    """Write -l flags (one per line) from link tset projection."""
    if not link_tset:
        return None
    return _write_tset_file(ctx, "tset_libs.txt", link_tset.project_as_args("libs"))

def write_runtime_prefixes(ctx, runtime_tset):
    """Write prefix paths (one per line) from runtime tset projection."""
    if not runtime_tset:
        return None
    return _write_tset_file(ctx, "tset_runtime_prefixes.txt", runtime_tset.project_as_args("prefixes"))

def add_flag_file(cmd, flag_name, writer_result):
    """Add a flag-file argument to cmd, handling None and hidden deps.

    writer_result is either None or (artifact, hidden_list) from a write_* helper.
    """
    if not writer_result:
        return
    artifact, hidden = writer_result
    cmd.add(flag_name, artifact)
    cmd.add(cmd_args(hidden = hidden))
