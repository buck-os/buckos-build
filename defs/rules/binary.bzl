"""
binary_package rule: custom install script for pre-built packages.

Four discrete cacheable actions:

1. src_unpack   — obtain source artifact from source dep
2. src_prepare  — apply patches + pre_configure_cmds (zero-cost passthrough when none)
3. install      — run install_script in a shell with $SRC and $OUT set
"""

load("//defs:providers.bzl", "BuildToolchainInfo", "PackageInfo")
load("//defs:toolchain_helpers.bzl", "TOOLCHAIN_ATTRS", "toolchain_env_args",
     "toolchain_extra_cflags", "toolchain_extra_ldflags")

# ── Phase helpers ─────────────────────────────────────────────────────

def _src_prepare(ctx, source):
    """Apply patches and pre_configure_cmds.

    Separate action so unpatched source stays cached.
    Uses patch_helper.py which copies source first (no artifact corruption).
    """
    if not ctx.attrs.patches and not ctx.attrs.pre_configure_cmds:
        return source  # No patches or cmds — zero-cost passthrough

    output = ctx.actions.declare_output("prepared", dir = True)
    cmd = cmd_args(ctx.attrs._patch_tool[RunInfo])
    cmd.add("--source-dir", source)
    cmd.add("--output-dir", output.as_output())
    for p in ctx.attrs.patches:
        cmd.add("--patch", p)
    for c in ctx.attrs.pre_configure_cmds:
        cmd.add("--cmd", c)

    # Pass dep base dirs so pre_configure_cmds can locate dep sources
    env = {}
    dep_base_dirs = []
    for dep in ctx.attrs.deps:
        if PackageInfo in dep:
            dep_base_dirs.append(dep[PackageInfo].prefix)
        else:
            dep_base_dirs.append(dep[DefaultInfo].default_outputs[0])
    if dep_base_dirs:
        env["DEP_BASE_DIRS"] = cmd_args(dep_base_dirs, delimiter = ":")

    ctx.actions.run(cmd, env = env, category = "prepare", identifier = ctx.attrs.name)
    return output

def _dep_env_args(ctx):
    """Build environment variables and PATH dirs from deps.

    Returns (env dict entries, dep_bin_paths list).
    Models on autotools' _dep_env_args() for consistent dep propagation.
    """
    pkg_config_paths = []
    path_dirs = []
    lib_dirs = []
    dep_base_dirs = []
    cflags = list(toolchain_extra_cflags(ctx)) + list(ctx.attrs.extra_cflags)
    ldflags = list(toolchain_extra_ldflags(ctx)) + list(ctx.attrs.extra_ldflags)

    for dep in ctx.attrs.deps:
        if PackageInfo in dep:
            prefix = dep[PackageInfo].prefix
            for f in dep[PackageInfo].cflags:
                cflags.append(f)
            for f in dep[PackageInfo].ldflags:
                ldflags.append(f)
        else:
            prefix = dep[DefaultInfo].default_outputs[0]
        dep_base_dirs.append(prefix)
        cflags.append(cmd_args(prefix, format = "-I{}/usr/include"))
        ldflags.append(cmd_args(prefix, format = "-L{}/usr/lib64"))
        ldflags.append(cmd_args(prefix, format = "-L{}/usr/lib"))
        lib_dirs.append(cmd_args(prefix, format = "{}/usr/lib64"))
        lib_dirs.append(cmd_args(prefix, format = "{}/usr/lib"))
        ldflags.append(cmd_args(prefix, format = "-Wl,-rpath-link,{}/usr/lib64"))
        ldflags.append(cmd_args(prefix, format = "-Wl,-rpath-link,{}/usr/lib"))
        pkg_config_paths.append(cmd_args(prefix, format = "{}/usr/lib64/pkgconfig"))
        pkg_config_paths.append(cmd_args(prefix, format = "{}/usr/lib/pkgconfig"))
        pkg_config_paths.append(cmd_args(prefix, format = "{}/usr/share/pkgconfig"))
        path_dirs.append(cmd_args(prefix, format = "{}/usr/bin"))
        path_dirs.append(cmd_args(prefix, format = "{}/usr/sbin"))
        # Bootstrap packages use /tools prefix
        cflags.append(cmd_args(prefix, format = "-I{}/tools/include"))
        ldflags.append(cmd_args(prefix, format = "-L{}/tools/lib64"))
        ldflags.append(cmd_args(prefix, format = "-L{}/tools/lib"))
        lib_dirs.append(cmd_args(prefix, format = "{}/tools/lib64"))
        lib_dirs.append(cmd_args(prefix, format = "{}/tools/lib"))
        ldflags.append(cmd_args(prefix, format = "-Wl,-rpath-link,{}/tools/lib64"))
        ldflags.append(cmd_args(prefix, format = "-Wl,-rpath-link,{}/tools/lib"))
        pkg_config_paths.append(cmd_args(prefix, format = "{}/tools/lib64/pkgconfig"))
        pkg_config_paths.append(cmd_args(prefix, format = "{}/tools/lib/pkgconfig"))
        path_dirs.append(cmd_args(prefix, format = "{}/tools/bin"))
        path_dirs.append(cmd_args(prefix, format = "{}/tools/sbin"))

    env = {}
    if pkg_config_paths:
        env["PKG_CONFIG_PATH"] = cmd_args(pkg_config_paths, delimiter = ":")
    if cflags:
        env["CFLAGS"] = cmd_args(cflags, delimiter = " ")
    if ldflags:
        env["LDFLAGS"] = cmd_args(ldflags, delimiter = " ")
    if dep_base_dirs:
        env["DEP_BASE_DIRS"] = cmd_args(dep_base_dirs, delimiter = ":")
    if lib_dirs:
        env["LD_LIBRARY_PATH"] = cmd_args(lib_dirs, delimiter = ":")

    return env, path_dirs

