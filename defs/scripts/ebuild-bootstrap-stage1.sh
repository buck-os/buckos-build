#!/bin/bash
# ebuild-bootstrap-stage1.sh - Bootstrap Stage 1: Minimal Cross-Compilation Toolchain
#
# PURPOSE: Build the initial cross-compilation toolchain targeting x86_64-buckos-linux-gnu
#
# USES:
#   - Host GCC compiler (system compiler)
#   - Host glibc (system C library)
#   - Host binutils (system assembler/linker)
#
# BUILDS:
#   - cross-binutils (assembler, linker for target)
#   - cross-gcc-pass1 (minimal C compiler, no libc support)
#   - linux-headers (kernel API headers)
#   - cross-glibc (C library for target)
#   - cross-libstdc++ (C++ standard library for target)
#   - cross-gcc-pass2 (full compiler with libc support)
#
# OUTPUT: /tools directory with complete cross-compilation toolchain
#
# ISOLATION LEVEL: PARTIAL
#   - Still depends on host compiler and libraries
#   - Builds tools that target buckos, not host
#   - Host PATH is included as fallback
#
# This script is SOURCED by the wrapper, not executed directly.
# Changes to this script invalidate packages that use ebuild_package with bootstrap_stage="stage1".
#
# Environment variables (set by wrapper):
#   _EBUILD_DESTDIR, _EBUILD_SRCDIR, _EBUILD_PKG_CONFIG_WRAPPER - paths
#   _EBUILD_DEP_DIRS - space-separated dependency directories
#   PN, PV, CATEGORY, SLOT, USE - package info
#   BOOTSTRAP_STAGE - should be "stage1"
#   PHASES_CONTENT - the build phases to execute

set -e  # Exit on error
set -o pipefail  # Catch errors in pipes

echo "========================================================================="
echo "BOOTSTRAP STAGE 1: Building Minimal Cross-Compilation Toolchain"
echo "========================================================================="
echo "Package: ${PN}-${PV}"
echo "Target: x86_64-buckos-linux-gnu"
echo "Stage: Building cross-toolchain using HOST compiler"
echo "Isolation: PARTIAL (uses host compiler/libraries)"
echo "========================================================================="

# Export BOOTSTRAP_STAGE for packages that need conditional logic based on stage
export BOOTSTRAP_STAGE="stage1"

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

# Bootstrap configuration
BUCKOS_TARGET="x86_64-buckos-linux-gnu"
export BUCKOS_TARGET

# =============================================================================
# Stage 1: Dependency Path Setup
# =============================================================================
# Collect paths from dependencies for finding source packages, tools, etc.

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

    # Check if this is a bootstrap toolchain output (from earlier stage1 packages)
    # IMPORTANT: Skip cross-toolchains for FOREIGN architectures from PATH
    # These contain tools prefixed with target triplet (aarch64-buckos-linux-gnu-*)
    # If added to PATH, they shadow host tools like 'as' and break host builds
    # Cross-toolchain packages that need their tools should add them explicitly
    # Pattern: skip packages with architecture suffix like "-aarch64", "-arm", etc.
    # But allow native x86_64 cross-toolchains (cross-binutils, cross-gcc-pass1 without arch suffix)
    if [ -d "$dep_dir/tools/bin" ]; then
        if [[ "$dep_dir" == *"cross-"*"-aarch64"* ]] || \
           [[ "$dep_dir" == *"cross-"*"-arm"* ]] || \
           [[ "$dep_dir" == *"cross-"*"-riscv"* ]] || \
           [[ "$dep_dir" == *"cross-"*"-powerpc"* ]]; then
            echo "Skipping foreign-arch cross-toolchain from PATH: $dep_dir"
        else
            TOOLCHAIN_PATH="${TOOLCHAIN_PATH:+$TOOLCHAIN_PATH:}$dep_dir/tools/bin"
            if [ -z "$BOOTSTRAP_SYSROOT" ] && [ -d "$dep_dir/tools" ]; then
                BOOTSTRAP_SYSROOT="$dep_dir/tools"
            fi
        fi
    fi

    # Collect toolchain library paths
    if [ -d "$dep_dir/tools/lib" ]; then
        TOOLCHAIN_LIBPATH="${TOOLCHAIN_LIBPATH:+$TOOLCHAIN_LIBPATH:}$dep_dir/tools/lib"
    fi

    # Capture the full toolchain root directory (for glibc, etc)
    if [ -d "$dep_dir/usr/lib64" ] || [ -d "$dep_dir/usr/lib" ]; then
        TOOLCHAIN_ROOT="${TOOLCHAIN_ROOT:+$TOOLCHAIN_ROOT:}$dep_dir"
    fi

    # Capture include directory from toolchain dependencies (for linux-headers, etc)
    if [ -d "$dep_dir/usr/include" ]; then
        TOOLCHAIN_INCLUDE="${TOOLCHAIN_INCLUDE:+$TOOLCHAIN_INCLUDE:}$dep_dir"
    fi

    # Regular dependency paths
    if [ -d "$dep_dir/usr/bin" ]; then
        DEP_PATH="${DEP_PATH:+$DEP_PATH:}$dep_dir/usr/bin"
    fi
    if [ -d "$dep_dir/bin" ]; then
        DEP_PATH="${DEP_PATH:+$DEP_PATH:}$dep_dir/bin"
    fi
    if [ -d "$dep_dir/usr/sbin" ]; then
        DEP_PATH="${DEP_PATH:+$DEP_PATH:}$dep_dir/usr/sbin"
    fi
    if [ -d "$dep_dir/sbin" ]; then
        DEP_PATH="${DEP_PATH:+$DEP_PATH:}$dep_dir/sbin"
    fi

    # Add Python package paths
    for pypath in "$dep_dir/usr/lib/python"*/dist-packages "$dep_dir/usr/lib/python"*/site-packages; do
        if [ -d "$pypath" ]; then
            DEP_PYTHONPATH="${DEP_PYTHONPATH:+$DEP_PYTHONPATH:}$pypath"
        fi
    done
