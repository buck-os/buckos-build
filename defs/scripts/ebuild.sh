#!/bin/bash
# ebuild.sh - External ebuild build framework script
# This script is SOURCED by the wrapper, not executed directly.
# Changes to this script invalidate packages that use ebuild_package.
#
# Environment variables (set by wrapper):
#   _EBUILD_DESTDIR, _EBUILD_SRCDIR, _EBUILD_PKG_CONFIG_WRAPPER - paths
#   _EBUILD_DEP_DIRS - space-separated dependency directories
#   PN, PV, CATEGORY, SLOT, USE - package info
#   USE_BOOTSTRAP, BOOTSTRAP_SYSROOT - bootstrap config
#   PHASES_CONTENT - the build phases to execute

# Installation directories (from wrapper environment)
mkdir -p "$_EBUILD_DESTDIR"
export DESTDIR="$(cd "$_EBUILD_DESTDIR" && pwd)"
export OUT="$DESTDIR"  # Alias for compatibility
export S="$(cd "$_EBUILD_SRCDIR" && pwd)"
export WORKDIR="$(dirname "$S")"
export T="$WORKDIR/temp"
mkdir -p "$T"
PKG_CONFIG_WRAPPER_SCRIPT="$_EBUILD_PKG_CONFIG_WRAPPER"

# Convert dep dirs from space-separated to array
read -ra DEP_DIRS_ARRAY <<< "$_EBUILD_DEP_DIRS"

# Package variables are already exported by wrapper
export PACKAGE_NAME="$PN"

# Bootstrap configuration
BUCKOS_TARGET="x86_64-buckos-linux-gnu"

# Set up PATH from dependency directories
# Convert relative paths to absolute to ensure they work after cd "$S" in phases.sh
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
    # Check if this is the bootstrap toolchain or has tools dir
    if [ -d "$dep_dir/tools/bin" ]; then
        TOOLCHAIN_PATH="${TOOLCHAIN_PATH:+$TOOLCHAIN_PATH:}$dep_dir/tools/bin"
        # Set sysroot from toolchain if not explicitly provided
        if [ -z "$BOOTSTRAP_SYSROOT" ] && [ -d "$dep_dir/tools" ]; then
            BOOTSTRAP_SYSROOT="$dep_dir/tools"
        fi
    fi
    # Collect toolchain library paths for bootstrap tools (bash, etc)
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
    # Add Python package paths for tools like meson that need Python modules
    for pypath in "$dep_dir/usr/lib/python"*/dist-packages "$dep_dir/usr/lib/python"*/site-packages; do
        if [ -d "$pypath" ]; then
            DEP_PYTHONPATH="${DEP_PYTHONPATH:+$DEP_PYTHONPATH:}$pypath"
        fi
    done
done

# Export toolchain paths for scripts that need them
export TOOLCHAIN_INCLUDE  # For --with-headers etc
export TOOLCHAIN_ROOT     # For copying toolchain files

# For regular packages: prioritize host tools, but include toolchain at the end
# This way: host utilities (bash, make, etc.) are used first (avoiding GLIBC conflicts)
# But GCC can still find its internal programs (cc1, etc.) from TOOLCHAIN_PATH
if [ -n "$DEP_PATH" ] && [ -n "$TOOLCHAIN_PATH" ]; then
    export PATH="$DEP_PATH:$PATH:$TOOLCHAIN_PATH"
elif [ -n "$DEP_PATH" ]; then
    export PATH="$DEP_PATH:$PATH"
elif [ -n "$TOOLCHAIN_PATH" ]; then
    export PATH="$PATH:$TOOLCHAIN_PATH"
fi

# Set up PYTHONPATH for Python-based build tools (meson, etc)
if [ -n "$DEP_PYTHONPATH" ]; then
    export PYTHONPATH="${DEP_PYTHONPATH}${PYTHONPATH:+:$PYTHONPATH}"
fi

