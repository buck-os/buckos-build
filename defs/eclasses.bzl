"""
Eclass inheritance system for BuckOs packages.

This module provides an eclass-like inheritance mechanism similar to Gentoo's
ebuild system, allowing code reuse and standardized build patterns.

Example usage:
    load("//defs:eclasses.bzl", "inherit", "ECLASSES")

    # Get combined configuration from multiple eclasses
    config = inherit(["cmake", "python-single-r1"])

    ebuild_package(
        name = "my-package",
        source = ":my-package-src",
        version = "1.0.0",
        src_configure = config["src_configure"],
        src_compile = config["src_compile"],
        src_install = config["src_install"],
        bdepend = config["bdepend"],
        ...
    )
"""

# =============================================================================
# ECLASS DEFINITIONS
# =============================================================================

# -----------------------------------------------------------------------------
# CMake Eclass
# -----------------------------------------------------------------------------

_CMAKE_ECLASS = {
    "name": "cmake",
    "description": "Support for cmake-based packages",
    "src_configure": '''
mkdir -p "$S/build"
# Build CMAKE_PREFIX_PATH from environment variable (set by ebuild.sh)
CMAKE_PREFIX_PATH_ARG=""
if [ -n "${CMAKE_PREFIX_PATH:-}" ]; then
    CMAKE_PREFIX_PATH_ARG="-DCMAKE_PREFIX_PATH=$CMAKE_PREFIX_PATH"
fi

# Build -rpath-link flags from LIBRARY_PATH for transitive dependency resolution
# This helps the linker find shared libraries that other shared libraries depend on
RPATH_LINK_FLAGS=""
if [ -n "${LIBRARY_PATH:-}" ]; then
    # LIBRARY_PATH is colon-separated; convert to -Wl,-rpath-link flags
    OLD_IFS="$IFS"
    IFS=":"
    for libdir in $LIBRARY_PATH; do
        if [ -d "$libdir" ]; then
            RPATH_LINK_FLAGS="${RPATH_LINK_FLAGS:+$RPATH_LINK_FLAGS }-Wl,-rpath-link,$libdir"
        fi
    done
    IFS="$OLD_IFS"
fi

# Also add -L flags for the linker to find libraries
LINK_DIR_FLAGS=""
if [ -n "${LIBRARY_PATH:-}" ]; then
    OLD_IFS="$IFS"
    IFS=":"
    for libdir in $LIBRARY_PATH; do
        if [ -d "$libdir" ]; then
            LINK_DIR_FLAGS="${LINK_DIR_FLAGS:+$LINK_DIR_FLAGS }-L$libdir"
        fi
    done
    IFS="$OLD_IFS"
fi

# Combine existing LDFLAGS with rpath-link and library path flags
CMAKE_LINKER_FLAGS="${LDFLAGS:-} ${RPATH_LINK_FLAGS:-} ${LINK_DIR_FLAGS:-}"

cmake \\
    -S "$S" \\
    -B "$S/build" \\
    -DCMAKE_INSTALL_PREFIX="${EPREFIX:-/usr}" \\
    -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}" \\
    -DCMAKE_INSTALL_LIBDIR="${LIBDIR:-lib64}" \\
    -DCMAKE_C_FLAGS="${CFLAGS:-}" \\
    -DCMAKE_CXX_FLAGS="${CXXFLAGS:-}" \\
    -DCMAKE_EXE_LINKER_FLAGS="${CMAKE_LINKER_FLAGS:-}" \\
    -DCMAKE_SHARED_LINKER_FLAGS="${CMAKE_LINKER_FLAGS:-}" \\
    -DCMAKE_MODULE_LINKER_FLAGS="${CMAKE_LINKER_FLAGS:-}" \\
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \\
    $CMAKE_PREFIX_PATH_ARG \\
    ${CMAKE_EXTRA_ARGS:-}
''',
    "src_compile": '''
cmake --build "$S/build" -j${MAKEOPTS:-$(nproc)}
''',
    "src_install": '''
DESTDIR="$DESTDIR" cmake --install "$S/build"
''',
    "src_test": '''
cd "$S/build"
ctest --output-on-failure
''',
    "exec_bdepend": ["//packages/linux/dev-tools/build-systems/cmake:cmake", "//packages/linux/dev-tools/build-systems/ninja:ninja"],
    "exports": ["cmake-utils_src_configure", "cmake-utils_src_compile", "cmake-utils_src_install"],
}

# -----------------------------------------------------------------------------
# Meson Eclass
# -----------------------------------------------------------------------------

_MESON_ECLASS = {
    "name": "meson",
    "description": "Support for meson-based packages",
    "src_configure": '''
# Wipe build directory first to ensure clean configuration
# This must happen BEFORE generating cross-file
if [ -d "${BUILD_DIR:-build}" ]; then
    echo "Build directory exists, wiping for clean reconfiguration..."
    rm -rf "${BUILD_DIR:-build}"
fi

# Generate meson cross-file when cross-compiling
MESON_CROSS_FILE=""
if [ "${CROSS_COMPILING:-false}" = "true" ] && [ -n "${CC:-}" ]; then
    MESON_CROSS_FILE="${BUILD_DIR:-build}/cross-file.ini"
    mkdir -p "${BUILD_DIR:-build}"

    # Build c_args and cpp_args from CFLAGS/CXXFLAGS
    # Split CFLAGS into array for proper meson format
    MESON_C_ARGS=""
    for flag in ${CFLAGS:-}; do
        if [ -n "$MESON_C_ARGS" ]; then
            MESON_C_ARGS="${MESON_C_ARGS}, '${flag}'"
        else
            MESON_C_ARGS="'${flag}'"
        fi
    done

    MESON_CXX_ARGS=""
    for flag in ${CXXFLAGS:-}; do
        if [ -n "$MESON_CXX_ARGS" ]; then
            MESON_CXX_ARGS="${MESON_CXX_ARGS}, '${flag}'"
        else
            MESON_CXX_ARGS="'${flag}'"
        fi
    done

    MESON_LINK_ARGS=""
    for flag in ${LDFLAGS:-}; do
        if [ -n "$MESON_LINK_ARGS" ]; then
            MESON_LINK_ARGS="${MESON_LINK_ARGS}, '${flag}'"
        else
            MESON_LINK_ARGS="'${flag}'"
        fi
    done

    # Detect target architecture from CHOST or compiler
    MESON_CPU_FAMILY="x86_64"
    MESON_CPU="x86_64"
    MESON_ENDIAN="little"

    TARGET_ARCH="${CHOST:-$(${CC:-gcc} -dumpmachine)}"
    case "$TARGET_ARCH" in
        aarch64*|arm64*)
            MESON_CPU_FAMILY="aarch64"
            MESON_CPU="aarch64"
            ;;
        x86_64*|amd64*)
            MESON_CPU_FAMILY="x86_64"
            MESON_CPU="x86_64"
            ;;
        arm*)
            MESON_CPU_FAMILY="arm"
            MESON_CPU="arm"
            ;;
        riscv64*)
            MESON_CPU_FAMILY="riscv64"
            MESON_CPU="riscv64"
            ;;
    esac

    # Build pkg_config_libdir array from PKG_CONFIG_LIBDIR (colon-separated)
    MESON_PKG_CONFIG_LIBDIR=""
    if [ -n "${PKG_CONFIG_LIBDIR:-}" ]; then
        for pc_dir in ${PKG_CONFIG_LIBDIR//:/ }; do
            if [ -n "$MESON_PKG_CONFIG_LIBDIR" ]; then
                MESON_PKG_CONFIG_LIBDIR="${MESON_PKG_CONFIG_LIBDIR}, '${pc_dir}'"
            else
                MESON_PKG_CONFIG_LIBDIR="'${pc_dir}'"
            fi
        done
    fi

    cat > "$MESON_CROSS_FILE" << CROSSEOF
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '${AR:-ar}'
strip = '${STRIP:-strip}'
pkg-config = 'pkg-config'

[properties]
pkg_config_libdir = [${MESON_PKG_CONFIG_LIBDIR}]
sys_root = '${SYSROOT:-}'

[built-in options]
c_args = [${MESON_C_ARGS}]
cpp_args = [${MESON_CXX_ARGS}]
c_link_args = [${MESON_LINK_ARGS}]
cpp_link_args = [${MESON_LINK_ARGS}]

[host_machine]
system = 'linux'
cpu_family = '$MESON_CPU_FAMILY'
cpu = '$MESON_CPU'
endian = '$MESON_ENDIAN'
CROSSEOF
    echo "Generated meson cross-file: $MESON_CROSS_FILE"
    cat "$MESON_CROSS_FILE"
fi

# Build meson command with optional cross-file
MESON_CMD="meson setup \\"${BUILD_DIR:-build}\\" --prefix=\\"\${EPREFIX:-/usr}\\" --libdir=\\"\${LIBDIR:-lib64}\\" --buildtype=\\"\${MESON_BUILD_TYPE:-release}\\""
if [ -n "$MESON_CROSS_FILE" ]; then
    MESON_CMD="$MESON_CMD --cross-file=\\"$MESON_CROSS_FILE\\""
fi
MESON_CMD="$MESON_CMD \${MESON_EXTRA_ARGS:-}"

eval $MESON_CMD
''',
    "src_compile": '''
meson compile -C "${BUILD_DIR:-build}" -j${MAKEOPTS:-$(nproc)}
''',
    "src_install": '''
DESTDIR="$DESTDIR" meson install -C "${BUILD_DIR:-build}"
''',
    "src_test": '''
meson test -C "${BUILD_DIR:-build}" --print-errorlogs
''',
    "exec_bdepend": ["//packages/linux/dev-tools/build-systems/meson:meson", "//packages/linux/dev-tools/build-systems/ninja:ninja"],
    "exports": ["meson_src_configure", "meson_src_compile", "meson_src_install"],
}

