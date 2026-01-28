#!/bin/bash
# install_binary.sh - External binary package installation script
# This script is SOURCED by the wrapper, not executed directly.
# Changes to this script invalidate packages that use binary_package.
#
# Environment variables (set by wrapper):
#   _BINARY_DESTDIR, _BINARY_SRCDIR, _BINARY_WORKDIR - paths
#   _BINARY_PKG_CONFIG_WRAPPER - pkg-config wrapper script path
#   _BINARY_DEP_DIRS - space-separated dependency directories
#   PN, PV - package name and version
#   PHASES_CONTENT - the pre_install, install_script, post_install phases

set -e

# === GUARD RAILS: Validate required environment variables ===
_binary_fail() {
    echo "ERROR: $1" >&2
    echo "  Package: ${PN:-unknown}" >&2
    exit 1
}

if [[ -z "$_BINARY_DESTDIR" ]]; then
    _binary_fail "DESTDIR not set - wrapper script misconfigured"
fi
if [[ -z "$_BINARY_WORKDIR" ]]; then
    _binary_fail "WORKDIR not set - wrapper script misconfigured"
fi
if [[ -z "$_BINARY_SRCDIR" ]]; then
    _binary_fail "SRCDIR not set - wrapper script misconfigured"
fi
if [[ ! -d "$_BINARY_SRCDIR" ]]; then
    _binary_fail "Source directory does not exist: $_BINARY_SRCDIR
  This usually means:
  1. The download_source/srcs target failed
  2. The source archive has an unexpected structure (wrong strip_components?)
  3. The source extraction silently failed"
fi
if [[ -z "$(ls -A "$_BINARY_SRCDIR" 2>/dev/null)" ]]; then
    _binary_fail "Source directory is empty: $_BINARY_SRCDIR
  The archive may have extracted to a different location.
  Check strip_components setting in download_source."
fi

# Directory setup from wrapper environment
# Argument order: DEST, WORK, SRCS (matches existing binary_package convention)
mkdir -p "$_BINARY_DESTDIR"
mkdir -p "$_BINARY_WORKDIR"
export OUT="$(cd "$_BINARY_DESTDIR" && pwd)"
export DESTDIR="$OUT"  # Alias for compatibility
export WORK="$(cd "$_BINARY_WORKDIR" && pwd)"
export SRCS="$(cd "$_BINARY_SRCDIR" && pwd)"
export BUILD_DIR="$WORK/build"
export T="$WORK/temp"
mkdir -p "$T"
mkdir -p "$BUILD_DIR"
PKG_CONFIG_WRAPPER_SCRIPT="$_BINARY_PKG_CONFIG_WRAPPER"

# Convert dep dirs from space-separated to array
read -ra DEP_DIRS_ARRAY <<< "$_BINARY_DEP_DIRS"

# Package variables are already exported by wrapper
export PACKAGE_NAME="$PN"

# Set up paths from dependency directories
DEP_PATH=""
DEP_LD_PATH=""
DEP_PKG_CONFIG_PATH=""
DEP_CPATH=""
PYTHON_HOME=""
PYTHON_LIB64=""

echo "=== binary_package dependency setup for $PN ==="
echo "Processing ${#DEP_DIRS_ARRAY[@]} dependency directories..."

# Store all dependency base directories for packages that need them
export DEP_BASE_DIRS=""