done

# Export toolchain paths for scripts that need them
export TOOLCHAIN_INCLUDE  # For --with-headers etc
export TOOLCHAIN_ROOT     # For copying toolchain files
export DEP_BASE_DIRS      # For packages that need direct access to dependency prefixes

# =============================================================================
# Stage 1: PATH Setup
# =============================================================================
# PATH priority: toolchain tools first, dependency tools, then HOST system
# Stage 1 ALLOWS host PATH fallback since we're building the initial toolchain

if [ -n "$TOOLCHAIN_PATH" ]; then
    export PATH="$TOOLCHAIN_PATH:$DEP_PATH:$PATH"
    echo "PATH (toolchain first): $TOOLCHAIN_PATH:$DEP_PATH:..."
elif [ -n "$DEP_PATH" ]; then
    export PATH="$DEP_PATH:$PATH"
    echo "PATH (deps first): $DEP_PATH:..."
else
    echo "PATH (host only): $PATH"
fi

# Set up PYTHONPATH for Python-based build tools
if [ -n "$DEP_PYTHONPATH" ]; then
    export PYTHONPATH="${DEP_PYTHONPATH}${PYTHONPATH:+:$PYTHONPATH}"
fi

# =============================================================================
# Stage 1: Clear Dangerous Environment Variables
# =============================================================================
# Clear host library paths to prevent HOST libraries from leaking in
# But we DON'T set LD_LIBRARY_PATH to toolchain libs yet - let the compiler
# find libraries naturally through its configured paths

unset LD_LIBRARY_PATH
unset LIBRARY_PATH
unset CPATH
unset C_INCLUDE_PATH
unset CPLUS_INCLUDE_PATH
unset PKG_CONFIG_PATH

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

# =============================================================================
# Stage 1: Compiler Setup
# =============================================================================
# CRITICAL: Stage 1 uses HOST compiler to build cross-compilation toolchain
# We explicitly use the host gcc/g++ to compile the cross-compiler itself

echo ""
echo "=== Stage 1 Build Configuration ==="
echo "BUILD_THREADS=$BUILD_THREADS"
echo "MAKE_JOBS=$MAKE_JOBS (nproc=$(nproc 2>/dev/null || echo 'N/A'))"
echo "Using HOST system compiler to build cross-toolchain"

# Use host compiler with C17/C++17 standards for GCC 15 compatibility
export CC="${CC:-gcc -std=gnu17}"
export CXX="${CXX:-g++ -std=gnu++17}"
export CPP="${CPP:-gcc -E}"
export CFLAGS="${CFLAGS:--O2 -std=gnu17}"
export CXXFLAGS="${CXXFLAGS:--O2 -std=gnu++17}"

echo "CC=$CC"
echo "CXX=$CXX"
echo "CFLAGS=$CFLAGS"
echo "CXXFLAGS=$CXXFLAGS"

