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

# Prevent cd from outputting paths when CDPATH is set
unset CDPATH

# === GUARD RAILS: Validate required environment variables ===
_ebuild_fail() {
    echo "ERROR: $1" >&2
    echo "  Package: ${PN:-unknown}" >&2
    exit 1
}

if [[ -z "$_EBUILD_DESTDIR" ]]; then
    _ebuild_fail "DESTDIR not set - wrapper script misconfigured"
fi
if [[ -z "$_EBUILD_SRCDIR" ]]; then
    _ebuild_fail "SRCDIR not set - wrapper script misconfigured"
fi
if [[ ! -d "$_EBUILD_SRCDIR" ]]; then
    _ebuild_fail "Source directory does not exist: $_EBUILD_SRCDIR
  This usually means:
  1. The download_source target failed
  2. The source archive has an unexpected structure (wrong strip_components?)
  3. The source extraction silently failed"
fi
if [[ -z "$(ls -A "$_EBUILD_SRCDIR" 2>/dev/null)" ]]; then
    _ebuild_fail "Source directory is empty: $_EBUILD_SRCDIR
  The archive may have extracted to a different location.
  Check strip_components setting in download_source."
fi

# Installation directories (from wrapper environment)
mkdir -p "$_EBUILD_DESTDIR"
export DESTDIR="$(cd "$_EBUILD_DESTDIR" && pwd)"
export OUT="$DESTDIR"  # Alias for compatibility
export S="$(cd "$_EBUILD_SRCDIR" && pwd)"
export WORKDIR="$(dirname "$S")"
export T="$WORKDIR/temp"
mkdir -p "$T"

# Ensure source files are writable - Buck may materialize them read-only between actions
# This is critical for builds that modify source files during configure/compile/install
chmod -R u+w "$S" 2>/dev/null || true

PKG_CONFIG_WRAPPER_SCRIPT="$_EBUILD_PKG_CONFIG_WRAPPER"

# Convert dep dirs from space-separated to array
read -ra DEP_DIRS_ARRAY <<< "$_EBUILD_DEP_DIRS"

# Convert host tool dirs from space-separated to array
# These are build tools (autoconf, gawk, meson, etc.) built for the HOST platform
read -ra HOST_TOOL_DIRS_ARRAY <<< "$_EBUILD_HOST_TOOL_DIRS"

# Package variables are already exported by wrapper
export PACKAGE_NAME="$PN"

# Bootstrap configuration - will be auto-detected from cross-compiler
BUCKOS_TARGET=""