# IMPORTANT: Clear host library paths to prevent host glibc/libraries from leaking
# into the build. This ensures packages link against buckos-provided libraries only.
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
# Bootstrap Toolchain Setup
# =============================================================================
# Track whether cross-compilation is actually active (not just requested)
CROSS_COMPILING="false"

# Skip bootstrap toolchain setup if host toolchain is configured
if [ "$USE_HOST_TOOLCHAIN" = "true" ]; then
    echo "=== Using Host System Toolchain ==="
    echo "Bootstrap toolchain: DISABLED"
    echo "Compiler: $(gcc --version 2>/dev/null | head -1 || echo 'gcc (not found)')"
    echo "====================================="
    # Use system compiler as-is
    export CC="${CC:-gcc}"
    export CXX="${CXX:-g++}"
    export CPP="${CPP:-gcc -E}"
    # Standard tools (AR, AS, etc.) are in PATH and will be auto-detected
elif [ "$USE_BOOTSTRAP" = "true" ]; then
    # Verify the cross-compiler actually exists
    if [ -n "$TOOLCHAIN_PATH" ] && [ -x "$TOOLCHAIN_PATH/${BUCKOS_TARGET}-gcc" ]; then
        CROSS_COMPILING="true"
        echo "=== Using Bootstrap Toolchain ==="
        echo "Target: $BUCKOS_TARGET"
        echo "Sysroot: $BOOTSTRAP_SYSROOT"
        echo "Toolchain PATH: $TOOLCHAIN_PATH"

        # Set cross-compilation environment variables
        # Use binary names (not absolute paths) so GCC can find its internal programs
        # The cross-compiler will be found via TOOLCHAIN_PATH at end of PATH
        export CC="${BUCKOS_TARGET}-gcc"
        export CXX="${BUCKOS_TARGET}-g++"
        export CPP="${BUCKOS_TARGET}-gcc -E"
        export AR="${BUCKOS_TARGET}-ar"
        export AS="${BUCKOS_TARGET}-as"
        export LD="${BUCKOS_TARGET}-ld"
        export NM="${BUCKOS_TARGET}-nm"
        export RANLIB="${BUCKOS_TARGET}-ranlib"
        export STRIP="${BUCKOS_TARGET}-strip"
        export OBJCOPY="${BUCKOS_TARGET}-objcopy"
        export OBJDUMP="${BUCKOS_TARGET}-objdump"
        export READELF="${BUCKOS_TARGET}-readelf"

        # Set sysroot for all compilation
        if [ -n "$BOOTSTRAP_SYSROOT" ]; then
            SYSROOT_FLAGS="--sysroot=$BOOTSTRAP_SYSROOT"
            export CFLAGS="${CFLAGS:-} $SYSROOT_FLAGS"
            export CXXFLAGS="${CXXFLAGS:-} $SYSROOT_FLAGS"
            export LDFLAGS="${LDFLAGS:-} $SYSROOT_FLAGS"

            # Set pkg-config to use sysroot
            export PKG_CONFIG_SYSROOT_DIR="$BOOTSTRAP_SYSROOT"
            export PKG_CONFIG_PATH="$BOOTSTRAP_SYSROOT/usr/lib/pkgconfig:$BOOTSTRAP_SYSROOT/usr/share/pkgconfig"
        fi

        # For autotools, set build/host triplets
        export BUILD_TRIPLET="$(gcc -dumpmachine)"
        export HOST_TRIPLET="$BUCKOS_TARGET"

        echo "CC=$CC"
        echo "CXX=$CXX"
        echo "CFLAGS=$CFLAGS"
        echo "==================================="
    else
        echo "=== Bootstrap toolchain requested but not available ==="
        echo "Cross-compiler not found, using host compiler"
        echo "This is expected for bootstrap stage 1 packages"
    fi
fi

