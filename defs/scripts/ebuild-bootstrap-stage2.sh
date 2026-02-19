#!/bin/bash
# Prevent cd from outputting paths when CDPATH is set
unset CDPATH
# ebuild-bootstrap-stage2.sh - Bootstrap Stage 2: Core System Utilities
#
# PURPOSE: Build core system utilities and tools using the cross-compilation toolchain
#
# USES:
#   - Stage 1 cross-gcc-pass2 (from /tools/bin)
#   - Stage 1 cross-glibc (from /tools or sysroot)
#   - Stage 1 cross-libstdc++ (from /tools or sysroot)
#   - NO host compiler or libraries
#
# BUILDS:
#   - ncurses, readline (terminal libraries)
#   - bash, coreutils, make (core shell/utilities)
#   - sed, gawk, grep, findutils, diffutils (text processing)
#   - tar, gzip, xz, bzip2 (compression)
#   - perl, python3 (build tool dependencies)
#   - pkg-config, m4, autoconf, automake (build tools)
#   - file, patch (utilities)
#
# OUTPUT: /tools directory with complete userland utilities
#
# ISOLATION LEVEL: STRONG
#   - Uses ONLY cross-compiler from Stage 1
#   - Links ONLY against Stage 1 libraries
#   - NO host PATH fallback
#   - NO host library paths
#   - Strict cross-compilation mode
#
# This script is SOURCED by the wrapper, not executed directly.

# =============================================================================
# Mount Namespace Setup for Sysroot
# =============================================================================
# The cross-compiler is configured to look for sysroot at /tools/x86_64-buckos-linux-gnu/sys-root
# But during the build, the toolchain is in buck-out, not /tools.
# We use a mount namespace to bind-mount the cross-gcc-pass2 output to /tools
# so the compiler can find its sysroot at the expected absolute path.
#
# Mount namespace function has been removed as we're using direct paths now
# Changes to this script invalidate packages that use ebuild_package with bootstrap_stage="stage2".
#
# Environment variables (set by wrapper):
#   _EBUILD_DESTDIR, _EBUILD_SRCDIR, _EBUILD_PKG_CONFIG_WRAPPER - paths
#   _EBUILD_DEP_DIRS - space-separated dependency directories
#   PN, PV, CATEGORY, SLOT, USE - package info
#   BOOTSTRAP_STAGE - should be "stage2"
#   PHASES_CONTENT - the build phases to execute

set -e  # Exit on error
set -o pipefail  # Catch errors in pipes

echo "========================================================================="
echo "BOOTSTRAP STAGE 2: Building Core System Utilities"
echo "========================================================================="
echo "Package: ${PN}-${PV}"
echo "Target: x86_64-buckos-linux-gnu"
echo "Stage: Building with Stage 1 cross-compiler"
echo "Isolation: STRONG (no host compiler/libraries)"
echo "========================================================================="

# Export BOOTSTRAP_STAGE for packages that need conditional logic based on stage
export BOOTSTRAP_STAGE="stage2"

# Installation directories (from wrapper environment)
mkdir -p "$_EBUILD_DESTDIR"
export DESTDIR="$(cd "$_EBUILD_DESTDIR" && pwd)"
export OUT="$DESTDIR"  # Alias for compatibility
export S="$(cd "$_EBUILD_SRCDIR" && pwd)"
export WORKDIR="$(dirname "$S")"
export T="$WORKDIR/temp"
mkdir -p "$T"