# -----------------------------------------------------------------------------
# Autotools Eclass
# -----------------------------------------------------------------------------

_AUTOTOOLS_ECLASS = {
    "name": "autotools",
    "description": "Support for autotools-based packages",
    "src_prepare": '''
# Run autoreconf if needed
if [ -f configure.ac ] || [ -f configure.in ]; then
    if [ ! -f configure ] || [ configure.ac -nt configure ] 2>/dev/null; then
        # Create a dummy autopoint if not available (gettext not installed)
        # autopoint is only needed for i18n, and many packages don't actually need it
        if ! command -v autopoint >/dev/null 2>&1; then
            mkdir -p "$T/bin"
            cat > "$T/bin/autopoint" << 'AUTOPOINT_STUB'
#!/bin/sh
# Stub autopoint - gettext not available
# This allows autoreconf to complete for packages that don't need i18n
echo "autopoint: stub (gettext not installed, skipping)"
exit 0
AUTOPOINT_STUB
            chmod +x "$T/bin/autopoint"
            export PATH="$T/bin:$PATH"
        fi
        autoreconf -fiv
    fi
fi
''',
    "src_configure": '''
ECONF_SOURCE="${ECONF_SOURCE:-.}"
"$ECONF_SOURCE/configure" \\
    --prefix="${EPREFIX:-/usr}" \\
    --build="${CBUILD:-$(gcc -dumpmachine)}" \\
    --host="${CHOST:-$(gcc -dumpmachine)}" \\
    --mandir="${EPREFIX:-/usr}/share/man" \\
    --infodir="${EPREFIX:-/usr}/share/info" \\
    --datadir="${EPREFIX:-/usr}/share" \\
    --sysconfdir="${EPREFIX:-/etc}" \\
    --localstatedir="${EPREFIX:-/var}" \\
    --libdir="${EPREFIX:-/usr}/${LIBDIR:-lib64}" \\
    ${EXTRA_ECONF:-}
''',
    "src_compile": '''
make -j${MAKEOPTS:-$(nproc)} ${EXTRA_EMAKE:-}
''',
    "src_install": '''
make DESTDIR="$DESTDIR" ${EXTRA_EMAKE:-} install
# Remove .la files to prevent libtool absolute path issues in cross-compilation (CLAUDE.md #8)
# Libtool .la files contain absolute paths like /usr/lib64/libfoo.so which point to host libraries
# during cross-compilation, causing "file in wrong format" linker errors
find "$DESTDIR" -name '*.la' -type f -delete 2>/dev/null || true
''',
    "src_test": '''
if make -q check 2>/dev/null; then
    make check
elif make -q test 2>/dev/null; then
    make test
fi
''',
    "exec_bdepend": ["//packages/linux/dev-tools/build-systems/autoconf:autoconf", "//packages/linux/dev-tools/build-systems/automake:automake", "//packages/linux/dev-tools/build-systems/libtool:libtool"],
    "exports": ["eautoreconf", "econf", "emake", "einstall"],
}

# -----------------------------------------------------------------------------
# Python Single-R1 Eclass
# -----------------------------------------------------------------------------

_PYTHON_SINGLE_R1_ECLASS = {
    "name": "python-single-r1",
    "description": "Support for packages that need a single Python implementation",
    "src_configure": '''
# Setup Python environment
export PYTHON="${PYTHON:-python3}"
export PYTHON_SITEDIR="$($PYTHON -c 'import site; print(site.getsitepackages()[0])')"

# Ensure setuptools and wheel are available
$PYTHON -m pip install --upgrade pip setuptools wheel 2>/dev/null || true
''',
    "src_compile": '''
# Set PYTHON variable (in case src_configure ran in a different subshell)
export PYTHON="${PYTHON:-python3}"

# Ensure setuptools and wheel are available
$PYTHON -m pip install --upgrade pip setuptools wheel 2>/dev/null || true

$PYTHON setup.py build
''',
    "src_install": '''
# Set PYTHON variable (in case earlier phases ran in different subshells)
export PYTHON="${PYTHON:-python3}"

# Ensure setuptools and wheel are available
$PYTHON -m pip install --upgrade pip setuptools wheel 2>/dev/null || true

$PYTHON setup.py install \\
    --prefix=/usr \\
    --root="$DESTDIR" \\
    --optimize=1 \\
    --skip-build
''',
    "src_test": '''
# Set PYTHON variable (in case earlier phases ran in different subshells)
export PYTHON="${PYTHON:-python3}"
$PYTHON -m pytest -v
''',
    "bdepend": [],
    "rdepend": ["//packages/linux/lang/python:python"],
    "exports": ["python_get_sitedir", "python_domodule", "python_newscript"],
}