# =============================================================================
# Host Build Environment (FOR_BUILD variables)
# =============================================================================
# When cross-compiling, some packages need to build host tools (like mkbuiltins
# for bash). These tools must be compiled with the HOST compiler using clean
# flags, not the cross-compiler or cross-compilation flags.
# Export *_FOR_BUILD variables that packages can use in their Makefiles.
#
# GCC 15 C23 compatibility fix: GCC 15 defaults to C23 which breaks GCC's own
# libiberty/obstack.c when bootstrapping. Force C17 for host compiler.
export CC_FOR_BUILD="${CC_FOR_BUILD:-gcc -std=gnu17}"
export CXX_FOR_BUILD="${CXX_FOR_BUILD:-g++ -std=gnu++17}"
export CPP_FOR_BUILD="${CPP_FOR_BUILD:-gcc -E}"
export CFLAGS_FOR_BUILD="${CFLAGS_FOR_BUILD:--O2 -std=gnu17}"
export CXXFLAGS_FOR_BUILD="${CXXFLAGS_FOR_BUILD:--O2 -std=gnu++17}"
export LDFLAGS_FOR_BUILD="${LDFLAGS_FOR_BUILD:-}"
export CPPFLAGS_FOR_BUILD="${CPPFLAGS_FOR_BUILD:-}"

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
    # Bootstrap toolchain uses /tools/lib
    if [ -d "$dep_dir/tools/lib" ]; then
        DEP_LIBPATH="${DEP_LIBPATH:+$DEP_LIBPATH:}$dep_dir/tools/lib"
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
# LD_LIBRARY_PATH handling:
# - Never include /tools/lib paths (bootstrap toolchain) as those are cross-compiled
#   libraries that will break the host shell and tools.
# - For active cross-compilation: DON'T set LD_LIBRARY_PATH at all.
# - For regular builds: Set LD_LIBRARY_PATH with non-toolchain library paths so that
#   build tools (python3, etc.) from dependencies can find their shared libraries.
if [ -n "$DEP_LIBPATH" ]; then
    if [ "$CROSS_COMPILING" != "true" ]; then
        # Filter out /tools/lib paths which are cross-compiled and break host tools
        HOST_LIBPATH=""
        IFS=':' read -ra LIBPATH_PARTS <<< "$DEP_LIBPATH"
        for libpath in "${LIBPATH_PARTS[@]}"; do
            if [[ "$libpath" != */tools/lib* ]]; then
                HOST_LIBPATH="${HOST_LIBPATH:+$HOST_LIBPATH:}$libpath"
            fi
        done
        if [ -n "$HOST_LIBPATH" ]; then
            export LD_LIBRARY_PATH="${HOST_LIBPATH}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        fi
    fi
    export LIBRARY_PATH="${DEP_LIBPATH}"
    DEP_LDFLAGS=""
    IFS=':' read -ra LIB_DIRS <<< "$DEP_LIBPATH"
    for lib_dir in "${LIB_DIRS[@]}"; do
        # Use -rpath-link for build-time linking, NOT -rpath
        # -rpath embeds build paths in binaries causing runtime issues
        # Libraries should be found via ld.so.conf and standard paths
        DEP_LDFLAGS="${DEP_LDFLAGS} -L$lib_dir -Wl,-rpath-link,$lib_dir"
    done
    export LDFLAGS="${LDFLAGS:-} $DEP_LDFLAGS"
fi
if [ -n "$DEP_PKG_CONFIG_PATH" ]; then
    export PKG_CONFIG_LIBDIR="${DEP_PKG_CONFIG_PATH}"
    unset PKG_CONFIG_PATH
    unset PKG_CONFIG_SYSROOT_DIR
fi