# Build HOST_TOOL_PATH from host tool directories (exec_bdepend)
# These are tools built for the HOST platform that need to run during the build
HOST_TOOL_PATH=""
HOST_TOOL_PYTHONPATH=""
EXEC_BDEP_BASE_DIRS=""
for tool_dir in "${HOST_TOOL_DIRS_ARRAY[@]}"; do
    # Convert to absolute path if relative
    if [[ "$tool_dir" != /* ]]; then
        tool_dir="$(cd "$tool_dir" 2>/dev/null && pwd)" || continue
    fi
    # Store base directory for packages that need direct access (e.g., ICU cross-compilation)
    EXEC_BDEP_BASE_DIRS="${EXEC_BDEP_BASE_DIRS:+$EXEC_BDEP_BASE_DIRS:}$tool_dir"
    if [ -d "$tool_dir/usr/bin" ]; then
        HOST_TOOL_PATH="${HOST_TOOL_PATH:+$HOST_TOOL_PATH:}$tool_dir/usr/bin"
    fi
    if [ -d "$tool_dir/bin" ]; then
        HOST_TOOL_PATH="${HOST_TOOL_PATH:+$HOST_TOOL_PATH:}$tool_dir/bin"
    fi
    # Add Python package paths for tools like meson that need Python modules
    for pypath in "$tool_dir/usr/lib/python"*/dist-packages "$tool_dir/usr/lib/python"*/site-packages; do
        if [ -d "$pypath" ]; then
            HOST_TOOL_PYTHONPATH="${HOST_TOOL_PYTHONPATH:+$HOST_TOOL_PYTHONPATH:}$pypath"
        fi
    done
done

# Set up PATH from dependency directories
# Convert relative paths to absolute to ensure they work after cd "$S" in phases.sh
DEP_PATH=""
DEP_PYTHONPATH=""
DEP_BASE_DIRS=""
TOOLCHAIN_PATH=""
TOOLCHAIN_LIBPATH=""
TOOLCHAIN_INCLUDE=""
TOOLCHAIN_ROOT=""
BOOTSTRAP_TOOLCHAIN_BIN=""  # Store bootstrap-toolchain bin dir for CC/CXX absolute paths
for dep_dir in "${DEP_DIRS_ARRAY[@]}"; do
    # Convert to absolute path if relative
    if [[ "$dep_dir" != /* ]]; then
        dep_dir="$(cd "$dep_dir" 2>/dev/null && pwd)" || continue
    fi
    # Store base directory for packages that need direct access
    DEP_BASE_DIRS="${DEP_BASE_DIRS:+$DEP_BASE_DIRS:}$dep_dir"
    # Check if this is a toolchain directory with cross-compiler tools
    if [ -d "$dep_dir/tools/bin" ]; then
        # Check if this is bootstrap-toolchain (aggregated package with both
        # cross-compiler AND cross-compiled utilities like gawk, make, sed)
        if [[ "$dep_dir" == *"bootstrap-toolchain"* ]]; then
            # Store for absolute path CC/CXX setup, but DON'T add to PATH
            # This avoids using cross-compiled gawk/make/sed that crash on host
            BOOTSTRAP_TOOLCHAIN_BIN="$dep_dir/tools/bin"
            if [ -z "$BOOTSTRAP_SYSROOT" ]; then
                BOOTSTRAP_SYSROOT="$dep_dir/tools"
            fi
            # Auto-detect BUCKOS_TARGET from cross-compiler name
            if [ -z "$BUCKOS_TARGET" ]; then
                for compiler in "$dep_dir/tools/bin/"*-buckos-linux-gnu-gcc; do
                    if [ -f "$compiler" ]; then
                        BUCKOS_TARGET=$(basename "$compiler" | sed 's/-gcc$//')
                        break
                    fi
                done
            fi
        else
            # For non-aggregated toolchain packages (cross-gcc-pass2, cross-binutils),
            # check if they have the cross-compiler and add to PATH
            for compiler in "$dep_dir/tools/bin/"*-buckos-linux-gnu-gcc; do
                if [ -f "$compiler" ]; then
                    TOOLCHAIN_PATH="${TOOLCHAIN_PATH:+$TOOLCHAIN_PATH:}$dep_dir/tools/bin"
                    if [ -z "$BOOTSTRAP_SYSROOT" ]; then
                        BOOTSTRAP_SYSROOT="$dep_dir/tools"
                    fi
                    # Auto-detect BUCKOS_TARGET from cross-compiler name
                    if [ -z "$BUCKOS_TARGET" ]; then
                        BUCKOS_TARGET=$(basename "$compiler" | sed 's/-gcc$//')
                    fi
                    break
                fi
            done
            # If no gcc found, check for binutils (separate package)
            if [[ "$TOOLCHAIN_PATH" != *"$dep_dir/tools/bin"* ]]; then
                for linker in "$dep_dir/tools/bin/"*-buckos-linux-gnu-ld; do
                    if [ -f "$linker" ]; then
                        TOOLCHAIN_PATH="${TOOLCHAIN_PATH:+$TOOLCHAIN_PATH:}$dep_dir/tools/bin"
                        # Auto-detect BUCKOS_TARGET from linker name
                        if [ -z "$BUCKOS_TARGET" ]; then
                            BUCKOS_TARGET=$(basename "$linker" | sed 's/-ld$//')
                        fi
                        break
                    fi
                done
            fi
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
# Priority: /usr/bin:/bin (host essentials) > HOST_TOOL_PATH > DEP_PATH > system PATH > TOOLCHAIN_PATH
# CRITICAL: Always ensure /usr/bin and /bin are at the front to guarantee host utilities
# are found first, preventing GLIBC version mismatches from target-built tools
HOST_ESSENTIAL_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
if [ -n "$HOST_TOOL_PATH" ]; then
    export PATH="$HOST_ESSENTIAL_PATH:$HOST_TOOL_PATH:$DEP_PATH:$PATH:$TOOLCHAIN_PATH"
elif [ -n "$DEP_PATH" ] && [ -n "$TOOLCHAIN_PATH" ]; then
    export PATH="$HOST_ESSENTIAL_PATH:$DEP_PATH:$PATH:$TOOLCHAIN_PATH"
elif [ -n "$DEP_PATH" ]; then
    export PATH="$HOST_ESSENTIAL_PATH:$DEP_PATH:$PATH"
elif [ -n "$TOOLCHAIN_PATH" ]; then
    export PATH="$HOST_ESSENTIAL_PATH:$PATH:$TOOLCHAIN_PATH"
else
    export PATH="$HOST_ESSENTIAL_PATH:$PATH"
fi

# Force use of host system text processing tools to avoid GLIBC version mismatches
# These tools might be in DEP_PATH from target builds, but they need to run on the host
# Setting these environment variables ensures configure scripts use host binaries
# EXCEPTION: Don't set these vars when building the tools themselves (bootstrap issue)
# grep's configure fails if GREP is set, gawk's configure might have similar issues
if [ "$PN" != "gawk" ]; then
    if command -v /usr/bin/gawk >/dev/null 2>&1; then
        export AWK=/usr/bin/gawk
        export GAWK=/usr/bin/gawk
    elif command -v /usr/bin/awk >/dev/null 2>&1; then
        export AWK=/usr/bin/awk
    fi
fi
if command -v /usr/bin/sed >/dev/null 2>&1; then
    export SED=/usr/bin/sed
fi
# NOTE: grep's configure explicitly checks if GREP/EGREP are set and fails if so
# This is a bootstrap protection - don't set GREP when building grep itself
if [ "$PN" != "grep" ]; then
    if command -v /usr/bin/grep >/dev/null 2>&1; then
        export GREP=/usr/bin/grep
    fi
fi
if command -v /usr/bin/m4 >/dev/null 2>&1; then
    export M4=/usr/bin/m4
fi

# Set up PYTHONPATH for Python-based build tools (meson, etc)
# Prioritize host tool Python paths over target dep Python paths
if [ -n "$HOST_TOOL_PYTHONPATH" ]; then
    export PYTHONPATH="${HOST_TOOL_PYTHONPATH}${DEP_PYTHONPATH:+:$DEP_PYTHONPATH}${PYTHONPATH:+:$PYTHONPATH}"
elif [ -n "$DEP_PYTHONPATH" ]; then
    export PYTHONPATH="${DEP_PYTHONPATH}${PYTHONPATH:+:$PYTHONPATH}"
fi

# Set up PERL5LIB for Perl-based build tools (autoconf, automake, etc)
# Autoconf installs its Perl modules to /usr/share/autoconf
# The autoreconf script uses $autom4te_perllibdir to find its modules
# Automake/aclocal uses AUTOMAKE_PERLLIBDIR for data files (am/*.am)
DEP_PERL5LIB=""
HOST_PERL5LIB=""
AUTOCONF_PERLLIBDIR=""
AUTOMAKE_PERLLIBDIR=""
ACLOCAL_AUTOMAKE_DIR=""
ACLOCAL_PATH=""

# First process HOST_TOOL_DIRS (exec_bdepend - autoconf/automake from host platform)
for tool_dir in "${HOST_TOOL_DIRS_ARRAY[@]}"; do
    if [[ "$tool_dir" != /* ]]; then
        tool_dir="$(cd "$tool_dir" 2>/dev/null && pwd)" || continue
    fi
    # Autoconf Perl modules - set autom4te_perllibdir for autoreconf
    if [ -d "$tool_dir/usr/share/autoconf" ]; then
        HOST_PERL5LIB="${HOST_PERL5LIB:+$HOST_PERL5LIB:}$tool_dir/usr/share/autoconf"
        if [ -z "$AUTOCONF_PERLLIBDIR" ]; then
            AUTOCONF_PERLLIBDIR="$tool_dir/usr/share/autoconf"
        fi
    fi
    # Automake Perl modules and data files
    for am_dir in "$tool_dir/usr/share/automake"*; do
        if [ -d "$am_dir" ]; then
            HOST_PERL5LIB="${HOST_PERL5LIB:+$HOST_PERL5LIB:}$am_dir"
            if [ -z "$AUTOMAKE_PERLLIBDIR" ]; then
                AUTOMAKE_PERLLIBDIR="$am_dir"
            fi
        fi
    done
    # aclocal directories
    for aclocal_dir in "$tool_dir/usr/share/aclocal"*; do
        if [ -d "$aclocal_dir" ]; then
            if [[ "$aclocal_dir" == *"aclocal-"* ]]; then
                if [ -z "$ACLOCAL_AUTOMAKE_DIR" ]; then
                    ACLOCAL_AUTOMAKE_DIR="$aclocal_dir"
                fi
            fi
            ACLOCAL_PATH="${ACLOCAL_PATH:+$ACLOCAL_PATH:}$aclocal_dir"
        fi
    done
    # Standard Perl lib directories
    for perl_lib in \
        "$tool_dir/usr/share/perl5" \
        "$tool_dir/usr/share/perl5/vendor_perl" \
        "$tool_dir/usr/lib/perl5" \
        "$tool_dir/usr/lib/perl5/vendor_perl" \
        "$tool_dir/usr/lib64/perl5" \
        "$tool_dir/usr/lib64/perl5/vendor_perl"; do
        if [ -d "$perl_lib" ]; then
            HOST_PERL5LIB="${HOST_PERL5LIB:+$HOST_PERL5LIB:}$perl_lib"
        fi
    done
done

# Then process DEP_DIRS (bdepend - target platform dependencies)
for dep_dir in "${DEP_DIRS_ARRAY[@]}"; do
    if [[ "$dep_dir" != /* ]]; then
        dep_dir="$(cd "$dep_dir" 2>/dev/null && pwd)" || continue
    fi
    # Autoconf Perl modules - set autom4te_perllibdir for autoreconf
    if [ -d "$dep_dir/usr/share/autoconf" ]; then
        DEP_PERL5LIB="${DEP_PERL5LIB:+$DEP_PERL5LIB:}$dep_dir/usr/share/autoconf"
        # autoreconf uses autom4te_perllibdir to find its modules
        if [ -z "$AUTOCONF_PERLLIBDIR" ]; then
            AUTOCONF_PERLLIBDIR="$dep_dir/usr/share/autoconf"
        fi
    fi
    # Automake Perl modules and data files (am/*.am, Automake/*.pm)
    # AUTOMAKE_PERLLIBDIR tells automake.real where to find its data files
    for am_dir in "$dep_dir/usr/share/automake"*; do
        if [ -d "$am_dir" ]; then
            DEP_PERL5LIB="${DEP_PERL5LIB:+$DEP_PERL5LIB:}$am_dir"
            # Set AUTOMAKE_PERLLIBDIR to the first automake-X.XX directory found
            if [ -z "$AUTOMAKE_PERLLIBDIR" ]; then
                AUTOMAKE_PERLLIBDIR="$am_dir"
            fi
        fi
    done
    # aclocal-X.XX directories for automake macros (e.g., aclocal-1.16)
    for aclocal_dir in "$dep_dir/usr/share/aclocal"*; do
        if [ -d "$aclocal_dir" ]; then
            # If this is aclocal-X.XX (versioned), set ACLOCAL_AUTOMAKE_DIR
            if [[ "$aclocal_dir" == *"aclocal-"* ]]; then
                if [ -z "$ACLOCAL_AUTOMAKE_DIR" ]; then
                    ACLOCAL_AUTOMAKE_DIR="$aclocal_dir"
                fi
            fi
            # Add all aclocal dirs to ACLOCAL_PATH
            ACLOCAL_PATH="${ACLOCAL_PATH:+$ACLOCAL_PATH:}$aclocal_dir"
        fi
    done
    # gettext installs its m4 macros (AM_GNU_GETTEXT, AM_ICONV, etc.) to
    # /usr/share/gettext/m4/ instead of /usr/share/aclocal/, so we need to
    # add that directory to ACLOCAL_PATH as well
    if [ -d "$dep_dir/usr/share/gettext/m4" ]; then
        ACLOCAL_PATH="${ACLOCAL_PATH:+$ACLOCAL_PATH:}$dep_dir/usr/share/gettext/m4"
    fi
    # Standard Perl lib directories (including vendor_perl for CPAN modules)
    for perl_lib in \
        "$dep_dir/usr/share/perl5" \
        "$dep_dir/usr/share/perl5/vendor_perl" \
        "$dep_dir/usr/lib/perl5" \
        "$dep_dir/usr/lib/perl5/vendor_perl" \
        "$dep_dir/usr/lib64/perl5" \
        "$dep_dir/usr/lib64/perl5/vendor_perl"; do
        if [ -d "$perl_lib" ]; then
            DEP_PERL5LIB="${DEP_PERL5LIB:+$DEP_PERL5LIB:}$perl_lib"
        fi
    done
done
# Export PERL5LIB with host tools first (exec_bdepend), then target deps
if [ -n "$HOST_PERL5LIB" ]; then
    export PERL5LIB="${HOST_PERL5LIB}${DEP_PERL5LIB:+:$DEP_PERL5LIB}${PERL5LIB:+:$PERL5LIB}"
elif [ -n "$DEP_PERL5LIB" ]; then
    export PERL5LIB="${DEP_PERL5LIB}${PERL5LIB:+:$PERL5LIB}"
fi
# Set autom4te_perllibdir for autoreconf to find its Perl modules
if [ -n "$AUTOCONF_PERLLIBDIR" ]; then
    export autom4te_perllibdir="$AUTOCONF_PERLLIBDIR"
fi
# Set AUTOMAKE_PERLLIBDIR for automake.real to find its data files (am/*.am)
# This overrides the hardcoded /usr/share/automake-X.XX path in automake.real
# AUTOMAKE_LIBDIR is the actual env var used by automake Config.pm
if [ -n "$AUTOMAKE_PERLLIBDIR" ]; then
    export AUTOMAKE_PERLLIBDIR
    export AUTOMAKE_LIBDIR="$AUTOMAKE_PERLLIBDIR"
fi
# Set ACLOCAL_AUTOMAKE_DIR for aclocal to find automake m4 macros
# Also set AUTOMAKE_UNINSTALLED to prevent aclocal from using hardcoded paths
if [ -n "$ACLOCAL_AUTOMAKE_DIR" ]; then
    export ACLOCAL_AUTOMAKE_DIR
    export AUTOMAKE_UNINSTALLED=1
fi
# Set ACLOCAL_PATH for aclocal to find m4 macro files
if [ -n "$ACLOCAL_PATH" ]; then
    export ACLOCAL_PATH
fi

# Set autotools environment variables to override hardcoded paths
# autoreconf uses AUTOCONF, AUTOHEADER, AUTOM4TE with /usr/bin defaults
# First check HOST_TOOL_DIRS (exec_bdepend - host platform tools)
for tool_dir in "${HOST_TOOL_DIRS_ARRAY[@]}"; do
    if [[ "$tool_dir" != /* ]]; then
        tool_dir="$(cd "$tool_dir" 2>/dev/null && pwd)" || continue
    fi
    # Check for autoconf tools
    if [ -z "$AUTOCONF" ] && [ -x "$tool_dir/usr/bin/autoconf" ]; then
        export AUTOCONF="$tool_dir/usr/bin/autoconf"
    fi
    if [ -z "$AUTOHEADER" ] && [ -x "$tool_dir/usr/bin/autoheader" ]; then
        export AUTOHEADER="$tool_dir/usr/bin/autoheader"
    fi
    if [ -z "$AUTOM4TE" ] && [ -x "$tool_dir/usr/bin/autom4te" ]; then
        export AUTOM4TE="$tool_dir/usr/bin/autom4te"
    fi
    # autom4te needs its config file
    if [ -z "$AUTOM4TE_CFG" ] && [ -f "$tool_dir/usr/share/autoconf/autom4te.cfg" ]; then
        export AUTOM4TE_CFG="$tool_dir/usr/share/autoconf/autom4te.cfg"
    fi
    # Also set AC_MACRODIR for autoconf m4 macros
    if [ -z "$AC_MACRODIR" ] && [ -d "$tool_dir/usr/share/autoconf" ]; then
        export AC_MACRODIR="$tool_dir/usr/share/autoconf"
    fi
    # Check for libtool's libtoolize
    if [ -z "$LIBTOOLIZE" ] && [ -x "$tool_dir/usr/bin/libtoolize" ]; then
        export LIBTOOLIZE="$tool_dir/usr/bin/libtoolize"
    fi
done

# Fallback: check DEP_DIRS (bdepend - for backwards compatibility)
for dep_dir in "${DEP_DIRS_ARRAY[@]}"; do
    if [[ "$dep_dir" != /* ]]; then
        dep_dir="$(cd "$dep_dir" 2>/dev/null && pwd)" || continue
    fi
    # Check for autoconf tools
    if [ -z "$AUTOCONF" ] && [ -x "$dep_dir/usr/bin/autoconf" ]; then
        export AUTOCONF="$dep_dir/usr/bin/autoconf"
    fi
    if [ -z "$AUTOHEADER" ] && [ -x "$dep_dir/usr/bin/autoheader" ]; then
        export AUTOHEADER="$dep_dir/usr/bin/autoheader"
    fi
    if [ -z "$AUTOM4TE" ] && [ -x "$dep_dir/usr/bin/autom4te" ]; then
        export AUTOM4TE="$dep_dir/usr/bin/autom4te"
    fi
    # autom4te needs its config file - set AUTOM4TE_CFG to override hardcoded /usr/share/autoconf path
    if [ -z "$AUTOM4TE_CFG" ] && [ -f "$dep_dir/usr/share/autoconf/autom4te.cfg" ]; then
        export AUTOM4TE_CFG="$dep_dir/usr/share/autoconf/autom4te.cfg"
    fi
    # Also set AC_MACRODIR for autoconf m4 macros
    if [ -z "$AC_MACRODIR" ] && [ -d "$dep_dir/usr/share/autoconf" ]; then
        export AC_MACRODIR="$dep_dir/usr/share/autoconf"
    fi
    # Check for libtool's libtoolize
    if [ -z "$LIBTOOLIZE" ] && [ -x "$dep_dir/usr/bin/libtoolize" ]; then
        export LIBTOOLIZE="$dep_dir/usr/bin/libtoolize"
    fi
done

# Create a dummy autopoint if gettext is not available
# autopoint is only needed for i18n, and many packages don't actually need it
# This stub allows autoreconf to complete for packages that don't require i18n
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

# Export MAKEOPTS so all build systems (make, cmake, meson, ninja, cargo) inherit job count
export MAKEOPTS="${MAKE_JOBS}"

# =============================================================================
# Build Configuration
# =============================================================================
echo "=== Build Configuration ==="
echo "BUILD_THREADS=$BUILD_THREADS"
echo "MAKE_JOBS=$MAKE_JOBS MAKEOPTS=$MAKEOPTS (nproc=$(nproc 2>/dev/null || echo 'N/A'))"

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
    # Standard tools - must be explicitly set for Makefiles that expect them
    export AR="${AR:-ar}"
    export AS="${AS:-as}"
    export LD="${LD:-ld}"
    export NM="${NM:-nm}"
    export RANLIB="${RANLIB:-ranlib}"
    export STRIP="${STRIP:-strip}"
    export OBJCOPY="${OBJCOPY:-objcopy}"
    export OBJDUMP="${OBJDUMP:-objdump}"
elif [ "$USE_BOOTSTRAP" = "true" ]; then
    # Determine which cross-compiler bin directory to use
    # Prefer BOOTSTRAP_TOOLCHAIN_BIN (aggregated toolchain) over TOOLCHAIN_PATH
    CROSS_COMPILER_BIN=""
    if [ -n "$BOOTSTRAP_TOOLCHAIN_BIN" ]; then
        CROSS_COMPILER_BIN="$BOOTSTRAP_TOOLCHAIN_BIN"
    elif [ -n "$TOOLCHAIN_PATH" ]; then
        # Use first directory in TOOLCHAIN_PATH (separated by colon)
        CROSS_COMPILER_BIN="${TOOLCHAIN_PATH%%:*}"
    fi

    # Verify the cross-compiler actually exists
    if [ -n "$CROSS_COMPILER_BIN" ] && [ -x "$CROSS_COMPILER_BIN/${BUCKOS_TARGET}-gcc" ]; then
        CROSS_COMPILING="true"
        export CROSS_COMPILING
        echo "=== Using Bootstrap Toolchain ==="
        echo "Target: $BUCKOS_TARGET"
        echo "Sysroot: $BOOTSTRAP_SYSROOT"
        echo "Cross-compiler bin: $CROSS_COMPILER_BIN"

        # Set cross-compilation environment variables using ABSOLUTE PATHS
        # This ensures we use the cross-compiler without putting bootstrap-toolchain in PATH
        # (which would expose cross-compiled utilities that crash on host)
        export CC="$CROSS_COMPILER_BIN/${BUCKOS_TARGET}-gcc"
        export CXX="$CROSS_COMPILER_BIN/${BUCKOS_TARGET}-g++"
        export CPP="$CROSS_COMPILER_BIN/${BUCKOS_TARGET}-gcc -E"
        export AR="$CROSS_COMPILER_BIN/${BUCKOS_TARGET}-ar"
        export AS="$CROSS_COMPILER_BIN/${BUCKOS_TARGET}-as"
        export LD="$CROSS_COMPILER_BIN/${BUCKOS_TARGET}-ld"
        export NM="$CROSS_COMPILER_BIN/${BUCKOS_TARGET}-nm"
        export RANLIB="$CROSS_COMPILER_BIN/${BUCKOS_TARGET}-ranlib"
        export STRIP="$CROSS_COMPILER_BIN/${BUCKOS_TARGET}-strip"
        export OBJCOPY="$CROSS_COMPILER_BIN/${BUCKOS_TARGET}-objcopy"
        export OBJDUMP="$CROSS_COMPILER_BIN/${BUCKOS_TARGET}-objdump"
        export READELF="$CROSS_COMPILER_BIN/${BUCKOS_TARGET}-readelf"

        # Set CHOST and CBUILD for autotools configure scripts
        # CHOST = target triplet (where binaries will run)
        # CBUILD = build machine triplet (where we're compiling)
        export CHOST="$BUCKOS_TARGET"
        # Get actual host triplet from uname
        HOST_ARCH=$(uname -m)
        case "$HOST_ARCH" in
            x86_64) export CBUILD="x86_64-unknown-linux-gnu" ;;
            aarch64) export CBUILD="aarch64-unknown-linux-gnu" ;;
            *) export CBUILD="${HOST_ARCH}-unknown-linux-gnu" ;;
        esac
        echo "CHOST=$CHOST (target)"
        echo "CBUILD=$CBUILD (build machine)"

        # Set sysroot for all compilation
        if [ -n "$BOOTSTRAP_SYSROOT" ]; then
            SYSROOT_FLAGS="--sysroot=$BOOTSTRAP_SYSROOT"

            # The bootstrap toolchain uses a non-standard layout:
            # - C library headers are in /tools/include/ (not /tools/usr/include/)
            # - C++ headers are in /tools/include/c++/<version>/
            # We need to add explicit -isystem flags because --sysroot alone
            # only looks in $SYSROOT/usr/include, not $SYSROOT/include
            #
            # IMPORTANT: The include order matters for #include_next to work!
            # C++ headers (like cstdlib) use #include_next to find C headers (stdlib.h).
            # #include_next searches directories AFTER the current file's directory.
            # So the order must be: C++ includes FIRST, then C library include LAST.

            # Add -B flag to help GCC find its binutils (ld, as, ar) in the sysroot
            # GCC's internal search paths look for binutils in <prefix>/x86_64-buckos-linux-gnu/bin/
            # Without -B, GCC may fall back to /usr/bin/ld which doesn't work with our sysroot
            BINUTILS_PATH="$BOOTSTRAP_SYSROOT/$BUCKOS_TARGET/bin"
            BINUTILS_FLAG=""
            if [ -d "$BINUTILS_PATH" ]; then
                BINUTILS_FLAG="-B$BINUTILS_PATH/"
            fi

            export CFLAGS="${CFLAGS:-} $SYSROOT_FLAGS $BINUTILS_FLAG"
            export CXXFLAGS="${CXXFLAGS:-} $SYSROOT_FLAGS $BINUTILS_FLAG"
            export LDFLAGS="${LDFLAGS:-} $SYSROOT_FLAGS $BINUTILS_FLAG"
            # CPPFLAGS also needs sysroot for preprocessor tests (configure checks $CPP $CPPFLAGS)
            export CPPFLAGS="${CPPFLAGS:-} $SYSROOT_FLAGS"

            # Add C++ standard library include paths FIRST
            # GCC cross-compilers with --sysroot don't automatically find libstdc++ headers
            # because they're installed relative to the GCC installation, not the sysroot
            for CXX_INCLUDE_DIR in "$BOOTSTRAP_SYSROOT/include/c++/"*; do
                if [ -d "$CXX_INCLUDE_DIR" ]; then
                    GCC_VERSION=$(basename "$CXX_INCLUDE_DIR")
                    export CXXFLAGS="$CXXFLAGS -isystem $CXX_INCLUDE_DIR"
                    # Also add to CPPFLAGS so $(CPPFLAGS) $(CXXFLAGS) order works
                    export CPPFLAGS="$CPPFLAGS -isystem $CXX_INCLUDE_DIR"
                    # Add target-specific subdirectory if it exists
                    if [ -d "$CXX_INCLUDE_DIR/$BUCKOS_TARGET" ]; then
                        export CXXFLAGS="$CXXFLAGS -isystem $CXX_INCLUDE_DIR/$BUCKOS_TARGET"
                        export CPPFLAGS="$CPPFLAGS -isystem $CXX_INCLUDE_DIR/$BUCKOS_TARGET"
                    fi
                    break  # Use the first version found
                fi
            done

            # Add GCC internal include directory for stdatomic.h, stddef.h, etc.
            # These headers are installed with GCC, not in the sysroot
            # Check both /lib/gcc and /tools/lib/gcc paths (depending on toolchain layout)
            # IMPORTANT: These must be searched BEFORE dependency includes to find C11 headers
            # We save to GCC_INTERNAL_ISYSTEM for later use (after DEP_ISYSTEM_FLAGS is built)
            for GCC_INCLUDE_DIR in "$BOOTSTRAP_SYSROOT/lib/gcc/$BUCKOS_TARGET/"*/include "$BOOTSTRAP_SYSROOT/tools/lib/gcc/$BUCKOS_TARGET/"*/include; do
                if [ -f "$GCC_INCLUDE_DIR/stdatomic.h" ]; then
                    # Save GCC include path - will be prepended before DEP_ISYSTEM_FLAGS later
                    export GCC_INTERNAL_ISYSTEM="-isystem $GCC_INCLUDE_DIR"
                    export CFLAGS="$CFLAGS $GCC_INTERNAL_ISYSTEM"
                    export CXXFLAGS="$CXXFLAGS $GCC_INTERNAL_ISYSTEM"
                    export CPPFLAGS="$CPPFLAGS $GCC_INTERNAL_ISYSTEM"
                    # Also set C_INCLUDE_PATH for meson builds which may not respect CPPFLAGS
                    export C_INCLUDE_PATH="${C_INCLUDE_PATH:+$C_INCLUDE_PATH:}$GCC_INCLUDE_DIR"
                    export CPLUS_INCLUDE_PATH="${CPLUS_INCLUDE_PATH:+$CPLUS_INCLUDE_PATH:}$GCC_INCLUDE_DIR"
                    break
                fi
            done

            # Add C library include path LAST (required for #include_next in C++ headers)
            # The bootstrap sysroot has headers in /include, not /usr/include,
            # so we need explicit -isystem flags (--sysroot alone won't find them)
            if [ -d "$BOOTSTRAP_SYSROOT/include" ]; then
                export CFLAGS="$CFLAGS -isystem $BOOTSTRAP_SYSROOT/include"
                export CXXFLAGS="$CXXFLAGS -isystem $BOOTSTRAP_SYSROOT/include"
                export CPPFLAGS="$CPPFLAGS -isystem $BOOTSTRAP_SYSROOT/include"
            fi

            # Set pkg-config to use sysroot
            export PKG_CONFIG_SYSROOT_DIR="$BOOTSTRAP_SYSROOT"
            export PKG_CONFIG_PATH="$BOOTSTRAP_SYSROOT/usr/lib/pkgconfig:$BOOTSTRAP_SYSROOT/usr/share/pkgconfig"
        fi

        # For autotools, set build/host triplets
        export BUILD_TRIPLET="$(gcc -dumpmachine)"
        export HOST_TRIPLET="$BUCKOS_TARGET"

        # CHOST/CBUILD are used by econf() and custom configure scripts
        export CHOST="$BUCKOS_TARGET"
        export CBUILD="$BUILD_TRIPLET"

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
# Ensure native compiler uses 64-bit libraries (not 32-bit /lib)
# On systems with multilib, /lib contains 32-bit and /lib64 contains 64-bit
# Include linker flags directly in CC_FOR_BUILD since some configure scripts
# don't check LDFLAGS_FOR_BUILD when testing the native compiler
_LDFLAGS_FOR_BUILD="-L/usr/lib64 -L/lib64 -Wl,-rpath,/usr/lib64"
export CC_FOR_BUILD="${CC_FOR_BUILD:-gcc -std=gnu17 $_LDFLAGS_FOR_BUILD}"
export CXX_FOR_BUILD="${CXX_FOR_BUILD:-g++ -std=gnu++17 $_LDFLAGS_FOR_BUILD}"
export CPP_FOR_BUILD="${CPP_FOR_BUILD:-gcc -E}"
export CFLAGS_FOR_BUILD="${CFLAGS_FOR_BUILD:--O2 -std=gnu17}"
export CXXFLAGS_FOR_BUILD="${CXXFLAGS_FOR_BUILD:--O2 -std=gnu++17}"
export LDFLAGS_FOR_BUILD="${LDFLAGS_FOR_BUILD:-$_LDFLAGS_FOR_BUILD}"
export CPPFLAGS_FOR_BUILD="${CPPFLAGS_FOR_BUILD:-}"
# Some packages use CC_BUILD instead of CC_FOR_BUILD (e.g., freetype)
export CC_BUILD="${CC_BUILD:-$CC_FOR_BUILD}"
export CXX_BUILD="${CXX_BUILD:-$CXX_FOR_BUILD}"
export CFLAGS_BUILD="${CFLAGS_BUILD:-$CFLAGS_FOR_BUILD}"
export LDFLAGS_BUILD="${LDFLAGS_BUILD:-$LDFLAGS_FOR_BUILD}"

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
# - Never include paths containing libc.so (cross-compiled glibc) as those will
#   cause host binaries like mkdir, cp, etc. to segfault.
# - For active cross-compilation: DON'T set LD_LIBRARY_PATH at all since most
#   libraries are built against the cross-compiled glibc which will break host tools.
#   Packages that need host tool support must set LD_LIBRARY_PATH manually in their
#   src_configure or src_compile phases.
# - For regular builds: Set LD_LIBRARY_PATH with non-toolchain library paths so that
#   build tools (python3, etc.) from dependencies can find their shared libraries.
if [ -n "$DEP_LIBPATH" ]; then
    IFS=':' read -ra LIBPATH_PARTS <<< "$DEP_LIBPATH"
    if [ "$CROSS_COMPILING" != "true" ]; then
        # Filter out paths that would break host tools:
        # - /tools/lib paths (bootstrap cross-compiled libraries)
        # - Paths containing libc.so (cross-compiled glibc)
        HOST_LIBPATH=""
        for libpath in "${LIBPATH_PARTS[@]}"; do
            if [[ "$libpath" == */tools/lib* ]]; then
                continue  # Skip bootstrap toolchain paths
            fi
            if ls "$libpath"/libc.so* >/dev/null 2>&1; then
                continue  # Skip paths with glibc - would break host binaries
            fi
            HOST_LIBPATH="${HOST_LIBPATH:+$HOST_LIBPATH:}$libpath"
        done
        if [ -n "$HOST_LIBPATH" ]; then
            export LD_LIBRARY_PATH="${HOST_LIBPATH}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        fi
    else
        # Cross-compilation: most dep libraries are cross-compiled against BuckOS
        # glibc and will break host tools if loaded. Only expose host-compatible
        # libraries: Python (built with use_bootstrap=False, linked to host glibc).
        HOST_LIBPATH=""
        for libpath in "${LIBPATH_PARTS[@]}"; do
            if ls "$libpath"/libpython*.so* >/dev/null 2>&1; then
                HOST_LIBPATH="${HOST_LIBPATH:+$HOST_LIBPATH:}$libpath"
            fi
        done
        if [ -n "$HOST_LIBPATH" ]; then
            export LD_LIBRARY_PATH="${HOST_LIBPATH}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        fi
    fi
    # Only set LIBRARY_PATH for non-cross builds. During cross-compilation,
    # the cross-compiler uses --sysroot and LDFLAGS for library paths.
    # Setting LIBRARY_PATH globally would leak cross-compiled library paths
    # to host tools (gcc, ld) used for build-time code generators.
    if [ "$CROSS_COMPILING" != "true" ]; then
        export LIBRARY_PATH="${DEP_LIBPATH}"
    fi
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
# CMAKE_PREFIX_PATH for CMake-based packages
# =============================================================================
# CMake uses CMAKE_PREFIX_PATH to find Find*.cmake modules, *Config.cmake files,
# and pkg-config paths from dependencies. Each entry should be a prefix directory
# (typically containing lib/cmake, share/cmake, or lib/pkgconfig subdirectories).
DEP_CMAKE_PREFIX_PATH=""
for dep_dir_raw in "${DEP_DIRS_ARRAY[@]}"; do
    if [[ "$dep_dir_raw" = /* ]]; then
        dep_dir="$dep_dir_raw"
    else
        dep_dir="$(cd "$dep_dir_raw" 2>/dev/null && pwd)" || continue
    fi
    # Add /usr prefix if it exists (most packages install there)
    if [ -d "$dep_dir/usr" ]; then
        DEP_CMAKE_PREFIX_PATH="${DEP_CMAKE_PREFIX_PATH:+$DEP_CMAKE_PREFIX_PATH;}$dep_dir/usr"
    fi
    # Also add the raw dependency directory for packages that install to /
    # (like ECM which installs to /share/ECM/cmake)
    if [ -d "$dep_dir/share/cmake" ] || [ -d "$dep_dir/share/ECM" ] || [ -d "$dep_dir/lib/cmake" ] || [ -d "$dep_dir/lib64/cmake" ]; then
        DEP_CMAKE_PREFIX_PATH="${DEP_CMAKE_PREFIX_PATH:+$DEP_CMAKE_PREFIX_PATH;}$dep_dir"
    fi
done
if [ -n "$DEP_CMAKE_PREFIX_PATH" ]; then
    export CMAKE_PREFIX_PATH="$DEP_CMAKE_PREFIX_PATH"
    echo "CMAKE_PREFIX_PATH set to: $CMAKE_PREFIX_PATH"
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
    # NOTE: Bootstrap toolchain /tools/include is handled separately in the
    # bootstrap toolchain setup section (around line 320-360) with careful
    # ordering for C++11 #include_next compatibility. Don't add it here.
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

    # GCC_INTERNAL_ISYSTEM must come FIRST to find stdatomic.h, stddef.h, etc.
    # before any dependency headers. Order: GCC internal -> dependencies -> sysroot
    export CFLAGS="${GCC_INTERNAL_ISYSTEM:-}${DEP_ISYSTEM_FLAGS} ${CFLAGS:-}"
    export CXXFLAGS="${GCC_INTERNAL_ISYSTEM:-}${DEP_ISYSTEM_FLAGS} ${CXXFLAGS:-}"
    export CXXFLAGS="${CXXFLAGS} -fpermissive"
    export CPPFLAGS="${GCC_INTERNAL_ISYSTEM:-}${DEP_I_FLAGS} ${CPPFLAGS:-}"
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

# =============================================================================
# Language Toolchain Detection (Go, Rust, LLVM)
# =============================================================================
# Detect and set up language toolchains from dependencies.
# These toolchains are conditionally added when use_host_toolchain=false.

# Go toolchain detection
GOROOT=""
for dep_dir in "${DEP_DIRS_ARRAY[@]}"; do
    if [[ "$dep_dir" != /* ]]; then
        dep_dir="$(cd "$dep_dir" 2>/dev/null && pwd)" || continue
    fi
    # Check for go-toolchain output structure
    if [ -x "$dep_dir/tools/go/bin/go" ]; then
        GOROOT="$dep_dir/tools/go"
        break
    fi
    # Also check standard /usr/lib/go location
    if [ -x "$dep_dir/usr/lib/go/bin/go" ]; then
        GOROOT="$dep_dir/usr/lib/go"
        break
    fi
done
if [ -n "$GOROOT" ]; then
    export GOROOT
    export PATH="$GOROOT/bin:$PATH"
    echo "Go toolchain detected: $GOROOT"
    echo "Go version: $(go version 2>/dev/null || echo 'unknown')"
fi

# Rust toolchain detection
RUST_TOOLCHAIN_DIR=""
for dep_dir in "${DEP_DIRS_ARRAY[@]}"; do
    if [[ "$dep_dir" != /* ]]; then
        dep_dir="$(cd "$dep_dir" 2>/dev/null && pwd)" || continue
    fi
    # Check for rust-toolchain output structure
    if [ -x "$dep_dir/tools/bin/rustc" ]; then
        RUST_TOOLCHAIN_DIR="$dep_dir/tools"
        break
    fi
    # Also check standard /usr/bin location
    if [ -x "$dep_dir/usr/bin/rustc" ]; then
        RUST_TOOLCHAIN_DIR="$dep_dir/usr"
        break
    fi
done
if [ -n "$RUST_TOOLCHAIN_DIR" ]; then
    export PATH="$RUST_TOOLCHAIN_DIR/bin:$PATH"
    # Set CARGO_HOME if not already set
    if [ -z "$CARGO_HOME" ]; then
        export CARGO_HOME="$T/cargo"
        mkdir -p "$CARGO_HOME"
    fi
    echo "Rust toolchain detected: $RUST_TOOLCHAIN_DIR"
    echo "Rust version: $(rustc --version 2>/dev/null || echo 'unknown')"
fi

# LLVM toolchain detection
LLVM_ROOT=""
for dep_dir in "${DEP_DIRS_ARRAY[@]}"; do
    if [[ "$dep_dir" != /* ]]; then
        dep_dir="$(cd "$dep_dir" 2>/dev/null && pwd)" || continue
    fi
    # Check for llvm-toolchain output structure
    if [ -x "$dep_dir/tools/llvm/bin/llvm-config" ]; then
        LLVM_ROOT="$dep_dir/tools/llvm"
        break
    fi
    # Also check standard /usr/lib/llvm/* location
    for llvm_ver in 21 20 19 18; do
        if [ -x "$dep_dir/usr/lib/llvm/$llvm_ver/bin/llvm-config" ]; then
            LLVM_ROOT="$dep_dir/usr/lib/llvm/$llvm_ver"
            break 2
        fi
    done
done
if [ -n "$LLVM_ROOT" ]; then
    export LLVM_ROOT
    export PATH="$LLVM_ROOT/bin:$PATH"
    # Set LLVM_CONFIG for CMake/meson projects
    export LLVM_CONFIG="$LLVM_ROOT/bin/llvm-config"
    echo "LLVM toolchain detected: $LLVM_ROOT"
    echo "LLVM version: $(llvm-config --version 2>/dev/null || echo 'unknown')"
fi

cd "$S"

# CRITICAL: Ensure source directory is writable BEFORE network isolation
# Buck2 artifacts and cp -a may preserve read-only permissions from cached files
# This must happen BEFORE entering unshare namespace where permission changes may fail
# IMPORTANT: Also make WORKDIR writable as some builds (coreutils) copy to ../source/
chmod -R u+w . 2>/dev/null || {
    find . -type f -exec chmod u+w {} + 2>/dev/null || true
    find . -type d -exec chmod u+w {} + 2>/dev/null || true
}
# Also make the parent WORKDIR writable in case of out-of-tree builds
chmod -R u+w "$WORKDIR" 2>/dev/null || {
    find "$WORKDIR" -type f -exec chmod u+w {} + 2>/dev/null || true
    find "$WORKDIR" -type d -exec chmod u+w {} + 2>/dev/null || true
}

# =============================================================================
# Go Module Pre-fetch (before network isolation)
# =============================================================================
# For Go packages without pre-downloaded modules, fetch dependencies before
# entering the network-isolated build environment.
_go_prefetch_done=false
if [ -z "${GOMODCACHE:-}" ] && [ ! -d vendor ]; then
    # Set up Go environment for module download
    export GOPATH="${GOPATH:-$WORKDIR/go}"
    export GOCACHE="${GOCACHE:-$WORKDIR/.cache/go-build}"
    export GOMODCACHE="${GOMODCACHE:-$GOPATH/pkg/mod}"
    export GO111MODULE=on
    export CGO_ENABLED="${CGO_ENABLED:-1}"

    mkdir -p "$GOPATH" "$GOCACHE" "$GOMODCACHE"

    # Download modules from root go.mod if it exists
    if [ -f go.mod ]; then
        echo "🔄 Pre-fetching Go module dependencies (before network isolation)..."
        if command -v go >/dev/null 2>&1; then
            echo "Running: go mod download -x"
            go mod download -x || {
                echo "⚠ Warning: go mod download failed, build may fail in network-isolated environment"
            }
            _go_prefetch_done=true
        fi
    fi

    # Also check for go.mod in immediate subdirectories (common for monorepos like gopls)
    # This handles cases where the main module is in a subdirectory
    for subdir in */; do
        if [ -f "${subdir}go.mod" ] && [ ! -d "${subdir}vendor" ]; then
            echo "🔄 Pre-fetching Go module dependencies from ${subdir} (before network isolation)..."
            if command -v go >/dev/null 2>&1; then
                (cd "$subdir" && echo "Running: go mod download -x in ${subdir}" && go mod download -x) || {
                    echo "⚠ Warning: go mod download failed in ${subdir}, build may fail in network-isolated environment"
                }
                _go_prefetch_done=true
            fi
        fi
    done

    if [ "$_go_prefetch_done" = "true" ]; then
        # Go makes module cache files read-only by design, but this prevents
        # Buck from cleaning the cache. Make them writable for cleanup.
        chmod -R u+w "$GOMODCACHE" 2>/dev/null || true
        echo "✓ Go modules pre-fetched to $GOMODCACHE"
    fi
fi

# =============================================================================
# Rustup Toolchain Handling (before network isolation)
# =============================================================================
# Some Rust projects have rust-toolchain.toml files that specify specific toolchain
# versions. When rustup detects these, it tries to download the specified toolchain.
# This fails in network-isolated builds. We handle this by:
# 1. Checking if a rust-toolchain file exists and what it specifies
# 2. If the toolchain is not installed, use the default/stable toolchain instead
if [ -f Cargo.toml ]; then
    RUST_TOOLCHAIN_FILE=""
    if [ -f rust-toolchain.toml ]; then
        RUST_TOOLCHAIN_FILE="rust-toolchain.toml"
    elif [ -f rust-toolchain ]; then
        RUST_TOOLCHAIN_FILE="rust-toolchain"
    fi

    if [ -n "$RUST_TOOLCHAIN_FILE" ]; then
        echo "📋 Found $RUST_TOOLCHAIN_FILE, checking toolchain availability..."

        # Extract the channel from the toolchain file
        REQUIRED_CHANNEL=""
        if [ -f rust-toolchain.toml ]; then
            REQUIRED_CHANNEL=$(grep -E '^channel\s*=' "$RUST_TOOLCHAIN_FILE" 2>/dev/null | sed 's/.*=\s*"\?\([^"]*\)"\?.*/\1/' | tr -d ' ')
        else
            REQUIRED_CHANNEL=$(cat "$RUST_TOOLCHAIN_FILE" | tr -d ' \n')
        fi

        if [ -n "$REQUIRED_CHANNEL" ]; then
            echo "  Required toolchain: $REQUIRED_CHANNEL"

            # Check if rustup is available and the toolchain is installed
            if command -v rustup >/dev/null 2>&1; then
                if rustup show 2>/dev/null | grep -q "^$REQUIRED_CHANNEL"; then
                    echo "  ✓ Toolchain $REQUIRED_CHANNEL is available"
                else
                    # Toolchain not installed - use default instead to avoid network download
                    echo "  ⚠ Toolchain $REQUIRED_CHANNEL not installed"
                    echo "  → Using default toolchain instead (to avoid network download)"
                    # Set RUSTUP_TOOLCHAIN to override the file
                    DEFAULT_TOOLCHAIN=$(rustup default 2>/dev/null | awk '{print $1}' | sed 's/(default)//')
                    if [ -n "$DEFAULT_TOOLCHAIN" ]; then
                        export RUSTUP_TOOLCHAIN="$DEFAULT_TOOLCHAIN"
                        echo "  → RUSTUP_TOOLCHAIN=$RUSTUP_TOOLCHAIN"
                    else
                        # Fallback to stable
                        export RUSTUP_TOOLCHAIN="stable"
                        echo "  → RUSTUP_TOOLCHAIN=stable (fallback)"
                    fi
                fi
            else
                # No rustup, just use whatever rustc is available
                echo "  → rustup not available, using system rustc"
            fi
        fi
    fi
fi

# =============================================================================
# Cargo Vendor (before network isolation)
# =============================================================================
# For Rust/Cargo packages, vendor all dependencies into a local vendor/ directory
# before entering the network-isolated build environment. This is more robust than
# cargo fetch because the vendored sources are self-contained and don't depend on
# CARGO_HOME cache being correctly populated.

# First check if vendor directory exists in dependencies (from vendor tarball)
# This allows pre-made vendor tarballs to be used for fully offline builds
# Use DEP_BASE_DIRS which contains absolute paths (converted earlier in the script)

# Determine where Cargo.toml is located (may be in source dir for workspace packages)
CARGO_ROOT=""
if [ -f Cargo.toml ]; then
    CARGO_ROOT="."
elif [ -f "${_EBUILD_SRCDIR:-../source}/Cargo.toml" ]; then
    CARGO_ROOT="${_EBUILD_SRCDIR:-../source}"
fi

VENDOR_FROM_DEP=false

# Check if vendor directory exists AND has actual crates (not just empty from failed attempt)
_local_vendor_valid=false
if [ -n "$CARGO_ROOT" ] && [ -d "$CARGO_ROOT/vendor" ]; then
    _local_vendor_count=$(find "$CARGO_ROOT/vendor" -maxdepth 1 -type d 2>/dev/null | wc -l)
    if [ "$_local_vendor_count" -gt 1 ]; then
        _local_vendor_valid=true
        echo "Found existing vendor directory with $(($_local_vendor_count - 1)) crates"
    else
        echo "Vendor directory exists but is empty ($(($_local_vendor_count)) entries), removing..."
        rm -rf "$CARGO_ROOT/vendor"
    fi
fi

if [ -n "$CARGO_ROOT" ] && [ "$_local_vendor_valid" = "false" ]; then
    echo "No valid vendor dir found, checking deps..."
    IFS=':' read -ra ABS_DEP_DIRS <<< "$DEP_BASE_DIRS"
    for dep_dir in "${ABS_DEP_DIRS[@]}"; do
        if [ -d "$dep_dir/vendor" ]; then
            echo "📦 Found pre-made vendor directory in $dep_dir"
            cp -r "$dep_dir/vendor" "$CARGO_ROOT/"
            if [ -f "$dep_dir/.cargo/config.toml" ]; then
                mkdir -p "$CARGO_ROOT/.cargo"
                cp "$dep_dir/.cargo/config.toml" "$CARGO_ROOT/.cargo/"
                echo "✓ Copied vendor directory and config.toml from dependency"
            elif [ -f "$dep_dir/config.toml" ]; then
                mkdir -p "$CARGO_ROOT/.cargo"
                cp "$dep_dir/config.toml" "$CARGO_ROOT/.cargo/"
                echo "✓ Copied vendor directory and config.toml from dependency"
            fi
            VENDOR_FROM_DEP=true
            export CARGO_NET_OFFLINE=true
            break
        fi
    done
fi

# Vendor if we have a CARGO_ROOT, no valid local vendor, and didn't get vendor from deps
if [ -n "$CARGO_ROOT" ] && [ "$_local_vendor_valid" = "false" ] && [ "$VENDOR_FROM_DEP" = "false" ]; then
    echo "🔄 Vendoring Cargo crate dependencies (before network isolation)..."
    echo "  CARGO_ROOT=$CARGO_ROOT"

    # Set up Cargo environment
    export CARGO_HOME="${CARGO_HOME:-$WORKDIR/.cargo}"
    mkdir -p "$CARGO_HOME"

    # Use sparse protocol for faster index updates
    export CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse

    # Check if there are git dependencies that need to be fetched first
    if grep -qE '^\s*git\s*=' "$CARGO_ROOT/Cargo.toml" 2>/dev/null || grep -qE '\[patch\.' "$CARGO_ROOT/Cargo.toml" 2>/dev/null; then
        echo "  Detected git dependencies, running cargo fetch first..."
        # cargo fetch will clone git dependencies into CARGO_HOME/git
        pushd "$CARGO_ROOT" > /dev/null
        if ! cargo fetch 2>&1; then
            echo "  ⚠ cargo fetch failed for git dependencies"
        fi
        popd > /dev/null
    fi

    CARGO_VENDOR_SUCCESS=false
    if command -v cargo >/dev/null 2>&1; then
        # Create vendor directory and config
        # Use --locked to respect Cargo.lock if it exists
        # IMPORTANT: cargo vendor outputs config to stdout and progress to stderr
        # We only want stdout in vendor_config.toml, stderr goes to terminal
        pushd "$CARGO_ROOT" > /dev/null
        if [ -f Cargo.lock ]; then
            echo "Running: cargo vendor --locked (in $CARGO_ROOT)"
            if cargo vendor --locked vendor > vendor_config.toml; then
                CARGO_VENDOR_SUCCESS=true
            else
                echo "⚠ Warning: cargo vendor --locked failed, trying without --locked"
                if cargo vendor vendor > vendor_config.toml; then
                    CARGO_VENDOR_SUCCESS=true
                fi
            fi
        else
            echo "Running: cargo vendor (in $CARGO_ROOT)"
            if cargo vendor vendor > vendor_config.toml; then
                CARGO_VENDOR_SUCCESS=true
            fi
        fi

        if [ "$CARGO_VENDOR_SUCCESS" = "true" ]; then
            # Create or update .cargo/config.toml to use vendored sources
            mkdir -p .cargo
            if [ -f .cargo/config.toml ]; then
                # Check if config already has vendor/source replacement
                if grep -q '\[source\.' .cargo/config.toml 2>/dev/null; then
                    echo "⚠ Existing .cargo/config.toml has [source] config, merging carefully"
                    # Backup original and merge
                    cp .cargo/config.toml .cargo/config.toml.bak
                    # Only add sections that don't already exist
                    if ! grep -q 'directory = "vendor"' .cargo/config.toml; then
                        echo "" >> .cargo/config.toml
                        cat vendor_config.toml >> .cargo/config.toml
                    fi
                else
                    # No existing source config, safe to append
                    echo "" >> .cargo/config.toml
                    cat vendor_config.toml >> .cargo/config.toml
                fi
            else
                mv vendor_config.toml .cargo/config.toml
            fi
            rm -f vendor_config.toml

            # Count vendored crates for diagnostics
            CRATE_COUNT=$(find vendor -maxdepth 1 -type d 2>/dev/null | wc -l)
            echo "✓ Cargo crates vendored to ./vendor/ ($((CRATE_COUNT - 1)) crates)"
            echo "✓ Cargo config updated at .cargo/config.toml"

            # Set offline mode for the build phase since we have all sources locally
            export CARGO_NET_OFFLINE=true
        else
            echo "⚠ Warning: cargo vendor failed, build may fail in network-isolated environment"
            # Show the error output for debugging
            if [ -f vendor_config.toml ]; then
                echo "--- cargo vendor output ---"
                cat vendor_config.toml
                echo "---"
            fi
            rm -f vendor_config.toml
        fi
        popd > /dev/null
    else
        echo "⚠ Warning: 'cargo' command not found, skipping crate vendoring"
    fi
fi

# Export all critical environment variables
export DESTDIR S EPREFIX PREFIX LIBDIR LIBDIR_SUFFIX BUILD_DIR WORKDIR T FILESDIR
export PATH PYTHONPATH PKG_CONFIG_PATH PKG_CONFIG_LIBDIR DEP_BASE_DIRS EXEC_BDEP_BASE_DIRS

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
    # Also export PHASE_* variables which are needed by PHASES_CONTENT
    {
        echo "#!/bin/bash"
        echo "# Explicitly set PATH to ensure toolchain binaries are found"
        echo "export PATH=\"$PATH\""
        [ -n "$TOOLCHAIN_PATH" ] && echo "export TOOLCHAIN_PATH=\"$TOOLCHAIN_PATH\""
        [ -n "$DEP_PATH" ] && echo "export DEP_PATH=\"$DEP_PATH\""
        # Export phase script paths (needed for bootstrap builds that use env -i)
        [ -n "$PHASE_ENV_SCRIPT" ] && echo "export PHASE_ENV_SCRIPT=\"$PHASE_ENV_SCRIPT\""
        [ -n "$PHASE_SRC_UNPACK" ] && echo "export PHASE_SRC_UNPACK=\"$PHASE_SRC_UNPACK\""
        [ -n "$PHASE_SRC_PREPARE" ] && echo "export PHASE_SRC_PREPARE=\"$PHASE_SRC_PREPARE\""
        [ -n "$PHASE_PRE_CONFIGURE" ] && echo "export PHASE_PRE_CONFIGURE=\"$PHASE_PRE_CONFIGURE\""
        [ -n "$PHASE_SRC_CONFIGURE" ] && echo "export PHASE_SRC_CONFIGURE=\"$PHASE_SRC_CONFIGURE\""
        [ -n "$PHASE_SRC_COMPILE" ] && echo "export PHASE_SRC_COMPILE=\"$PHASE_SRC_COMPILE\""
        [ -n "$PHASE_SRC_TEST" ] && echo "export PHASE_SRC_TEST=\"$PHASE_SRC_TEST\""
        [ -n "$PHASE_SRC_INSTALL" ] && echo "export PHASE_SRC_INSTALL=\"$PHASE_SRC_INSTALL\""
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
    elif command -v unshare >/dev/null 2>&1; then
        # Use network namespace isolation like Gentoo Portage does.
        # When running as root (uid=0), we only need --net for network isolation.
        # DO NOT use --map-current-user as it creates a user namespace which causes
        # permission issues (files chmod'd before entering the namespace have different
        # ownership inside the user namespace).
        # Portage uses: unshare(CLONE_NEWNET | CLONE_NEWUTS) directly via libc when uid=0.
        UNSHARE_OPTS="--net"

        # Test if unshare --net works (requires root or CAP_SYS_ADMIN)
        # Like Portage, we only use network isolation when running as root.
        # User namespace with --map-current-user causes permission issues due to UID mapping.
        if unshare $UNSHARE_OPTS true 2>/dev/null; then
            echo "🔒 Running build phases in network-isolated environment"
        else
            # Non-root or insufficient permissions - skip network isolation entirely
            # (Portage also only enables network-sandbox when uid=0)
            echo "⚠ Warning: unshare --net requires root, building without network isolation"
            "$PHASES_BASH" "$T/phases.sh"
            UNSHARE_OPTS=""
        fi

        if [ -n "$UNSHARE_OPTS" ]; then
        unshare $UNSHARE_OPTS -- env \
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
            CMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH:-}" \
            ACLOCAL_PATH="$ACLOCAL_PATH" \
            ACLOCAL_AUTOMAKE_DIR="${ACLOCAL_AUTOMAKE_DIR:-}" \
            AUTOMAKE_PERLLIBDIR="${AUTOMAKE_PERLLIBDIR:-}" \
            AUTOMAKE_LIBDIR="${AUTOMAKE_LIBDIR:-}" \
            AUTOMAKE_UNINSTALLED="${AUTOMAKE_UNINSTALLED:-}" \
            PERL5LIB="${PERL5LIB:-}" \
            autom4te_perllibdir="${autom4te_perllibdir:-}" \
            AUTOCONF="${AUTOCONF:-}" \
            AUTOHEADER="${AUTOHEADER:-}" \
            AUTOM4TE="${AUTOM4TE:-}" \
            AUTOM4TE_CFG="${AUTOM4TE_CFG:-}" \
            AC_MACRODIR="${AC_MACRODIR:-}" \
            LIBTOOLIZE="${LIBTOOLIZE:-}" \
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
            GOPATH="${GOPATH:-}" \
            GOMODCACHE="${GOMODCACHE:-}" \
            GOCACHE="${GOCACHE:-}" \
            GO111MODULE=on \
            GOPROXY="${GOPROXY:-off}" \
            CGO_ENABLED="${CGO_ENABLED:-1}" \
            CARGO_HOME="${CARGO_HOME:-}" \
            CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse \
            CARGO_NET_OFFLINE=true \
            RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-}" \
            /bin/bash --norc --noprofile "$T/phases.sh"
        fi
    else
        echo "⚠ Warning: unshare command not found, building without network isolation"
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