# -----------------------------------------------------------------------------
# Python R1 Eclass (multiple implementations)
# -----------------------------------------------------------------------------

_PYTHON_R1_ECLASS = {
    "name": "python-r1",
    "description": "Support for packages compatible with multiple Python versions",
    "src_configure": '''
# Setup for multiple Python implementations
export PYTHON="${PYTHON:-python3}"
for impl in ${PYTHON_COMPAT:-python3}; do
    mkdir -p "${BUILD_DIR:-build}-$impl"
done

# Ensure setuptools and wheel are available
$PYTHON -m pip install --upgrade pip setuptools wheel 2>/dev/null || true
''',
    "src_compile": '''
# Set PYTHON variable for multi-implementation builds
export PYTHON="${PYTHON:-python3}"

# Ensure setuptools and wheel are available
$PYTHON -m pip install --upgrade pip setuptools wheel 2>/dev/null || true

for impl in ${PYTHON_COMPAT:-python3}; do
    cd "${BUILD_DIR:-build}-$impl"
    $impl ../setup.py build
done
''',
    "src_install": '''
# Set PYTHON variable for multi-implementation builds
export PYTHON="${PYTHON:-python3}"

# Ensure setuptools and wheel are available
$PYTHON -m pip install --upgrade pip setuptools wheel 2>/dev/null || true

for impl in ${PYTHON_COMPAT:-python3}; do
    cd "${BUILD_DIR:-build}-$impl"
    $impl ../setup.py install \\
        --prefix=/usr \\
        --root="$DESTDIR" \\
        --optimize=1 \\
        --skip-build
done
''',
    "bdepend": [],
    "rdepend": ["//packages/linux/lang/python:python"],
    "exports": ["python_foreach_impl", "python_setup"],
}

# -----------------------------------------------------------------------------
# Go Module Eclass
# -----------------------------------------------------------------------------

_GO_MODULE_ECLASS = {
    "name": "go-module",
    "description": "Support for Go module-based packages",
    "src_configure": '''
export GOPATH="${GOPATH:-$PWD/go}"
export GOCACHE="${GOCACHE:-$PWD/.cache/go-build}"
export CGO_ENABLED="${CGO_ENABLED:-1}"

# Check for pre-fetched modules from ebuild.sh (GOPROXY already set to off)
if [ "${GOPROXY:-}" = "off" ] && [ -n "${GOMODCACHE:-}" ]; then
    echo "Using pre-fetched Go module cache: $GOMODCACHE (GOPROXY=off)"
# Check for GOMODCACHE from go_sum_deps (set by go_package)
elif [ -n "${GOMODCACHE:-}" ] && [ -d "$GOMODCACHE/cache/download" ]; then
    export GOPROXY="off"
    echo "Using pre-downloaded Go module cache: $GOMODCACHE"
# Use vendored dependencies if available
elif [ -d vendor ]; then
    export GOFLAGS="${GOFLAGS:-} -mod=vendor"
    export GOPROXY="off"
    echo "Using vendored Go modules"
else
    export GOMODCACHE="${GOMODCACHE:-$GOPATH/pkg/mod}"
fi
''',
    "src_compile": '''
go build \\
    -v \\
    -p ${MAKEOPTS:-$(nproc)} \\
    -ldflags="-s -w ${GO_LDFLAGS:-}" \\
    -o "${BUILD_DIR:-build}/" \\
    ${GO_PACKAGES:-.}
''',
    "src_install": '''
mkdir -p "$DESTDIR/usr/bin"
find "${BUILD_DIR:-build}" -maxdepth 1 -type f -executable -exec install -m 0755 {} "$DESTDIR/usr/bin/" \;
''',
    "src_test": '''
go test -v ${GO_TEST_PACKAGES:-./...}
''',
    # Go toolchain is added dynamically by go_package based on host vs bootstrap mode
    "bdepend": [],
    "exports": ["go-module_src_compile", "go-module_src_install"],
}

# -----------------------------------------------------------------------------
# Ruby Eclass
# -----------------------------------------------------------------------------

_RUBY_ECLASS = {
    "name": "ruby",
    "description": "Support for Ruby gem packages",
    "src_configure": '''
export GEM_HOME="$DESTDIR/usr/lib/ruby/gems"
export GEM_PATH="$GEM_HOME:/usr/lib/ruby/gems"
''',
    "src_compile": '''
# Build gem from gemspec if present
if ls *.gemspec 1>/dev/null 2>&1; then
    gem build *.gemspec
fi
''',
    "src_install": '''
mkdir -p "$DESTDIR/usr/bin"
mkdir -p "$DESTDIR/usr/lib/ruby/gems"

# Install the built gem
if ls *.gem 1>/dev/null 2>&1; then
    gem install --local --install-dir "$DESTDIR/usr/lib/ruby/gems" \
        --bindir "$DESTDIR/usr/bin" \
        --no-document *.gem
fi
''',
    "src_test": '''
if [ -f Rakefile ]; then
    rake test 2>/dev/null || rake spec 2>/dev/null || true
fi
''',
    "bdepend": [],
    "rdepend": ["//packages/linux/lang/ruby:ruby"],
    "exports": ["ruby_src_compile", "ruby_src_install"],
}

# -----------------------------------------------------------------------------
# Cargo Eclass
# -----------------------------------------------------------------------------

_CARGO_ECLASS = {
    "name": "cargo",
    "description": "Support for Rust/Cargo packages",
    "src_configure": '''
export CARGO_HOME="${CARGO_HOME:-$PWD/.cargo}"
mkdir -p "$CARGO_HOME"

# Use vendored crates if available (from cargo_lock_deps or rust_vendor)
if [ -d vendor ]; then
    mkdir -p .cargo
    # Check if config.toml already exists (from cargo_lock_deps)
    if [ ! -f .cargo/config.toml ]; then
        cat > .cargo/config.toml << 'CARGO_CONFIG_EOF'
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor"

[net]
offline = true
CARGO_CONFIG_EOF
    fi
    export CARGO_NET_OFFLINE=true
    echo "Using vendored Rust crates (offline mode)"
fi
''',
    "src_compile": '''
# Unset CARGO_BUILD_RUSTC_WRAPPER to avoid sccache path length issues in buck-out
CARGO_BUILD_RUSTC_WRAPPER="" cargo build --release \\
    --jobs ${MAKEOPTS:-$(nproc)} \\
    ${CARGO_NET_OFFLINE:+--offline} \\
    ${CARGO_BUILD_FLAGS:-}
''',
    "src_install": '''
mkdir -p "$DESTDIR/usr/bin"
find target/release -maxdepth 1 -type f -executable ! -name "*.d" -exec install -m 0755 {} "$DESTDIR/usr/bin/" \;
''',
    "src_test": '''
cargo test --release ${CARGO_TEST_FLAGS:-}
''',
    # Rust toolchain is added dynamically by cargo_package based on host vs bootstrap mode
    "bdepend": [],
    "exports": ["cargo_src_configure", "cargo_src_compile", "cargo_src_install"],
}

# -----------------------------------------------------------------------------
# XDG Eclass
# -----------------------------------------------------------------------------