def _install(ctx, source):
    """Run install_script with SRC pointing to source and OUT to output prefix."""
    output = ctx.actions.declare_output("installed", dir = True)

    # Write a wrapper that sets SRCS/OUT from positional args then sources
    # the user script.  This ensures output.as_output() appears in cmd_args
    # so Buck2 can track the declared output.
    wrapper = ctx.actions.write("wrapper.sh", """\
#!/bin/bash
set -e
# Save project root — Buck2 runs actions from here, all artifact paths
# (buck-out/v2/...) are relative to this directory.
_PROJECT_ROOT="$PWD"

# Resolve a single path to absolute (relative to project root).
_resolve() { [[ "$1" = /* ]] && echo "$1" || echo "$_PROJECT_ROOT/$1"; }

# Resolve relative buck-out paths in compiler/linker flag strings to absolute.
# Without this, libtool and other tools fail after cd into the source tree.
_resolve_flag_paths() {
    local result=""
    for token in $1; do
        case "$token" in
            -I[^/]*)             token="-I${_PROJECT_ROOT}/${token#-I}" ;;
            -L[^/]*)             token="-L${_PROJECT_ROOT}/${token#-L}" ;;
            -Wl,-rpath-link,[^/]*) token="-Wl,-rpath-link,${_PROJECT_ROOT}/${token#-Wl,-rpath-link,}" ;;
            -Wl,-rpath,[^/]*)    token="-Wl,-rpath,${_PROJECT_ROOT}/${token#-Wl,-rpath,}" ;;
            [^-]*/*)             [[ ! "$token" = /* ]] && token="${_PROJECT_ROOT}/$token" ;;
        esac
        result="${result:+$result }$token"
    done
    echo "$result"
}

# Resolve relative paths in colon-separated lists (PKG_CONFIG_PATH etc).
_resolve_colon_paths() {
    local IFS=':' result=""
    for p in $1; do
        [[ -n "$p" && "$p" != /* ]] && p="${_PROJECT_ROOT}/$p"
        result="${result:+$result:}$p"
    done
    echo "$result"
}

export SRCS="$(_resolve "$1")"; shift
export OUT="$(_resolve "$1")"; shift
export PV="$1"; shift

# Standard build env vars available to install_script
export DESTDIR="$OUT"
export S="$SRCS"
export WORKDIR="$(_resolve "${BUCK_SCRATCH_PATH:-$(mktemp -d)}")"
export MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"
export MAKEOPTS="${MAKEOPTS:-$(nproc)}"

# Disable host compiler/build caches — Buck2 caches actions itself.
unset RUSTC_WRAPPER 2>/dev/null || true
export CARGO_BUILD_RUSTC_WRAPPER=""
export CCACHE_DISABLE=1

# Resolve install script to absolute before cd
_INSTALL_SCRIPT="$(_resolve "$1")"

# Resolve env vars containing relative buck-out paths to absolute
# so they survive cd into the source tree.
[[ -n "${CC:-}" ]]              && export CC="$(_resolve_flag_paths "$CC")"
[[ -n "${CXX:-}" ]]             && export CXX="$(_resolve_flag_paths "$CXX")"
[[ -n "${AR:-}" ]]              && export AR="$(_resolve_flag_paths "$AR")"
[[ -n "${CFLAGS:-}" ]]          && export CFLAGS="$(_resolve_flag_paths "$CFLAGS")"
[[ -n "${LDFLAGS:-}" ]]         && export LDFLAGS="$(_resolve_flag_paths "$LDFLAGS")"
[[ -n "${CPPFLAGS:-}" ]]        && export CPPFLAGS="$(_resolve_flag_paths "$CPPFLAGS")"
[[ -n "${PKG_CONFIG_PATH:-}" ]] && export PKG_CONFIG_PATH="$(_resolve_colon_paths "$PKG_CONFIG_PATH")"
[[ -n "${_DEP_BIN_PATHS:-}" ]]  && export _DEP_BIN_PATHS="$(_resolve_colon_paths "$_DEP_BIN_PATHS")"
[[ -n "${DEP_BASE_DIRS:-}" ]]   && export DEP_BASE_DIRS="$(_resolve_colon_paths "$DEP_BASE_DIRS")"
[[ -n "${LD_LIBRARY_PATH:-}" ]] && export LD_LIBRARY_PATH="$(_resolve_colon_paths "$LD_LIBRARY_PATH")"

# Prepend dep bin paths to PATH
[[ -n "${_DEP_BIN_PATHS:-}" ]] && export PATH="$_DEP_BIN_PATHS:$PATH"

# Copy source to writable directory — Buck2 source artifacts are read-only,
# but install scripts need to write (mkdir build, in-source builds, etc.).
# This mirrors what configure_helper.py / build_helper.py do for autotools.
if [[ -d "$SRCS" ]]; then
    mkdir -p "$WORKDIR"
    _WRITABLE="${WORKDIR}/src"
    _SRCS_REAL="$(realpath "$SRCS")"
    _WRITABLE_REAL="$(realpath "$_WRITABLE" 2>/dev/null || echo "$_WRITABLE")"
    if [[ "$_SRCS_REAL" != "$_WRITABLE_REAL" ]]; then
        cp -a "$SRCS/." "$_WRITABLE"
        chmod -R u+w "$_WRITABLE"
        # Restore execute bits on autotools scripts (Buck2 artifacts may strip them)
        find "$_WRITABLE" -type f \\( -name 'configure' -o -name 'config.guess' -o -name 'config.sub' -o -name 'install-sh' -o -name 'depcomp' -o -name 'missing' -o -name 'compile' -o -name 'ltmain.sh' -o -name 'mkinstalldirs' -o -name 'config.status' \\) -exec chmod +x {} + 2>/dev/null || true
        # Touch autotools-generated files so make doesn't try to regenerate
        # them (Buck2 normalises timestamps, making sources look newer).
        find "$_WRITABLE" -type f \\( -name 'configure' -o -name 'configure.sh' -o -name 'aclocal.m4' -o -name 'config.h.in' -o -name 'Makefile.in' -o -name '*.info' -o -name '*.1' \\) -exec touch {} + 2>/dev/null || true
    fi
    export SRCS="$_WRITABLE"
    export S="$_WRITABLE"
    cd "$_WRITABLE"
elif [[ -f "$SRCS" ]]; then
    cd "$(dirname "$SRCS")"
fi
source "$_INSTALL_SCRIPT"
""", is_executable = True)

    script = ctx.actions.write("install.sh", ctx.attrs.install_script, is_executable = True)

    cmd = cmd_args("bash", "-e", wrapper, source, output.as_output(), ctx.attrs.version, script)

    env = {}

    # Inject toolchain CC/CXX/AR directly from BuildToolchainInfo
    tc = ctx.attrs._toolchain[BuildToolchainInfo]
    env["CC"] = cmd_args(tc.cc.args, delimiter = " ")
    env["CXX"] = cmd_args(tc.cxx.args, delimiter = " ")
    env["AR"] = cmd_args(tc.ar.args, delimiter = " ")

    # Inject dep environment (CFLAGS, LDFLAGS, PKG_CONFIG_PATH, PATH)
    dep_env, dep_paths = _dep_env_args(ctx)
    for key, value in dep_env.items():
        env[key] = value
    if dep_paths:
        env["_DEP_BIN_PATHS"] = cmd_args(dep_paths, delimiter = ":")

    # Inject user-specified environment variables (last — overrides everything)
    for key, value in ctx.attrs.env.items():
        env[key] = value

    ctx.actions.run(
        cmd,
        env = env,
        category = "install",
        identifier = ctx.attrs.name,
    )
    return output