for dep_dir in "${DEP_DIRS_ARRAY[@]}"; do
    # Convert to absolute path if relative
    if [[ "$dep_dir" != /* ]]; then
        dep_dir="$(cd "$dep_dir" 2>/dev/null && pwd)" || continue
    fi

    echo "  Checking dependency: $dep_dir"

    # Store base directory
    DEP_BASE_DIRS="${DEP_BASE_DIRS:+$DEP_BASE_DIRS:}$dep_dir"

    # Check all standard include directories
    for inc_subdir in usr/include include; do
        if [ -d "$dep_dir/$inc_subdir" ]; then
            DEP_CPATH="${DEP_CPATH:+$DEP_CPATH:}$dep_dir/$inc_subdir"
            echo "    Found include dir: $dep_dir/$inc_subdir"
        fi
    done

    # Check all standard bin directories
    for bin_subdir in usr/bin bin usr/sbin sbin; do
        if [ -d "$dep_dir/$bin_subdir" ]; then
            DEP_PATH="${DEP_PATH:+$DEP_PATH:}$dep_dir/$bin_subdir"
            echo "    Found bin dir: $dep_dir/$bin_subdir"
        fi
    done

    # Check all standard lib directories
    for lib_subdir in usr/lib usr/lib64 lib lib64; do
        if [ -d "$dep_dir/$lib_subdir" ]; then
            DEP_LD_PATH="${DEP_LD_PATH:+$DEP_LD_PATH:}$dep_dir/$lib_subdir"
            echo "    Found lib dir: $dep_dir/$lib_subdir"
        fi
    done

    # Check for pkgconfig directories
    for pc_subdir in usr/lib64/pkgconfig usr/lib/pkgconfig usr/share/pkgconfig lib/pkgconfig lib64/pkgconfig; do
        if [ -d "$dep_dir/$pc_subdir" ]; then
            DEP_PKG_CONFIG_PATH="${DEP_PKG_CONFIG_PATH:+$DEP_PKG_CONFIG_PATH:}$dep_dir/$pc_subdir"
            echo "    Found pkgconfig dir: $dep_dir/$pc_subdir"
        fi
    done

    # Detect Python installation
    for py_dir in "$dep_dir"/usr/lib/python3.* "$dep_dir"/usr/lib64/python3.*; do
        if [ -d "$py_dir" ]; then
            py_version=$(basename "$py_dir")
            if [ -z "$PYTHON_HOME" ]; then
                PYTHON_HOME="$dep_dir/usr"
                echo "    Found PYTHONHOME: $PYTHON_HOME (from $py_version)"
            fi
            if [ -d "$py_dir/lib-dynload" ] && [ -z "$PYTHON_LIB64" ]; then
                PYTHON_LIB64="$py_dir"
            fi
        fi
    done
done

echo "=== Environment setup ==="
if [ -n "$DEP_PATH" ]; then
    export PATH="$DEP_PATH:$PATH"
    echo "PATH=$PATH"
fi
if [ -n "$DEP_LD_PATH" ]; then
    export LD_LIBRARY_PATH="$DEP_LD_PATH"
    export LIBRARY_PATH="$DEP_LD_PATH"
    echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"

    DEP_LDFLAGS=""
    IFS=':' read -ra LIB_DIRS <<< "$DEP_LD_PATH"
    for lib_dir in "${LIB_DIRS[@]}"; do
        DEP_LDFLAGS="${DEP_LDFLAGS} -L$lib_dir -Wl,-rpath-link,$lib_dir"
    done
    export LDFLAGS="${DEP_LDFLAGS} ${LDFLAGS:-}"
    echo "LDFLAGS=$LDFLAGS"
fi
if [ -n "$DEP_CPATH" ]; then
    export CPATH="$DEP_CPATH"
    export C_INCLUDE_PATH="$DEP_CPATH"
    export CPLUS_INCLUDE_PATH="$DEP_CPATH"
    echo "CPATH=$CPATH"

    DEP_ISYSTEM_FLAGS=""
    DEP_I_FLAGS=""
    IFS=':' read -ra INC_DIRS <<< "$DEP_CPATH"
    for inc_dir in "${INC_DIRS[@]}"; do
        DEP_ISYSTEM_FLAGS="${DEP_ISYSTEM_FLAGS} -isystem $inc_dir"
        DEP_I_FLAGS="${DEP_I_FLAGS} -I$inc_dir"
    done

    export CFLAGS="${DEP_ISYSTEM_FLAGS} ${CFLAGS:-}"
    export CXXFLAGS="${DEP_ISYSTEM_FLAGS} ${CXXFLAGS:-}"
    export CXXFLAGS="${CXXFLAGS} -fpermissive"
    export CPPFLAGS="${DEP_I_FLAGS} ${CPPFLAGS:-}"
    echo "CFLAGS=$CFLAGS"
fi
echo "DEP_BASE_DIRS=$DEP_BASE_DIRS"
if [ -n "$PYTHON_HOME" ]; then
    export PYTHONHOME="$PYTHON_HOME"
    echo "PYTHONHOME=$PYTHONHOME"
fi
if [ -n "$PYTHON_LIB64" ] && [ -d "$PYTHON_LIB64/lib-dynload" ]; then
    export PYTHONPATH="$PYTHON_LIB64/lib-dynload${PYTHONPATH:+:$PYTHONPATH}"
    echo "PYTHONPATH=$PYTHONPATH"
fi
if [ -n "$DEP_PKG_CONFIG_PATH" ]; then
    export PKG_CONFIG_LIBDIR="$DEP_PKG_CONFIG_PATH"
    unset PKG_CONFIG_PATH
    unset PKG_CONFIG_SYSROOT_DIR
    echo "PKG_CONFIG_LIBDIR=$PKG_CONFIG_LIBDIR"

    mkdir -p "$T/bin"
    cp "$PKG_CONFIG_WRAPPER_SCRIPT" "$T/bin/pkg-config"
    chmod +x "$T/bin/pkg-config"
    export PATH="$T/bin:$PATH"
    echo "Installed pkg-config wrapper at $T/bin/pkg-config"
fi

# Verify key tools are available
echo "=== Verifying tools ==="
for tool in cmake python3 cc gcc ninja make; do
    if command -v $tool >/dev/null 2>&1; then
        tool_path=$(command -v $tool)
        tool_version=$($tool --version 2>&1 | head -1 || echo "unknown")
        echo "  $tool: $tool_path ($tool_version)"
    else
        echo "  $tool: NOT FOUND"
    fi
done

echo "=== End dependency setup ($(date '+%Y-%m-%d %H:%M:%S')) ==="
echo ""

cd "$WORK"

# Build timing
BUILD_START=$(date +%s)

# Run the phases (from PHASES_CONTENT environment variable set by wrapper)
if [ -n "$PHASES_CONTENT" ]; then
    echo "$PHASES_CONTENT" > "$T/phases.sh"
    chmod +x "$T/phases.sh"
    "$T/phases.sh"
else
    echo "ERROR: PHASES_CONTENT not set" >&2
    exit 1
fi

# Global cleanup: Remove libtool .la files
LA_COUNT=$(find "$DESTDIR" -name "*.la" -type f 2>/dev/null | wc -l)
if [ "$LA_COUNT" -gt 0 ]; then
    echo "Removing $LA_COUNT libtool .la files (using pkg-config instead)"
    find "$DESTDIR" -name "*.la" -type f -delete 2>/dev/null || true
fi

BUILD_END=$(date +%s)
echo "[TIMING] Total build time: $((BUILD_END - BUILD_START)) seconds"

# =============================================================================
# Post-build verification
# =============================================================================
echo ""
echo "📋 Verifying build output..."

FILE_COUNT=$(find "$OUT" -type f 2>/dev/null | wc -l)
DIR_COUNT=$(find "$OUT" -type d 2>/dev/null | wc -l)

if [ "$FILE_COUNT" -eq 0 ]; then
    echo "" >&2
    echo "✗ BUILD VERIFICATION FAILED: No files were installed" >&2
    echo "  Package: $PN-$PV" >&2
    echo "  Output directory: $OUT" >&2
    exit 1
fi

echo "✓ Build verification passed: $FILE_COUNT files in $DIR_COUNT directories"

echo ""
echo "=== Build summary for $PN $PV ==="
echo "Output directory: $OUT"
echo "Total files: $FILE_COUNT"
echo "Total size: $(du -sh "$OUT" 2>/dev/null | cut -f1)"
echo "=== End build summary ($(date '+%Y-%m-%d %H:%M:%S')) ==="