_XDG_ECLASS = {
    "name": "xdg",
    "description": "XDG base directory specification support",
    "src_install": '''
# Standard install phase - can be customized
''',
    "post_install": '''
# Update desktop database
if [ -d "$DESTDIR/usr/share/applications" ]; then
    update-desktop-database -q "$DESTDIR/usr/share/applications" 2>/dev/null || true
fi

# Update icon cache
if [ -d "$DESTDIR/usr/share/icons/hicolor" ]; then
    gtk-update-icon-cache -q -t -f "$DESTDIR/usr/share/icons/hicolor" 2>/dev/null || true
fi

# Update MIME database
if [ -d "$DESTDIR/usr/share/mime" ]; then
    update-mime-database "$DESTDIR/usr/share/mime" 2>/dev/null || true
fi
''',
    "rdepend": [],
    "exports": ["xdg_desktop_database_update", "xdg_icon_cache_update", "xdg_mimeinfo_database_update"],
}

# -----------------------------------------------------------------------------
# Kernel Module Eclass
# -----------------------------------------------------------------------------

_LINUX_MOD_ECLASS = {
    "name": "linux-mod",
    "description": "Support for external kernel module building",
    "src_configure": '''
# Verify kernel source availability
if [ -z "${KERNEL_DIR:-}" ]; then
    if [ -d "/lib/modules/$(uname -r)/build" ]; then
        export KERNEL_DIR="/lib/modules/$(uname -r)/build"
    elif [ -d "/usr/src/linux" ]; then
        export KERNEL_DIR="/usr/src/linux"
    else
        echo "ERROR: Cannot find kernel sources"
        exit 1
    fi
fi
export KBUILD_DIR="${KBUILD_DIR:-$KERNEL_DIR}"
''',
    "src_compile": '''
make -C "$KERNEL_DIR" M="$PWD" modules
''',
    "src_install": '''
make -C "$KERNEL_DIR" M="$PWD" INSTALL_MOD_PATH="$DESTDIR" modules_install
''',
    "bdepend": ["//packages/kernel:linux-headers"],
    "exports": ["linux-mod_src_compile", "linux-mod_src_install"],
}

# -----------------------------------------------------------------------------
# Account User Eclass
# -----------------------------------------------------------------------------

_ACCT_USER_ECLASS = {
    "name": "acct-user",
    "description": "Support for creating system user accounts",
    "src_install": '''
# Account user creation eclass
# Variables expected:
#   ACCT_USER_NAME - username to create
#   ACCT_USER_ID - numeric UID (optional, -1 for auto-assign)
#   ACCT_USER_SHELL - login shell (default: /sbin/nologin)
#   ACCT_USER_HOME - home directory (default: /dev/null)
#   ACCT_USER_GROUPS - comma-separated list of supplementary groups
#   ACCT_USER_PRIMARY_GROUP - primary group (default: same as username)

ACCT_USER_NAME="${ACCT_USER_NAME:-}"
ACCT_USER_ID="${ACCT_USER_ID:--1}"
ACCT_USER_SHELL="${ACCT_USER_SHELL:-/sbin/nologin}"
ACCT_USER_HOME="${ACCT_USER_HOME:-/dev/null}"
ACCT_USER_GROUPS="${ACCT_USER_GROUPS:-}"
ACCT_USER_PRIMARY_GROUP="${ACCT_USER_PRIMARY_GROUP:-$ACCT_USER_NAME}"

if [ -z "$ACCT_USER_NAME" ]; then
    echo "ERROR: ACCT_USER_NAME must be set"
    exit 1
fi

mkdir -p "$DESTDIR/etc"

# Create passwd entry
# Format: username:x:uid:gid:gecos:home:shell
if [ "$ACCT_USER_ID" = "-1" ]; then
    # Auto-assign UID - use a placeholder that will be resolved at install time
    # System users typically use UIDs in range 100-999
    ACCT_USER_ID="$(echo "$ACCT_USER_NAME" | cksum | cut -d' ' -f1)"
    ACCT_USER_ID=$((($ACCT_USER_ID % 899) + 100))
fi

# Write to passwd.d fragment for merging during system install
mkdir -p "$DESTDIR/usr/lib/sysusers.d"
cat > "$DESTDIR/usr/lib/sysusers.d/${ACCT_USER_NAME}.conf" << EOF
# System user: $ACCT_USER_NAME
# Created by acct-user eclass
u $ACCT_USER_NAME $ACCT_USER_ID "$ACCT_USER_NAME system user" $ACCT_USER_HOME $ACCT_USER_SHELL
EOF

# Also write traditional passwd fragment for systems without systemd-sysusers
mkdir -p "$DESTDIR/usr/share/acct-user"
cat > "$DESTDIR/usr/share/acct-user/${ACCT_USER_NAME}.passwd" << EOF
$ACCT_USER_NAME:x:$ACCT_USER_ID:$ACCT_USER_ID:$ACCT_USER_NAME system user:$ACCT_USER_HOME:$ACCT_USER_SHELL
EOF

# Write shadow entry (locked password)
cat > "$DESTDIR/usr/share/acct-user/${ACCT_USER_NAME}.shadow" << EOF
$ACCT_USER_NAME:!:0:::::
EOF

# If supplementary groups specified, write group membership
if [ -n "$ACCT_USER_GROUPS" ]; then
    echo "$ACCT_USER_GROUPS" > "$DESTDIR/usr/share/acct-user/${ACCT_USER_NAME}.groups"
fi

echo "Created system user: $ACCT_USER_NAME (uid=$ACCT_USER_ID)"
''',
    "post_install": '''
# Post-install hook to actually create the user on the system
ACCT_USER_NAME="${ACCT_USER_NAME:-}"
ACCT_USER_ID="${ACCT_USER_ID:--1}"
ACCT_USER_SHELL="${ACCT_USER_SHELL:-/sbin/nologin}"
ACCT_USER_HOME="${ACCT_USER_HOME:-/dev/null}"
ACCT_USER_PRIMARY_GROUP="${ACCT_USER_PRIMARY_GROUP:-$ACCT_USER_NAME}"

if [ -n "$ACCT_USER_NAME" ]; then
    # Check if user already exists
    if ! getent passwd "$ACCT_USER_NAME" >/dev/null 2>&1; then
        if command -v useradd >/dev/null 2>&1; then
            useradd_args="-r -s $ACCT_USER_SHELL -d $ACCT_USER_HOME"
            if [ "$ACCT_USER_ID" != "-1" ]; then
                useradd_args="$useradd_args -u $ACCT_USER_ID"
            fi
            if [ -n "$ACCT_USER_PRIMARY_GROUP" ]; then
                useradd_args="$useradd_args -g $ACCT_USER_PRIMARY_GROUP"
            fi
            useradd $useradd_args "$ACCT_USER_NAME" 2>/dev/null || true
        fi
    fi
fi
''',
    "bdepend": [],
    "rdepend": [],
    "exports": ["acct_user_create", "acct_user_home", "acct_user_shell"],
}

# -----------------------------------------------------------------------------
# Account Group Eclass
# -----------------------------------------------------------------------------