# =============================================================================
# pkg-config Wrapper for Build Isolation
# =============================================================================
declare -A PKGCONFIG_PREFIX_MAP
for dep_dir_raw in "${DEP_DIRS_ARRAY[@]}"; do
    if [[ "$dep_dir_raw" = /* ]]; then
        dep_dir="$dep_dir_raw"
    else
        dep_dir="$(cd "$dep_dir_raw" 2>/dev/null && pwd)" || continue
    fi
    for pc_subdir in usr/lib64/pkgconfig usr/lib/pkgconfig usr/share/pkgconfig lib64/pkgconfig lib/pkgconfig; do
        if [ -d "$dep_dir/$pc_subdir" ]; then
            PKGCONFIG_PREFIX_MAP["$dep_dir/$pc_subdir"]="$dep_dir"
        fi
    done
done
export PKGCONFIG_PREFIX_MAP

# Copy external pkg-config wrapper to temp directory
mkdir -p "$T/bin"
cp "$PKG_CONFIG_WRAPPER_SCRIPT" "$T/bin/pkg-config"
chmod +x "$T/bin/pkg-config"
export PATH="$T/bin:$PATH"

# Set up include paths from dependencies
DEP_CPATH=""
for dep_dir_raw in "${DEP_DIRS_ARRAY[@]}"; do
    if [[ "$dep_dir_raw" = /* ]]; then
        dep_dir="$dep_dir_raw"
    else
        dep_dir="$(cd "$dep_dir_raw" 2>/dev/null && pwd)" || dep_dir="$(pwd)/$dep_dir_raw"
    fi
    if [ -d "$dep_dir/usr/include" ]; then
        DEP_CPATH="${DEP_CPATH:+$DEP_CPATH:}$dep_dir/usr/include"
    fi
    if [ -d "$dep_dir/include" ]; then
        DEP_CPATH="${DEP_CPATH:+$DEP_CPATH:}$dep_dir/include"
    fi
    # Bootstrap toolchain uses /tools/include
    if [ -d "$dep_dir/tools/include" ]; then
        DEP_CPATH="${DEP_CPATH:+$DEP_CPATH:}$dep_dir/tools/include"
    fi
done
if [ -n "$DEP_CPATH" ]; then
    export CPATH="${DEP_CPATH}"
    export C_INCLUDE_PATH="${DEP_CPATH}"
    export CPLUS_INCLUDE_PATH="${DEP_CPATH}"

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
fi

# Set up linker flags
if [ -n "$DEP_LIBPATH" ]; then
    LDFLAGS_LIBPATH=""
    RPATH_LINK=""
    IFS=':' read -ra LIBPATH_ARRAY <<< "$DEP_LIBPATH"
    for libpath in "${LIBPATH_ARRAY[@]}"; do
        LDFLAGS_LIBPATH="${LDFLAGS_LIBPATH} -L$libpath"
        RPATH_LINK="${RPATH_LINK} -Wl,-rpath-link,$libpath"
    done
    export LDFLAGS="${LDFLAGS_LIBPATH}${RPATH_LINK}${LDFLAGS:+ $LDFLAGS}"
fi

export EPREFIX="${EPREFIX:-}"
export PREFIX="${PREFIX:-/usr}"
export LIBDIR="${LIBDIR:-lib64}"
export LIBDIR_SUFFIX="${LIBDIR_SUFFIX:-64}"

# Build directories
export BUILD_DIR="${BUILD_DIR:-$S/build}"
export FILESDIR="${FILESDIR:-}"

# Clean temp (preserve pkg-config wrapper in $T/bin)
rm -rf "$T/phases.sh" "$T/phases-run.sh" 2>/dev/null || true

# USE flag helper
use() {
    [[ " $USE " == *" $1 "* ]]
}

cd "$S"

# Export all critical environment variables
export DESTDIR S EPREFIX PREFIX LIBDIR LIBDIR_SUFFIX BUILD_DIR WORKDIR T FILESDIR
export PATH PYTHONPATH PKG_CONFIG_PATH PKG_CONFIG_LIBDIR DEP_BASE_DIRS

# Export cross-compilation variables if set
if [ -n "$CC" ]; then
    export CC CXX AR AS LD NM RANLIB STRIP OBJCOPY OBJDUMP READELF
    export CFLAGS CXXFLAGS LDFLAGS
    export CHOST CBUILD
fi

# Run the phases (from PHASES_CONTENT environment variable set by wrapper)
if [ -n "$PHASES_CONTENT" ]; then
    # Write phases to temp file for execution
    # IMPORTANT: Prepend PATH export to ensure it's available in unshare environment
    {
        echo "#!/bin/bash"
        echo "# Explicitly set PATH to ensure toolchain binaries are found"
        echo "export PATH=\"$PATH\""
        [ -n "$TOOLCHAIN_PATH" ] && echo "export TOOLCHAIN_PATH=\"$TOOLCHAIN_PATH\""
        [ -n "$DEP_PATH" ] && echo "export DEP_PATH=\"$DEP_PATH\""
        echo ""
        echo "$PHASES_CONTENT"
    } > "$T/phases.sh"
    chmod +x "$T/phases.sh"

    # NOTE: We do NOT set LD_LIBRARY_PATH to bootstrap toolchain libraries here
    # because we use host bash to run build scripts (see below). Setting LD_LIBRARY_PATH
    # to bootstrap libraries would cause host bash to try loading incompatible libraries,
    # resulting in segmentation faults. The bootstrap cross-compiler finds its libraries
    # through --sysroot and -rpath-link flags set in CFLAGS/LDFLAGS.

    # Determine which bash to use for phases
    # NOTE: We use host bash even when bootstrap toolchain is available because
    # bootstrap bash has the host's dynamic linker hardcoded (/lib64/ld-linux-x86-64.so.2)
    # which causes GLIBC version conflicts. The build phases just need a working bash;
    # what matters is that the *compiler* uses the bootstrap toolchain.
    PHASES_BASH="bash"

    # Skip unshare for bootstrap builds and use host bash to avoid GLIBC issues
    if [[ "$PHASES_BASH" == *"bootstrap-bash"* ]] || [[ "$PN" == *"bootstrap"* ]]; then
        echo "⚠ Bootstrap build detected, using host bash and tools to avoid compatibility issues"

        # Use env -i to start with clean environment, only keep essential variables
        # This ensures we don't inherit problematic environment from bootstrap tools
        env -i \
            PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
            HOME="$HOME" \
            S="$S" \
            T="$T" \
            DESTDIR="$DESTDIR" \
            PN="$PN" \
            PV="$PV" \
            USE="$USE" \
            DEP_BASE_DIRS="$DEP_BASE_DIRS" \
            /bin/bash --norc --noprofile "$T/phases.sh"
    elif command -v unshare >/dev/null 2>&1 && unshare --net true 2>/dev/null; then
        echo "🔒 Running build phases in network-isolated environment (no internet access)"
        # Explicitly preserve all environment variables and use --norc --noprofile to prevent
        # bash from sourcing profile files that might reset PATH
        # IMPORTANT: Also preserve TOOLCHAIN_PATH and DEP_PATH for PATH reconstruction
        unshare --net -- env \
            PATH="$PATH" \
            TOOLCHAIN_PATH="$TOOLCHAIN_PATH" \
            DEP_PATH="$DEP_PATH" \
            CC="$CC" \
            CXX="$CXX" \
            CPP="$CPP" \
            AR="$AR" \
            AS="$AS" \
            LD="$LD" \
            NM="$NM" \
            RANLIB="$RANLIB" \
            STRIP="$STRIP" \
            OBJCOPY="$OBJCOPY" \
            OBJDUMP="$OBJDUMP" \
            READELF="$READELF" \
            CFLAGS="$CFLAGS" \
            CXXFLAGS="$CXXFLAGS" \
            LDFLAGS="$LDFLAGS" \
            CPPFLAGS="$CPPFLAGS" \
            PKG_CONFIG_PATH="$PKG_CONFIG_PATH" \
            PKG_CONFIG_LIBDIR="$PKG_CONFIG_LIBDIR" \
            ACLOCAL_PATH="$ACLOCAL_PATH" \
            HOME="$HOME" \
            S="$S" \
            T="$T" \
            DESTDIR="$DESTDIR" \
            PN="$PN" \
            PV="$PV" \
            USE="$USE" \
            DEP_BASE_DIRS="$DEP_BASE_DIRS" \
            CROSS_COMPILING="$CROSS_COMPILING" \
            BUCKOS_TARGET="$BUCKOS_TARGET" \
            BOOTSTRAP_SYSROOT="$BOOTSTRAP_SYSROOT" \
            /bin/bash --norc --noprofile "$T/phases.sh"
    else
        echo "⚠ Warning: unshare not available or insufficient permissions, building without network isolation"
        "$PHASES_BASH" "$T/phases.sh"
    fi
else
    echo "ERROR: PHASES_CONTENT not set" >&2
    exit 1
fi

# =============================================================================
# Post-build verification
# =============================================================================
echo ""
echo "📋 Verifying build output..."
echo "DEBUG: Current directory: $(pwd)"
echo "DEBUG: DESTDIR='$DESTDIR'"
echo "DEBUG: DESTDIR exists? $([ -d "$DESTDIR" ] && echo 'yes' || echo 'no')"

# IMPORTANT: Disable verification for bootstrap builds
# Bootstrap-toolchain is a meta-package that just collects files from dependencies
# The files exist but may not be accessible during verification due to Buck2 sandboxing
if [[ "$PN" == "bootstrap-toolchain" ]]; then
    echo "⚠ Skipping verification for bootstrap-toolchain meta-package"
    echo "✓ Bootstrap toolchain package created successfully"
else
    # Regular verification for non-bootstrap packages
    FILE_COUNT=$(/usr/bin/find "$DESTDIR" -type f 2>/dev/null | /usr/bin/wc -l)
    DIR_COUNT=$(/usr/bin/find "$DESTDIR" -type d 2>/dev/null | /usr/bin/wc -l)

    # Strip whitespace from counts
    FILE_COUNT=$(echo "$FILE_COUNT" | /usr/bin/tr -d ' \t\n\r')
    DIR_COUNT=$(echo "$DIR_COUNT" | /usr/bin/tr -d ' \t\n\r')

    if [ "$FILE_COUNT" -eq 0 ]; then
        echo "" >&2
        echo "✗ BUILD VERIFICATION FAILED: No files were installed" >&2
        echo "  Package: $PN-$PV" >&2
        echo "  DESTDIR: $DESTDIR" >&2
        echo "" >&2
        echo "  This usually means:" >&2
        echo "  1. The build succeeded but 'make install' didn't use DESTDIR" >&2
        echo "  2. The install phase has incorrect paths" >&2
        echo "  3. The package installed to the wrong location" >&2
        exit 1
    fi

    echo "✓ Build verification passed: $FILE_COUNT files in $DIR_COUNT directories"

    echo ""
    echo "📂 Installed files summary:"
fi

# Skip summary for bootstrap-toolchain
if [[ "$PN" != "bootstrap-toolchain" ]]; then
/usr/bin/find "$DESTDIR" -type d -name "bin" -exec sh -c 'echo "  Binaries: $(/usr/bin/ls "$1" 2>/dev/null | /usr/bin/wc -l) files in $1"' _ {} \;
/usr/bin/find "$DESTDIR" -type d -name "lib" -o -name "lib64" 2>/dev/null | /usr/bin/head -2 | while read d; do
    echo "  Libraries: $(/usr/bin/find "$d" -maxdepth 1 -name "*.so*" -o -name "*.a" 2>/dev/null | /usr/bin/wc -l) files in $d"
done
/usr/bin/find "$DESTDIR" -type d -name "include" 2>/dev/null | /usr/bin/head -1 | while read d; do
    echo "  Headers: $(/usr/bin/find "$d" -name "*.h" 2>/dev/null | /usr/bin/wc -l) files in $d"
done
fi