# Standard build tools (host versions)
export AR="${AR:-ar}"
export AS="${AS:-as}"
export LD="${LD:-ld}"
export NM="${NM:-nm}"
export RANLIB="${RANLIB:-ranlib}"
export STRIP="${STRIP:-strip}"
export OBJCOPY="${OBJCOPY:-objcopy}"
export OBJDUMP="${OBJDUMP:-objdump}"
export READELF="${READELF:-readelf}"

# =============================================================================
# Stage 1: FOR_BUILD Variables
# =============================================================================
# When building cross-tools, some packages need to compile helper programs
# that run on the BUILD (host) system. These use *_FOR_BUILD variables.
#
# Example: GCC's genmodes program must run on the host to generate target files
#
# GCC 15 C23 compatibility: Force C17/C++17 for host compiler builds

export CC_FOR_BUILD="${CC_FOR_BUILD:-gcc}"
export CXX_FOR_BUILD="${CXX_FOR_BUILD:-g++}"
export CPP_FOR_BUILD="${CPP_FOR_BUILD:-gcc -E}"
export CFLAGS_FOR_BUILD="${CFLAGS_FOR_BUILD:--O2 -std=gnu17}"
export CXXFLAGS_FOR_BUILD="${CXXFLAGS_FOR_BUILD:--O2 -std=gnu++17}"
export CPPFLAGS_FOR_BUILD="${CPPFLAGS_FOR_BUILD:-}"
# CRITICAL: Force LDFLAGS_FOR_BUILD to empty string for Stage 1
# Stage 1 builds cross-toolchain, and build-time helper tools must run on the
# host without cross-compilation linker flags (--sysroot, -static-libstdc++, etc.)
export LDFLAGS_FOR_BUILD=""

echo "CC_FOR_BUILD=$CC_FOR_BUILD"
echo "CXX_FOR_BUILD=$CXX_FOR_BUILD"

# =============================================================================
# Stage 1: Library and Include Path Setup
# =============================================================================
# Set up library paths from dependencies for pkg-config and linking

DEP_LIBPATH=""
DEP_PKG_CONFIG_PATH=""

for dep_dir_raw in "${DEP_DIRS_ARRAY[@]}"; do
    # Convert to absolute path - crucial for libtool which cds during install
    if [[ "$dep_dir_raw" = /* ]]; then
        dep_dir="$dep_dir_raw"
    else
        dep_dir="$(cd "$dep_dir_raw" 2>/dev/null && pwd)" || dep_dir="$(pwd)/$dep_dir_raw"
    fi

    # Collect library paths (order: lib64, lib, tools/lib)
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
    if [ -d "$dep_dir/tools/lib" ]; then
        DEP_LIBPATH="${DEP_LIBPATH:+$DEP_LIBPATH:}$dep_dir/tools/lib"
    fi

    # Collect pkg-config paths
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

# CRITICAL: Do NOT accumulate LDFLAGS from all dependencies for Stage 1
# Stage 1 builds the cross-compiler using the HOST compiler, which should
# use host library paths naturally. Adding -L flags for all dependencies
# causes "Argument list too long" errors when the command line exceeds ARG_MAX.
# The cross-compiler doesn't need explicit -L flags; it links against host
# libraries via the host compiler's default search paths.
# Set LDFLAGS to empty string (not unset) so configure scripts work correctly.
export LDFLAGS=""

# Set up pkg-config
if [ -n "$DEP_PKG_CONFIG_PATH" ]; then
    export PKG_CONFIG_PATH="$DEP_PKG_CONFIG_PATH"
fi

# Use our pkg-config wrapper if available
if [ -f "$PKG_CONFIG_WRAPPER_SCRIPT" ]; then
    export PKG_CONFIG="$PKG_CONFIG_WRAPPER_SCRIPT"
    echo "Using pkg-config wrapper: $PKG_CONFIG_WRAPPER_SCRIPT"
fi

echo "=== End Stage 1 Setup ==="
echo ""

# =============================================================================
# Execute Build Phases
# =============================================================================
cd "$S"

# Source and execute the phases content (runs src_prepare, src_configure, src_compile, src_install)
eval "$PHASES_CONTENT"

# Verify output
echo ""
echo "=== Stage 1 Build Complete ==="
echo "Output directory: $DESTDIR"
if [ -d "$DESTDIR/tools" ]; then
    echo "Tools installed:"
    find "$DESTDIR/tools" -type f -name '*.so*' -o -type f -executable | head -20 || true
else
    echo "Warning: No /tools directory created"
fi

echo "========================================================================="
echo "BOOTSTRAP STAGE 1 COMPLETE: Cross-toolchain built successfully"
echo "========================================================================="