_ACCT_GROUP_ECLASS = {
    "name": "acct-group",
    "description": "Support for creating system group accounts",
    "src_install": '''
# Account group creation eclass
# Variables expected:
#   ACCT_GROUP_NAME - group name to create
#   ACCT_GROUP_ID - numeric GID (optional, -1 for auto-assign)

ACCT_GROUP_NAME="${ACCT_GROUP_NAME:-}"
ACCT_GROUP_ID="${ACCT_GROUP_ID:--1}"

if [ -z "$ACCT_GROUP_NAME" ]; then
    echo "ERROR: ACCT_GROUP_NAME must be set"
    exit 1
fi

mkdir -p "$DESTDIR/etc"

# Auto-assign GID if not specified
if [ "$ACCT_GROUP_ID" = "-1" ]; then
    # System groups typically use GIDs in range 100-999
    ACCT_GROUP_ID="$(echo "$ACCT_GROUP_NAME" | cksum | cut -d' ' -f1)"
    ACCT_GROUP_ID=$((($ACCT_GROUP_ID % 899) + 100))
fi

# Write to sysusers.d fragment for systemd-sysusers
mkdir -p "$DESTDIR/usr/lib/sysusers.d"
cat > "$DESTDIR/usr/lib/sysusers.d/${ACCT_GROUP_NAME}.conf" << EOF
# System group: $ACCT_GROUP_NAME
# Created by acct-group eclass
g $ACCT_GROUP_NAME $ACCT_GROUP_ID
EOF

# Also write traditional group fragment for systems without systemd-sysusers
mkdir -p "$DESTDIR/usr/share/acct-group"
cat > "$DESTDIR/usr/share/acct-group/${ACCT_GROUP_NAME}.group" << EOF
$ACCT_GROUP_NAME:x:$ACCT_GROUP_ID:
EOF

echo "Created system group: $ACCT_GROUP_NAME (gid=$ACCT_GROUP_ID)"
''',
    "post_install": '''
# Post-install hook to actually create the group on the system
ACCT_GROUP_NAME="${ACCT_GROUP_NAME:-}"
ACCT_GROUP_ID="${ACCT_GROUP_ID:--1}"

if [ -n "$ACCT_GROUP_NAME" ]; then
    # Check if group already exists
    if ! getent group "$ACCT_GROUP_NAME" >/dev/null 2>&1; then
        if command -v groupadd >/dev/null 2>&1; then
            groupadd_args="-r"
            if [ "$ACCT_GROUP_ID" != "-1" ]; then
                groupadd_args="$groupadd_args -g $ACCT_GROUP_ID"
            fi
            groupadd $groupadd_args "$ACCT_GROUP_NAME" 2>/dev/null || true
        fi
    fi
fi
''',
    "bdepend": [],
    "rdepend": [],
    "exports": ["acct_group_create"],
}

# -----------------------------------------------------------------------------
# Systemd Eclass
# -----------------------------------------------------------------------------

_SYSTEMD_ECLASS = {
    "name": "systemd",
    "description": "Systemd unit file installation helpers",
    "post_install": '''
# Reload systemd if running
if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
fi
''',
    "rdepend": ["//packages/sys-apps:systemd"],
    "exports": ["systemd_dounit", "systemd_newunit", "systemd_enable_service", "systemd_get_unitdir"],
}

# -----------------------------------------------------------------------------
# Perl Eclass
# -----------------------------------------------------------------------------

_PERL_ECLASS = {
    "name": "perl",
    "description": "Support for CPAN/Perl module packages",
    "src_configure": '''
# Detect build system (Makefile.PL vs Build.PL)
if [ -f Build.PL ]; then
    export PERL_BUILD_SYSTEM="build"
    perl Build.PL \\
        --installdirs=vendor \\
        --destdir="$DESTDIR" \\
        ${PERL_BUILD_ARGS:-}
elif [ -f Makefile.PL ]; then
    export PERL_BUILD_SYSTEM="makemaker"
    perl Makefile.PL \\
        INSTALLDIRS=vendor \\
        PREFIX="${EPREFIX:-/usr}" \\
        ${PERL_MAKEMAKER_ARGS:-}
else
    echo "ERROR: No Build.PL or Makefile.PL found"
    exit 1
fi
''',
    "src_compile": '''
if [ "${PERL_BUILD_SYSTEM:-makemaker}" = "build" ]; then
    ./Build
else
    make -j${MAKEOPTS:-$(nproc)}
fi
''',
    "src_install": '''
if [ "${PERL_BUILD_SYSTEM:-makemaker}" = "build" ]; then
    ./Build install --destdir="$DESTDIR"
else
    make install DESTDIR="$DESTDIR"
fi

# Remove perllocal.pod and .packlist files (not needed in packages)
find "$DESTDIR" -name perllocal.pod -delete 2>/dev/null || true
find "$DESTDIR" -name .packlist -delete 2>/dev/null || true
find "$DESTDIR" -type d -empty -delete 2>/dev/null || true
''',
    "src_test": '''
if [ "${PERL_BUILD_SYSTEM:-makemaker}" = "build" ]; then
    ./Build test
else
    make test
fi
''',
    "bdepend": ["//packages/linux/lang/perl:perl"],
    "rdepend": ["//packages/linux/lang/perl:perl"],
    "exports": ["perl_src_configure", "perl_src_compile", "perl_src_install"],
}

# -----------------------------------------------------------------------------
# NPM Eclass
# -----------------------------------------------------------------------------

_NPM_ECLASS = {
    "name": "npm",
    "description": "Support for Node.js/npm packages",
    "src_configure": '''
# Setup npm environment for offline/vendored builds
export NPM_CONFIG_CACHE="${NPM_CONFIG_CACHE:-$PWD/.npm-cache}"
export NODE_ENV="${NODE_ENV:-production}"

# Check for vendored node_modules (offline build)
if [ -d node_modules ]; then
    export NPM_OFFLINE=true
    echo "Using vendored node_modules (offline mode)"
elif [ "${NPM_OFFLINE:-}" = "true" ]; then
    echo "ERROR: NPM_OFFLINE=true but no node_modules directory found"
    echo "Please provide vendored dependencies via vendored_deps parameter"
    exit 1
else
    # Online build: run npm install
    npm install --production=${NPM_PRODUCTION:-true} ${NPM_INSTALL_ARGS:-}
fi
''',
    "src_compile": '''
# Check if build script exists in package.json
if [ -f package.json ] && grep -q '"build"' package.json; then
    npm run build ${NPM_BUILD_ARGS:-}
else
    echo "No build script found in package.json, skipping compile phase"
fi
''',
    "src_install": '''
# Create installation directories
mkdir -p "$DESTDIR/usr/lib/node_modules/${NPM_PACKAGE_NAME:-$(basename $PWD)}"
mkdir -p "$DESTDIR/usr/bin"

# Copy package files to /usr/lib/node_modules/<package-name>
# Copy all files except development-only directories
for item in *; do
    case "$item" in
        .git|.github|.gitignore|test|tests|spec|__tests__|coverage|.nyc_output)
            # Skip development/test directories
            ;;
        *)
            cp -r "$item" "$DESTDIR/usr/lib/node_modules/${NPM_PACKAGE_NAME:-$(basename $PWD)}/"
            ;;
    esac
done

# Create bin symlinks if package.json has bin entries
if [ -f package.json ]; then
    # Parse bin entries from package.json and create symlinks
    # Handle both string and object forms of "bin"
    node -e "
        const pkg = require('./package.json');
        const name = pkg.name || process.env.NPM_PACKAGE_NAME || require('path').basename(process.cwd());
        const installDir = '/usr/lib/node_modules/' + name;
        if (pkg.bin) {
            if (typeof pkg.bin === 'string') {
                // Single binary with package name
                console.log(name + ':' + pkg.bin);
            } else {
                // Object with multiple binaries
                for (const [binName, binPath] of Object.entries(pkg.bin)) {
                    console.log(binName + ':' + binPath);
                }
            }
        }
    " 2>/dev/null | while IFS=: read -r bin_name bin_path; do
        if [ -n "$bin_name" ] && [ -n "$bin_path" ]; then
            # Create symlink in /usr/bin pointing to the script in node_modules
            pkg_name="${NPM_PACKAGE_NAME:-$(basename $PWD)}"
            ln -sf "/usr/lib/node_modules/$pkg_name/$bin_path" "$DESTDIR/usr/bin/$bin_name"
            echo "Created symlink: /usr/bin/$bin_name -> /usr/lib/node_modules/$pkg_name/$bin_path"
        fi
    done
fi
''',
    "src_test": '''
if [ -f package.json ] && grep -q '"test"' package.json; then
    npm test ${NPM_TEST_ARGS:-}
fi
''',
    "bdepend": ["//packages/linux/lang/nodejs:nodejs"],
    "rdepend": ["//packages/linux/lang/nodejs:nodejs"],
    "exports": ["npm_src_configure", "npm_src_compile", "npm_src_install"],
}