# Convert pkg-config wrapper to absolute path (needed for configure scripts)
if [[ "$_EBUILD_PKG_CONFIG_WRAPPER" = /* ]]; then
    PKG_CONFIG_WRAPPER_SCRIPT="$_EBUILD_PKG_CONFIG_WRAPPER"
else
    # Get project root (everything before /buck-out/)
    PROJECT_ROOT="${S%/buck-out/*}"
    PKG_CONFIG_WRAPPER_SCRIPT="$PROJECT_ROOT/$_EBUILD_PKG_CONFIG_WRAPPER"
fi

# Convert dep dirs from space-separated to array
read -ra DEP_DIRS_ARRAY <<< "$_EBUILD_DEP_DIRS"

# Package variables are already exported by wrapper
export PACKAGE_NAME="$PN"

# Bootstrap configuration - BUCKOS_TARGET will be auto-detected from cross-compiler
# Default to x86_64, but will be overridden by auto-detection below
BUCKOS_TARGET=""

# =============================================================================
# Stage 2: Dependency Path Setup
# =============================================================================
# Collect paths from Stage 1 dependencies

DEP_PATH=""
DEP_PYTHONPATH=""
DEP_BASE_DIRS=""
TOOLCHAIN_PATH=""
TOOLCHAIN_LIBPATH=""
TOOLCHAIN_INCLUDE=""
TOOLCHAIN_ROOT=""

for dep_dir in "${DEP_DIRS_ARRAY[@]}"; do
    # Convert to absolute path if relative
    if [[ "$dep_dir" != /* ]]; then
        dep_dir="$(cd "$dep_dir" 2>/dev/null && pwd)" || continue
    fi

    # Store base directory for packages that need direct access
    DEP_BASE_DIRS="${DEP_BASE_DIRS:+$DEP_BASE_DIRS:}$dep_dir"

    # Check if this is the cross-compiler toolchain from Stage 1
    # IMPORTANT: Only add cross-gcc and cross-binutils to TOOLCHAIN_PATH
    # Do NOT add bootstrap-make, bootstrap-sed, etc. - those are cross-compiled
    # for the TARGET and cannot run on the HOST system
    if [ -d "$dep_dir/tools/bin" ]; then
        # Check for cross-compiler or cross-binutils by looking for the target triplet pattern
        # This works for any arch: x86_64-buckos-linux-gnu, aarch64-buckos-linux-gnu, etc.
        for compiler in "$dep_dir/tools/bin/"*-buckos-linux-gnu-gcc; do
            if [ -f "$compiler" ]; then
                TOOLCHAIN_PATH="${TOOLCHAIN_PATH:+$TOOLCHAIN_PATH:}$dep_dir/tools/bin"
                echo "Added cross-gcc to TOOLCHAIN_PATH: $dep_dir/tools/bin"
                # Auto-detect BUCKOS_TARGET from cross-compiler name
                if [ -z "$BUCKOS_TARGET" ]; then
                    BUCKOS_TARGET=$(basename "$compiler" | sed 's/-gcc$//')
                    echo "Auto-detected BUCKOS_TARGET: $BUCKOS_TARGET"
                fi
                break
            fi
        done
        # If no gcc found, check for binutils (separate package)
        if [[ "$TOOLCHAIN_PATH" != *"$dep_dir/tools/bin"* ]]; then
            for linker in "$dep_dir/tools/bin/"*-buckos-linux-gnu-ld; do
                if [ -f "$linker" ]; then
                    TOOLCHAIN_PATH="${TOOLCHAIN_PATH:+$TOOLCHAIN_PATH:}$dep_dir/tools/bin"
                    echo "Added cross-binutils to TOOLCHAIN_PATH: $dep_dir/tools/bin"
                    # Auto-detect BUCKOS_TARGET from linker name if not already set
                    if [ -z "$BUCKOS_TARGET" ]; then
                        BUCKOS_TARGET=$(basename "$linker" | sed 's/-ld$//')
                        echo "Auto-detected BUCKOS_TARGET from binutils: $BUCKOS_TARGET"
                    fi
                    break
                fi
            done
        fi
        # NOTE: We don't set BOOTSTRAP_SYSROOT in Stage 2 because libraries
        # are spread across multiple dependencies. We use -L paths instead.
    fi

    # Collect toolchain library paths for runtime (bash, etc)
    if [ -d "$dep_dir/tools/lib" ]; then
        TOOLCHAIN_LIBPATH="${TOOLCHAIN_LIBPATH:+$TOOLCHAIN_LIBPATH:}$dep_dir/tools/lib"
    fi

    # Capture the full toolchain root directory (for glibc, etc)
    if [ -d "$dep_dir/usr/lib64" ] || [ -d "$dep_dir/usr/lib" ]; then
        TOOLCHAIN_ROOT="${TOOLCHAIN_ROOT:+$TOOLCHAIN_ROOT:}$dep_dir"
    fi

    # Capture include directory from toolchain dependencies
    if [ -d "$dep_dir/usr/include" ]; then
        TOOLCHAIN_INCLUDE="${TOOLCHAIN_INCLUDE:+$TOOLCHAIN_INCLUDE:}$dep_dir"
    fi

    # Regular dependency paths (other Stage 2 packages)
    if [ -d "$dep_dir/tools/bin" ]; then
        DEP_PATH="${DEP_PATH:+$DEP_PATH:}$dep_dir/tools/bin"
    fi
    if [ -d "$dep_dir/usr/bin" ]; then
        DEP_PATH="${DEP_PATH:+$DEP_PATH:}$dep_dir/usr/bin"
    fi
    if [ -d "$dep_dir/bin" ]; then
        DEP_PATH="${DEP_PATH:+$DEP_PATH:}$dep_dir/bin"
    fi

    # Add Python package paths
    for pypath in "$dep_dir/usr/lib/python"*/dist-packages "$dep_dir/usr/lib/python"*/site-packages; do
        if [ -d "$pypath" ]; then
            DEP_PYTHONPATH="${DEP_PYTHONPATH:+$DEP_PYTHONPATH:}$pypath"
        fi
    done
done

# Export toolchain paths for scripts that need them
export TOOLCHAIN_INCLUDE
export TOOLCHAIN_ROOT
export DEP_BASE_DIRS

# Fallback BUCKOS_TARGET if not auto-detected (shouldn't happen with proper deps)
if [ -z "$BUCKOS_TARGET" ]; then
    BUCKOS_TARGET="x86_64-buckos-linux-gnu"
    echo "WARNING: Could not auto-detect BUCKOS_TARGET, defaulting to $BUCKOS_TARGET"
fi
export BUCKOS_TARGET

# =============================================================================
# Stage 2: PATH Setup with Host Build Tools
# =============================================================================
# IMPORTANT: Stage 2 builds use the cross-COMPILER from Stage 1 to generate
# binaries for the TARGET system. However, BUILD TOOLS (make, sed, awk, etc.)
# must be HOST tools because:
#
# 1. Cross-compiled Stage 2 tools (bootstrap-coreutils, etc.) are linked
#    against the TARGET glibc (e.g., glibc 2.38) which isn't available
#    on the HOST system
# 2. These tools cannot execute on the host - they're for the target system
# 3. Only when we chroot into the target (Stage 3) can we use these tools
#
# Therefore, for Stage 2:
# - Cross-compiler (${BUCKOS_TARGET}-gcc) from TOOLCHAIN_PATH
# - Build tools (make, sed, awk, grep) from HOST system (/usr/bin, /bin)
# - DEP_PATH is NOT added to PATH for executables (only for libraries/includes)

if [ -z "$TOOLCHAIN_PATH" ]; then
    echo "========================================================================="
    echo "ERROR: TOOLCHAIN_PATH is empty!"
    echo "Stage 2 requires Stage 1 cross-compiler in dependencies."
    echo "========================================================================="
    exit 1
fi

# Set PATH: cross-compiler first, then HOST tools
# NOTE: We intentionally exclude DEP_PATH from executable PATH because
# cross-compiled Stage 2 tools cannot run on the host (glibc mismatch)

# Also add target-specific bin directories (e.g., tools/aarch64-buckos-linux-gnu/bin/)
# GCC looks for unprefixed tools (as, ld) in <prefix>/<target>/bin/ relative to its installation
# Since cross-gcc and cross-binutils are in separate Buck output dirs, we need these in PATH
TARGET_BIN_PATHS=""
for dep_dir in "${DEP_DIRS_ARRAY[@]}"; do
    if [[ "$dep_dir" != /* ]]; then
        dep_dir="$(cd "$dep_dir" 2>/dev/null && pwd)" || continue
    fi
    if [ -d "$dep_dir/tools/${BUCKOS_TARGET}/bin" ]; then
        TARGET_BIN_PATHS="${TARGET_BIN_PATHS:+$TARGET_BIN_PATHS:}$dep_dir/tools/${BUCKOS_TARGET}/bin"
        echo "Found target-specific tools at: $dep_dir/tools/${BUCKOS_TARGET}/bin"
    fi
done

export PATH="$TOOLCHAIN_PATH${TARGET_BIN_PATHS:+:$TARGET_BIN_PATHS}:/usr/bin:/bin"

echo "Stage 2 PATH setup:"
echo "  Cross-compiler: $TOOLCHAIN_PATH"
if [ -n "$TARGET_BIN_PATHS" ]; then
    echo "  Target tools: $TARGET_BIN_PATHS"
fi
echo "  Build tools: /usr/bin, /bin (HOST)"
echo "  NOTE: Cross-compiled deps (DEP_PATH) are for linking only, not execution"

# Verify cross-compiler is available
if ! command -v ${BUCKOS_TARGET}-gcc >/dev/null 2>&1; then
    echo "========================================================================="
    echo "ERROR: Cross-compiler ${BUCKOS_TARGET}-gcc not found!"
    echo "TOOLCHAIN_PATH: $TOOLCHAIN_PATH"
    echo "PATH: $PATH"
    echo "Searching for compiler in TOOLCHAIN_PATH:"
    for toolchain_dir in ${TOOLCHAIN_PATH//:/ }; do
        if [ -d "$toolchain_dir" ]; then
            echo "  $toolchain_dir:"
            ls -1 "$toolchain_dir" | grep -E '^(x86_64|gcc|cc)' || echo "    (no compiler found)"
        else
            echo "  $toolchain_dir: (directory not found)"
        fi
    done
    echo "========================================================================="
    exit 1
fi

# Verify essential host build tools are available
ESSENTIAL_TOOLS="make bash sh sed awk grep find"
MISSING_TOOLS=""

for tool in $ESSENTIAL_TOOLS; do
    if ! command -v $tool >/dev/null 2>&1; then
        MISSING_TOOLS="$MISSING_TOOLS $tool"
    fi
done

if [ -n "$MISSING_TOOLS" ]; then
    echo "========================================================================="
    echo "ERROR: Missing essential host build tools:$MISSING_TOOLS"
    echo "Stage 2 requires these tools from the host system."
    echo "========================================================================="
    exit 1
fi

echo "PATH: $PATH"

# Set up PYTHONPATH for Python-based build tools
if [ -n "$DEP_PYTHONPATH" ]; then
    export PYTHONPATH="${DEP_PYTHONPATH}${PYTHONPATH:+:$PYTHONPATH}"
fi

# =============================================================================
# Stage 2: Clear ALL Host Environment Variables
# =============================================================================
# CRITICAL: Prevent ANY host system contamination

unset LD_LIBRARY_PATH
unset LIBRARY_PATH
unset CPATH
unset C_INCLUDE_PATH
unset CPLUS_INCLUDE_PATH
unset PKG_CONFIG_PATH

# Also clear any lingering flags that might reference host paths
unset CFLAGS
unset CXXFLAGS
unset LDFLAGS
unset CPPFLAGS

# =============================================================================
# Build Threads Configuration
# =============================================================================
# Set MAKE_JOBS based on BUILD_THREADS (if not already set by wrapper)
# 0 or empty = auto-detect with nproc, otherwise use specified value
if [ -z "$MAKE_JOBS" ]; then
    if [ -z "$BUILD_THREADS" ] || [ "$BUILD_THREADS" = "0" ]; then
        if command -v nproc >/dev/null 2>&1; then
            export MAKE_JOBS="$(nproc)"
        else
            # nproc not available, use unlimited parallelism
            export MAKE_JOBS=""
        fi
    else
        export MAKE_JOBS="$BUILD_THREADS"
    fi
fi

# Export MAKEOPTS so all build systems inherit job count
export MAKEOPTS="${MAKE_JOBS}"

# =============================================================================
# Stage 2: Cross-Compilation Setup
# =============================================================================
# Use cross-compiler from Stage 1 to build Stage 2 utilities

echo ""
echo "=== Stage 2 Cross-Compilation Configuration ==="
echo "Using Stage 1 cross-compiler: ${BUCKOS_TARGET}-gcc"

# Verify cross-compiler is accessible
if ! command -v ${BUCKOS_TARGET}-gcc >/dev/null 2>&1; then
    echo "ERROR: Cross-compiler not found in PATH"
    echo "PATH=$PATH"
    exit 1
fi

echo "Cross-compiler found at: $(command -v ${BUCKOS_TARGET}-gcc)"

# Check if we have cross-compiler directories passed from the wrapper
# Use them directly without mount namespace
if [ -n "$BOOTSTRAP_CROSS_GCC_DIR" ] && [ -n "$BOOTSTRAP_CROSS_BINUTILS_DIR" ]; then
    # Convert to absolute paths if they're relative
    if [[ "$BOOTSTRAP_CROSS_GCC_DIR" != /* ]]; then
        # Get project root (everything before /buck-out/)
        PROJECT_ROOT="${PWD%/buck-out/*}"
        if [ "$PROJECT_ROOT" = "$PWD" ]; then
            # If we're not in buck-out, use current directory as root
            PROJECT_ROOT="$(pwd)"
        fi
        BOOTSTRAP_CROSS_GCC_DIR="$PROJECT_ROOT/$BOOTSTRAP_CROSS_GCC_DIR"
    fi
    if [[ "$BOOTSTRAP_CROSS_BINUTILS_DIR" != /* ]]; then
        # Get project root (everything before /buck-out/)
        PROJECT_ROOT="${PWD%/buck-out/*}"
        if [ "$PROJECT_ROOT" = "$PWD" ]; then
            # If we're not in buck-out, use current directory as root
            PROJECT_ROOT="$(pwd)"
        fi
        BOOTSTRAP_CROSS_BINUTILS_DIR="$PROJECT_ROOT/$BOOTSTRAP_CROSS_BINUTILS_DIR"
    fi

    echo "Using cross-compiler from direct paths:"
    echo "  GCC: $BOOTSTRAP_CROSS_GCC_DIR"
    echo "  Binutils: $BOOTSTRAP_CROSS_BINUTILS_DIR"

    # Use absolute paths to the cross-compiler tools
    # GCC can find its sysroot relative to its installation
    export CC="$BOOTSTRAP_CROSS_GCC_DIR/bin/${BUCKOS_TARGET}-gcc"
    export CXX="$BOOTSTRAP_CROSS_GCC_DIR/bin/${BUCKOS_TARGET}-g++"
    export CPP="$BOOTSTRAP_CROSS_GCC_DIR/bin/${BUCKOS_TARGET}-gcc -E"
    export AR="$BOOTSTRAP_CROSS_BINUTILS_DIR/bin/${BUCKOS_TARGET}-ar"
    export AS="$BOOTSTRAP_CROSS_BINUTILS_DIR/bin/${BUCKOS_TARGET}-as"
    export LD="$BOOTSTRAP_CROSS_BINUTILS_DIR/bin/${BUCKOS_TARGET}-ld"
    export NM="$BOOTSTRAP_CROSS_BINUTILS_DIR/bin/${BUCKOS_TARGET}-nm"
    export RANLIB="$BOOTSTRAP_CROSS_BINUTILS_DIR/bin/${BUCKOS_TARGET}-ranlib"
    export STRIP="$BOOTSTRAP_CROSS_BINUTILS_DIR/bin/${BUCKOS_TARGET}-strip"
    export OBJCOPY="$BOOTSTRAP_CROSS_BINUTILS_DIR/bin/${BUCKOS_TARGET}-objcopy"
    export OBJDUMP="$BOOTSTRAP_CROSS_BINUTILS_DIR/bin/${BUCKOS_TARGET}-objdump"
    export READELF="$BOOTSTRAP_CROSS_BINUTILS_DIR/bin/${BUCKOS_TARGET}-readelf"

    # GCC should find its sysroot automatically
    export CFLAGS="-O2"
    export CXXFLAGS="-O2"
    export LDFLAGS=""
else
    # Fallback - use tools from buck-out with explicit sysroot
    echo "Using tools with explicit sysroot"
    # Find the cross-GCC sysroot from dependencies
    # Check multiple possible layouts:
    # 1. Sysroot layout: tools/${BUCKOS_TARGET}/sys-root/usr/lib
    # 2. FHS layout (cross-glibc): usr/lib or usr/lib64
    CROSS_GCC_SYSROOT=""
    if [ -n "$DEP_BASE_DIRS" ]; then
        IFS=':' read -ra DEP_DIRS <<< "$DEP_BASE_DIRS"
        for dep_dir in "${DEP_DIRS[@]}"; do
            # Check sysroot layout first
            if [ -d "$dep_dir/tools/${BUCKOS_TARGET}/sys-root/usr/lib" ]; then
                CROSS_GCC_SYSROOT="$dep_dir/tools/${BUCKOS_TARGET}/sys-root"
                echo "Found cross-GCC sysroot at: $CROSS_GCC_SYSROOT"
                break
            fi
            # Check FHS layout (cross-glibc uses /usr/lib or /usr/lib64)
            # Look for libc.so.6 which is unique to glibc
            if [ -f "$dep_dir/usr/lib/libc.so.6" ]; then
                CROSS_GCC_SYSROOT="$dep_dir"
                echo "Found cross-glibc (FHS layout) at: $CROSS_GCC_SYSROOT"
                break
            fi
            if [ -f "$dep_dir/usr/lib64/libc.so.6" ]; then
                CROSS_GCC_SYSROOT="$dep_dir"
                echo "Found cross-glibc (FHS layout lib64) at: $CROSS_GCC_SYSROOT"
                break
            fi
        done
    fi

    if [ -z "$CROSS_GCC_SYSROOT" ]; then
        echo "WARNING: Could not find cross-GCC sysroot in dependencies"
        echo "DEP_BASE_DIRS=$DEP_BASE_DIRS"
    fi

    # Find linux kernel headers in dependencies
    LINUX_HEADERS_DIR=""
    if [ -n "$DEP_BASE_DIRS" ]; then
        IFS=':' read -ra DEP_DIRS <<< "$DEP_BASE_DIRS"
        for dep_dir in "${DEP_DIRS[@]}"; do
            # Check for linux headers in tools/${BUCKOS_TARGET}/include
            if [ -d "$dep_dir/tools/${BUCKOS_TARGET}/include/linux" ]; then
                LINUX_HEADERS_DIR="$dep_dir/tools/${BUCKOS_TARGET}/include"
                echo "Found linux headers at: $LINUX_HEADERS_DIR"
                break
            fi
            # Check for linux headers in tools/include
            if [ -d "$dep_dir/tools/include/linux" ]; then
                LINUX_HEADERS_DIR="$dep_dir/tools/include"
                echo "Found linux headers at: $LINUX_HEADERS_DIR"
                break
            fi
        done
    fi

    SYSROOT_FLAG=""
    LDFLAGS_SYSROOT=""
    CFLAGS_SYSROOT=""
    INCLUDE_SYSROOT=""
    if [ -n "$CROSS_GCC_SYSROOT" ]; then
        SYSROOT_FLAG="--sysroot=$CROSS_GCC_SYSROOT"
        # GCC was configured with non-standard header dir, so we must explicitly add /usr/include
        INCLUDE_SYSROOT="-isystem $CROSS_GCC_SYSROOT/usr/include"
        # Also add linux kernel headers if found
        if [ -n "$LINUX_HEADERS_DIR" ]; then
            INCLUDE_SYSROOT="$INCLUDE_SYSROOT -isystem $LINUX_HEADERS_DIR"
        fi
        # -B tells GCC where to find CRT startup files (crti.o, crtn.o, etc.)
        CFLAGS_SYSROOT="--sysroot=$CROSS_GCC_SYSROOT -B$CROSS_GCC_SYSROOT/usr/lib/ $INCLUDE_SYSROOT"
        # Add explicit library path for CRT files and shared libraries
        LDFLAGS_SYSROOT="-Wl,--sysroot=$CROSS_GCC_SYSROOT -B$CROSS_GCC_SYSROOT/usr/lib/ -L$CROSS_GCC_SYSROOT/usr/lib"
    fi

    # Don't embed --sysroot in CC - some configure scripts don't like options in CC
    # Instead, pass sysroot through CFLAGS/LDFLAGS
    export CC="${BUCKOS_TARGET}-gcc"
    export CXX="${BUCKOS_TARGET}-g++"
    # Use gcc -E instead of standalone cpp so it picks up CFLAGS (including --sysroot)
    export CPP="${BUCKOS_TARGET}-gcc -E $CFLAGS_SYSROOT"
    export AR="${BUCKOS_TARGET}-ar"
    export AS="${BUCKOS_TARGET}-as"
    export LD="${BUCKOS_TARGET}-ld"
    export NM="${BUCKOS_TARGET}-nm"
    export RANLIB="${BUCKOS_TARGET}-ranlib"
    export STRIP="${BUCKOS_TARGET}-strip"
    export OBJCOPY="${BUCKOS_TARGET}-objcopy"
    export OBJDUMP="${BUCKOS_TARGET}-objdump"
    export READELF="${BUCKOS_TARGET}-readelf"

    export CFLAGS="-O2 $CFLAGS_SYSROOT"
    export CXXFLAGS="-O2 $CFLAGS_SYSROOT"
    export CPPFLAGS="$CFLAGS_SYSROOT"
    export LDFLAGS="$LDFLAGS_SYSROOT"
fi

echo "CC=$CC"
echo "CXX=$CXX"
echo "CFLAGS=$CFLAGS"
echo "CXXFLAGS=$CXXFLAGS"
echo "LDFLAGS=$LDFLAGS"

# Set build/host triplets for autotools
export BUILD_TRIPLET="$(gcc -dumpmachine 2>/dev/null || echo "x86_64-pc-linux-gnu")"
export HOST_TRIPLET="$BUCKOS_TARGET"

echo "BUILD_TRIPLET=$BUILD_TRIPLET (host system)"
echo "HOST_TRIPLET=$HOST_TRIPLET (target system)"

# =============================================================================
# Stage 2: FOR_BUILD Variables
# =============================================================================
# Some packages need to build helper programs that run on the BUILD (host)
# system during compilation. These use HOST compiler with C17/C++17.
#
# Example: bash's mkbuiltins program
#
# IMPORTANT: These tools run on the host but shouldn't link against host
# libraries where possible. We use clean flags.

# Use -B/usr/bin so the host gcc finds the host assembler/linker
# instead of the cross-toolchain ones that appear first in PATH
export CC_FOR_BUILD="${CC_FOR_BUILD:-gcc -B/usr/bin -std=gnu17}"
export CXX_FOR_BUILD="${CXX_FOR_BUILD:-g++ -B/usr/bin -std=gnu++17}"
export CPP_FOR_BUILD="${CPP_FOR_BUILD:-gcc -B/usr/bin -E}"
export CFLAGS_FOR_BUILD="${CFLAGS_FOR_BUILD:--O2 -std=gnu17}"
export CXXFLAGS_FOR_BUILD="${CXXFLAGS_FOR_BUILD:--O2 -std=gnu++17}"
export CPPFLAGS_FOR_BUILD="${CPPFLAGS_FOR_BUILD:-}"
# CRITICAL: Force LDFLAGS_FOR_BUILD to empty string for Stage 2
# Stage 2 uses cross-compiler to build target utilities, but build-time helper
# tools must run on the host without cross-compilation linker flags
export LDFLAGS_FOR_BUILD=""

echo "CC_FOR_BUILD=$CC_FOR_BUILD (for build-time helper tools)"
echo "CXX_FOR_BUILD=$CXX_FOR_BUILD"

# =============================================================================
# Stage 2: Library Path Setup
# =============================================================================
# Set up library paths from Stage 1 and other Stage 2 dependencies

DEP_LIBPATH=""
DEP_PKG_CONFIG_PATH=""

for dep_dir_raw in "${DEP_DIRS_ARRAY[@]}"; do
    # Convert to absolute path
    if [[ "$dep_dir_raw" = /* ]]; then
        dep_dir="$dep_dir_raw"
    else
        dep_dir="$(cd "$dep_dir_raw" 2>/dev/null && pwd)" || dep_dir="$(pwd)/$dep_dir_raw"
    fi

    # Skip cross-compilation toolchain packages - they're handled by sysroot
    # Only collect paths from bootstrap-* stage2 packages
    if [[ "$dep_dir" == */__cross-gcc* ]] || \
       [[ "$dep_dir" == */__cross-binutils* ]] || \
       [[ "$dep_dir" == */__cross-glibc* ]]; then
        # Skip library paths for cross-compilation toolchain (sysroot handles these)
        # But still collect pkg-config paths
        if [ -d "$dep_dir/tools/lib/pkgconfig" ]; then
            DEP_PKG_CONFIG_PATH="${DEP_PKG_CONFIG_PATH:+$DEP_PKG_CONFIG_PATH:}$dep_dir/tools/lib/pkgconfig"
        fi
        if [ -d "$dep_dir/usr/lib64/pkgconfig" ]; then
            DEP_PKG_CONFIG_PATH="${DEP_PKG_CONFIG_PATH:+$DEP_PKG_CONFIG_PATH:}$dep_dir/usr/lib64/pkgconfig"
        fi
        if [ -d "$dep_dir/usr/lib/pkgconfig" ]; then
            DEP_PKG_CONFIG_PATH="${DEP_PKG_CONFIG_PATH:+$DEP_PKG_CONFIG_PATH:}$dep_dir/usr/lib/pkgconfig"
        fi
        if [ -d "$dep_dir/usr/share/pkgconfig" ]; then
            DEP_PKG_CONFIG_PATH="${DEP_PKG_CONFIG_PATH:+$DEP_PKG_CONFIG_PATH:}$dep_dir/usr/share/pkgconfig"
        fi
        continue
    fi

    # Collect library paths (priority: tools/lib, lib64, lib)
    if [ -d "$dep_dir/tools/lib64" ]; then
        DEP_LIBPATH="${DEP_LIBPATH:+$DEP_LIBPATH:}$dep_dir/tools/lib64"
    fi
    if [ -d "$dep_dir/tools/lib" ]; then
        DEP_LIBPATH="${DEP_LIBPATH:+$DEP_LIBPATH:}$dep_dir/tools/lib"
    fi
    if [ -d "$dep_dir/usr/lib64" ]; then
        DEP_LIBPATH="${DEP_LIBPATH:+$DEP_LIBPATH:}$dep_dir/usr/lib64"
    fi
    if [ -d "$dep_dir/usr/lib" ]; then
        DEP_LIBPATH="${DEP_LIBPATH:+$DEP_LIBPATH:}$dep_dir/usr/lib"
    fi
    if [ -d "$dep_dir/lib64" ]; then
        DEP_LIBPATH="${DEP_LIBPATH:+$DEP_LIBPATH:}$dep_dir/lib64"
    fi
    if [ -d "$dep_dir/lib" ]; then
        DEP_LIBPATH="${DEP_LIBPATH:+$DEP_LIBPATH:}$dep_dir/lib"
    fi

    # Collect pkg-config paths
    if [ -d "$dep_dir/tools/lib/pkgconfig" ]; then
        DEP_PKG_CONFIG_PATH="${DEP_PKG_CONFIG_PATH:+$DEP_PKG_CONFIG_PATH:}$dep_dir/tools/lib/pkgconfig"
    fi
    if [ -d "$dep_dir/usr/lib64/pkgconfig" ]; then
        DEP_PKG_CONFIG_PATH="${DEP_PKG_CONFIG_PATH:+$DEP_PKG_CONFIG_PATH:}$dep_dir/usr/lib64/pkgconfig"
    fi
    if [ -d "$dep_dir/usr/lib/pkgconfig" ]; then
        DEP_PKG_CONFIG_PATH="${DEP_PKG_CONFIG_PATH:+$DEP_PKG_CONFIG_PATH:}$dep_dir/usr/lib/pkgconfig"
    fi
    if [ -d "$dep_dir/usr/share/pkgconfig" ]; then
        DEP_PKG_CONFIG_PATH="${DEP_PKG_CONFIG_PATH:+$DEP_PKG_CONFIG_PATH:}$dep_dir/usr/share/pkgconfig"
    fi
done

# Add library paths to LDFLAGS (in addition to sysroot)
# Include dependency library paths even in namespace mode
# The sysroot only contains base system libraries, not stage2 dependencies
if [ -n "$DEP_LIBPATH" ]; then
    for lib_dir in ${DEP_LIBPATH//:/ }; do
        export LDFLAGS="$LDFLAGS -L$lib_dir"
    done
fi

# Set up pkg-config
if [ -n "$DEP_PKG_CONFIG_PATH" ]; then
    if [ -n "$PKG_CONFIG_PATH" ]; then
        export PKG_CONFIG_PATH="$DEP_PKG_CONFIG_PATH:$PKG_CONFIG_PATH"
    else
        export PKG_CONFIG_PATH="$DEP_PKG_CONFIG_PATH"
    fi
fi

# Use our pkg-config wrapper if available
if [ -f "$PKG_CONFIG_WRAPPER_SCRIPT" ]; then
    export PKG_CONFIG="$PKG_CONFIG_WRAPPER_SCRIPT"
    echo "Using pkg-config wrapper: $PKG_CONFIG_WRAPPER_SCRIPT"
fi

echo "=== End Stage 2 Setup ==="
echo ""

# =============================================================================
# Execute Build Phases
# =============================================================================
cd "$S"

# Source and execute the phases content (runs src_prepare, src_configure, src_compile, src_install)
eval "$PHASES_CONTENT"

# =============================================================================
# Stage 2: Post-Install Verification
# =============================================================================
echo ""
echo "=== Stage 2 Post-Install Verification ==="

# Check that binaries were actually built
if command -v wc >/dev/null 2>&1; then
    if command -v fd >/dev/null 2>&1; then
        BINARY_COUNT=$(fd --type x --no-ignore --hidden '' "$DESTDIR" 2>/dev/null | wc -l)
        LIBRARY_COUNT=$(fd --type f --no-ignore --hidden '\.so' "$DESTDIR" 2>/dev/null | wc -l)
    else
        BINARY_COUNT=$(find "$DESTDIR" -type f -executable 2>/dev/null | wc -l)
        LIBRARY_COUNT=$(find "$DESTDIR" -type f -name '*.so*' 2>/dev/null | wc -l)
    fi
    echo "Installed: $BINARY_COUNT executables, $LIBRARY_COUNT shared libraries"
else
    # wc not available during early bootstrap, just check if files exist
    if command -v fd >/dev/null 2>&1; then
        if fd --type x --no-ignore --hidden --max-results 1 '' "$DESTDIR" 2>/dev/null | grep -q .; then
            echo "Installed: executables found (count unavailable, wc not built yet)"
        fi
        if fd --type f --no-ignore --hidden --max-results 1 '\.so' "$DESTDIR" 2>/dev/null | grep -q .; then
            echo "Installed: shared libraries found (count unavailable, wc not built yet)"
        fi
    else
        if find "$DESTDIR" -type f -executable 2>/dev/null | head -1 | grep -q .; then
            echo "Installed: executables found (count unavailable, wc not built yet)"
        fi
        if find "$DESTDIR" -type f -name '*.so*' 2>/dev/null | head -1 | grep -q .; then
            echo "Installed: shared libraries found (count unavailable, wc not built yet)"
        fi
    fi
fi

# Sample check for host library contamination (quick check)
if command -v ldd >/dev/null 2>&1; then
    echo ""
    echo "Checking for host library dependencies (sample)..."
    if command -v fd >/dev/null 2>&1; then
        SAMPLE_BINARY=$(fd --type x --no-ignore --hidden --max-results 1 '' "$DESTDIR" 2>/dev/null || true)
    else
        SAMPLE_BINARY=$(find "$DESTDIR" -type f -executable | head -1 || true)
    fi
    if [ -n "$SAMPLE_BINARY" ] && file "$SAMPLE_BINARY" 2>/dev/null | grep -q "ELF"; then
        echo "Sample binary: $SAMPLE_BINARY"
        if ldd "$SAMPLE_BINARY" 2>/dev/null | grep -E "(/lib64/|/usr/lib/)" | grep -v "buckos" | grep -v "/tools/"; then
            echo "WARNING: Binary may link to host libraries!"
            echo "Full ldd output:"
            ldd "$SAMPLE_BINARY" || true
        else
            echo "OK: No obvious host library dependencies detected"
        fi
    fi
fi

echo "=== End Stage 2 Verification ==="
echo ""

echo "========================================================================="
echo "BOOTSTRAP STAGE 2 COMPLETE: Core utilities built successfully"
echo "========================================================================="