# ── Rule implementation ───────────────────────────────────────────────

def _binary_package_impl(ctx):
    # Phase 1: src_unpack — obtain source from dep
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]

    # Phase 2: src_prepare — apply patches + pre_configure_cmds
    prepared = _src_prepare(ctx, source)

    # Phase 3: install
    installed = _install(ctx, prepared)

    pkg_info = PackageInfo(
        name = ctx.attrs.name,
        version = ctx.attrs.version,
        prefix = installed,
        include_dirs = [],
        lib_dirs = [],
        bin_dirs = [],
        libraries = [],
        pkg_config_path = None,
        cflags = [],
        ldflags = [],
        license = ctx.attrs.license,
        src_uri = ctx.attrs.src_uri,
        src_sha256 = ctx.attrs.src_sha256,
        homepage = ctx.attrs.homepage,
        supplier = "Organization: BuckOS",
        description = ctx.attrs.description,
        cpe = ctx.attrs.cpe,
    )

    return [DefaultInfo(default_output = installed), pkg_info]

# ── Rule definition ───────────────────────────────────────────────────

binary_package = rule(
    impl = _binary_package_impl,
    attrs = {
        # Source and identity
        "source": attrs.dep(),
        "version": attrs.string(),

        # Build configuration
        "install_script": attrs.string(default = "cp -a \"$SRCS\"/. \"$OUT/\""),
        "pre_configure_cmds": attrs.list(attrs.string(), default = []),
        "env": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "deps": attrs.list(attrs.dep(), default = []),
        "patches": attrs.list(attrs.source(), default = []),

        # Unused by binary but accepted by the package() macro interface
        "configure_args": attrs.list(attrs.string(), default = []),
        "extra_cflags": attrs.list(attrs.string(), default = []),
        "extra_ldflags": attrs.list(attrs.string(), default = []),
        "libraries": attrs.list(attrs.string(), default = []),
        "post_install_cmds": attrs.list(attrs.string(), default = []),

        # Labels (metadata-only, for BXL queries)
        "labels": attrs.list(attrs.string(), default = []),

        # SBOM metadata
        "license": attrs.string(default = "UNKNOWN"),
        "src_uri": attrs.string(default = ""),
        "src_sha256": attrs.string(default = ""),
        "homepage": attrs.option(attrs.string(), default = None),
        "description": attrs.string(default = ""),
        "cpe": attrs.option(attrs.string(), default = None),

        # Tool deps (hidden — resolved automatically)
        "_patch_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:patch_helper"),
        ),
    } | TOOLCHAIN_ATTRS,
)