# -----------------------------------------------------------------------------
# Qt5 Eclass
# -----------------------------------------------------------------------------

_QT5_ECLASS = {
    "name": "qt5",
    "description": "Support for Qt5-based packages",
    "src_configure": '''
export QT_SELECT=qt5
export PATH="/usr/lib/qt5/bin:$PATH"

if [ -f *.pro ]; then
    qmake ${QMAKE_ARGS:-}
elif [ -f CMakeLists.txt ]; then
    mkdir -p "${BUILD_DIR:-build}"
    cd "${BUILD_DIR:-build}"
    cmake .. \\
        -DCMAKE_INSTALL_PREFIX="${EPREFIX:-/usr}" \\
        -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}" \\
        -DQT_QMAKE_EXECUTABLE=/usr/lib/qt5/bin/qmake \\
        ${CMAKE_EXTRA_ARGS:-}
fi
''',
    "src_compile": '''
if [ -f Makefile ]; then
    make -j${MAKEOPTS:-$(nproc)}
elif [ -d "${BUILD_DIR:-build}" ]; then
    cmake --build "${BUILD_DIR:-build}" -j${MAKEOPTS:-$(nproc)}
fi
''',
    "src_install": '''
if [ -f Makefile ]; then
    make INSTALL_ROOT="$DESTDIR" install
elif [ -d "${BUILD_DIR:-build}" ]; then
    DESTDIR="$DESTDIR" cmake --install "${BUILD_DIR:-build}"
fi
''',
    "bdepend": ["//packages/dev-qt:qtcore"],
    "rdepend": ["//packages/dev-qt:qtcore"],
    "exports": ["qt5_get_bindir", "qt5_get_headerdir", "qt5_get_libdir"],
}

# -----------------------------------------------------------------------------
# Qt6 Eclass
# -----------------------------------------------------------------------------

_QT6_ECLASS = {
    "name": "qt6",
    "description": "Support for Qt6-based packages",
    "src_configure": '''
export QT_SELECT=qt6
export PATH="/usr/lib/qt6/bin:$PATH"

if ls *.pro 1>/dev/null 2>&1; then
    # QMake6-based project
    qmake6 ${QMAKE_ARGS:-}
elif [ -f CMakeLists.txt ]; then
    # CMake-based project (preferred for Qt6)
    mkdir -p "${BUILD_DIR:-build}"
    cd "${BUILD_DIR:-build}"
    cmake .. \\
        -DCMAKE_INSTALL_PREFIX="${EPREFIX:-/usr}" \\
        -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}" \\
        -DCMAKE_INSTALL_LIBDIR="${LIBDIR:-lib64}" \\
        -DQt6_DIR="/usr/lib/cmake/Qt6" \\
        -DQT_QMAKE_EXECUTABLE=/usr/lib/qt6/bin/qmake6 \\
        ${CMAKE_EXTRA_ARGS:-}
fi
''',
    "src_compile": '''
if [ -f Makefile ]; then
    make -j${MAKEOPTS:-$(nproc)}
elif [ -d "${BUILD_DIR:-build}" ]; then
    cmake --build "${BUILD_DIR:-build}" -j${MAKEOPTS:-$(nproc)}
fi
''',
    "src_install": '''
if [ -f Makefile ]; then
    make INSTALL_ROOT="$DESTDIR" install
elif [ -d "${BUILD_DIR:-build}" ]; then
    DESTDIR="$DESTDIR" cmake --install "${BUILD_DIR:-build}"
fi
''',
    "bdepend": ["//packages/dev-qt/qt6-base:qt6-base"],
    "rdepend": ["//packages/dev-qt/qt6-base:qt6-base"],
    "exports": ["qt6_get_bindir", "qt6_get_headerdir", "qt6_get_libdir"],
}

# -----------------------------------------------------------------------------
# Font Eclass
# -----------------------------------------------------------------------------

_FONT_ECLASS = {
    "name": "font",
    "description": "Support for font package installation",
    "src_configure": '''
# Fonts don't need configuration
:
''',
    "src_compile": '''
# Fonts don't need compilation
:
''',
    "src_install": '''
# Install fonts to appropriate directories based on type
# FONT_TYPES can be set to: ttf, otf, pcf, bdf, type1, etc.
# FONT_SUFFIX can be set for custom suffix patterns (e.g., "*.ttf *.TTF")

FONT_TYPES="${FONT_TYPES:-ttf otf}"
FONT_DIR_BASE="$DESTDIR/usr/share/fonts"

for font_type in $FONT_TYPES; do
    case "$font_type" in
        ttf|TTF)
            FONT_DIR="$FONT_DIR_BASE/TTF"
            SUFFIX="${FONT_SUFFIX_TTF:-*.ttf *.TTF}"
            ;;
        otf|OTF)
            FONT_DIR="$FONT_DIR_BASE/OTF"
            SUFFIX="${FONT_SUFFIX_OTF:-*.otf *.OTF}"
            ;;
        pcf|PCF)
            FONT_DIR="$FONT_DIR_BASE/misc"
            SUFFIX="${FONT_SUFFIX_PCF:-*.pcf *.pcf.gz}"
            ;;
        bdf|BDF)
            FONT_DIR="$FONT_DIR_BASE/misc"
            SUFFIX="${FONT_SUFFIX_BDF:-*.bdf *.bdf.gz}"
            ;;
        type1|TYPE1)
            FONT_DIR="$FONT_DIR_BASE/Type1"
            SUFFIX="${FONT_SUFFIX_TYPE1:-*.pfa *.pfb *.afm}"
            ;;
        *)
            FONT_DIR="$FONT_DIR_BASE/$font_type"
            SUFFIX="${FONT_SUFFIX:-*.$font_type}"
            ;;
    esac

    mkdir -p "$FONT_DIR"

    # Find and install fonts (search in source directory and subdirectories)
    for pattern in $SUFFIX; do
        find . -name "$pattern" -type f -exec install -m 644 {} "$FONT_DIR/" \; 2>/dev/null || true
    done
done

# Install license files if present
for license in LICENSE* COPYING* OFL* README*; do
    if [ -f "$license" ]; then
        mkdir -p "$DESTDIR/usr/share/licenses/${PN:-fonts}"
        install -m 644 "$license" "$DESTDIR/usr/share/licenses/${PN:-fonts}/"
    fi
done
''',
    "post_install": '''
# Update font cache
if command -v fc-cache >/dev/null 2>&1; then
    fc-cache -f "$DESTDIR/usr/share/fonts" 2>/dev/null || true
fi
''',
    "bdepend": [],
    "rdepend": [],
    "exports": ["font_src_install", "font_update_cache"],
}

# -----------------------------------------------------------------------------
# Java Eclass
# -----------------------------------------------------------------------------

_JAVA_ECLASS = {
    "name": "java",
    "description": "Support for basic Java packages with javac",
    "src_compile": '''
# Find Java source files
JAVA_SRC_DIR="${JAVA_SRC_DIR:-src}"
if [ ! -d "$JAVA_SRC_DIR" ]; then
    # Try common source layouts
    for dir in src/main/java src/java .; do
        if [ -d "$dir" ] && find "$dir" -name "*.java" | head -1 | grep -q .; then
            JAVA_SRC_DIR="$dir"
            break
        fi
    done
fi

# Create output directory
mkdir -p "${BUILD_DIR:-build}/classes"

# Compile Java sources
find "$JAVA_SRC_DIR" -name "*.java" > "${BUILD_DIR:-build}/sources.txt"
if [ -s "${BUILD_DIR:-build}/sources.txt" ]; then
    javac \\
        -d "${BUILD_DIR:-build}/classes" \\
        -source "${JAVA_SOURCE:-11}" \\
        -target "${JAVA_TARGET:-11}" \\
        ${JAVAC_OPTS:-} \\
        @"${BUILD_DIR:-build}/sources.txt"
fi

# Create JAR file
JAR_NAME="${JAR_NAME:-${PN:-package}}"
jar cf "${BUILD_DIR:-build}/${JAR_NAME}.jar" -C "${BUILD_DIR:-build}/classes" .
''',
    "src_install": '''
# Install JAR files to standard location
mkdir -p "$DESTDIR/usr/share/java"
find "${BUILD_DIR:-build}" -maxdepth 1 -name "*.jar" -exec install -m 0644 {} "$DESTDIR/usr/share/java/" \\;

# Install any resource files if present
if [ -d "${RESOURCES_DIR:-src/main/resources}" ]; then
    mkdir -p "$DESTDIR/usr/share/java/resources"
    cp -r "${RESOURCES_DIR:-src/main/resources}"/* "$DESTDIR/usr/share/java/resources/" 2>/dev/null || true
fi
''',
    "src_test": '''
# Run tests if test directory exists
if [ -d "${TEST_SRC_DIR:-src/test/java}" ]; then
    mkdir -p "${BUILD_DIR:-build}/test-classes"
    find "${TEST_SRC_DIR:-src/test/java}" -name "*.java" > "${BUILD_DIR:-build}/test-sources.txt"
    if [ -s "${BUILD_DIR:-build}/test-sources.txt" ]; then
        javac \\
            -d "${BUILD_DIR:-build}/test-classes" \\
            -cp "${BUILD_DIR:-build}/classes:${CLASSPATH:-}" \\
            @"${BUILD_DIR:-build}/test-sources.txt"
    fi
fi
''',
    "bdepend": [],
    "rdepend": [],
    "exports": ["java_src_compile", "java_src_install"],
}

# -----------------------------------------------------------------------------
# Maven Eclass
# -----------------------------------------------------------------------------

_MAVEN_ECLASS = {
    "name": "maven",
    "description": "Support for Maven-based Java packages",
    "src_configure": '''
# Set up Maven for offline mode if dependencies are pre-fetched
if [ -n "${MAVEN_REPO:-}" ] && [ -d "$MAVEN_REPO" ]; then
    export MAVEN_OPTS="${MAVEN_OPTS:-} -Dmaven.repo.local=$MAVEN_REPO"
    MVN_OFFLINE="--offline"
    echo "Using pre-fetched Maven repository: $MAVEN_REPO"
else
    MVN_OFFLINE=""
fi

# Resolve dependencies (skip in offline mode as they should already be present)
if [ -z "$MVN_OFFLINE" ]; then
    mvn dependency:resolve ${MVN_EXTRA_ARGS:-} || true
fi
''',
    "src_compile": '''
# Build with Maven, skipping tests by default
mvn package \\
    -DskipTests \\
    ${MVN_OFFLINE:-} \\
    ${MVN_EXTRA_ARGS:-}
''',
    "src_install": '''
# Install resulting JAR files
mkdir -p "$DESTDIR/usr/share/java"

# Find and install main artifact JAR (excluding sources, javadoc, tests)
for jar in target/*.jar; do
    if [ -f "$jar" ]; then
        case "$jar" in
            *-sources.jar|*-javadoc.jar|*-tests.jar)
                # Skip non-runtime JARs
                ;;
            *)
                install -m 0644 "$jar" "$DESTDIR/usr/share/java/"
                ;;
        esac
    fi
done

# Install any executable scripts/wrappers if present
if [ -d target/bin ]; then
    mkdir -p "$DESTDIR/usr/bin"
    find target/bin -type f -executable -exec install -m 0755 {} "$DESTDIR/usr/bin/" \\;
fi

# Install configuration files if present
if [ -d target/conf ] || [ -d src/main/resources ]; then
    mkdir -p "$DESTDIR/etc/${PN:-java-app}"
    [ -d target/conf ] && cp -r target/conf/* "$DESTDIR/etc/${PN:-java-app}/" 2>/dev/null || true
    [ -d src/main/resources ] && cp -r src/main/resources/* "$DESTDIR/etc/${PN:-java-app}/" 2>/dev/null || true
fi
''',
    "src_test": '''
# Run Maven tests
mvn test ${MVN_OFFLINE:-} ${MVN_EXTRA_ARGS:-}
''',
    "bdepend": ["//packages/linux/dev-tools/build-systems/maven:maven"],
    "rdepend": [],
    "exports": ["maven_src_configure", "maven_src_compile", "maven_src_install"],
}

# =============================================================================
# ECLASS REGISTRY
# =============================================================================

ECLASSES = {
    "cmake": _CMAKE_ECLASS,
    "meson": _MESON_ECLASS,
    "autotools": _AUTOTOOLS_ECLASS,
    "python-single-r1": _PYTHON_SINGLE_R1_ECLASS,
    "python-r1": _PYTHON_R1_ECLASS,
    "go-module": _GO_MODULE_ECLASS,
    "ruby": _RUBY_ECLASS,
    "cargo": _CARGO_ECLASS,
    "xdg": _XDG_ECLASS,
    "linux-mod": _LINUX_MOD_ECLASS,
    "acct-user": _ACCT_USER_ECLASS,
    "acct-group": _ACCT_GROUP_ECLASS,
    "systemd": _SYSTEMD_ECLASS,
    "perl": _PERL_ECLASS,
    "npm": _NPM_ECLASS,
    "qt5": _QT5_ECLASS,
    "qt6": _QT6_ECLASS,
    "font": _FONT_ECLASS,
    "java": _JAVA_ECLASS,
    "maven": _MAVEN_ECLASS,
}

# =============================================================================
# INHERITANCE FUNCTIONS
# =============================================================================

def inherit(eclass_names):
    """
    Inherit from one or more eclasses, returning merged configuration.

    This is the main entry point for the eclass system. It takes a list of
    eclass names and returns a dictionary with merged phase functions and
    dependencies.

    Args:
        eclass_names: List of eclass names to inherit from

    Returns:
        Dictionary with:
        - src_prepare: Combined prepare phase
        - src_configure: Combined configure phase
        - src_compile: Combined compile phase
        - src_install: Combined install phase
        - src_test: Combined test phase
        - post_install: Combined post-install hooks
        - bdepend: Combined build dependencies
        - rdepend: Combined runtime dependencies
        - inherited: List of inherited eclass names

    Example:
        config = inherit(["cmake", "xdg"])
        ebuild_package(
            name = "my-app",
            src_configure = config["src_configure"],
            src_compile = config["src_compile"],
            src_install = config["src_install"],
            bdepend = config["bdepend"],
        )
    """
    result = {
        "src_prepare": "",
        "src_configure": "",
        "src_compile": "",
        "src_install": "",
        "src_test": "",
        "post_install": "",
        "bdepend": [],
        "exec_bdepend": [],  # Build tools that run on host platform
        "rdepend": [],
        "inherited": [],
    }

    for name in eclass_names:
        if name not in ECLASSES:
            fail("Unknown eclass: {}. Available: {}".format(name, ", ".join(ECLASSES.keys())))

        eclass = ECLASSES[name]
        result["inherited"].append(name)

        # Merge phase functions (later eclasses can override)
        if "src_prepare" in eclass and eclass["src_prepare"]:
            result["src_prepare"] = eclass["src_prepare"]
        if "src_configure" in eclass and eclass["src_configure"]:
            result["src_configure"] = eclass["src_configure"]
        if "src_compile" in eclass and eclass["src_compile"]:
            result["src_compile"] = eclass["src_compile"]
        if "src_install" in eclass and eclass["src_install"]:
            result["src_install"] = eclass["src_install"]
        if "src_test" in eclass and eclass["src_test"]:
            result["src_test"] = eclass["src_test"]

        # Concatenate post-install hooks
        if "post_install" in eclass and eclass["post_install"]:
            result["post_install"] += "\n" + eclass["post_install"]

        # Merge dependencies (deduplicating)
        if "bdepend" in eclass:
            for dep in eclass["bdepend"]:
                if dep not in result["bdepend"]:
                    result["bdepend"].append(dep)
        if "exec_bdepend" in eclass:
            for dep in eclass["exec_bdepend"]:
                if dep not in result["exec_bdepend"]:
                    result["exec_bdepend"].append(dep)
        if "rdepend" in eclass:
            for dep in eclass["rdepend"]:
                if dep not in result["rdepend"]:
                    result["rdepend"].append(dep)

    return result

def get_eclass(name):
    """
    Get a single eclass definition by name.

    Args:
        name: Name of the eclass

    Returns:
        Dictionary with eclass configuration
    """
    if name not in ECLASSES:
        fail("Unknown eclass: {}".format(name))
    return ECLASSES[name]

def list_eclasses():
    """
    Get list of all available eclass names.

    Returns:
        List of eclass name strings
    """
    return list(ECLASSES.keys())

def eclass_has_phase(eclass_name, phase):
    """
    Check if an eclass provides a specific phase function.

    Args:
        eclass_name: Name of the eclass
        phase: Phase name (src_configure, src_compile, etc.)

    Returns:
        Boolean indicating if the eclass provides the phase
    """
    if eclass_name not in ECLASSES:
        return False
    eclass = ECLASSES[eclass_name]
    return phase in eclass and eclass[phase]

# =============================================================================
# ECLASS HELPER MACROS
# =============================================================================

def eclass_package(
        name,
        source,
        version,
        eclass_inherit,
        category = "",
        slot = "0",
        description = "",
        homepage = "",
        license = "",
        use_flags = [],
        env = {},
        depend = [],
        rdepend = [],
        bdepend = [],
        pdepend = [],
        maintainers = [],
        src_prepare_extra = "",
        src_configure_extra = "",
        src_compile_extra = "",
        src_install_extra = "",
        run_tests = False,
        **kwargs):
    """
    Create an ebuild-style package with eclass inheritance.

    This is a convenience macro that combines ebuild_package with the
    inherit() function for cleaner package definitions.

    Args:
        name: Package name
        source: Source dependency
        version: Package version
        eclass_inherit: List of eclasses to inherit from
        ... (other ebuild_package arguments)

    Example:
        eclass_package(
            name = "my-cmake-app",
            source = ":my-cmake-app-src",
            version = "1.0.0",
            eclass_inherit = ["cmake", "xdg"],
            description = "My CMake Application",
        )
    """
    # This would be implemented in package_defs.bzl to create ebuild_package
    # with inherited eclass configuration
    pass  # Implementation would go here

# =============================================================================
# DOCUMENTATION
# =============================================================================

"""
## Available Eclasses

### cmake
Support for CMake-based packages. Provides standard cmake configure, build,
and install phases.

### meson
Support for Meson-based packages with ninja backend.

### autotools
Support for traditional autotools (configure/make) packages.

### python-single-r1
Support for Python packages that need a single Python implementation.

### python-r1
Support for Python packages compatible with multiple Python versions.

### go-module
Support for Go module-based packages.

### cargo
Support for Rust/Cargo packages.

### xdg
XDG base directory specification support for desktop applications.

### linux-mod
Support for external Linux kernel module building.

### systemd
Systemd unit file installation helpers.

### npm
Support for Node.js/npm packages. Handles npm install (online or with vendored
node_modules), npm build, and installation to /usr/lib/node_modules with
automatic bin symlink creation from package.json.

### qt5
Support for Qt5-based packages.

### qt6
Support for Qt6-based packages. Handles both qmake6 (.pro files) and cmake
(CMakeLists.txt) build systems.

## Adding New Eclasses

To add a new eclass:

1. Define the eclass dictionary with:
   - name: Eclass identifier
   - description: What the eclass does
   - src_*: Phase function scripts
   - bdepend: Build dependencies
   - rdepend: Runtime dependencies
   - exports: Exported function names (documentation)

2. Add to ECLASSES registry

3. Document in this file

Example:
    _MY_ECLASS = {
        "name": "my-eclass",
        "description": "My custom eclass",
        "src_configure": "...",
        "src_compile": "...",
        "bdepend": [...],
    }

    ECLASSES["my-eclass"] = _MY_ECLASS
"""
