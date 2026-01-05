"""
Package build rules for BuckOs Linux Distribution.
Similar to Gentoo's ebuild system but using Buck2.
"""

load("//defs:eclasses.bzl", "ECLASSES", "inherit")
load("//defs:use_flags.bzl",
     "get_effective_use",
     "use_dep",
     "use_cmake_options",
     "use_meson_options",
     "use_configure_args",
     "use_cargo_args",
     "use_go_build_args")
load("//defs:distro_constraints.bzl",
     "validate_compat_tags",
     "get_distro_constraints",
     "DISTRO_BUCKOS")
load("//defs:fhs_mapping.bzl",
     "get_configure_args_for_layout")
load("//config:fedora_build_flags.bzl",
     "get_fedora_build_env")

# Bootstrap toolchain target path (for use in package definitions)
# All packages will use this by default to ensure they link against BuckOS glibc
# rather than the host system's libraries.
# Note: Uses toolchains// cell prefix per buck2 cell configuration
BOOTSTRAP_TOOLCHAIN = "toolchains//bootstrap:bootstrap-toolchain"

def get_toolchain_dep():
    """
    Returns the bootstrap toolchain dependency.

    Note: When use_host_toolchain config is enabled, the ebuild_package rule implementation
    will automatically filter out this dependency, so it's safe to always include it here.
    """
    return BOOTSTRAP_TOOLCHAIN

def _should_use_host_toolchain():
    """
    Check if host toolchain should be used instead of bootstrap toolchain.
    Reads from buckos.use_host_toolchain config (default: false)
    """
    use_host = read_config("buckos", "use_host_toolchain", "false")
    return use_host.lower() in ["true", "1", "yes"]

# Platform constraint values for target_compatible_with
# Only macOS packages need constraints to prevent building on Linux
# Linux packages don't need constraints since we're building on Linux
# Uses prelude OS constraint which is automatically detected from host
_MACOS_CONSTRAINT = "prelude//os/constraints:macos"

def _get_platform_constraints():
    """
    Detect the target platform from the package path and return appropriate
    target_compatible_with constraints. Only macOS packages get constraints
    to prevent them from building on Linux. Linux packages have no constraints.
    """
    pkg = native.package_name()
    if pkg.startswith("packages/mac/"):
        return [_MACOS_CONSTRAINT]
    # Linux packages and others: no constraints (builds on Linux)
    return []

def _apply_platform_constraints(kwargs):
    """
    Apply platform constraints to kwargs if not already specified.
    This should be called at the start of each package macro.
    """
    if "target_compatible_with" not in kwargs:
        constraints = _get_platform_constraints()
        if constraints:
            kwargs["target_compatible_with"] = constraints
    return kwargs

# Package metadata structure
PackageInfo = provider(fields = [
    "name",
    "version",
    "description",
    "homepage",
    "license",
    "src_uri",
    "checksum",
    "dependencies",
    "build_dependencies",
    "maintainers",  # List of maintainer IDs for package support contacts
])

# -----------------------------------------------------------------------------
# Signature Download Rule (tries .sig, .asc, .sign extensions)
# -----------------------------------------------------------------------------

def _download_signature_impl(ctx: AnalysisContext) -> list[Provider]:
    """Download GPG signature, trying multiple extensions."""
    out_file = ctx.actions.declare_output(ctx.attrs.out)

    script = ctx.attrs._download_script[DefaultInfo].default_outputs[0]

    cmd = cmd_args([
        "bash",
        script,
        out_file.as_output(),
        ctx.attrs.src_uri,
        ctx.attrs.sha256,
    ])

    ctx.actions.run(
        cmd,
        category = "download_signature",
        identifier = ctx.attrs.name,
        local_only = True,  # Network access needed
    )

    return [DefaultInfo(default_output = out_file)]

_download_signature = rule(
    impl = _download_signature_impl,
    attrs = {
        "src_uri": attrs.string(doc = "Base URL of the source archive (extension will be appended)"),
        "sha256": attrs.string(doc = "Expected SHA256 of the signature file"),
        "out": attrs.string(doc = "Output filename"),
        "_download_script": attrs.dep(default = "//defs/scripts:download-signature"),
    },
)

# Source Extraction Rule (used with http_file for downloads)
# -----------------------------------------------------------------------------

def _extract_source_impl(ctx: AnalysisContext) -> list[Provider]:
    """Extract archive and optionally verify GPG signature."""
    out_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)

    # Get the archive file from http_file dependency
    archive_file = ctx.attrs.archive[DefaultInfo].default_outputs[0]

    # Get optional signature file from http_file dependency
    sig_file = ""
    if ctx.attrs.signature:
        sig_file = ctx.attrs.signature[DefaultInfo].default_outputs[0]

    # GPG verification parameters
    gpg_key = ctx.attrs.gpg_key if ctx.attrs.gpg_key else ""
    gpg_keyring = ctx.attrs.gpg_keyring if ctx.attrs.gpg_keyring else ""

    # Build exclude patterns for tar (no quotes - the script handles glob protection)
    exclude_args = " ".join(["--exclude={}".format(pattern) for pattern in ctx.attrs.exclude_patterns])

    # Get strip_components value (default is 1 for backward compatibility)
    strip_components = ctx.attrs.strip_components

    # Get extract setting (default True)
    do_extract = "1" if ctx.attrs.extract else "0"

    # Get the external extraction script
    script = ctx.attrs._extract_script[DefaultInfo].default_outputs[0]

    cmd = cmd_args([
        "bash",
        script,
        out_dir.as_output(),
        archive_file,
    ])

    # Add optional arguments
    if sig_file:
        cmd.add(sig_file)
    else:
        cmd.add("")

    cmd.add([
        gpg_key,
        gpg_keyring,
        exclude_args,
        str(strip_components),
        do_extract,
    ])

    ctx.actions.run(
        cmd,
        category = "extract",
        identifier = ctx.attrs.name,
        local_only = True,  # http_file outputs may need local execution
    )

    return [DefaultInfo(default_output = out_dir)]

_extract_source = rule(
    impl = _extract_source_impl,
    attrs = {
        "archive": attrs.dep(doc = "http_file dependency for the archive"),
        "signature": attrs.option(attrs.dep(), default = None, doc = "http_file dependency for GPG signature"),
        "gpg_key": attrs.option(attrs.string(), default = None),
        "gpg_keyring": attrs.option(attrs.string(), default = None),
        "exclude_patterns": attrs.list(attrs.string(), default = []),
        "strip_components": attrs.int(default = 1),
        "extract": attrs.bool(default = True),
        "_extract_script": attrs.dep(default = "//defs/scripts:extract-source"),
    },
)

def download_source(
        name: str,
        src_uri: str,
        sha256: str,
        signature_sha256: str | None = None,
        signature_required: bool = False,
        gpg_key: str | None = None,
        gpg_keyring: str | None = None,
        exclude_patterns: list[str] = [],
        strip_components: int = 1,
        extract: bool = True,
        visibility: list[str] = ["PUBLIC"]):
    """
    Download and extract source archives using Buck2's native http_file.

    This macro creates:
    1. An http_file target for the main archive
    2. An http_file target for the GPG signature (if signature_sha256 provided)
    3. An _extract_source rule that extracts and optionally verifies GPG

    Signature verification workflow:
    - Set signature_required=True (default) to require signature verification
    - Run `./tools/update_checksums.py --populate-signatures` to auto-discover signatures
      and populate signature_sha256 values
    - Build will fail if signature_required=True but signature_sha256 is missing

    Args:
        name: Target name for the extracted source
        src_uri: URL to download the source archive from
        sha256: SHA256 checksum of the archive
        signature_sha256: SHA256 checksum of the signature file. Use update_checksums.py
                         to populate. When provided, tries .asc/.sig/.sign extensions.
        signature_required: If True (default), fails when signature_sha256 is missing.
                           Set to False to disable signature verification entirely.
        gpg_key: GPG key ID to verify against
        gpg_keyring: Path to GPG keyring file
        exclude_patterns: Patterns to exclude from extraction
        strip_components: Number of leading path components to strip (default: 1)
        extract: Whether to extract the archive (default: True)
        visibility: Target visibility
    """
    # Extract filename from URL to preserve extension
    # Handle URLs with query params like gitweb (?p=...) or GitHub (/archive/...)
    url_path = src_uri.split("?")[0]  # Remove query string
    archive_filename = url_path.split("/")[-1]

    # If filename is empty or doesn't look like an archive, derive from name
    if not archive_filename or "." not in archive_filename:
        # Try to detect extension from URL params (e.g., sf=tgz)
        ext = ".tar.gz"  # Default
        if "sf=tgz" in src_uri or ".tgz" in src_uri:
            ext = ".tar.gz"
        elif "sf=tbz2" in src_uri or ".tar.bz2" in src_uri:
            ext = ".tar.bz2"
        elif "sf=txz" in src_uri or ".tar.xz" in src_uri:
            ext = ".tar.xz"
        elif ".zip" in src_uri:
            ext = ".zip"
        archive_filename = name + ext

    # Create http_file for the main archive
    archive_target = name + "-archive"
    native.http_file(
        name = archive_target,
        urls = [src_uri],
        sha256 = sha256,
        out = archive_filename,  # Preserve original filename with extension
        visibility = ["PUBLIC"],
    )

    # Create signature download rule if signature_required and signature_sha256 provided
    # This rule tries .sig, .asc, .sign extensions automatically
    sig_target = None
    if signature_required and not signature_sha256:
        fail("signature_required=True but signature_sha256 not provided for {}. Run ./tools/update_checksums.py".format(name))
    if signature_required and signature_sha256:
        sig_target = name + "-sig"
        _download_signature(
            name = sig_target,
            src_uri = src_uri,
            sha256 = signature_sha256,
            out = archive_filename + ".sig",
        )

    # Create extraction rule
    _extract_source(
        name = name,
        archive = ":" + archive_target,
        signature = (":" + sig_target) if sig_target else None,
        gpg_key = gpg_key,
        gpg_keyring = gpg_keyring,
        exclude_patterns = exclude_patterns,
        strip_components = strip_components,
        extract = extract,
        visibility = visibility,
    )

def _kernel_config_impl(ctx: AnalysisContext) -> list[Provider]:
    """Merge kernel configuration fragments into a single .config file."""
    output = ctx.actions.declare_output(ctx.attrs.name + ".config")

    # Collect all config fragments
    config_files = []
    for frag in ctx.attrs.fragments:
        config_files.append(frag)

    script = ctx.actions.write(
        "merge_config.sh",
        """#!/bin/bash
set -e
OUTPUT="$1"
shift

# Start with empty config
> "$OUTPUT"

# Merge all config fragments
# Later fragments override earlier ones
for config in "$@"; do
    if [ -f "$config" ]; then
        # Read each line from the fragment
        while IFS= read -r line || [ -n "$line" ]; do
            # Skip empty lines and comments for processing
            if [[ -z "$line" ]] || [[ "$line" =~ ^# ]]; then
                echo "$line" >> "$OUTPUT"
                continue
            fi

            # Extract config option name
            if [[ "$line" =~ ^(CONFIG_[A-Za-z0-9_]+)= ]]; then
                opt="${BASH_REMATCH[1]}"
                # Remove any existing setting for this option
                sed -i "/^$opt=/d" "$OUTPUT"
                sed -i "/^# $opt is not set/d" "$OUTPUT"
            elif [[ "$line" =~ ^#[[:space:]]*(CONFIG_[A-Za-z0-9_]+)[[:space:]]is[[:space:]]not[[:space:]]set ]]; then
                opt="${BASH_REMATCH[1]}"
                # Remove any existing setting for this option
                sed -i "/^$opt=/d" "$OUTPUT"
                sed -i "/^# $opt is not set/d" "$OUTPUT"
            fi

            echo "$line" >> "$OUTPUT"
        done < "$config"
    fi
done
""",
        is_executable = True,
    )

    ctx.actions.run(
        cmd_args([
            "bash",
            script,
            output.as_output(),
        ] + config_files),
        category = "kernel_config",
        identifier = ctx.attrs.name,
    )

    return [DefaultInfo(default_output = output)]

kernel_config = rule(
    impl = _kernel_config_impl,
    attrs = {
        "fragments": attrs.list(attrs.source()),
    },
)

def _kernel_build_impl(ctx: AnalysisContext) -> list[Provider]:
    """Build Linux kernel with custom configuration."""
    install_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)
    src_dir = ctx.attrs.source[DefaultInfo].default_outputs[0]

    # Kernel config - can be a source file or output from kernel_config
    config_file = None
    if ctx.attrs.config:
        config_file = ctx.attrs.config
    elif ctx.attrs.config_dep:
        config_file = ctx.attrs.config_dep[DefaultInfo].default_outputs[0]

    script = ctx.actions.write(
        "build_kernel.sh",
        """#!/bin/bash
set -e

# Arguments:
# $1 = install directory (output)
# $2 = source directory (input)
# $3 = build scratch directory (output, for writable build)
# $4 = config file (optional)

# Save absolute paths before changing directory
SRC_DIR="$(cd "$2" && pwd)"

# Build scratch directory - passed from Buck2 for hermetic builds
BUILD_DIR="$3"

# Convert install paths to absolute
if [[ "$1" = /* ]]; then
    INSTALL_BASE="$1"
else
    INSTALL_BASE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
fi

export INSTALL_PATH="$INSTALL_BASE/boot"
export INSTALL_MOD_PATH="$INSTALL_BASE"
mkdir -p "$INSTALL_PATH"

if [ -n "$4" ]; then
    # Convert config path to absolute if it's relative
    if [[ "$4" = /* ]]; then
        CONFIG_PATH="$4"
    else
        CONFIG_PATH="$(pwd)/$4"
    fi
fi

# Copy source to writable build directory (buck2 inputs are read-only)
# BUILD_DIR is passed as $3 from Buck2 for hermetic, deterministic builds
mkdir -p "$BUILD_DIR"

# Check if we need to force GNU11 standard for GCC 14+ (C23 conflicts with kernel's bool/true/false)
# GCC 14+ defaults to C23 where bool/true/false are keywords, breaking older kernel code
CC_BIN="${CC:-gcc}"
CC_VER=$($CC_BIN --version 2>/dev/null | head -1)
echo "Compiler version: $CC_VER"
MAKE_CC_OVERRIDE=""
if echo "$CC_VER" | grep -iq gcc; then
    # Extract version number - handles "gcc (GCC) 15.2.1" or "gcc (Fedora 14.2.1-6) 14.2.1" formats
    GCC_MAJOR=$(echo "$CC_VER" | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1)
    echo "Detected GCC major version: $GCC_MAJOR"
    if [ -n "$GCC_MAJOR" ] && [ "$GCC_MAJOR" -ge 14 ] 2>/dev/null; then
        echo "GCC 14+ detected, creating wrapper to append -std=gnu11"
        # Create a gcc wrapper that appends -std=gnu11 as the LAST argument
        # This ensures it overrides any -std= flags set by kernel Makefiles
        WRAPPER_DIR="$(cd "$BUILD_DIR" && pwd)/.cc-wrapper"
        mkdir -p "$WRAPPER_DIR"
        cat > "$WRAPPER_DIR/gcc" << 'WRAPPER'
#!/bin/bash
exec /usr/bin/gcc "$@" -std=gnu11
WRAPPER
        chmod +x "$WRAPPER_DIR/gcc"
        # Pass CC explicitly on make command line with absolute path
        MAKE_CC_OVERRIDE="CC=$WRAPPER_DIR/gcc HOSTCC=$WRAPPER_DIR/gcc"
        echo "Will use: $MAKE_CC_OVERRIDE"
    fi
fi
echo "Copying kernel source to build directory: $BUILD_DIR"
cp -a "$SRC_DIR"/. "$BUILD_DIR/"
cd "$BUILD_DIR"

# Apply config
if [ -n "$CONFIG_PATH" ]; then
    cp "$CONFIG_PATH" .config
    # Ensure config is complete with olddefconfig (non-interactive)
    make $MAKE_CC_OVERRIDE olddefconfig

    # If hardware-specific config fragment exists, merge it
    HARDWARE_CONFIG="$(dirname "$SRC_DIR")/../../hardware-kernel.config"
    if [ -f "$HARDWARE_CONFIG" ]; then
        echo "Merging hardware-specific kernel config..."
        # Use kernel's merge script to combine base config with hardware fragment
        scripts/kconfig/merge_config.sh -m .config "$HARDWARE_CONFIG"
        # Update config with new options (non-interactive)
        make $MAKE_CC_OVERRIDE olddefconfig
    fi
else
    make $MAKE_CC_OVERRIDE defconfig
fi

# Build kernel
# -Wno-unterminated-string-initialization: suppresses ACPI driver warnings about truncated strings
# GCC wrapper (if GCC 14+) appends -std=gnu11 to all compilations via CC override
make $MAKE_CC_OVERRIDE -j$(nproc) WERROR=0 KCFLAGS="-Wno-unterminated-string-initialization"

# Manual install to avoid system kernel-install scripts that try to write to /boot, run dracut, etc.
# Get kernel release version
KRELEASE=$(make $MAKE_CC_OVERRIDE -s kernelrelease)
echo "Installing kernel version: $KRELEASE"

# Install kernel image
mkdir -p "$INSTALL_PATH"
cp arch/x86/boot/bzImage "$INSTALL_PATH/vmlinuz-$KRELEASE"
cp System.map "$INSTALL_PATH/System.map-$KRELEASE"
cp .config "$INSTALL_PATH/config-$KRELEASE"

# Install modules
make $MAKE_CC_OVERRIDE INSTALL_MOD_PATH="$INSTALL_BASE" modules_install

# Install headers (useful for out-of-tree modules)
mkdir -p "$INSTALL_BASE/usr/src/linux-$KRELEASE"
make $MAKE_CC_OVERRIDE INSTALL_HDR_PATH="$INSTALL_BASE/usr" headers_install
""",
        is_executable = True,
    )

    # Declare a scratch directory for the kernel build (Buck2 inputs are read-only)
    # Using a declared output ensures deterministic paths instead of /tmp or $$
    build_scratch_dir = ctx.actions.declare_output(ctx.attrs.name + "-build-scratch", dir = True)

    # Build command arguments
    cmd = cmd_args([
        "bash",
        script,
        install_dir.as_output(),
        src_dir,
        build_scratch_dir.as_output(),
    ])

    # Add config file if present
    if config_file:
        cmd.add(config_file)

    ctx.actions.run(
        cmd,
        category = "kernel",
        identifier = ctx.attrs.name,
    )

    return [DefaultInfo(default_output = install_dir)]

kernel_build = rule(
    impl = _kernel_build_impl,
    attrs = {
        "source": attrs.dep(),
        "version": attrs.string(),
        "config": attrs.option(attrs.source(), default = None),
        "config_dep": attrs.option(attrs.dep(), default = None),
    },
)

def _binary_package_impl(ctx: AnalysisContext) -> list[Provider]:
    """
    Create a package from pre-built binaries with custom installation script.

    This rule is designed for packages that:
    - Download precompiled binaries
    - Require bootstrap compilation (like Go, GHC, Rust)
    - Need custom installation logic

    Environment variables available in install_script:
    - $SRCS: Directory containing extracted source files from all srcs dependencies
    - $OUT: Output/installation directory (like $DESTDIR)
    - $WORK: Working directory for temporary files
    - $BUILD_DIR: Build subdirectory
    - $PN: Package name
    - $PV: Package version
    """
    install_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)

    # Collect source directories from dependencies
    src_dirs = []
    for src in ctx.attrs.srcs:
        src_dirs.append(src[DefaultInfo].default_outputs[0])

    # Collect all dependency directories for PATH setup
    dep_dirs = []
    for dep in ctx.attrs.deps + ctx.attrs.build_deps:
        outputs = dep[DefaultInfo].default_outputs
        for output in outputs:
            dep_dirs.append(output)

    # Build the installation script
    install_script = ctx.attrs.install_script if ctx.attrs.install_script else """
        # Default: copy all source contents to output
        cp -r $SRCS/* $OUT/ 2>/dev/null || true
    """

    # Pre-install commands
    pre_install = ctx.attrs.pre_install if ctx.attrs.pre_install else ""

    # Post-install commands
    post_install = ctx.attrs.post_install if ctx.attrs.post_install else ""

    script = ctx.actions.write(
        "install_binary.sh",
        """#!/bin/bash
set -e

# Package variables
export PN="{name}"
export PV="{version}"
export PACKAGE_NAME="{name}"

# Directory setup
mkdir -p "$1"
mkdir -p "$2"
export OUT="$(cd "$1" && pwd)"
export WORK="$(cd "$2" && pwd)"
export SRCS="$(cd "$3" && pwd)"
export BUILD_DIR="$WORK/build"
shift 3  # Remove OUT, WORK, SRCS from args, remaining are dependency dirs

# Set up PATH, LD_LIBRARY_PATH, PKG_CONFIG_PATH from dependency directories
DEP_PATH=""
DEP_LD_PATH=""
DEP_PKG_CONFIG_PATH=""
PYTHON_HOME=""
PYTHON_LIB64=""

echo "=== binary_package dependency setup for {name} ==="
echo "Processing $# dependency directories..."

# Store all dependency base directories for packages that need them (e.g., GCC)
export DEP_BASE_DIRS=""

for dep_dir in "$@"; do
    # Convert to absolute path if relative
    if [[ "$dep_dir" != /* ]]; then
        dep_dir="$(cd "$dep_dir" 2>/dev/null && pwd)" || continue
    fi

    echo "  Checking dependency: $dep_dir"

    # Store base directory
    DEP_BASE_DIRS="${{DEP_BASE_DIRS:+$DEP_BASE_DIRS:}}$dep_dir"

    # Check all standard include directories
    for inc_subdir in usr/include include; do
        if [ -d "$dep_dir/$inc_subdir" ]; then
            DEP_CPATH="${{DEP_CPATH:+$DEP_CPATH:}}$dep_dir/$inc_subdir"
            echo "    Found include dir: $dep_dir/$inc_subdir"
        fi
    done

    # Check all standard bin directories
    for bin_subdir in usr/bin bin usr/sbin sbin; do
        if [ -d "$dep_dir/$bin_subdir" ]; then
            DEP_PATH="${{DEP_PATH:+$DEP_PATH:}}$dep_dir/$bin_subdir"
            echo "    Found bin dir: $dep_dir/$bin_subdir"
            # List executables for debugging
            ls "$dep_dir/$bin_subdir" 2>/dev/null | head -5 | while read f; do echo "      - $f"; done
        fi
    done

    # Check all standard lib directories
    for lib_subdir in usr/lib usr/lib64 lib lib64; do
        if [ -d "$dep_dir/$lib_subdir" ]; then
            DEP_LD_PATH="${{DEP_LD_PATH:+$DEP_LD_PATH:}}$dep_dir/$lib_subdir"
            echo "    Found lib dir: $dep_dir/$lib_subdir"
        fi
    done

    # Check for pkgconfig directories
    for pc_subdir in usr/lib64/pkgconfig usr/lib/pkgconfig usr/share/pkgconfig lib/pkgconfig lib64/pkgconfig; do
        if [ -d "$dep_dir/$pc_subdir" ]; then
            DEP_PKG_CONFIG_PATH="${{DEP_PKG_CONFIG_PATH:+$DEP_PKG_CONFIG_PATH:}}$dep_dir/$pc_subdir"
            echo "    Found pkgconfig dir: $dep_dir/$pc_subdir"
        fi
    done

    # Detect Python installation (any version)
    for py_dir in "$dep_dir"/usr/lib/python3.* "$dep_dir"/usr/lib64/python3.*; do
        if [ -d "$py_dir" ]; then
            py_version=$(basename "$py_dir")
            if [ -z "$PYTHON_HOME" ]; then
                PYTHON_HOME="$dep_dir/usr"
                echo "    Found PYTHONHOME: $PYTHON_HOME (from $py_version)"
            fi
            if [ -d "$py_dir/lib-dynload" ] && [ -z "$PYTHON_LIB64" ]; then
                PYTHON_LIB64="$py_dir"
                echo "    Found Python lib-dynload: $py_dir/lib-dynload"
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
    # Only use dependency library paths - do NOT inherit from host
    export LD_LIBRARY_PATH="$DEP_LD_PATH"
    export LIBRARY_PATH="$DEP_LD_PATH"
    echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
    echo "LIBRARY_PATH=$LIBRARY_PATH"

    # Add -L and -rpath flags to LDFLAGS for linker isolation
    DEP_LDFLAGS=""
    IFS=':' read -ra LIB_DIRS <<< "$DEP_LD_PATH"
    for lib_dir in "${{LIB_DIRS[@]}}"; do
        DEP_LDFLAGS="${{DEP_LDFLAGS}} -L$lib_dir -Wl,-rpath-link,$lib_dir"
    done
    export LDFLAGS="${{DEP_LDFLAGS}} ${{LDFLAGS:-}}"
    echo "LDFLAGS=$LDFLAGS"
fi
# Set CPATH for C/C++ include paths - do NOT inherit from host
if [ -n "$DEP_CPATH" ]; then
    export CPATH="$DEP_CPATH"
    export C_INCLUDE_PATH="$DEP_CPATH"
    export CPLUS_INCLUDE_PATH="$DEP_CPATH"
    echo "CPATH=$CPATH"

    # CRITICAL: Use -isystem instead of -I for dependency includes
    # -isystem paths are searched BEFORE the compiler's built-in system paths
    # This ensures our dependency headers are found before host system headers,
    # preventing version mismatches (e.g., compiling against host pcre2.h 10.47
    # but linking against our pcre2 library with different symbol versions)
    DEP_ISYSTEM_FLAGS=""
    IFS=':' read -ra INC_DIRS <<< "$DEP_CPATH"
    for inc_dir in "${{INC_DIRS[@]}}"; do
        DEP_ISYSTEM_FLAGS="${{DEP_ISYSTEM_FLAGS}} -isystem $inc_dir"
    done
    export CFLAGS="${{DEP_ISYSTEM_FLAGS}} ${{CFLAGS:-}}"
    export CXXFLAGS="${{DEP_ISYSTEM_FLAGS}} ${{CXXFLAGS:-}}"
    echo "CFLAGS=$CFLAGS"
fi
# Export DEP_BASE_DIRS for packages that need direct access to dependency prefixes
echo "DEP_BASE_DIRS=$DEP_BASE_DIRS"
if [ -n "$PYTHON_HOME" ]; then
    export PYTHONHOME="$PYTHON_HOME"
    echo "PYTHONHOME=$PYTHONHOME"
fi
# Set PYTHONPATH to include lib-dynload if it exists
if [ -n "$PYTHON_LIB64" ] && [ -d "$PYTHON_LIB64/lib-dynload" ]; then
    export PYTHONPATH="$PYTHON_LIB64/lib-dynload${{PYTHONPATH:+:$PYTHONPATH}}"
    echo "PYTHONPATH=$PYTHONPATH"
fi
# Also add site-packages directories from dependencies to PYTHONPATH
for dep_dir in $DEP_BASE_DIRS; do
    for sp_dir in "$dep_dir"/usr/lib/python*/site-packages "$dep_dir"/usr/lib64/python*/site-packages; do
        if [ -d "$sp_dir" ]; then
            export PYTHONPATH="${{PYTHONPATH:+$PYTHONPATH:}}$sp_dir"
        fi
    done
done
if [ -n "$PYTHONPATH" ]; then
    echo "PYTHONPATH=$PYTHONPATH"
fi
# CRITICAL: Use PKG_CONFIG_LIBDIR instead of PKG_CONFIG_PATH
# PKG_CONFIG_PATH *appends* to the default search (still finds /usr/lib64/pkgconfig)
# PKG_CONFIG_LIBDIR *replaces* the default search (only finds our dependencies)
if [ -n "$DEP_PKG_CONFIG_PATH" ]; then
    export PKG_CONFIG_LIBDIR="$DEP_PKG_CONFIG_PATH"
    unset PKG_CONFIG_PATH
    unset PKG_CONFIG_SYSROOT_DIR
    echo "PKG_CONFIG_LIBDIR=$PKG_CONFIG_LIBDIR"

    # Create pkg-config wrapper that rewrites paths from .pc files
    # Problem: .pc files contain prefix=/usr, so pkg-config returns -I/usr/include
    # which finds host headers instead of our dependency headers in buck-out.
    mkdir -p "$WORK/bin"
    cat > "$WORK/bin/pkg-config" << 'PKGCONFIG_WRAPPER_EOF'
#!/bin/bash
REAL_PKGCONFIG=""
for p in $(type -ap pkg-config); do
    if [ "$p" != "$0" ] && [[ "$p" != */WORK/bin/pkg-config ]] && [[ "$p" != *-work/bin/pkg-config ]]; then
        REAL_PKGCONFIG="$p"
        break
    fi
done
[ -z "$REAL_PKGCONFIG" ] && REAL_PKGCONFIG="/usr/bin/pkg-config"
[ ! -x "$REAL_PKGCONFIG" ] && {{ echo "pkg-config wrapper: cannot find real pkg-config" >&2; exit 1; }}

OUTPUT=$("$REAL_PKGCONFIG" "$@")
RC=$?
[ $RC -ne 0 ] && exit $RC
[ -z "$OUTPUT" ] && exit 0

case "$*" in
    *--cflags*|*--libs*|*--variable*)
        PKG_NAME=""
        for arg in "$@"; do
            case "$arg" in --*) ;; *) PKG_NAME="$arg"; break ;; esac
        done
        if [ -n "$PKG_NAME" ] && [ -n "$PKG_CONFIG_LIBDIR" ]; then
            IFS=':' read -ra PC_DIRS <<< "$PKG_CONFIG_LIBDIR"
            for pc_dir in "${{PC_DIRS[@]}}"; do
                if [ -f "$pc_dir/$PKG_NAME.pc" ]; then
                    DEP_ROOT="${{pc_dir%/usr/lib64/pkgconfig}}"
                    DEP_ROOT="${{DEP_ROOT%/usr/lib/pkgconfig}}"
                    DEP_ROOT="${{DEP_ROOT%/usr/share/pkgconfig}}"
                    DEP_ROOT="${{DEP_ROOT%/lib64/pkgconfig}}"
                    DEP_ROOT="${{DEP_ROOT%/lib/pkgconfig}}"
                    if [ "$DEP_ROOT" != "$pc_dir" ]; then
                        OUTPUT=$(echo "$OUTPUT" | sed -e "s|-I/usr/include|-I$DEP_ROOT/usr/include|g" \
                                                      -e "s|-L/usr/lib64|-L$DEP_ROOT/usr/lib64|g" \
                                                      -e "s|-L/usr/lib|-L$DEP_ROOT/usr/lib|g" \
                                                      -e "s| /usr/include| $DEP_ROOT/usr/include|g" \
                                                      -e "s| /usr/lib| $DEP_ROOT/usr/lib|g")
                    fi
                    break
                fi
            done
        fi
        ;;
esac
echo "$OUTPUT"
PKGCONFIG_WRAPPER_EOF
    chmod +x "$WORK/bin/pkg-config"
    export PATH="$WORK/bin:$PATH"
    echo "Installed pkg-config wrapper at $WORK/bin/pkg-config"
fi

# Verify key tools are available
echo "=== Verifying tools ==="
MISSING_TOOLS=""
for tool in cmake python3 cc gcc ninja make; do
    if command -v $tool >/dev/null 2>&1; then
        tool_path=$(command -v $tool)
        tool_version=$($tool --version 2>&1 | head -1 || echo "unknown")
        echo "  $tool: $tool_path ($tool_version)"
    else
        echo "  $tool: NOT FOUND"
        MISSING_TOOLS="${{MISSING_TOOLS}} $tool"
    fi
done

# Show warning for missing tools that might be needed
if [ -n "$MISSING_TOOLS" ]; then
    echo ""
    echo "WARNING: The following tools were not found:$MISSING_TOOLS"
    echo "If build fails, ensure these tools are in dependencies."
fi

echo "=== End dependency setup ($(date '+%Y-%m-%d %H:%M:%S')) ==="
echo ""

# Save replay script for debugging failed builds
REPLAY_SCRIPT="$WORK/replay-build.sh"
cat > "$REPLAY_SCRIPT" << 'REPLAY_EOF'
#!/bin/bash
# Replay script for {name} {version}
# Generated: $(date)
# Re-run this script to reproduce the build environment

set -e
export OUT="REPLAY_OUT_PLACEHOLDER"
export WORK="REPLAY_WORK_PLACEHOLDER"
export SRCS="REPLAY_SRCS_PLACEHOLDER"
export BUILD_DIR="$WORK/build"
REPLAY_EOF

# Add environment variables
echo "export PATH=\"$PATH\"" >> "$REPLAY_SCRIPT"
echo "export LD_LIBRARY_PATH=\"$LD_LIBRARY_PATH\"" >> "$REPLAY_SCRIPT"
[ -n "$PYTHONHOME" ] && echo "export PYTHONHOME=\"$PYTHONHOME\"" >> "$REPLAY_SCRIPT"
[ -n "$PYTHONPATH" ] && echo "export PYTHONPATH=\"$PYTHONPATH\"" >> "$REPLAY_SCRIPT"
[ -n "$PKG_CONFIG_PATH" ] && echo "export PKG_CONFIG_PATH=\"$PKG_CONFIG_PATH\"" >> "$REPLAY_SCRIPT"
echo "" >> "$REPLAY_SCRIPT"
echo "cd \"\$WORK\"" >> "$REPLAY_SCRIPT"
echo "echo 'Environment ready. Run your commands here.'" >> "$REPLAY_SCRIPT"
echo "exec bash -i" >> "$REPLAY_SCRIPT"

# Replace placeholders with actual paths
sed -i "s|REPLAY_OUT_PLACEHOLDER|$OUT|g" "$REPLAY_SCRIPT"
sed -i "s|REPLAY_WORK_PLACEHOLDER|$WORK|g" "$REPLAY_SCRIPT"
sed -i "s|REPLAY_SRCS_PLACEHOLDER|$SRCS|g" "$REPLAY_SCRIPT"
chmod +x "$REPLAY_SCRIPT"
echo "Replay script saved to: $REPLAY_SCRIPT"

mkdir -p "$BUILD_DIR"

# Change to working directory
cd "$WORK"

# Build timing
BUILD_START=$(date +%s)

# Pre-install hook
PRE_START=$(date +%s)
{pre_install}
PRE_END=$(date +%s)
echo "[TIMING] Pre-install: $((PRE_END - PRE_START)) seconds"

# Main installation script
MAIN_START=$(date +%s)
{install_script}
MAIN_END=$(date +%s)
echo "[TIMING] Main install: $((MAIN_END - MAIN_START)) seconds"

# Post-install hook
POST_START=$(date +%s)
{post_install}
POST_END=$(date +%s)
echo "[TIMING] Post-install: $((POST_END - POST_START)) seconds"

# Global cleanup: Remove libtool .la files to prevent host path leakage
# Modern systems use pkg-config instead, and .la files often contain
# absolute paths to host libraries that break cross-compilation
LA_COUNT=$(find "$DESTDIR" -name "*.la" -type f 2>/dev/null | wc -l)
if [ "$LA_COUNT" -gt 0 ]; then
    echo "Removing $LA_COUNT libtool .la files (using pkg-config instead)"
    find "$DESTDIR" -name "*.la" -type f -delete 2>/dev/null || true
fi

BUILD_END=$(date +%s)
echo "[TIMING] Total build time: $((BUILD_END - BUILD_START)) seconds"

# =============================================================================
# Post-build verification: Ensure package produced output
# =============================================================================
echo ""
echo "📋 Verifying build output..."

# Check if OUT has any files
FILE_COUNT=$(find "$OUT" -type f 2>/dev/null | wc -l)
DIR_COUNT=$(find "$OUT" -type d 2>/dev/null | wc -l)

if [ "$FILE_COUNT" -eq 0 ]; then
    echo "" >&2
    echo "✗ BUILD VERIFICATION FAILED: No files were installed" >&2
    echo "  Package: {name}-{version}" >&2
    echo "  Output directory: $OUT" >&2
    echo "" >&2
    echo "  This usually means:" >&2
    echo "  1. The install_script didn't copy files to \$OUT" >&2
    echo "  2. The build succeeded but installation paths are wrong" >&2
    echo "  3. DESTDIR or prefix wasn't set correctly" >&2
    echo "" >&2
    echo "  Check the install_script in the BUCK file" >&2
    exit 1
fi

echo "✓ Build verification passed: $FILE_COUNT files in $DIR_COUNT directories"

# Post-build summary
echo ""
echo "=== Build summary for {name} {version} ==="
echo "Output directory: $OUT"
echo "Installed directories:"
find "$OUT" -type d -maxdepth 3 | head -20
echo ""
echo "Installed binaries (first 10):"
find "$OUT" -type f -executable -name "*" | head -10
echo ""
echo "Total files: $FILE_COUNT"
echo "Total size: $(du -sh "$OUT" 2>/dev/null | cut -f1)"
echo "=== End build summary ($(date '+%Y-%m-%d %H:%M:%S')) ==="
""".format(
            name = ctx.attrs.name,
            version = ctx.attrs.version,
            pre_install = pre_install,
            install_script = install_script,
            post_install = post_install,
        ),
        is_executable = True,
    )

    # Build command with all source directories
    # We create a combined source directory
    combine_script = ctx.actions.write(
        "combine_sources.sh",
        """#!/bin/bash
set -e
COMBINED_DIR="$1"
shift
mkdir -p "$COMBINED_DIR"
for src_dir in "$@"; do
    if [ -d "$src_dir" ]; then
        cp -r "$src_dir"/* "$COMBINED_DIR/" 2>/dev/null || true
    fi
done
""",
        is_executable = True,
    )

    # Create intermediate combined sources directory
    combined_srcs = ctx.actions.declare_output(ctx.attrs.name + "-combined-srcs", dir = True)
    work_dir = ctx.actions.declare_output(ctx.attrs.name + "-work", dir = True)

    # First combine the sources
    combine_cmd = cmd_args(["bash", combine_script, combined_srcs.as_output()])
    for src_dir in src_dirs:
        combine_cmd.add(src_dir)

    ctx.actions.run(
        combine_cmd,
        category = "combine",
        identifier = ctx.attrs.name + "-combine",
    )

    # Then run the installation
    install_cmd = cmd_args([
        "bash",
        script,
        install_dir.as_output(),
        work_dir.as_output(),
        combined_srcs,
    ])
    # Add dependency directories for PATH setup
    for dep_dir in dep_dirs:
        install_cmd.add(dep_dir)

    ctx.actions.run(
        install_cmd,
        category = "binary_install",
        identifier = ctx.attrs.name,
    )

    return [
        DefaultInfo(default_output = install_dir),
        PackageInfo(
            name = ctx.attrs.name,
            version = ctx.attrs.version,
            description = ctx.attrs.description,
            homepage = ctx.attrs.homepage,
            license = ctx.attrs.license,
            src_uri = "",
            checksum = "",
            dependencies = ctx.attrs.deps,
            build_dependencies = ctx.attrs.build_deps,
            maintainers = ctx.attrs.maintainers,
        ),
    ]

binary_package = rule(
    impl = _binary_package_impl,
    attrs = {
        "srcs": attrs.list(attrs.dep(), default = []),
        "install_script": attrs.string(default = ""),
        "pre_install": attrs.string(default = ""),
        "post_install": attrs.string(default = ""),
        "version": attrs.string(default = "1.0"),
        "description": attrs.string(default = ""),
        "homepage": attrs.string(default = ""),
        "license": attrs.string(default = ""),
        "deps": attrs.list(attrs.dep(), default = []),
        "build_deps": attrs.list(attrs.dep(), default = []),
        "maintainers": attrs.list(attrs.string(), default = []),
    },
)

# -----------------------------------------------------------------------------
# Precompiled Binary Package Rule
# -----------------------------------------------------------------------------

def _precompiled_package_impl(ctx: AnalysisContext) -> list[Provider]:
    """
    Simple rule for packages that are downloaded as precompiled binaries
    and just need to be extracted to the right location.

    This is simpler than binary_package when you just need to:
    - Download a binary tarball
    - Extract it to a specific location
    - Optionally create symlinks
    """
    install_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)

    # Get source directory from dependency
    src_dir = ctx.attrs.source[DefaultInfo].default_outputs[0]

    # Build the installation script
    extract_to = ctx.attrs.extract_to if ctx.attrs.extract_to else "/usr"

    # Generate symlink commands
    symlink_cmds = []
    for link, target in ctx.attrs.symlinks.items():
        symlink_cmds.append('mkdir -p "$OUT/$(dirname "{}")"'.format(link))
        symlink_cmds.append('ln -sf "{}" "$OUT/{}"'.format(target, link))
    symlinks_script = "\n".join(symlink_cmds)

    script = ctx.actions.write(
        "install_precompiled.sh",
        """#!/bin/bash
set -e

export OUT="$1"
export SRC="$2"

# Create target directory
mkdir -p "$OUT{extract_to}"

# Copy precompiled files
cp -r "$SRC"/* "$OUT{extract_to}/" 2>/dev/null || true

# Create symlinks
{symlinks}
""".format(
            extract_to = extract_to,
            symlinks = symlinks_script,
        ),
        is_executable = True,
    )

    ctx.actions.run(
        cmd_args([
            "bash",
            script,
            install_dir.as_output(),
            src_dir,
        ]),
        category = "precompiled",
        identifier = ctx.attrs.name,
    )

    return [
        DefaultInfo(default_output = install_dir),
        PackageInfo(
            name = ctx.attrs.name,
            version = ctx.attrs.version,
            description = ctx.attrs.description,
            homepage = ctx.attrs.homepage,
            license = ctx.attrs.license,
            src_uri = "",
            checksum = "",
            dependencies = ctx.attrs.deps,
            build_dependencies = [],
            maintainers = ctx.attrs.maintainers,
        ),
    ]

precompiled_package = rule(
    impl = _precompiled_package_impl,
    attrs = {
        "source": attrs.dep(),
        "version": attrs.string(),
        "extract_to": attrs.string(default = "/usr"),
        "symlinks": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "description": attrs.string(default = ""),
        "homepage": attrs.string(default = ""),
        "license": attrs.string(default = ""),
        "deps": attrs.list(attrs.dep(), default = []),
        "maintainers": attrs.list(attrs.string(), default = []),
    },
)

def _rootfs_impl(ctx: AnalysisContext) -> list[Provider]:
    """Assemble a root filesystem from packages."""
    rootfs_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)

    # Recursively collect all packages and their runtime dependencies
    all_packages = {}  # Use dict to avoid duplicates

    def collect_package_deps(pkg):
        """Recursively collect a package and its runtime dependencies."""
        # Get default outputs
        default_outputs = pkg[DefaultInfo].default_outputs

        # Add all outputs to our collection
        for output in default_outputs:
            pkg_key = str(output)
            if pkg_key not in all_packages:
                all_packages[pkg_key] = output

        # Try to collect runtime dependencies if this target has PackageInfo
        # Use get() method which returns None if provider doesn't exist
        pkg_info = pkg.get(PackageInfo)
        if pkg_info and pkg_info.dependencies:
            for dep in pkg_info.dependencies:
                collect_package_deps(dep)

    # Collect all packages starting from the explicitly listed ones
    for pkg in ctx.attrs.packages:
        collect_package_deps(pkg)

    # Convert to list for command arguments
    pkg_dirs = list(all_packages.values())

    # Create assembly script
    script_content = """#!/bin/bash
set -e
ROOTFS="$1"
shift

# Create base directory structure
mkdir -p "$ROOTFS"/{bin,sbin,lib,lib64,usr/{bin,sbin,lib,lib64},etc,var,tmp,proc,sys,dev,run,root,home}

# Copy packages
for pkg_dir in "$@"; do
    if [ -d "$pkg_dir" ]; then
        cp -a "$pkg_dir"/* "$ROOTFS"/ 2>/dev/null || true
    fi
done

# Create compatibility symlinks for /bin -> /usr/bin
# Many scripts expect common utilities in /bin (especially /bin/sh)
for cmd in sh bash; do
    if [ -f "$ROOTFS/usr/bin/$cmd" ] && [ ! -e "$ROOTFS/bin/$cmd" ]; then
        ln -sf ../usr/bin/$cmd "$ROOTFS/bin/$cmd"
    fi
done

# Set permissions
chmod 1777 "$ROOTFS/tmp"
chmod 755 "$ROOTFS/root"
"""

    script = ctx.actions.write("assemble.sh", script_content, is_executable = True)

    cmd = cmd_args(["bash", script, rootfs_dir.as_output()])
    for pkg_dir in pkg_dirs:
        cmd.add(pkg_dir)

    ctx.actions.run(
        cmd,
        category = "rootfs",
        identifier = ctx.attrs.name,
    )

    return [DefaultInfo(default_output = rootfs_dir)]

rootfs = rule(
    impl = _rootfs_impl,
    attrs = {
        "packages": attrs.list(attrs.dep()),
    },
)

def _initramfs_impl(ctx: AnalysisContext) -> list[Provider]:
    """Create an initramfs cpio archive from a rootfs."""
    initramfs_file = ctx.actions.declare_output(ctx.attrs.name + ".cpio.gz")

    # Get rootfs directory from dependency
    rootfs_dir = ctx.attrs.rootfs[DefaultInfo].default_outputs[0]

    # Compression type
    compression = ctx.attrs.compression
    if compression == "gz":
        compress_cmd = "gzip -9"
        suffix = ".gz"
    elif compression == "xz":
        compress_cmd = "xz -9 --check=crc32"
        suffix = ".xz"
    elif compression == "lz4":
        compress_cmd = "lz4 -l -9"
        suffix = ".lz4"
    elif compression == "zstd":
        compress_cmd = "zstd -19"
        suffix = ".zstd"
    else:
        compress_cmd = "gzip -9"
        suffix = ".gz"

    # Init binary path
    init_path = ctx.attrs.init if ctx.attrs.init else "/sbin/init"

    script = ctx.actions.write(
        "create_initramfs.sh",
        """#!/bin/bash
set -e

ROOTFS="$1"
OUTPUT="$2"
INIT_PATH="{init_path}"

# Create a temporary directory for initramfs modifications
WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT

# Copy rootfs to work directory
cp -a "$ROOTFS"/* "$WORK"/

# Ensure init exists
if [ ! -e "$WORK$INIT_PATH" ]; then
    # Try to find busybox or create a minimal init
    if [ -x "$WORK/bin/busybox" ]; then
        mkdir -p "$WORK/sbin"
        ln -sf /bin/busybox "$WORK/sbin/init"
    elif [ -x "$WORK/bin/sh" ]; then
        # Create minimal init script
        cat > "$WORK/sbin/init" << 'INIT_EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
exec /bin/sh
INIT_EOF
        chmod +x "$WORK/sbin/init"
    fi
fi

# Create the cpio archive
cd "$WORK"
find . -print0 | cpio --null -o -H newc | {compress_cmd} > "$OUTPUT"

echo "Created initramfs: $OUTPUT"
""".format(init_path = init_path, compress_cmd = compress_cmd),
        is_executable = True,
    )

    ctx.actions.run(
        cmd_args([
            "bash",
            script,
            rootfs_dir,
            initramfs_file.as_output(),
        ]),
        category = "initramfs",
        identifier = ctx.attrs.name,
    )

    return [DefaultInfo(default_output = initramfs_file)]

initramfs = rule(
    impl = _initramfs_impl,
    attrs = {
        "rootfs": attrs.dep(),
        "compression": attrs.string(default = "gz"),
        "init": attrs.string(default = "/sbin/init"),
    },
)

def _qemu_boot_script_impl(ctx: AnalysisContext) -> list[Provider]:
    """Generate a QEMU boot script for testing."""
    boot_script = ctx.actions.declare_output(ctx.attrs.name + ".sh")

    # Get kernel and initramfs
    kernel_dir = ctx.attrs.kernel[DefaultInfo].default_outputs[0]
    initramfs_file = ctx.attrs.initramfs[DefaultInfo].default_outputs[0]

    # QEMU options
    memory = ctx.attrs.memory
    cpus = ctx.attrs.cpus
    arch = ctx.attrs.arch
    extra_args = " ".join(ctx.attrs.extra_args) if ctx.attrs.extra_args else ""
    kernel_args = ctx.attrs.kernel_args if ctx.attrs.kernel_args else "console=ttyS0 quiet"

    # Determine QEMU binary based on architecture
    if arch == "x86_64":
        qemu_bin = "qemu-system-x86_64"
        machine = "q35"
    elif arch == "aarch64":
        qemu_bin = "qemu-system-aarch64"
        machine = "virt"
    elif arch == "riscv64":
        qemu_bin = "qemu-system-riscv64"
        machine = "virt"
    else:
        qemu_bin = "qemu-system-x86_64"
        machine = "q35"

    script_content = """#!/bin/bash
# QEMU Boot Script for BuckOs
# Generated by Buck2 build system

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Paths to built artifacts
KERNEL_DIR="{kernel_dir}"
INITRAMFS="{initramfs}"

# Find kernel image
KERNEL=""
for k in "$KERNEL_DIR/boot/vmlinuz"* "$KERNEL_DIR/boot/bzImage" "$KERNEL_DIR/vmlinuz"*; do
    if [ -f "$k" ]; then
        KERNEL="$k"
        break
    fi
done

if [ -z "$KERNEL" ]; then
    echo "Error: Cannot find kernel image in $KERNEL_DIR"
    exit 1
fi

echo "Booting BuckOs with QEMU..."
echo "  Kernel: $KERNEL"
echo "  Initramfs: $INITRAMFS"
echo ""
echo "Press Ctrl-A X to exit QEMU"
echo ""

{qemu_bin} \\
    -machine {machine} \\
    -m {memory} \\
    -smp {cpus} \\
    -kernel "$KERNEL" \\
    -initrd "$INITRAMFS" \\
    -append "{kernel_args}" \\
    -nographic \\
    -no-reboot \\
    {extra_args} \\
    "$@"
""".format(
        kernel_dir = kernel_dir,
        initramfs = initramfs_file,
        qemu_bin = qemu_bin,
        machine = machine,
        memory = memory,
        cpus = cpus,
        kernel_args = kernel_args,
        extra_args = extra_args,
    )

    ctx.actions.write(
        boot_script.as_output(),
        script_content,
        is_executable = True,
    )

    return [DefaultInfo(default_output = boot_script)]

qemu_boot_script = rule(
    impl = _qemu_boot_script_impl,
    attrs = {
        "kernel": attrs.dep(),
        "initramfs": attrs.dep(),
        "arch": attrs.string(default = "x86_64"),
        "memory": attrs.string(default = "512M"),
        "cpus": attrs.string(default = "2"),
        "kernel_args": attrs.string(default = "console=ttyS0 quiet"),
        "extra_args": attrs.list(attrs.string(), default = []),
    },
)

def _iso_image_impl(ctx: AnalysisContext) -> list[Provider]:
    """Create a bootable ISO image from kernel, initramfs, and optional rootfs."""
    iso_file = ctx.actions.declare_output(ctx.attrs.name + ".iso")

    # Get kernel and initramfs
    kernel_dir = ctx.attrs.kernel[DefaultInfo].default_outputs[0]
    initramfs_file = ctx.attrs.initramfs[DefaultInfo].default_outputs[0]

    # Optional rootfs for live system
    rootfs_dir = None
    if ctx.attrs.rootfs:
        rootfs_dir = ctx.attrs.rootfs[DefaultInfo].default_outputs[0]

    # Boot mode configuration
    boot_mode = ctx.attrs.boot_mode
    volume_label = ctx.attrs.volume_label
    kernel_args = ctx.attrs.kernel_args if ctx.attrs.kernel_args else "quiet"

    # GRUB configuration for EFI boot
    grub_cfg = """
# GRUB configuration for BuckOs ISO
set timeout=5
set default=0

menuentry "BuckOs Linux" {{
    linux /boot/vmlinuz {kernel_args}
    initrd /boot/initramfs.img
}}

menuentry "BuckOs Linux (recovery mode)" {{
    linux /boot/vmlinuz {kernel_args} single
    initrd /boot/initramfs.img
}}
""".format(kernel_args = kernel_args)

    # Isolinux configuration for BIOS boot
    isolinux_cfg = """
DEFAULT buckos
TIMEOUT 50
PROMPT 1

LABEL buckos
    MENU LABEL BuckOs Linux
    LINUX /boot/vmlinuz
    INITRD /boot/initramfs.img
    APPEND {kernel_args}

LABEL recovery
    MENU LABEL BuckOs Linux (recovery mode)
    LINUX /boot/vmlinuz
    INITRD /boot/initramfs.img
    APPEND {kernel_args} single
""".format(kernel_args = kernel_args)

    # Determine if we should include squashfs rootfs
    include_rootfs = "yes" if rootfs_dir else ""

    script = ctx.actions.write(
        "create_iso.sh",
        """#!/bin/bash
set -e

ISO_OUT="$1"
KERNEL_DIR="$2"
INITRAMFS="$3"
ROOTFS_DIR="$4"
BOOT_MODE="{boot_mode}"
VOLUME_LABEL="{volume_label}"

# Create ISO working directory
WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT

mkdir -p "$WORK/boot"
mkdir -p "$WORK/boot/grub"
mkdir -p "$WORK/isolinux"
mkdir -p "$WORK/EFI/BOOT"

# Find and copy kernel
KERNEL=""
for k in "$KERNEL_DIR/boot/vmlinuz"* "$KERNEL_DIR/boot/bzImage" "$KERNEL_DIR/vmlinuz"*; do
    if [ -f "$k" ]; then
        KERNEL="$k"
        break
    fi
done

if [ -z "$KERNEL" ]; then
    echo "Error: Cannot find kernel image in $KERNEL_DIR"
    exit 1
fi

cp "$KERNEL" "$WORK/boot/vmlinuz"
cp "$INITRAMFS" "$WORK/boot/initramfs.img"

# Create GRUB configuration
cat > "$WORK/boot/grub/grub.cfg" << 'GRUBCFG'
{grub_cfg}
GRUBCFG

# Create isolinux configuration
cat > "$WORK/isolinux/isolinux.cfg" << 'ISOCFG'
{isolinux_cfg}
ISOCFG

# Include rootfs as squashfs if provided
if [ -n "{include_rootfs}" ] && [ -d "$ROOTFS_DIR" ]; then
    echo "Creating squashfs from rootfs..."
    mkdir -p "$WORK/live"
    if command -v mksquashfs >/dev/null 2>&1; then
        mksquashfs "$ROOTFS_DIR" "$WORK/live/filesystem.squashfs" -comp xz -no-progress
    else
        echo "Warning: mksquashfs not found, skipping rootfs inclusion"
    fi
fi

# Create the ISO image based on boot mode
echo "Creating ISO image with boot mode: $BOOT_MODE"

if [ "$BOOT_MODE" = "bios" ] || [ "$BOOT_MODE" = "hybrid" ]; then
    # Check for isolinux/syslinux
    ISOLINUX_BIN=""
    for path in /usr/lib/syslinux/bios/isolinux.bin /usr/share/syslinux/isolinux.bin /usr/lib/ISOLINUX/isolinux.bin; do
        if [ -f "$path" ]; then
            ISOLINUX_BIN="$path"
            break
        fi
    done

    if [ -n "$ISOLINUX_BIN" ]; then
        cp "$ISOLINUX_BIN" "$WORK/isolinux/"

        # Copy ldlinux.c32 if available
        LDLINUX=""
        for path in /usr/lib/syslinux/bios/ldlinux.c32 /usr/share/syslinux/ldlinux.c32 /usr/lib/syslinux/ldlinux.c32; do
            if [ -f "$path" ]; then
                LDLINUX="$path"
                break
            fi
        done
        [ -n "$LDLINUX" ] && cp "$LDLINUX" "$WORK/isolinux/"
    fi
fi

# Create ISO using xorriso (preferred) or genisoimage
if command -v xorriso >/dev/null 2>&1; then
    case "$BOOT_MODE" in
        bios)
            xorriso -as mkisofs \\
                -o "$ISO_OUT" \\
                -isohybrid-mbr /usr/lib/syslinux/bios/isohdpfx.bin 2>/dev/null || true \\
                -c isolinux/boot.cat \\
                -b isolinux/isolinux.bin \\
                -no-emul-boot \\
                -boot-load-size 4 \\
                -boot-info-table \\
                -V "$VOLUME_LABEL" \\
                "$WORK"
            ;;
        efi)
            # Create EFI boot image
            mkdir -p "$WORK/EFI/BOOT"
            if command -v grub-mkimage >/dev/null 2>&1; then
                grub-mkimage -o "$WORK/EFI/BOOT/BOOTX64.EFI" -O x86_64-efi -p /boot/grub \\
                    part_gpt part_msdos fat iso9660 normal boot linux configfile loopback chain \\
                    efifwsetup efi_gop efi_uga ls search search_label search_fs_uuid search_fs_file \\
                    gfxterm gfxterm_background gfxterm_menu test all_video loadenv exfat ext2 ntfs \\
                    2>/dev/null || echo "Warning: grub-mkimage failed"
            fi

            # Create EFI boot image file
            dd if=/dev/zero of="$WORK/boot/efi.img" bs=1M count=10
            mkfs.vfat "$WORK/boot/efi.img"
            mmd -i "$WORK/boot/efi.img" ::/EFI ::/EFI/BOOT
            mcopy -i "$WORK/boot/efi.img" "$WORK/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/ 2>/dev/null || true

            xorriso -as mkisofs \\
                -o "$ISO_OUT" \\
                -e boot/efi.img \\
                -no-emul-boot \\
                -V "$VOLUME_LABEL" \\
                "$WORK"
            ;;
        hybrid|*)
            # Hybrid BIOS+EFI boot
            # Create EFI boot image
            mkdir -p "$WORK/EFI/BOOT"
            if command -v grub-mkimage >/dev/null 2>&1; then
                grub-mkimage -o "$WORK/EFI/BOOT/BOOTX64.EFI" -O x86_64-efi -p /boot/grub \\
                    part_gpt part_msdos fat iso9660 normal boot linux configfile loopback chain \\
                    efifwsetup efi_gop efi_uga ls search search_label search_fs_uuid search_fs_file \\
                    gfxterm gfxterm_background gfxterm_menu test all_video loadenv exfat ext2 ntfs \\
                    2>/dev/null || echo "Warning: grub-mkimage failed"
            fi

            # Create EFI boot image file
            dd if=/dev/zero of="$WORK/boot/efi.img" bs=1M count=10
            mkfs.vfat "$WORK/boot/efi.img" 2>/dev/null || true
            if command -v mmd >/dev/null 2>&1; then
                mmd -i "$WORK/boot/efi.img" ::/EFI ::/EFI/BOOT
                mcopy -i "$WORK/boot/efi.img" "$WORK/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/ 2>/dev/null || true
            fi

            # Build ISO with both BIOS and EFI support
            xorriso -as mkisofs \\
                -o "$ISO_OUT" \\
                -isohybrid-mbr /usr/lib/syslinux/bios/isohdpfx.bin 2>/dev/null || true \\
                -c isolinux/boot.cat \\
                -b isolinux/isolinux.bin \\
                -no-emul-boot \\
                -boot-load-size 4 \\
                -boot-info-table \\
                -eltorito-alt-boot \\
                -e boot/efi.img \\
                -no-emul-boot \\
                -isohybrid-gpt-basdat \\
                -V "$VOLUME_LABEL" \\
                "$WORK" || \\
            # Fallback to simpler ISO if hybrid fails
            xorriso -as mkisofs \\
                -o "$ISO_OUT" \\
                -c isolinux/boot.cat \\
                -b isolinux/isolinux.bin \\
                -no-emul-boot \\
                -boot-load-size 4 \\
                -boot-info-table \\
                -V "$VOLUME_LABEL" \\
                "$WORK"
            ;;
    esac
elif command -v genisoimage >/dev/null 2>&1; then
    genisoimage \\
        -o "$ISO_OUT" \\
        -b isolinux/isolinux.bin \\
        -c isolinux/boot.cat \\
        -no-emul-boot \\
        -boot-load-size 4 \\
        -boot-info-table \\
        -V "$VOLUME_LABEL" \\
        -J -R \\
        "$WORK"
elif command -v mkisofs >/dev/null 2>&1; then
    mkisofs \\
        -o "$ISO_OUT" \\
        -b isolinux/isolinux.bin \\
        -c isolinux/boot.cat \\
        -no-emul-boot \\
        -boot-load-size 4 \\
        -boot-info-table \\
        -V "$VOLUME_LABEL" \\
        -J -R \\
        "$WORK"
else
    echo "Error: No ISO creation tool found (xorriso, genisoimage, or mkisofs required)"
    exit 1
fi

echo "Created ISO image: $ISO_OUT"
ls -lh "$ISO_OUT"
""".format(
            boot_mode = boot_mode,
            volume_label = volume_label,
            grub_cfg = grub_cfg,
            isolinux_cfg = isolinux_cfg,
            include_rootfs = include_rootfs,
        ),
        is_executable = True,
    )

    rootfs_arg = rootfs_dir if rootfs_dir else ""

    ctx.actions.run(
        cmd_args([
            "bash",
            script,
            iso_file.as_output(),
            kernel_dir,
            initramfs_file,
            rootfs_arg,
        ]),
        category = "iso",
        identifier = ctx.attrs.name,
    )

    return [DefaultInfo(default_output = iso_file)]

iso_image = rule(
    impl = _iso_image_impl,
    attrs = {
        "kernel": attrs.dep(),
        "initramfs": attrs.dep(),
        "rootfs": attrs.option(attrs.dep(), default = None),
        "boot_mode": attrs.string(default = "hybrid"),  # bios, efi, or hybrid
        "volume_label": attrs.string(default = "BUCKOS"),
        "kernel_args": attrs.string(default = "quiet"),
    },
)

# =============================================================================
# EBUILD-STYLE HELPER FUNCTIONS
# =============================================================================
# These helpers mirror Gentoo's ebuild system functionality for Buck2

# -----------------------------------------------------------------------------
# Logging and Output Helpers
# -----------------------------------------------------------------------------

def einfo(msg: str) -> str:
    """Print an informational message (green asterisk)."""
    return 'echo -e "\\033[32m * \\033[0m{}"'.format(msg)

def ewarn(msg: str) -> str:
    """Print a warning message (yellow asterisk)."""
    return 'echo -e "\\033[33m * \\033[0mWARNING: {}"'.format(msg)

def eerror(msg: str) -> str:
    """Print an error message (red asterisk)."""
    return 'echo -e "\\033[31m * \\033[0mERROR: {}"'.format(msg)

def ebegin(msg: str) -> str:
    """Print a message indicating start of a process."""
    return 'echo -e "\\033[32m * \\033[0m{}..."'.format(msg)

def eend(retval: str = "$?") -> str:
    """Print success/failure based on return value."""
    return '''
if [ {} -eq 0 ]; then
    echo -e "\\033[32m [ ok ]\\033[0m"
else
    echo -e "\\033[31m [ !! ]\\033[0m"
fi
'''.format(retval)

def die(msg: str) -> str:
    """Print error and exit with failure."""
    return '{}\nexit 1'.format(eerror(msg))

# -----------------------------------------------------------------------------
# Installation Directory Helpers
# -----------------------------------------------------------------------------

def into(dir: str) -> str:
    """Set the installation prefix for subsequent do* commands."""
    return 'export INSDESTTREE="{}"'.format(dir)

def insinto(dir: str) -> str:
    """Set installation directory for doins."""
    return 'export INSDESTTREE="{}"'.format(dir)

def exeinto(dir: str) -> str:
    """Set installation directory for doexe."""
    return 'export EXEDESTTREE="{}"'.format(dir)

def docinto(dir: str) -> str:
    """Set installation subdirectory for dodoc."""
    return 'export DOCDESTTREE="{}"'.format(dir)

# -----------------------------------------------------------------------------
# File Installation Helpers
# -----------------------------------------------------------------------------

def dobin(files: list[str]) -> str:
    """Install executables into /usr/bin."""
    cmds = ['mkdir -p "$DESTDIR/usr/bin"']
    for f in files:
        cmds.append('install -m 0755 "{}" "$DESTDIR/usr/bin/"'.format(f))
    return "\n".join(cmds)

def dosbin(files: list[str]) -> str:
    """Install system executables into /usr/sbin."""
    cmds = ['mkdir -p "$DESTDIR/usr/sbin"']
    for f in files:
        cmds.append('install -m 0755 "{}" "$DESTDIR/usr/sbin/"'.format(f))
    return "\n".join(cmds)

def dolib_so(files: list[str]) -> str:
    """Install shared libraries into /usr/lib64 (or /usr/lib)."""
    cmds = ['mkdir -p "$DESTDIR/${LIBDIR:-usr/lib64}"']
    for f in files:
        cmds.append('install -m 0755 "{}" "$DESTDIR/${{LIBDIR:-usr/lib64}}/"'.format(f))
    return "\n".join(cmds)

def dolib_a(files: list[str]) -> str:
    """Install static libraries into /usr/lib64 (or /usr/lib)."""
    cmds = ['mkdir -p "$DESTDIR/${LIBDIR:-usr/lib64}"']
    for f in files:
        cmds.append('install -m 0644 "{}" "$DESTDIR/${{LIBDIR:-usr/lib64}}/"'.format(f))
    return "\n".join(cmds)

def newlib_so(src: str, dst: str) -> str:
    """Install shared library with new name."""
    return '''mkdir -p "$DESTDIR/${{LIBDIR:-usr/lib64}}"
install -m 0755 "{}" "$DESTDIR/${{LIBDIR:-usr/lib64}}/{}"'''.format(src, dst)

def newlib_a(src: str, dst: str) -> str:
    """Install static library with new name."""
    return '''mkdir -p "$DESTDIR/${{LIBDIR:-usr/lib64}}"
install -m 0644 "{}" "$DESTDIR/${{LIBDIR:-usr/lib64}}/{}"'''.format(src, dst)

def doins(files: list[str]) -> str:
    """Install files into INSDESTTREE (default: /usr/share)."""
    cmds = ['mkdir -p "$DESTDIR/${INSDESTTREE:-usr/share}"']
    for f in files:
        cmds.append('install -m 0644 "{}" "$DESTDIR/${{INSDESTTREE:-usr/share}}/"'.format(f))
    return "\n".join(cmds)

def newins(src: str, dst: str) -> str:
    """Install file with new name into INSDESTTREE."""
    return '''mkdir -p "$DESTDIR/${{INSDESTTREE:-usr/share}}"
install -m 0644 "{}" "$DESTDIR/${{INSDESTTREE:-usr/share}}/{}"'''.format(src, dst)

def doexe(files: list[str]) -> str:
    """Install executables into EXEDESTTREE."""
    cmds = ['mkdir -p "$DESTDIR/${EXEDESTTREE:-usr/bin}"']
    for f in files:
        cmds.append('install -m 0755 "{}" "$DESTDIR/${{EXEDESTTREE:-usr/bin}}/"'.format(f))
    return "\n".join(cmds)

def newexe(src: str, dst: str) -> str:
    """Install executable with new name."""
    return '''mkdir -p "$DESTDIR/${{EXEDESTTREE:-usr/bin}}"
install -m 0755 "{}" "$DESTDIR/${{EXEDESTTREE:-usr/bin}}/{}"'''.format(src, dst)

def doheader(files: list[str]) -> str:
    """Install header files into /usr/include."""
    cmds = ['mkdir -p "$DESTDIR/usr/include"']
    for f in files:
        cmds.append('install -m 0644 "{}" "$DESTDIR/usr/include/"'.format(f))
    return "\n".join(cmds)

def newheader(src: str, dst: str) -> str:
    """Install header file with new name."""
    return '''mkdir -p "$DESTDIR/usr/include"
install -m 0644 "{}" "$DESTDIR/usr/include/{}"'''.format(src, dst)

def doconfd(files: list[str]) -> str:
    """Install config files into /etc/conf.d."""
    cmds = ['mkdir -p "$DESTDIR/etc/conf.d"']
    for f in files:
        cmds.append('install -m 0644 "{}" "$DESTDIR/etc/conf.d/"'.format(f))
    return "\n".join(cmds)

def doenvd(files: list[str]) -> str:
    """Install environment files into /etc/env.d."""
    cmds = ['mkdir -p "$DESTDIR/etc/env.d"']
    for f in files:
        cmds.append('install -m 0644 "{}" "$DESTDIR/etc/env.d/"'.format(f))
    return "\n".join(cmds)

def doinitd(files: list[str]) -> str:
    """Install init scripts into /etc/init.d."""
    cmds = ['mkdir -p "$DESTDIR/etc/init.d"']
    for f in files:
        cmds.append('install -m 0755 "{}" "$DESTDIR/etc/init.d/"'.format(f))
    return "\n".join(cmds)

def dosym(target: str, link: str) -> str:
    """Create a symbolic link."""
    return '''mkdir -p "$DESTDIR/$(dirname "{}")"
ln -sf "{}" "$DESTDIR/{}"'''.format(link, target, link)

def dosym_rel(target: str, link: str) -> str:
    """Create a relative symbolic link."""
    return '''mkdir -p "$DESTDIR/$(dirname "{}")"
ln -srf "$DESTDIR/{}" "$DESTDIR/{}"'''.format(link, target, link)

def newbin(src: str, dst: str) -> str:
    """Install executable with new name into /usr/bin."""
    return '''mkdir -p "$DESTDIR/usr/bin"
install -m 0755 "{}" "$DESTDIR/usr/bin/{}"'''.format(src, dst)

def newsbin(src: str, dst: str) -> str:
    """Install system executable with new name into /usr/sbin."""
    return '''mkdir -p "$DESTDIR/usr/sbin"
install -m 0755 "{}" "$DESTDIR/usr/sbin/{}"'''.format(src, dst)

# -----------------------------------------------------------------------------
# Documentation Helpers
# -----------------------------------------------------------------------------

def dodoc(files: list[str]) -> str:
    """Install documentation files."""
    cmds = ['mkdir -p "$DESTDIR/usr/share/doc/${PN:-$PACKAGE_NAME}/${DOCDESTTREE:-}"']
    for f in files:
        cmds.append('install -m 0644 "{}" "$DESTDIR/usr/share/doc/${{PN:-$PACKAGE_NAME}}/${{DOCDESTTREE:-}}/"'.format(f))
    return "\n".join(cmds)

def newdoc(src: str, dst: str) -> str:
    """Install documentation file with new name."""
    return '''mkdir -p "$DESTDIR/usr/share/doc/${{PN:-$PACKAGE_NAME}}/${{DOCDESTTREE:-}}"
install -m 0644 "{}" "$DESTDIR/usr/share/doc/${{PN:-$PACKAGE_NAME}}/${{DOCDESTTREE:-}}/{}"'''.format(src, dst)

def doman(files: list[str]) -> str:
    """Install man pages."""
    cmds = []
    for f in files:
        # Detect man section from filename
        cmds.append('''
_manfile="{}"
_section="${{_manfile##*.}}"
mkdir -p "$DESTDIR/usr/share/man/man$_section"
install -m 0644 "$_manfile" "$DESTDIR/usr/share/man/man$_section/"
'''.format(f))
    return "\n".join(cmds)

def newman(src: str, dst: str) -> str:
    """Install man page with new name."""
    return '''
_section="${{{1}##*.}}"
mkdir -p "$DESTDIR/usr/share/man/man$_section"
install -m 0644 "{}" "$DESTDIR/usr/share/man/man$_section/{}"
'''.format(dst, src, dst)

def doinfo(files: list[str]) -> str:
    """Install GNU info files."""
    cmds = ['mkdir -p "$DESTDIR/usr/share/info"']
    for f in files:
        cmds.append('install -m 0644 "{}" "$DESTDIR/usr/share/info/"'.format(f))
    return "\n".join(cmds)

def dohtml(files: list[str], recursive: bool = False) -> str:
    """Install HTML documentation."""
    cmds = ['mkdir -p "$DESTDIR/usr/share/doc/${PN:-$PACKAGE_NAME}/html"']
    if recursive:
        for f in files:
            cmds.append('cp -r "{}" "$DESTDIR/usr/share/doc/${{PN:-$PACKAGE_NAME}}/html/"'.format(f))
    else:
        for f in files:
            cmds.append('install -m 0644 "{}" "$DESTDIR/usr/share/doc/${{PN:-$PACKAGE_NAME}}/html/"'.format(f))
    return "\n".join(cmds)

# -----------------------------------------------------------------------------
# Directory and Permission Helpers
# -----------------------------------------------------------------------------

def dodir(dirs: list[str]) -> str:
    """Create directories in DESTDIR."""
    cmds = []
    for d in dirs:
        cmds.append('mkdir -p "$DESTDIR/{}"'.format(d))
    return "\n".join(cmds)

def keepdir(dirs: list[str]) -> str:
    """Create directories and add .keep files to preserve empty dirs."""
    cmds = []
    for d in dirs:
        cmds.append('mkdir -p "$DESTDIR/{}"'.format(d))
        cmds.append('touch "$DESTDIR/{}/.keep"'.format(d))
    return "\n".join(cmds)

def fowners(owner: str, files: list[str]) -> str:
    """Change file ownership (recorded for package manager)."""
    cmds = []
    for f in files:
        cmds.append('chown {} "$DESTDIR/{}"'.format(owner, f))
    return "\n".join(cmds)

def fperms(mode: str, files: list[str]) -> str:
    """Change file permissions."""
    cmds = []
    for f in files:
        cmds.append('chmod {} "$DESTDIR/{}"'.format(mode, f))
    return "\n".join(cmds)

# -----------------------------------------------------------------------------
# Compilation Helpers
# -----------------------------------------------------------------------------

def emake(args: list[str] = []) -> str:
    """Run make with standard parallel jobs and arguments."""
    args_str = " ".join(args) if args else ""
    return 'make -j${{MAKEOPTS:-$(nproc)}} {}'.format(args_str)

def econf(args: list[str] = []) -> str:
    """Run configure with standard arguments."""
    args_str = " ".join(args) if args else ""
    return '''
ECONF_SOURCE="${{ECONF_SOURCE:-.}}"
"$ECONF_SOURCE/configure" \\
    --prefix="${{EPREFIX:-/usr}}" \\
    --build="${{CBUILD:-$(gcc -dumpmachine)}}" \\
    --host="${{CHOST:-$(gcc -dumpmachine)}}" \\
    --mandir="${{EPREFIX:-/usr}}/share/man" \\
    --infodir="${{EPREFIX:-/usr}}/share/info" \\
    --datadir="${{EPREFIX:-/usr}}/share" \\
    --sysconfdir="${{EPREFIX:-/etc}}" \\
    --localstatedir="${{EPREFIX:-/var}}" \\
    --libdir="${{EPREFIX:-/usr}}/${{LIBDIR_SUFFIX:-lib64}}" \\
    {}
'''.format(args_str)

def einstall(args: list[str] = []) -> str:
    """Run make install with DESTDIR."""
    args_str = " ".join(args) if args else ""
    return 'make DESTDIR="$DESTDIR" {} install'.format(args_str)

def eautoreconf() -> str:
    """Run autoreconf to regenerate autotools files."""
    return '''
{begin}
if [ -f configure.ac ] || [ -f configure.in ]; then
    autoreconf -fiv
fi
{end}
'''.format(begin = ebegin("Running autoreconf"), end = eend())

def elibtoolize() -> str:
    """Run libtoolize to update libtool scripts."""
    return '''
{begin}
if [ -f configure.ac ] || [ -f configure.in ]; then
    libtoolize --copy --force
fi
{end}
'''.format(begin = ebegin("Running libtoolize"), end = eend())

# -----------------------------------------------------------------------------
# Patch Helpers
# -----------------------------------------------------------------------------

def epatch(patches: list[str], strip: int = 1) -> str:
    """Apply patches to source."""
    cmds = []
    for p in patches:
        cmds.append('{}\npatch -p{} < "{}"'.format(
            ebegin("Applying patch {}".format(p)),
            strip,
            p,
        ))
    return "\n".join(cmds)

def eapply(patches: list[str], strip: int = 1) -> str:
    """Modern patch application (EAPI 6+)."""
    cmds = []
    for p in patches:
        cmds.append('''
{begin}
if [ -d "{patch}" ]; then
    for _p in "{patch}"/*.patch; do
        patch -p{strip} < "$_p" || die "Patch failed: $_p"
    done
else
    patch -p{strip} < "{patch}" || die "Patch failed: {patch}"
fi
'''.format(begin = ebegin("Applying {}".format(p)), patch = p, strip = strip))
    return "\n".join(cmds)

def eapply_user() -> str:
    """Apply user patches from /etc/portage/patches."""
    return '''
# Apply user patches if they exist
_user_patches="${{EPREFIX:-}}/etc/portage/patches/${{CATEGORY}}/${{PN}}"
if [ -d "$_user_patches" ]; then
    {}
    for _p in "$_user_patches"/*.patch; do
        [ -f "$_p" ] && patch -p1 < "$_p"
    done
fi
'''.format(ebegin("Applying user patches"))

# -----------------------------------------------------------------------------
# USE Flag Helpers
# -----------------------------------------------------------------------------

def use_enable(flag: str, option: str = "") -> str:
    """Generate --enable-X or --disable-X based on USE flag."""
    opt = option if option else flag
    return '''
if use {}; then
    echo "--enable-{}"
else
    echo "--disable-{}"
fi
'''.format(flag, opt, opt)

def use_with(flag: str, option: str = "") -> str:
    """Generate --with-X or --without-X based on USE flag."""
    opt = option if option else flag
    return '''
if use {}; then
    echo "--with-{}"
else
    echo "--without-{}"
fi
'''.format(flag, opt, opt)

def usev(flag: str, value: str = "") -> str:
    """Echo value if USE flag is enabled."""
    val = value if value else flag
    return '''
if use {}; then
    echo "{}"
fi
'''.format(flag, val)

def usex(flag: str, yes_val: str = "yes", no_val: str = "no") -> str:
    """Return different values based on USE flag."""
    return '''
if use {}; then
    echo "{}"
else
    echo "{}"
fi
'''.format(flag, yes_val, no_val)

def use_check(flag: str) -> str:
    """Return shell code to check if a USE flag is set."""
    return '[[ " $USE " == *" {} "* ]]'.format(flag)

# -----------------------------------------------------------------------------
# Build System Specific Helpers
# -----------------------------------------------------------------------------

def cmake_src_configure(args: list[str] = [], build_type: str = "Release") -> str:
    """Configure CMake project."""
    args_str = " ".join(args) if args else ""
    return '''
mkdir -p "${{BUILD_DIR:-build}}"
cd "${{BUILD_DIR:-build}}"
cmake \\
    -DCMAKE_INSTALL_PREFIX="${{EPREFIX:-/usr}}" \\
    -DCMAKE_BUILD_TYPE={build_type} \\
    -DCMAKE_INSTALL_LIBDIR="${{LIBDIR:-lib64}}" \\
    -DCMAKE_C_FLAGS="${{CFLAGS:-}}" \\
    -DCMAKE_CXX_FLAGS="${{CXXFLAGS:-}}" \\
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \\
    {args} \\
    ..
'''.format(build_type = build_type, args = args_str)

def cmake_src_compile(args: list[str] = []) -> str:
    """Build CMake project."""
    args_str = " ".join(args) if args else ""
    return '''
cd "${{BUILD_DIR:-build}}"
cmake --build . -j${{MAKEOPTS:-$(nproc)}} {}
'''.format(args_str)

def cmake_src_install(args: list[str] = []) -> str:
    """Install CMake project."""
    args_str = " ".join(args) if args else ""
    return '''
cd "${{BUILD_DIR:-build}}"
DESTDIR="$DESTDIR" cmake --install . {}
'''.format(args_str)

def meson_src_configure(args: list[str] = [], build_type: str = "release") -> str:
    """Configure Meson project."""
    args_str = " ".join(args) if args else ""
    return '''
meson setup "${{BUILD_DIR:-build}}" \\
    --prefix="${{EPREFIX:-/usr}}" \\
    --libdir="${{LIBDIR:-lib64}}" \\
    --buildtype={build_type} \\
    {}
'''.format(args_str, build_type = build_type)

def meson_src_compile() -> str:
    """Build Meson project."""
    return 'meson compile -C "${BUILD_DIR:-build}" -j${MAKEOPTS:-$(nproc)}'

def meson_src_install() -> str:
    """Install Meson project."""
    return 'DESTDIR="$DESTDIR" meson install -C "${BUILD_DIR:-build}"'

def cargo_src_configure(args: list[str] = []) -> str:
    """Configure Cargo/Rust project."""
    args_str = " ".join(args) if args else ""
    return '''
export CARGO_HOME="${{CARGO_HOME:-$PWD/.cargo}}"
mkdir -p "$CARGO_HOME"
# Configure offline mode if vendor dir exists
if [ -d vendor ]; then
    mkdir -p .cargo
    cat > .cargo/config.toml << 'CARGO_EOF'
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor"
CARGO_EOF
fi
{}
'''.format(args_str)

def cargo_src_compile(args: list[str] = []) -> str:
    """Build Cargo/Rust project."""
    args_str = " ".join(args) if args else ""
    return '''
cargo build --release \\
    --jobs ${{MAKEOPTS:-$(nproc)}} \\
    {}
'''.format(args_str)

def cargo_src_install(bins: list[str] = []) -> str:
    """Install Cargo/Rust binaries."""
    if bins:
        cmds = ['mkdir -p "$DESTDIR/usr/bin"']
        for b in bins:
            cmds.append('install -m 0755 "target/release/{}" "$DESTDIR/usr/bin/"'.format(b))
        return "\n".join(cmds)
    return '''
mkdir -p "$DESTDIR/usr/bin"
find target/release -maxdepth 1 -type f -executable ! -name "*.d" -exec install -m 0755 {{}} "$DESTDIR/usr/bin/" \\;
'''

def go_src_compile(packages: list[str] = ["."], ldflags: str = "") -> str:
    """Build Go project."""
    pkgs = " ".join(packages)
    return '''
export GOPATH="${{GOPATH:-$PWD/go}}"
export GOCACHE="${{GOCACHE:-$PWD/.cache/go-build}}"
export CGO_ENABLED="${{CGO_ENABLED:-1}}"
go build \\
    -v \\
    -ldflags="-s -w {ldflags}" \\
    -o "${{BUILD_DIR:-build}}/" \\
    {packages}
'''.format(ldflags = ldflags, packages = pkgs)

def go_src_install(bins: list[str] = []) -> str:
    """Install Go binaries."""
    if bins:
        cmds = ['mkdir -p "$DESTDIR/usr/bin"']
        for b in bins:
            cmds.append('install -m 0755 "${{BUILD_DIR:-build}}/{}" "$DESTDIR/usr/bin/"'.format(b))
        return "\n".join(cmds)
    return '''
mkdir -p "$DESTDIR/usr/bin"
find "${{BUILD_DIR:-build}}" -maxdepth 1 -type f -executable -exec install -m 0755 {{}} "$DESTDIR/usr/bin/" \\;
'''

def ninja_src_compile(args: list[str] = []) -> str:
    """Build with Ninja."""
    args_str = " ".join(args) if args else ""
    return 'ninja -C "${{BUILD_DIR:-build}}" -j${{MAKEOPTS:-$(nproc)}} {}'.format(args_str)

def ninja_src_install() -> str:
    """Install with Ninja."""
    return 'DESTDIR="$DESTDIR" ninja -C "${BUILD_DIR:-build}" install'

def python_src_install(python: str = "python3") -> str:
    """Install Python package."""
    return '''
{python} setup.py install \\
    --prefix=/usr \\
    --root="$DESTDIR" \\
    --optimize=1 \\
    --skip-build
'''.format(python = python)

def pip_src_install(python: str = "python3") -> str:
    """Install Python package with pip."""
    return '''
{python} -m pip install \\
    --prefix=/usr \\
    --root="$DESTDIR" \\
    --no-deps \\
    --no-build-isolation \\
    .
'''.format(python = python)

# -----------------------------------------------------------------------------
# VCS Source Helpers
# -----------------------------------------------------------------------------

def git_src_unpack(repo: str, branch: str = "main", depth: int = 1) -> str:
    """Clone git repository."""
    return '''
git clone \\
    --depth={depth} \\
    --branch={branch} \\
    "{repo}" \\
    "${{S:-source}}"
'''.format(repo = repo, branch = branch, depth = depth)

def git_src_prepare() -> str:
    """Prepare git source (submodules, etc.)."""
    return '''
cd "${S:-source}"
if [ -f .gitmodules ]; then
    git submodule update --init --recursive --depth=1
fi
'''

def svn_src_unpack(repo: str, revision: str = "HEAD") -> str:
    """Checkout SVN repository."""
    return '''
svn checkout \\
    -r {revision} \\
    "{repo}" \\
    "${{S:-source}}"
'''.format(repo = repo, revision = revision)

def hg_src_unpack(repo: str, branch: str = "default") -> str:
    """Clone Mercurial repository."""
    return '''
hg clone \\
    -b {branch} \\
    "{repo}" \\
    "${{S:-source}}"
'''.format(repo = repo, branch = branch)

# -----------------------------------------------------------------------------
# Test Helpers
# -----------------------------------------------------------------------------

def default_src_test() -> str:
    """Default test phase implementation."""
    return '''
if [ -f Makefile ] || [ -f GNUmakefile ] || [ -f makefile ]; then
    if make -q check 2>/dev/null; then
        emake check
    elif make -q test 2>/dev/null; then
        emake test
    fi
fi
'''

def python_test(args: list[str] = []) -> str:
    """Run Python tests with pytest."""
    args_str = " ".join(args) if args else ""
    return 'python3 -m pytest {} -v'.format(args_str)

def go_test(packages: list[str] = ["./..."]) -> str:
    """Run Go tests."""
    pkgs = " ".join(packages)
    return 'go test -v {}'.format(pkgs)

def cargo_test(args: list[str] = []) -> str:
    """Run Cargo tests."""
    args_str = " ".join(args) if args else ""
    return 'cargo test --release {}'.format(args_str)

# -----------------------------------------------------------------------------
# Environment Setup Helpers
# -----------------------------------------------------------------------------

# Toolchain detection shell functions (Gentoo-style tc-* helpers)
# These are embedded into build scripts to provide runtime toolchain detection
TC_FUNCS = '''
# Gentoo-style toolchain helper functions
tc-getCC() { echo "${CC:-gcc}"; }
tc-getCXX() { echo "${CXX:-g++}"; }
tc-getLD() { echo "${LD:-ld}"; }
tc-getAR() { echo "${AR:-ar}"; }
tc-getRANLIB() { echo "${RANLIB:-ranlib}"; }
tc-getNM() { echo "${NM:-nm}"; }
tc-getSTRIP() { echo "${STRIP:-strip}"; }
tc-getOBJCOPY() { echo "${OBJCOPY:-objcopy}"; }
tc-getPKG_CONFIG() { echo "${PKG_CONFIG:-pkg-config}"; }

tc-is-gcc() {
    local cc="$(tc-getCC)"
    local ver=$($cc --version 2>/dev/null | head -1)
    echo "$ver" | grep -iq "gcc"
}

tc-is-clang() {
    local cc="$(tc-getCC)"
    local ver=$($cc --version 2>/dev/null | head -1)
    echo "$ver" | grep -iq "clang"
}

tc-get-compiler-type() {
    if tc-is-clang; then
        echo "clang"
    elif tc-is-gcc; then
        echo "gcc"
    else
        echo "unknown"
    fi
}

# Get GCC major version number
gcc-major-version() {
    local cc="$(tc-getCC)"
    local ver=$($cc --version 2>/dev/null | head -1)
    echo "$ver" | sed -n 's/.*[gG][cC][cC][^0-9]*\\([0-9]*\\)\\..*/\\1/p'
}

# Get Clang major version number
clang-major-version() {
    local cc="$(tc-getCC)"
    local ver=$($cc --version 2>/dev/null | head -1)
    echo "$ver" | sed -n 's/.*clang[^0-9]*\\([0-9]*\\)\\..*/\\1/p'
}

# Check if GCC version is at least N
gcc-min-version() {
    local min="$1"
    local cur=$(gcc-major-version)
    [ -n "$cur" ] && [ "$cur" -ge "$min" ] 2>/dev/null
}

# Check if Clang version is at least N
clang-min-version() {
    local min="$1"
    local cur=$(clang-major-version)
    [ -n "$cur" ] && [ "$cur" -ge "$min" ] 2>/dev/null
}

# Apply GCC 15+ C23 compatibility fix (wraps CC with -std=gnu11)
tc-fix-gcc15-c23() {
    if tc-is-gcc && gcc-min-version 15; then
        local cc="$(tc-getCC)"
        export CC="$cc -std=gnu11"
        export CXX="$(tc-getCXX) -std=gnu++17"
        echo "Applied GCC 15+ C23 compatibility fix: CC=$CC"
        return 0
    fi
    return 1
}
'''

def tc_export(vars: list[str] = ["CC", "CXX", "LD", "AR", "RANLIB", "NM"]) -> str:
    """Export toolchain variables."""
    exports = []
    for var in vars:
        if var == "CC":
            exports.append('export CC="${CC:-gcc}"')
        elif var == "CXX":
            exports.append('export CXX="${CXX:-g++}"')
        elif var == "LD":
            exports.append('export LD="${LD:-ld}"')
        elif var == "AR":
            exports.append('export AR="${AR:-ar}"')
        elif var == "RANLIB":
            exports.append('export RANLIB="${RANLIB:-ranlib}"')
        elif var == "NM":
            exports.append('export NM="${NM:-nm}"')
        elif var == "STRIP":
            exports.append('export STRIP="${STRIP:-strip}"')
        elif var == "OBJCOPY":
            exports.append('export OBJCOPY="${OBJCOPY:-objcopy}"')
        elif var == "PKG_CONFIG":
            exports.append('export PKG_CONFIG="${PKG_CONFIG:-pkg-config}"')
    return "\n".join(exports)

def tc_funcs() -> str:
    """Return shell functions for toolchain detection."""
    return TC_FUNCS

def append_cflags(flags: list[str]) -> str:
    """Append flags to CFLAGS."""
    return 'export CFLAGS="$CFLAGS {}"'.format(" ".join(flags))

def append_cxxflags(flags: list[str]) -> str:
    """Append flags to CXXFLAGS."""
    return 'export CXXFLAGS="$CXXFLAGS {}"'.format(" ".join(flags))

def append_ldflags(flags: list[str]) -> str:
    """Append flags to LDFLAGS."""
    return 'export LDFLAGS="$LDFLAGS {}"'.format(" ".join(flags))

def filter_flags(patterns: list[str]) -> str:
    """Remove flags matching patterns from CFLAGS/CXXFLAGS."""
    cmds = []
    for pat in patterns:
        cmds.append('CFLAGS=$(echo "$CFLAGS" | sed "s/{}//g")'.format(pat))
        cmds.append('CXXFLAGS=$(echo "$CXXFLAGS" | sed "s/{}//g")'.format(pat))
    return "\n".join(cmds)

def replace_flags(old: str, new: str) -> str:
    """Replace flag in CFLAGS/CXXFLAGS."""
    return '''
CFLAGS="${{CFLAGS//{old}/{new}}}"
CXXFLAGS="${{CXXFLAGS//{old}/{new}}}"
'''.format(old = old, new = new)

# -----------------------------------------------------------------------------
# Package Information Helpers
# -----------------------------------------------------------------------------

def get_version_component_range(component_range: str, version: str) -> str:
    """Extract version components (e.g., '1-2' from '1.2.3')."""
    return '''
_ver="{version}"
_range="{range}"
echo "$_ver" | cut -d. -f"$_range"
'''.format(version = version, range = component_range)

def get_major_version(version: str) -> str:
    """Get major version number."""
    return 'echo "{}" | cut -d. -f1'.format(version)

def get_minor_version(version: str) -> str:
    """Get minor version number (major.minor)."""
    return 'echo "{}" | cut -d. -f1-2'.format(version)

def ver_cut(range: str, version: str) -> str:
    """Cut version string by components."""
    return 'echo "{}" | cut -d. -f{}'.format(version, range)

def ver_rs(sep_from: str, sep_to: str, version: str) -> str:
    """Replace version separator."""
    return 'echo "{}" | sed "s/{}/${}$/g"'.format(version, sep_from, sep_to)

# -----------------------------------------------------------------------------
# Systemd Helpers
# -----------------------------------------------------------------------------

def systemd_dounit(files: list[str]) -> str:
    """Install systemd unit files."""
    cmds = ['mkdir -p "$DESTDIR/usr/lib/systemd/system"']
    for f in files:
        cmds.append('install -m 0644 "{}" "$DESTDIR/usr/lib/systemd/system/"'.format(f))
    return "\n".join(cmds)

def systemd_newunit(src: str, dst: str) -> str:
    """Install systemd unit file with new name."""
    return '''mkdir -p "$DESTDIR/usr/lib/systemd/system"
install -m 0644 "{}" "$DESTDIR/usr/lib/systemd/system/{}"'''.format(src, dst)

def systemd_douserunit(files: list[str]) -> str:
    """Install systemd user unit files."""
    cmds = ['mkdir -p "$DESTDIR/usr/lib/systemd/user"']
    for f in files:
        cmds.append('install -m 0644 "{}" "$DESTDIR/usr/lib/systemd/user/"'.format(f))
    return "\n".join(cmds)

def systemd_enable_service(service: str, target: str = "multi-user.target") -> str:
    """Create symlink to enable systemd service."""
    return '''mkdir -p "$DESTDIR/usr/lib/systemd/system/{target}.wants"
ln -sf "../{service}" "$DESTDIR/usr/lib/systemd/system/{target}.wants/{service}"
'''.format(service = service, target = target)

# -----------------------------------------------------------------------------
# OpenRC Helpers
# -----------------------------------------------------------------------------

def openrc_doinitd(files: list[str]) -> str:
    """Install OpenRC init scripts."""
    return doinitd(files)

def openrc_doconfd(files: list[str]) -> str:
    """Install OpenRC conf.d files."""
    return doconfd(files)

def newinitd(src: str, dst: str) -> str:
    """Install OpenRC init script with new name."""
    return '''mkdir -p "$DESTDIR/etc/init.d"
install -m 0755 "{}" "$DESTDIR/etc/init.d/{}"'''.format(src, dst)

def newconfd(src: str, dst: str) -> str:
    """Install conf.d file with new name."""
    return '''mkdir -p "$DESTDIR/etc/conf.d"
install -m 0644 "{}" "$DESTDIR/etc/conf.d/{}"'''.format(src, dst)

# -----------------------------------------------------------------------------
# Portage/Package Manager Helpers
# -----------------------------------------------------------------------------

def has_version(atom: str) -> str:
    """Check if package is installed (shell condition)."""
    # This would integrate with the package manager
    return '[ -n "$(find "${{EPREFIX:-}}/var/db/pkg" -maxdepth 2 -name "{}*" 2>/dev/null)" ]'.format(atom)

def best_version(atom: str) -> str:
    """Get best matching installed version."""
    return 'find "${EPREFIX:-}/var/db/pkg" -maxdepth 2 -name "{}*" -printf "%f\\n" 2>/dev/null | sort -V | tail -1'.format(atom)

# -----------------------------------------------------------------------------
# Ebuild Phase Package Rule
# -----------------------------------------------------------------------------

def _ebuild_package_impl(ctx: AnalysisContext) -> list[Provider]:
    """
    Build a package using ebuild-style phases:
    - src_unpack: Extract sources
    - src_prepare: Apply patches, run autoreconf
    - src_configure: Run configure/cmake/meson setup
    - src_compile: Build the software
    - src_test: Run tests (optional)
    - src_install: Install to DESTDIR
    """
    install_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)

    # Read build threads from Buck2 config (default 0 = auto-detect with nproc)
    build_threads = read_config("buckos", "build_threads", "0")
    if not build_threads:
        build_threads = read_config("build", "threads", "0")

    # Get source directory from dependency
    src_dir = ctx.attrs.source[DefaultInfo].default_outputs[0]

    # Read host toolchain config
    use_host_toolchain = read_config("buckos", "use_host_toolchain", "false").lower() in ["true", "1", "yes"]

    # Filter dependencies: skip bootstrap toolchain when using host toolchain
    bdepend_list = ctx.attrs.bdepend
    if use_host_toolchain:
        # Filter out bootstrap toolchain from bdepend when using host toolchain
        bdepend_list = [dep for dep in ctx.attrs.bdepend if "bootstrap-toolchain" not in str(dep.label)]

    # Collect all dependency directories (depend + bdepend + rdepend) for PATH setup
    dep_dirs = []
    for dep in ctx.attrs.depend + bdepend_list + ctx.attrs.rdepend:
        outputs = dep[DefaultInfo].default_outputs
        for output in outputs:
            dep_dirs.append(output)

    # Build phases (use 'true' as no-op for empty phases to avoid syntax errors)
    src_unpack = ctx.attrs.src_unpack if ctx.attrs.src_unpack else "true"
    src_prepare = ctx.attrs.src_prepare if ctx.attrs.src_prepare else "true"
    pre_configure = ctx.attrs.pre_configure if ctx.attrs.pre_configure else "true"
    src_configure = ctx.attrs.src_configure if ctx.attrs.src_configure else "true"
    src_compile = ctx.attrs.src_compile if ctx.attrs.src_compile else "make -j$(nproc)"
    src_test = ctx.attrs.src_test if ctx.attrs.src_test else "true"
    src_install = ctx.attrs.src_install if ctx.attrs.src_install else "make install DESTDIR=\"$DESTDIR\""

    # Environment variables
    env_setup = []
    for k, v in ctx.attrs.env.items():
        env_setup.append('export {}="{}"'.format(k, v))
    env_str = "\n".join(env_setup)

    # USE flags
    use_flags = " ".join(ctx.attrs.use_flags) if ctx.attrs.use_flags else ""

    # Check if bootstrap toolchain is being used
    use_bootstrap = ctx.attrs.use_bootstrap if hasattr(ctx.attrs, "use_bootstrap") else False
    bootstrap_sysroot = ctx.attrs.bootstrap_sysroot if hasattr(ctx.attrs, "bootstrap_sysroot") else ""
    bootstrap_stage = ctx.attrs.bootstrap_stage if hasattr(ctx.attrs, "bootstrap_stage") else ""

    # Get external scripts (tracked by Buck2 for proper cache invalidation)
    pkg_config_wrapper = ctx.attrs._pkg_config_wrapper[DefaultInfo].default_outputs[0]

    # Select appropriate ebuild script based on bootstrap stage
    # When using host toolchain, always use regular ebuild.sh (bootstrap stages are for cross-compilation)
    if use_host_toolchain or not bootstrap_stage:
        ebuild_script = ctx.attrs._ebuild_script[DefaultInfo].default_outputs[0]
    elif bootstrap_stage == "stage1":
        ebuild_script = ctx.attrs._ebuild_bootstrap_stage1_script[DefaultInfo].default_outputs[0]
    elif bootstrap_stage == "stage2":
        ebuild_script = ctx.attrs._ebuild_bootstrap_stage2_script[DefaultInfo].default_outputs[0]
    elif bootstrap_stage == "stage3":
        ebuild_script = ctx.attrs._ebuild_bootstrap_stage3_script[DefaultInfo].default_outputs[0]
    else:
        # Default: use regular ebuild script
        ebuild_script = ctx.attrs._ebuild_script[DefaultInfo].default_outputs[0]

    # Generate patch application commands if patches are provided
    # We'll pass patch files via command line arguments and copy them to the build dir
    patch_file_list = []
    if ctx.attrs.patches:
        for patch in ctx.attrs.patches:
            patch_file_list.append(patch)

    # Write wrapper script that sources external framework and defines phases
    # This approach works because Buck2 tracks both the written script AND the sourced framework
    # Patches will be applied in the wrapper script before phases run
    patch_count = len(patch_file_list)
    script = ctx.actions.write(
        "ebuild_wrapper.sh",
        '''#!/bin/bash
set -e

# Ensure basic PATH is set for utilities like readlink
export PATH="${{PATH:-/usr/bin:/bin:/usr/local/bin}}"

# CRITICAL: Save all original arguments for potential re-execution in mount namespace
ORIGINAL_ARGS=("$@")

# Arguments: DESTDIR, SRC_DIR, PKG_CONFIG_WRAPPER, FRAMEWORK_SCRIPT, PATCH_COUNT, patches..., dep_dirs...
# Save these before shifting
# Convert paths to absolute to work in mount namespace
export _EBUILD_DESTDIR="$(readlink -f "$1")"
export _EBUILD_SRCDIR="$(readlink -f "$2")"
export _EBUILD_PKG_CONFIG_WRAPPER="$(readlink -f "$3")"
FRAMEWORK_SCRIPT="$(readlink -f "$4")"
PATCH_COUNT="$5"
shift 5

# Try to download binary package from mirror before building from source
# Enabled when BUCKOS_BINARY_MIRROR environment variable is set
# Mirror structure: $MIRROR/index.json and $MIRROR/<first-letter>/<package>.tar.gz
# Example: export BUCKOS_BINARY_MIRROR=file:///tmp/buckos-mirror
# Example: export BUCKOS_BINARY_MIRROR=https://mirror.buckos.org
# Set BUCKOS_PREFER_BINARIES=false to disable binary downloads
if [ -n "$BUCKOS_BINARY_MIRROR" ] && [ "${{BUCKOS_PREFER_BINARIES:-true}}" = "true" ]; then
    echo "Checking binary mirror ($BUCKOS_BINARY_MIRROR) for {name}-{version}..."

    # Simple binary download logic without complex config hash calculation
    # Query index.json and find matching package by name/version
    INDEX_URL="$BUCKOS_BINARY_MIRROR/index.json"

    if curl -f -s "$INDEX_URL" -o /tmp/mirror-index-$$.json 2>/dev/null || wget -q "$INDEX_URL" -O /tmp/mirror-index-$$.json 2>/dev/null; then
        # Find package in index using python3 or fallback to grep
        if command -v python3 &>/dev/null; then
            PACKAGE_INFO=$(python3 -c "
import json, sys
try:
    with open('/tmp/mirror-index-$$.json') as f:
        index = json.load(f)
    packages = index.get('by_name', {{}}).get('{name}', [])
    # Find matching version
    for pkg in packages:
        if pkg.get('version') == '{version}':
            print(pkg.get('filename', ''))
            print(pkg.get('config_hash', ''))
            break
except: pass
" 2>/dev/null)

            if [ -n "$PACKAGE_INFO" ]; then
                FILENAME=$(echo "$PACKAGE_INFO" | head -1)
                CONFIG_HASH=$(echo "$PACKAGE_INFO" | tail -1)

                if [ -n "$FILENAME" ]; then
                    FIRST_LETTER=$(echo "{name}" | cut -c1 | tr '[:upper:]' '[:lower:]')
                    PACKAGE_URL="$BUCKOS_BINARY_MIRROR/$FIRST_LETTER/$FILENAME"
                    HASH_URL="$PACKAGE_URL.sha256"

                    echo "Downloading binary: $FILENAME..."

                    # Download package and hash
                    if (curl -f -s "$PACKAGE_URL" -o /tmp/pkg-$$.tar.gz && curl -f -s "$HASH_URL" -o /tmp/pkg-$$.tar.gz.sha256) || \
                       (wget -q "$PACKAGE_URL" -O /tmp/pkg-$$.tar.gz && wget -q "$HASH_URL" -O /tmp/pkg-$$.tar.gz.sha256); then

                        # Verify SHA256
                        EXPECTED_HASH=$(head -1 /tmp/pkg-$$.tar.gz.sha256 | awk '{{print $1}}')
                        if command -v sha256sum &>/dev/null; then
                            ACTUAL_HASH=$(sha256sum /tmp/pkg-$$.tar.gz | awk '{{print $1}}')
                        elif command -v shasum &>/dev/null; then
                            ACTUAL_HASH=$(shasum -a 256 /tmp/pkg-$$.tar.gz | awk '{{print $1}}')
                        fi

                        if [ "$EXPECTED_HASH" = "$ACTUAL_HASH" ]; then
                            echo "Binary verified, extracting to $_EBUILD_DESTDIR..."
                            mkdir -p "$_EBUILD_DESTDIR"
                            tar -xzf /tmp/pkg-$$.tar.gz -C "$_EBUILD_DESTDIR" --strip-components=0
                            rm -f /tmp/pkg-$$.tar.gz /tmp/pkg-$$.tar.gz.sha256 /tmp/mirror-index-$$.json
                            echo "Binary package installed successfully from mirror"
                            exit 0
                        else
                            echo "Warning: SHA256 mismatch, falling back to source build"
                        fi
                    fi
                fi
            fi
        fi
        rm -f /tmp/mirror-index-$$.json /tmp/pkg-$$.tar.gz /tmp/pkg-$$.tar.gz.sha256 2>/dev/null || true
    fi
fi

# No binary available or download failed - continue with source build
echo "Building {name}-{version} from source..."

# Extract patch files from command line arguments
# Patches will be applied before building, so we can use relative paths
PATCH_FILES=()
for ((i=0; i<$PATCH_COUNT; i++)); do
    PATCH_FILES+=("$1")
    shift
done

# Remaining args ($@) are: dep_dirs...
export _EBUILD_DEP_DIRS="$@"

# Set up LD_LIBRARY_PATH early so bootstrap bash can find its libraries
# This must happen before any bash subprocesses are spawned
_TOOLCHAIN_LIBPATH=""
for dep_dir in "$@"; do
    if [ -d "$dep_dir/tools/lib" ]; then
        _TOOLCHAIN_LIBPATH="${{_TOOLCHAIN_LIBPATH:+$_TOOLCHAIN_LIBPATH:}}$dep_dir/tools/lib"
    fi
done
if [ -n "$_TOOLCHAIN_LIBPATH" ]; then
    export LD_LIBRARY_PATH="${{_TOOLCHAIN_LIBPATH}}${{LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}}"
fi

# Export package variables
export PN="{name}"
export PV="{version}"
export PACKAGE_NAME="{name}"
export CATEGORY="{category}"
export SLOT="{slot}"
export USE="{use_flags}"
export USE_BOOTSTRAP="{use_bootstrap}"
export USE_HOST_TOOLCHAIN="{use_host}"
export BOOTSTRAP_SYSROOT="{bootstrap_sysroot}"
export BUILD_THREADS="{build_threads}"

# Set MAKE_JOBS based on BUILD_THREADS
# 0 = auto-detect with nproc, otherwise use specified value
if [ "$BUILD_THREADS" = "0" ]; then
    if command -v nproc >/dev/null 2>&1; then
        export MAKE_JOBS="$(nproc)"
    else
        # nproc not available (early bootstrap), use unlimited parallelism
        export MAKE_JOBS=""
    fi
else
    export MAKE_JOBS="$BUILD_THREADS"
fi

# CRITICAL: Copy source to isolated build directory
# Buck2's download_source produces a single shared artifact - multiple packages using
# the same source would modify the same directory, causing patch conflicts.
# We MUST copy to a package-specific directory to ensure isolation.
if [ -d "$_EBUILD_SRCDIR" ]; then
    echo "Copying source to isolated build directory..."
    BUILD_SRCDIR="$_EBUILD_DESTDIR/../source"
    rm -rf "$BUILD_SRCDIR"
    mkdir -p "$(dirname "$BUILD_SRCDIR")"
    cp -a "$_EBUILD_SRCDIR" "$BUILD_SRCDIR"
    # Update _EBUILD_SRCDIR to point to the isolated copy
    export _EBUILD_SRCDIR="$BUILD_SRCDIR"
    echo "Source copied to: $BUILD_SRCDIR"
fi

# Apply patches BEFORE running phases (in original working directory)
# This way we can use relative patch paths without conversion
if [ ${{#PATCH_FILES[@]}} -gt 0 ]; then
    echo "📦 Applying patches to source..."
    cd "$_EBUILD_SRCDIR"
    for patch_file in "${{PATCH_FILES[@]}}"; do
        if [ -n "$patch_file" ]; then
            echo -e "\\033[32m * \\033[0mApplying $(basename "$patch_file")..."
            # Use absolute path from original directory for patch file
            if [[ "$patch_file" != /* ]]; then
                patch_file="$OLDPWD/$patch_file"
            fi
            patch -p1 < "$patch_file" || {{ echo "✗ Patch failed: $patch_file"; exit 1; }}
        fi
    done
    cd "$OLDPWD"
    echo "✓ Patches applied successfully"
fi

# Define the phases script content using heredoc (avoids single-quote escaping issues)
# Note: read -d '' returns non-zero on EOF, so we use || true to prevent set -e from exiting
read -r -d '' PHASES_CONTENT << 'PHASES_EOF' || true
#!/bin/bash
set -e
set -o pipefail

# USE flag helper
use() {{
    [[ " $USE " == *" $1 "* ]]
}}

# Error handler
handle_phase_error() {{
    local phase=$1
    local exit_code=$2
    echo "✗ Build phase $phase FAILED (exit code: $exit_code)" >&2
    echo "  Package: $PN-$PV" >&2
    exit $exit_code
}}

# Custom environment
{env}

cd "$S"

# Phase: src_unpack
{src_unpack}

# Phase: src_prepare
echo "📦 Phase: src_prepare"
if command -v tee >/dev/null 2>&1; then
    ( {src_prepare} ) 2>&1 | tee "$T/src_prepare.log" || handle_phase_error "src_prepare" ${{PIPESTATUS[0]}}
else
    ( {src_prepare} ) > "$T/src_prepare.log" 2>&1 || handle_phase_error "src_prepare" $?
fi

# Phase: pre_configure
echo "📦 Phase: pre_configure"
if command -v tee >/dev/null 2>&1; then
    ( {pre_configure} ) 2>&1 | tee "$T/pre_configure.log" || handle_phase_error "pre_configure" ${{PIPESTATUS[0]}}
else
    ( {pre_configure} ) > "$T/pre_configure.log" 2>&1 || handle_phase_error "pre_configure" $?
fi

# Phase: src_configure
echo "📦 Phase: src_configure"
if command -v tee >/dev/null 2>&1; then
    ( {src_configure} ) 2>&1 | tee "$T/src_configure.log" || handle_phase_error "src_configure" ${{PIPESTATUS[0]}}
else
    ( {src_configure} ) > "$T/src_configure.log" 2>&1 || handle_phase_error "src_configure" $?
fi

# Phase: src_compile
echo "📦 Phase: src_compile"
if command -v tee >/dev/null 2>&1; then
    ( {src_compile} ) 2>&1 | tee "$T/src_compile.log" || handle_phase_error "src_compile" ${{PIPESTATUS[0]}}
else
    ( {src_compile} ) > "$T/src_compile.log" 2>&1 || handle_phase_error "src_compile" $?
fi

# Phase: src_test
if [ -n "{run_tests}" ]; then
    echo "📦 Phase: src_test"
    if command -v tee >/dev/null 2>&1; then
        ( {src_test} ) 2>&1 | tee "$T/src_test.log" || handle_phase_error "src_test" ${{PIPESTATUS[0]}}
    else
        ( {src_test} ) > "$T/src_test.log" 2>&1 || handle_phase_error "src_test" $?
    fi
fi

# Phase: src_install
echo "📦 Phase: src_install"
if command -v tee >/dev/null 2>&1; then
    ( {src_install} ) 2>&1 | tee "$T/src_install.log" || handle_phase_error "src_install" ${{PIPESTATUS[0]}}
else
    ( {src_install} ) > "$T/src_install.log" 2>&1 || handle_phase_error "src_install" $?
fi
PHASES_EOF
export PHASES_CONTENT

# For bootstrap stage2, we need to set up a mount namespace to bind-mount
# the cross-gcc toolchain to /tools so the compiler can find its sysroot
if [ "{bootstrap_stage}" = "stage2" ] && [ -z "$BOOTSTRAP_NAMESPACE_ACTIVE" ]; then
    echo "=== Setting up mount namespace for stage2 bootstrap ==="

    # Find cross-gcc-pass2 and cross-binutils directories
    CROSS_GCC_DIR=""
    CROSS_BINUTILS_DIR=""
    for dep_dir in $_EBUILD_DEP_DIRS; do
        if [ -d "$dep_dir/tools/bin" ] && [ -f "$dep_dir/tools/bin/x86_64-buckos-linux-gnu-gcc" ]; then
            CROSS_GCC_DIR="$dep_dir/tools"
            echo "Found cross-gcc toolchain: $CROSS_GCC_DIR"
        fi
        if [ -d "$dep_dir/tools/bin" ] && [ -f "$dep_dir/tools/bin/x86_64-buckos-linux-gnu-ld" ]; then
            CROSS_BINUTILS_DIR="$dep_dir/tools"
            echo "Found cross-binutils toolchain: $CROSS_BINUTILS_DIR"
        fi
    done

    if [ -n "$CROSS_GCC_DIR" ] && [ -n "$CROSS_BINUTILS_DIR" ]; then
        # Export the cross-compiler paths for stage2 to use directly
        echo "Found cross-toolchain directories:"
        echo "  GCC: $CROSS_GCC_DIR"
        echo "  Binutils: $CROSS_BINUTILS_DIR"

        export BOOTSTRAP_CROSS_GCC_DIR="$CROSS_GCC_DIR"
        export BOOTSTRAP_CROSS_BINUTILS_DIR="$CROSS_BINUTILS_DIR"

        # Add both cross-compiler bin directories to PATH
        # GCC's bin needs to come first since it has the main compiler
        export PATH="$CROSS_GCC_DIR/bin:$CROSS_BINUTILS_DIR/bin:$PATH"

        # Unset LD_LIBRARY_PATH to avoid GLIBC version conflicts
        unset LD_LIBRARY_PATH

        echo "Updated PATH with cross-compiler directories"
    else
        echo "WARNING: Could not find cross-gcc toolchain"
    fi
fi

# Source the external framework (provides PATH setup, dependency handling, etc.)
source "$FRAMEWORK_SCRIPT"
'''.format(
            name = ctx.attrs.name,
            version = ctx.attrs.version,
            category = ctx.attrs.category,
            slot = ctx.attrs.slot,
            use_flags = use_flags,
            use_bootstrap = "true" if use_bootstrap else "false",
            use_host = "true" if use_host_toolchain else "false",
            bootstrap_sysroot = bootstrap_sysroot,
            bootstrap_stage = bootstrap_stage,
            build_threads = build_threads,
            env = env_str,
            src_unpack = src_unpack,
            src_prepare = src_prepare,
            pre_configure = pre_configure,
            src_configure = src_configure,
            src_compile = src_compile,
            src_test = src_test,
            src_install = src_install,
            run_tests = "yes" if ctx.attrs.run_tests else "",
        ),
        is_executable = True,
    )

    # Build command - wrapper sources the external framework
    cmd = cmd_args([
        "bash",
        script,
        install_dir.as_output(),
        src_dir,
        pkg_config_wrapper,
        ebuild_script,  # Framework script to be sourced
        str(patch_count),  # Number of patch files
    ])
    # Add patch files as arguments
    for patch_file in patch_file_list:
        cmd.add(patch_file)
    # Add all dependency directories as arguments
    for dep_dir in dep_dirs:
        cmd.add(dep_dir)

    # Determine if this action should be local-only:
    # - Bootstrap packages (use_bootstrap=true) use the host compiler and tools,
    #   so they must run locally to ensure host compatibility
    # - Packages can explicitly override with local_only attribute
    local_only_attr = ctx.attrs.local_only if hasattr(ctx.attrs, "local_only") else None
    if local_only_attr != None:
        is_local_only = local_only_attr
    else:
        # Default: local_only=True for bootstrap packages
        is_local_only = use_bootstrap

    ctx.actions.run(
        cmd,
        category = "ebuild",
        identifier = ctx.attrs.name,
        local_only = is_local_only,
    )

    return [
        DefaultInfo(default_output = install_dir),
        PackageInfo(
            name = ctx.attrs.name,
            version = ctx.attrs.version,
            description = ctx.attrs.description,
            homepage = ctx.attrs.homepage,
            license = ctx.attrs.license,
            src_uri = "",
            checksum = "",
            dependencies = ctx.attrs.rdepend,
            build_dependencies = ctx.attrs.bdepend,
            maintainers = ctx.attrs.maintainers,
        ),
    ]


ebuild_package = rule(
    impl = _ebuild_package_impl,
    attrs = {
        "source": attrs.dep(),
        "version": attrs.string(),
        "category": attrs.string(default = ""),
        "slot": attrs.string(default = "0"),
        "description": attrs.string(default = ""),
        "homepage": attrs.string(default = ""),
        "license": attrs.string(default = ""),
        "use_flags": attrs.list(attrs.string(), default = []),
        "src_unpack": attrs.string(default = ""),
        "src_prepare": attrs.string(default = ""),
        "pre_configure": attrs.string(default = ""),
        "src_configure": attrs.string(default = ""),
        "src_compile": attrs.string(default = ""),
        "src_test": attrs.string(default = ""),
        "src_install": attrs.string(default = ""),
        "run_tests": attrs.bool(default = False),
        "env": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "depend": attrs.list(attrs.dep(), default = []),
        "rdepend": attrs.list(attrs.dep(), default = []),
        "bdepend": attrs.list(attrs.dep(), default = []),
        "pdepend": attrs.list(attrs.dep(), default = []),
        "maintainers": attrs.list(attrs.string(), default = []),
        "patches": attrs.list(attrs.source(), default = []),
        # Bootstrap toolchain support
        "use_bootstrap": attrs.bool(default = False),
        "bootstrap_sysroot": attrs.string(default = ""),
        # Bootstrap stage selection (stage1, stage2, stage3, or empty for regular builds)
        # stage1: Uses host compiler to build cross-toolchain (partial isolation)
        # stage2: Uses cross-compiler to build core utilities (strong isolation)
        # stage3: Uses bootstrap toolchain to rebuild itself (complete isolation, verification)
        "bootstrap_stage": attrs.string(default = ""),
        # Remote execution control - set to True for packages that must run locally
        # (e.g., bootstrap packages that depend on host-specific tools)
        "local_only": attrs.bool(default = False),
        # External scripts for proper cache invalidation
        "_pkg_config_wrapper": attrs.dep(default = "//defs/scripts:pkg-config-wrapper"),
        "_ebuild_script": attrs.dep(default = "//defs/scripts:ebuild"),
        "_ebuild_bootstrap_stage1_script": attrs.dep(default = "//defs/scripts:ebuild-bootstrap-stage1"),
        "_ebuild_bootstrap_stage2_script": attrs.dep(default = "//defs/scripts:ebuild-bootstrap-stage2"),
        "_ebuild_bootstrap_stage3_script": attrs.dep(default = "//defs/scripts:ebuild-bootstrap-stage3"),
    },
)

# -----------------------------------------------------------------------------
# Convenience Macros
# -----------------------------------------------------------------------------

def simple_package(
        name: str,
        version: str,
        src_uri: str,
        sha256: str,
        configure_args: list[str] = [],
        make_args: list[str] = [],
        deps: list[str] = [],
        maintainers: list[str] = [],
        patches: list[str] = [],
        signature_sha256: str | None = None,
        gpg_key: str | None = None,
        gpg_keyring: str | None = None,
        exclude_patterns: list[str] = [],
        **kwargs):
    """
    Convenience macro for standard autotools packages without USE flags.
    This is a simplified wrapper around autotools_package() for basic packages.

    Args:
        signature_sha256: SHA256 of GPG signature file (use update_checksums.py to populate)
        gpg_key: Optional GPG key ID or fingerprint to import and verify against
        gpg_keyring: Optional path to GPG keyring file with trusted keys
        exclude_patterns: List of patterns to exclude from source extraction (passed to tar --exclude)
    """
    # Forward to autotools_package() which supports both USE flags and simple builds
    autotools_package(
        name = name,
        version = version,
        src_uri = src_uri,
        sha256 = sha256,
        configure_args = configure_args,
        make_args = make_args,
        deps = deps,
        maintainers = maintainers,
        patches = patches,
        signature_sha256 = signature_sha256,
        gpg_key = gpg_key,
        gpg_keyring = gpg_keyring,
        exclude_patterns = exclude_patterns,
        **kwargs
    )

def cmake_package(
        name: str,
        version: str,
        src_uri: str | None = None,
        sha256: str | None = None,
        source: str | None = None,
        cmake_args: list[str] = [],
        pre_configure: str = "",
        deps: list[str] = [],
        maintainers: list[str] = [],
        patches: list[str] = [],
        # USE flag support
        iuse: list[str] = [],
        use_defaults: list[str] = [],
        use_options: dict = {},
        use_deps: dict = {},
        global_use: dict | None = None,
        package_overrides: dict | None = None,
        # Distribution compatibility
        compat_tags: list[str] | None = None,
        signature_sha256: str | None = None,
        signature_required: bool = False,
        gpg_key: str | None = None,
        gpg_keyring: str | None = None,
        exclude_patterns: list[str] = [],
        **kwargs):
    """
    Convenience macro for CMake packages with USE flag support.
    Uses the cmake eclass for standardized build phases.

    Args:
        name: Package name
        version: Package version
        src_uri: Source download URL
        sha256: Source checksum
        cmake_args: Base CMake arguments
        pre_configure: Pre-configure script
        deps: Base dependencies (always applied)
        maintainers: Package maintainers
        iuse: List of USE flags this package supports
        use_defaults: Default enabled USE flags
        use_options: Dict mapping USE flag to CMake option(s)
                     Example: {"ssl": "ENABLE_SSL", "tests": "BUILD_TESTING"}
        use_deps: Dict mapping USE flag to conditional dependencies
        global_use: Global USE flag configuration
        package_overrides: Package-specific USE overrides
        signature_sha256: SHA256 of GPG signature file (use update_checksums.py to populate)
        gpg_key: Optional GPG key ID or fingerprint to import and verify against
        gpg_keyring: Optional path to GPG keyring file with trusted keys
        exclude_patterns: List of patterns to exclude from source extraction (passed to tar --exclude)

    Example:
        cmake_package(
            name = "libfoo",
            version = "1.2.3",
            src_uri = "https://example.com/libfoo-1.2.3.tar.gz",
            sha256 = "...",
            iuse = ["ssl", "tests", "doc"],
            use_defaults = ["ssl"],
            use_options = {
                "ssl": "ENABLE_SSL",
                "tests": "BUILD_TESTING",
                "doc": "BUILD_DOCUMENTATION",
            },
            use_deps = {
                "ssl": ["//packages/linux/dev-libs/openssl"],
            },
        )
    """
    # Apply platform-specific constraints (Linux packages only build on Linux, etc.)
    kwargs = _apply_platform_constraints(kwargs)

    # Handle source - either use provided source or create one from src_uri
    if source:
        src_target = source
    else:
        if not src_uri or not sha256:
            fail("Either 'source' or both 'src_uri' and 'sha256' must be provided")
        src_name = name + "-src"
        download_source(
            name = src_name,
            src_uri = src_uri,
            sha256 = sha256,
            signature_sha256 = signature_sha256,
            signature_required = signature_required,
            gpg_key = gpg_key,
            gpg_keyring = gpg_keyring,
            exclude_patterns = exclude_patterns,
        )
        src_target = ":" + src_name

    # Calculate effective USE flags if USE flags are specified
    effective_use = []
    resolved_deps = list(deps)
    resolved_cmake_args = list(cmake_args)

    if iuse:
        effective_use = get_effective_use(
            name,
            iuse,
            use_defaults,
            global_use,
            package_overrides,
        )

        # Resolve conditional dependencies
        resolved_deps.extend(use_dep(use_deps, effective_use))

        # Generate CMake options based on USE flags
        if use_options:
            cmake_opts = use_cmake_options(use_options, effective_use)
            resolved_cmake_args.extend(cmake_opts)

    # Use eclass inheritance for cmake
    eclass_config = inherit(["cmake"])

    # Handle cmake_args by setting environment variable
    env = kwargs.pop("env", {})
    if resolved_cmake_args:
        env["CMAKE_EXTRA_ARGS"] = " ".join(resolved_cmake_args)

    # Merge eclass bdepend with any existing bdepend
    bdepend = list(kwargs.pop("bdepend", []))
    for dep in eclass_config["bdepend"]:
        if dep not in bdepend:
            bdepend.append(dep)

    # Add bootstrap toolchain by default to ensure linking against BuckOS glibc
    # Use get_toolchain_dep() which returns select() based on platform constraints
    use_bootstrap = kwargs.pop("use_bootstrap", True)
    if use_bootstrap:
        bdepend.append(get_toolchain_dep())

    # Allow overriding eclass phases via kwargs
    custom_src_prepare = kwargs.pop("src_prepare", None)
    custom_src_configure = kwargs.pop("src_configure", None)
    custom_src_compile = kwargs.pop("src_compile", None)
    custom_src_install = kwargs.pop("src_install", None)

    # Combine with eclass phases
    src_prepare = custom_src_prepare if custom_src_prepare else eclass_config.get("src_prepare", "")

    # Export patch files and create references
    patch_refs = []
    for i, patch in enumerate(patches):
        if patch.startswith(":") or patch.startswith("//"):
            # Already a target reference
            patch_refs.append(patch)
        else:
            # Create an export_file target for this patch
            patch_target_name = "{}-patch-{}".format(name, i)
            native.export_file(
                name = patch_target_name,
                src = patch,
                visibility = [],  # Private to this package
            )
            patch_refs.append(":" + patch_target_name)

    ebuild_package(
        name = name,
        source = src_target,
        version = version,
        pre_configure = pre_configure,
        src_prepare = src_prepare,
        patches = patch_refs,  # Buck2 target references
        src_configure = custom_src_configure if custom_src_configure else eclass_config["src_configure"],
        src_compile = custom_src_compile if custom_src_compile else eclass_config["src_compile"],
        src_install = custom_src_install if custom_src_install else eclass_config["src_install"],
        rdepend = resolved_deps,
        bdepend = bdepend,
        env = env,
        maintainers = maintainers,
        use_flags = effective_use,
        use_bootstrap = use_bootstrap,
        **kwargs
    )

def meson_package(
        name: str,
        version: str,
        src_uri: str | None = None,
        sha256: str | None = None,
        source: str | None = None,
        meson_args: list[str] = [],
        deps: list[str] = [],
        maintainers: list[str] = [],
        patches: list[str] = [],
        # USE flag support
        iuse: list[str] = [],
        use_defaults: list[str] = [],
        use_options: dict = {},
        use_deps: dict = {},
        global_use: dict | None = None,
        package_overrides: dict | None = None,
        # Distribution compatibility
        compat_tags: list[str] | None = None,
        signature_sha256: str | None = None,
        signature_required: bool = False,
        gpg_key: str | None = None,
        gpg_keyring: str | None = None,
        exclude_patterns: list[str] = [],
        **kwargs):
    """
    Convenience macro for Meson packages with USE flag support.
    Uses the meson eclass for standardized build phases.

    Args:
        name: Package name
        version: Package version
        src_uri: Source download URL
        sha256: Source checksum
        meson_args: Base Meson arguments
        deps: Base dependencies (always applied)
        maintainers: Package maintainers
        iuse: List of USE flags this package supports
        use_defaults: Default enabled USE flags
        use_options: Dict mapping USE flag to Meson option(s)
                     Example: {"ssl": "ssl", "tests": "tests"}
        use_deps: Dict mapping USE flag to conditional dependencies
        global_use: Global USE flag configuration
        package_overrides: Package-specific USE overrides
        signature_sha256: SHA256 of GPG signature file (use update_checksums.py to populate)
        gpg_key: Optional GPG key ID or fingerprint to import and verify against
        gpg_keyring: Optional path to GPG keyring file with trusted keys
        exclude_patterns: List of patterns to exclude from source extraction (passed to tar --exclude)

    Example:
        meson_package(
            name = "libbar",
            version = "2.3.4",
            src_uri = "https://example.com/libbar-2.3.4.tar.xz",
            sha256 = "...",
            iuse = ["ssl", "tests", "doc"],
            use_defaults = ["ssl"],
            use_options = {
                "ssl": "ssl",
                "tests": "tests",
                "doc": "docs",
            },
            use_deps = {
                "ssl": ["//packages/linux/dev-libs/openssl"],
            },
        )
    """
    # Apply platform-specific constraints (Linux packages only build on Linux, etc.)
    kwargs = _apply_platform_constraints(kwargs)

    # Handle source - either use provided source or create one from src_uri
    if source:
        src_target = source
    else:
        if not src_uri or not sha256:
            fail("Either 'source' or both 'src_uri' and 'sha256' must be provided")
        src_name = name + "-src"
        download_source(
            name = src_name,
            src_uri = src_uri,
            sha256 = sha256,
            signature_sha256 = signature_sha256,
            signature_required = signature_required,
            gpg_key = gpg_key,
            gpg_keyring = gpg_keyring,
            exclude_patterns = exclude_patterns,
        )
        src_target = ":" + src_name

    # Calculate effective USE flags if USE flags are specified
    effective_use = []
    resolved_deps = list(deps)
    resolved_meson_args = list(meson_args)

    if iuse:
        effective_use = get_effective_use(
            name,
            iuse,
            use_defaults,
            global_use,
            package_overrides,
        )

        # Resolve conditional dependencies
        resolved_deps.extend(use_dep(use_deps, effective_use))

        # Generate Meson options based on USE flags
        if use_options:
            meson_opts = use_meson_options(use_options, effective_use)
            resolved_meson_args.extend(meson_opts)

    # Use eclass inheritance for meson
    eclass_config = inherit(["meson"])

    # Handle meson_args by setting environment variable
    env = kwargs.pop("env", {})
    if resolved_meson_args:
        env["MESON_EXTRA_ARGS"] = " ".join(resolved_meson_args)

    # Merge eclass bdepend with any existing bdepend
    bdepend = list(kwargs.pop("bdepend", []))
    for dep in eclass_config["bdepend"]:
        if dep not in bdepend:
            bdepend.append(dep)

    # Add bootstrap toolchain by default to ensure linking against BuckOS glibc
    # Use get_toolchain_dep() which returns select() based on platform constraints
    use_bootstrap = kwargs.pop("use_bootstrap", True)
    if use_bootstrap:
        bdepend.append(get_toolchain_dep())

    # Allow overriding eclass phases via kwargs
    custom_src_prepare = kwargs.pop("src_prepare", None)
    custom_src_configure = kwargs.pop("src_configure", None)
    custom_src_compile = kwargs.pop("src_compile", None)
    custom_src_install = kwargs.pop("src_install", None)

    # Combine with eclass phases
    src_prepare = custom_src_prepare if custom_src_prepare else eclass_config.get("src_prepare", "")


    ebuild_package(
        name = name,
        source = src_target,
        version = version,
        src_prepare = src_prepare,
        src_configure = custom_src_configure if custom_src_configure else eclass_config["src_configure"],
        src_compile = custom_src_compile if custom_src_compile else eclass_config["src_compile"],
        src_install = custom_src_install if custom_src_install else eclass_config["src_install"],
        rdepend = resolved_deps,
        bdepend = bdepend,
        env = env,
        maintainers = maintainers,
        use_flags = effective_use,
        use_bootstrap = use_bootstrap,
        **kwargs
    )

def autotools_package(
        name: str,
        version: str,
        src_uri: str | None = None,
        sha256: str | None = None,
        source: str | None = None,
        configure_args: list[str] = [],
        make_args: list[str] = [],
        deps: list[str] = [],
        maintainers: list[str] = [],
        patches: list[str] = [],
        # USE flag support
        iuse: list[str] = [],
        use_defaults: list[str] = [],
        use_configure: dict = {},
        use_deps: dict = {},
        global_use: dict | None = None,
        package_overrides: dict | None = None,
        # Distribution compatibility
        compat_tags: list[str] | None = None,
        signature_sha256: str | None = None,
        signature_required: bool = False,
        gpg_key: str | None = None,
        gpg_keyring: str | None = None,
        exclude_patterns: list[str] = [],
        **kwargs):
    """
    Convenience macro for autotools packages with USE flag support.
    Uses the autotools eclass for standardized build phases.

    This replaces both configure_make_package() and use_package() with a
    unified interface consistent with all other language package types.

    Args:
        name: Package name
        version: Package version
        src_uri: Source download URL (required if source not provided)
        sha256: Source checksum (required if source not provided)
        source: Pre-defined source target (alternative to src_uri/sha256)
        configure_args: Base configure arguments
        make_args: Make arguments
        deps: Base dependencies (always applied)
        maintainers: Package maintainers
        iuse: List of USE flags this package supports
        use_defaults: Default enabled USE flags
        use_configure: Dict mapping USE flag to configure argument(s)
                       Example: {"ssl": "--with-ssl", "-ssl": "--without-ssl"}
        use_deps: Dict mapping USE flag to conditional dependencies
        global_use: Global USE flag configuration
        package_overrides: Package-specific USE overrides
        compat_tags: Distribution compatibility tags (e.g., ["buckos-native", "fedora"])
                    Defaults to ["buckos-native"] if not specified
        signature_sha256: SHA256 of GPG signature file (use update_checksums.py to populate)
        gpg_key: Optional GPG key ID or fingerprint to import and verify against
        gpg_keyring: Optional path to GPG keyring file with trusted keys
        exclude_patterns: List of patterns to exclude from source extraction (passed to tar --exclude)

    Example:
        autotools_package(
            name = "curl",
            version = "8.5.0",
            src_uri = "https://curl.se/download/curl-8.5.0.tar.xz",
            sha256 = "...",
            iuse = ["ssl", "http2", "ipv6"],
            use_defaults = ["ssl", "ipv6"],
            use_configure = {
                "ssl": "--with-ssl",
                "-ssl": "--without-ssl",
                "http2": "--with-nghttp2",
                "ipv6": "--enable-ipv6",
                "-ipv6": "--disable-ipv6",
            },
            use_deps = {
                "ssl": ["//packages/linux/dev-libs/openssl"],
                "http2": ["//packages/linux/net-libs/nghttp2"],
            },
        )
    """
    # Apply platform-specific constraints (Linux packages only build on Linux, etc.)
    kwargs = _apply_platform_constraints(kwargs)

    # Handle distribution compatibility tags
    if compat_tags == None:
        compat_tags = [DISTRO_BUCKOS]  # Default to BuckOS-native only

    # Validate compat tags
    warnings = validate_compat_tags(compat_tags)
    for warning in warnings:
        print("Warning in {}: {}".format(name, warning))

    # Store compat tags in metadata for later use
    # Buck2 metadata keys must contain exactly one dot (e.g., "custom.key")
    if "metadata" not in kwargs:
        kwargs["metadata"] = {}
    kwargs["metadata"]["custom.compat_tags"] = compat_tags

    # Handle source - either use provided source or create one from src_uri
    if source:
        src_target = source
    else:
        if not src_uri or not sha256:
            fail("Either 'source' or both 'src_uri' and 'sha256' must be provided")
        src_name = name + "-src"
        download_source(
            name = src_name,
            src_uri = src_uri,
            sha256 = sha256,
            signature_sha256 = signature_sha256,
            signature_required = signature_required,
            gpg_key = gpg_key,
            gpg_keyring = gpg_keyring,
            exclude_patterns = exclude_patterns,
        )
        src_target = ":" + src_name

    # Calculate effective USE flags if USE flags are specified
    effective_use = []
    resolved_deps = list(deps)
    resolved_configure_args = list(configure_args)

    if iuse:
        effective_use = get_effective_use(
            name,
            iuse,
            use_defaults,
            global_use,
            package_overrides,
        )

        # Resolve conditional dependencies
        resolved_deps.extend(use_dep(use_deps, effective_use))

        # Generate configure arguments based on USE flags
        if use_configure:
            config_args = use_configure_args(use_configure, effective_use)
            resolved_configure_args.extend(config_args)

    # Use eclass inheritance for autotools
    eclass_config = inherit(["autotools"])

    # Handle configure and make args by setting environment variables
    env = kwargs.pop("env", {})
    if resolved_configure_args:
        env["EXTRA_ECONF"] = " ".join(resolved_configure_args)
    if make_args:
        env["EXTRA_EMAKE"] = " ".join(make_args)

    # Merge eclass bdepend with any existing bdepend
    bdepend = list(kwargs.pop("bdepend", []))
    for dep in eclass_config["bdepend"]:
        if dep not in bdepend:
            bdepend.append(dep)

    # Add bootstrap toolchain by default to ensure linking against BuckOS glibc
    # Skip if this package is part of the bootstrap toolchain itself
    use_bootstrap = kwargs.pop("use_bootstrap", True)
    if use_bootstrap and BOOTSTRAP_TOOLCHAIN not in bdepend:
        bdepend.append(BOOTSTRAP_TOOLCHAIN)

    # Get pre_configure and post_install if provided
    pre_configure = kwargs.pop("pre_configure", "")
    post_install = kwargs.pop("post_install", "")

    # Allow overriding eclass phases for non-autotools packages
    custom_src_prepare = kwargs.pop("src_prepare", None)
    custom_src_configure = kwargs.pop("src_configure", None)
    custom_src_compile = kwargs.pop("src_compile", None)
    custom_src_install = kwargs.pop("src_install", None)

    # Combine with eclass phases
    src_prepare = custom_src_prepare if custom_src_prepare else eclass_config.get("src_prepare", "")


    if pre_configure:
        src_prepare += "\n" + pre_configure

    # Use custom phases if provided, otherwise use eclass defaults
    src_configure = custom_src_configure if custom_src_configure else eclass_config["src_configure"]
    src_compile = custom_src_compile if custom_src_compile else eclass_config["src_compile"]

    # For src_install, always append post_install if provided (whether using custom or eclass)
    src_install = custom_src_install if custom_src_install else eclass_config["src_install"]
    if post_install:
        src_install += "\n" + post_install

    # Export patch files and create references
    patch_refs = []
    for i, patch in enumerate(patches):
        if patch.startswith(":") or patch.startswith("//"):
            # Already a target reference
            patch_refs.append(patch)
        else:
            # Create an export_file target for this patch
            patch_target_name = "{}-patch-{}".format(name, i)
            native.export_file(
                name = patch_target_name,
                src = patch,
                visibility = [],  # Private to this package
            )
            patch_refs.append(":" + patch_target_name)

    ebuild_package(
        name = name,
        source = src_target,
        version = version,
        patches = patch_refs,  # Buck2 target references
        src_prepare = src_prepare,
        src_configure = src_configure,
        src_compile = src_compile,
        src_install = src_install,
        rdepend = resolved_deps,
        bdepend = bdepend,
        env = env,
        maintainers = maintainers,
        use_flags = effective_use,
        use_bootstrap = use_bootstrap,
        **kwargs
    )

def cargo_package(
        name: str,
        version: str,
        src_uri: str,
        sha256: str,
        bins: list[str] = [],
        cargo_args: list[str] = [],
        deps: list[str] = [],
        maintainers: list[str] = [],
        patches: list[str] = [],
        # USE flag support
        iuse: list[str] = [],
        use_defaults: list[str] = [],
        use_features: dict = {},
        use_deps: dict = {},
        global_use: dict | None = None,
        package_overrides: dict | None = None,
        signature_sha256: str | None = None,
        gpg_key: str | None = None,
        gpg_keyring: str | None = None,
        signature_required: bool = False,
        exclude_patterns: list[str] = [],
        **kwargs):
    """
    Convenience macro for Rust/Cargo packages with USE flag support.
    Uses the cargo eclass for standardized build phases.

    Args:
        name: Package name
        version: Package version
        src_uri: Source download URL
        sha256: Source checksum
        bins: Binary names to install
        cargo_args: Base Cargo arguments
        deps: Base dependencies (always applied)
        maintainers: Package maintainers
        iuse: List of USE flags this package supports
        use_defaults: Default enabled USE flags
        use_features: Dict mapping USE flag to Cargo feature(s)
                      Example: {"ssl": "tls", "compression": ["zstd", "brotli"]}
        use_deps: Dict mapping USE flag to conditional dependencies
        global_use: Global USE flag configuration
        package_overrides: Package-specific USE overrides
        signature_sha256: SHA256 of GPG signature file (use update_checksums.py to populate)
        gpg_key: Optional GPG key ID or fingerprint to import and verify against
        gpg_keyring: Optional path to GPG keyring file with trusted keys
        exclude_patterns: List of patterns to exclude from source extraction (passed to tar --exclude)

    Example:
        cargo_package(
            name = "ripgrep",
            version = "14.0.0",
            src_uri = "https://github.com/BurntSushi/ripgrep/archive/14.0.0.tar.gz",
            sha256 = "...",
            iuse = ["pcre2", "simd"],
            use_defaults = ["simd"],
            use_features = {
                "pcre2": "pcre2",
                "simd": "simd-accel",
            },
            use_deps = {
                "pcre2": ["//packages/linux/dev-libs/pcre2"],
            },
        )
    """
    # Apply platform-specific constraints (Linux packages only build on Linux, etc.)
    kwargs = _apply_platform_constraints(kwargs)

    src_name = name + "-src"

    download_source(
        name = src_name,
        src_uri = src_uri,
        sha256 = sha256,
        signature_sha256 = signature_sha256,
        signature_required = signature_required,
        gpg_key = gpg_key,
        gpg_keyring = gpg_keyring,
        exclude_patterns = exclude_patterns,
    )

    # Calculate effective USE flags if USE flags are specified
    effective_use = []
    resolved_deps = list(deps)
    resolved_cargo_args = list(cargo_args)

    if iuse:
        effective_use = get_effective_use(
            name,
            iuse,
            use_defaults,
            global_use,
            package_overrides,
        )

        # Resolve conditional dependencies
        resolved_deps.extend(use_dep(use_deps, effective_use))

        # Generate Cargo arguments with features
        if use_features:
            resolved_cargo_args = use_cargo_args(use_features, effective_use, cargo_args)

    # Use eclass inheritance for cargo
    eclass_config = inherit(["cargo"])

    # Handle cargo_args by setting environment variable
    env = kwargs.pop("env", {})
    if resolved_cargo_args:
        env["CARGO_BUILD_FLAGS"] = " ".join(resolved_cargo_args)

    # Merge eclass bdepend with any existing bdepend
    bdepend = list(kwargs.pop("bdepend", []))
    for dep in eclass_config["bdepend"]:
        if dep not in bdepend:
            bdepend.append(dep)

    # Add bootstrap toolchain by default to ensure linking against BuckOS glibc
    # Use get_toolchain_dep() which returns select() based on platform constraints
    use_bootstrap = kwargs.pop("use_bootstrap", True)
    if use_bootstrap:
        bdepend.append(get_toolchain_dep())

    # Filter out rdepend from kwargs since we pass it explicitly as deps
    kwargs.pop("rdepend", None)

    # Allow overriding eclass phases via kwargs
    custom_src_prepare = kwargs.pop("src_prepare", None)

    # Combine with eclass phases
    src_prepare = custom_src_prepare if custom_src_prepare else eclass_config.get("src_prepare", "")


    # Use custom install if bins specified, otherwise use eclass default
    src_install = cargo_src_install(bins) if bins else eclass_config["src_install"]

    ebuild_package(
        name = name,
        source = ":" + src_name,
        version = version,
        src_prepare = src_prepare,
        src_configure = eclass_config["src_configure"],
        src_compile = eclass_config["src_compile"],
        src_install = src_install,
        rdepend = resolved_deps,
        bdepend = bdepend,
        env = env,
        maintainers = maintainers,
        use_flags = effective_use,
        use_bootstrap = use_bootstrap,
        **kwargs
    )

def go_package(
        name: str,
        version: str,
        src_uri: str,
        sha256: str,
        bins: list[str] = [],
        packages: list[str] = ["."],
        deps: list[str] = [],
        maintainers: list[str] = [],
        patches: list[str] = [],
        # USE flag support
        iuse: list[str] = [],
        use_defaults: list[str] = [],
        use_tags: dict = {},
        use_deps: dict = {},
        global_use: dict | None = None,
        package_overrides: dict | None = None,
        signature_sha256: str | None = None,
        gpg_key: str | None = None,
        gpg_keyring: str | None = None,
        signature_required: bool = False,
        exclude_patterns: list[str] = [],
        **kwargs):
    """
    Convenience macro for Go packages with USE flag support.
    Uses the go-module eclass for standardized build phases.

    Args:
        name: Package name
        version: Package version
        src_uri: Source download URL
        sha256: Source checksum
        bins: Binary names to install
        packages: Go packages to build
        deps: Base dependencies (always applied)
        maintainers: Package maintainers
        iuse: List of USE flags this package supports
        use_defaults: Default enabled USE flags
        use_tags: Dict mapping USE flag to Go build tag(s)
                  Example: {"sqlite": "sqlite", "postgres": "postgres"}
        use_deps: Dict mapping USE flag to conditional dependencies
        global_use: Global USE flag configuration
        package_overrides: Package-specific USE overrides
        signature_sha256: SHA256 of GPG signature file (use update_checksums.py to populate)
        gpg_key: Optional GPG key ID or fingerprint to import and verify against
        gpg_keyring: Optional path to GPG keyring file with trusted keys
        exclude_patterns: List of patterns to exclude from source extraction (passed to tar --exclude)

    Example:
        go_package(
            name = "go-sqlite3",
            version = "1.14.18",
            src_uri = "https://github.com/mattn/go-sqlite3/archive/v1.14.18.tar.gz",
            sha256 = "...",
            iuse = ["icu", "json1", "fts5"],
            use_defaults = ["json1"],
            use_tags = {
                "icu": "icu",
                "json1": "json1",
                "fts5": "fts5",
            },
            use_deps = {
                "icu": ["//packages/linux/dev-libs/icu"],
            },
        )
    """
    # Apply platform-specific constraints (Linux packages only build on Linux, etc.)
    kwargs = _apply_platform_constraints(kwargs)

    src_name = name + "-src"

    download_source(
        name = src_name,
        src_uri = src_uri,
        sha256 = sha256,
        signature_sha256 = signature_sha256,
        signature_required = signature_required,
        gpg_key = gpg_key,
        gpg_keyring = gpg_keyring,
        exclude_patterns = exclude_patterns,
    )

    # Calculate effective USE flags if USE flags are specified
    effective_use = []
    resolved_deps = list(deps)
    resolved_go_build_args = kwargs.pop("go_build_args", [])

    if iuse:
        effective_use = get_effective_use(
            name,
            iuse,
            use_defaults,
            global_use,
            package_overrides,
        )

        # Resolve conditional dependencies
        resolved_deps.extend(use_dep(use_deps, effective_use))

        # Generate Go build arguments with tags
        if use_tags:
            resolved_go_build_args = use_go_build_args(use_tags, effective_use, resolved_go_build_args)

    # Use eclass inheritance for go-module
    eclass_config = inherit(["go-module"])

    # Handle packages by setting environment variable
    env = kwargs.pop("env", {})
    if packages != ["."]:
        env["GO_PACKAGES"] = " ".join(packages)

    # Handle go_build_args
    if resolved_go_build_args:
        env["GO_BUILD_FLAGS"] = " ".join(resolved_go_build_args)

    # Merge eclass bdepend with any existing bdepend
    bdepend = list(kwargs.pop("bdepend", []))
    for dep in eclass_config["bdepend"]:
        if dep not in bdepend:
            bdepend.append(dep)

    # Add bootstrap toolchain by default to ensure linking against BuckOS glibc
    # Use get_toolchain_dep() which returns select() based on platform constraints
    use_bootstrap = kwargs.pop("use_bootstrap", True)
    if use_bootstrap:
        bdepend.append(get_toolchain_dep())

    # Allow overriding eclass phases via kwargs
    custom_src_prepare = kwargs.pop("src_prepare", None)

    # Combine with eclass phases
    src_prepare = custom_src_prepare if custom_src_prepare else eclass_config.get("src_prepare", "")


    # Use custom install if bins specified, otherwise use eclass default
    src_install = go_src_install(bins) if bins else eclass_config["src_install"]

    ebuild_package(
        name = name,
        source = ":" + src_name,
        version = version,
        src_prepare = src_prepare,
        src_configure = eclass_config["src_configure"],
        src_compile = eclass_config["src_compile"],
        src_install = src_install,
        rdepend = resolved_deps,
        bdepend = bdepend,
        env = env,
        maintainers = maintainers,
        use_flags = effective_use,
        use_bootstrap = use_bootstrap,
        **kwargs
    )

def python_package(
        name: str,
        version: str,
        src_uri: str,
        sha256: str,
        python: str = "python3",
        deps: list[str] = [],
        maintainers: list[str] = [],
        patches: list[str] = [],
        # USE flag support
        iuse: list[str] = [],
        use_defaults: list[str] = [],
        use_extras: dict = {},
        use_deps: dict = {},
        global_use: dict | None = None,
        package_overrides: dict | None = None,
        signature_sha256: str | None = None,
        gpg_key: str | None = None,
        gpg_keyring: str | None = None,
        signature_required: bool = False,
        exclude_patterns: list[str] = [],
        **kwargs):
    """
    Convenience macro for Python packages with USE flag support.
    Uses the python-single-r1 eclass for standardized build phases.

    Args:
        name: Package name
        version: Package version
        src_uri: Source download URL
        sha256: Source checksum
        python: Python interpreter (default: python3)
        deps: Base dependencies (always applied)
        maintainers: Package maintainers
        iuse: List of USE flags this package supports
        use_defaults: Default enabled USE flags
        use_extras: Dict mapping USE flag to Python extras
                    Example: {"ssl": "ssl", "http2": "http2"}
        use_deps: Dict mapping USE flag to conditional dependencies
        global_use: Global USE flag configuration
        package_overrides: Package-specific USE overrides
        signature_sha256: SHA256 of GPG signature file (use update_checksums.py to populate)
        gpg_key: Optional GPG key ID or fingerprint to import and verify against
        gpg_keyring: Optional path to GPG keyring file with trusted keys
        exclude_patterns: List of patterns to exclude from source extraction (passed to tar --exclude)

    Example:
        python_package(
            name = "requests",
            version = "2.31.0",
            src_uri = "https://github.com/psf/requests/archive/v2.31.0.tar.gz",
            sha256 = "...",
            iuse = ["socks", "security"],
            use_defaults = ["security"],
            use_extras = {
                "socks": "socks",
                "security": "security",
            },
            use_deps = {
                "socks": ["//packages/linux/dev-python/pysocks"],
            },
        )
    """
    src_name = name + "-src"

    download_source(
        name = src_name,
        src_uri = src_uri,
        sha256 = sha256,
        signature_sha256 = signature_sha256,
        signature_required = signature_required,
        gpg_key = gpg_key,
        gpg_keyring = gpg_keyring,
        exclude_patterns = exclude_patterns,
    )

    # Calculate effective USE flags if USE flags are specified
    effective_use = []
    resolved_deps = list(deps)
    extras = []

    if iuse:
        effective_use = get_effective_use(
            name,
            iuse,
            use_defaults,
            global_use,
            package_overrides,
        )

        # Resolve conditional dependencies
        resolved_deps.extend(use_dep(use_deps, effective_use))

        # Collect Python extras based on USE flags
        enabled_set = set(effective_use)
        for flag, extra_name in use_extras.items():
            if flag in enabled_set:
                if isinstance(extra_name, list):
                    extras.extend(extra_name)
                else:
                    extras.append(extra_name)

    # Use eclass inheritance for python-single-r1
    eclass_config = inherit(["python-single-r1"])

    # Handle python version by setting environment variable
    env = kwargs.pop("env", {})
    if python != "python3":
        env["PYTHON"] = python

    # Set extras if any are enabled
    if extras:
        env["PYTHON_EXTRAS"] = ",".join(extras)

    # Merge eclass bdepend with any existing bdepend
    bdepend = list(kwargs.pop("bdepend", []))
    for dep in eclass_config["bdepend"]:
        if dep not in bdepend:
            bdepend.append(dep)

    # Add bootstrap toolchain by default
    # Use get_toolchain_dep() which returns select() based on platform constraints
    use_bootstrap = kwargs.pop("use_bootstrap", True)
    if use_bootstrap:
        bdepend.append(get_toolchain_dep())

    # Merge eclass rdepend with resolved dependencies
    rdepend = resolved_deps
    for dep in eclass_config.get("rdepend", []):
        if dep not in rdepend:
            rdepend.append(dep)

    # Filter out python-specific parameters that ebuild_package doesn't accept
    filtered_kwargs = dict(kwargs)
    filtered_kwargs.pop("python_deps", None)
    filtered_kwargs.pop("extras", None)
    filtered_kwargs.pop("build_deps", None)

    # Allow overriding eclass phases via kwargs
    custom_src_prepare = filtered_kwargs.pop("src_prepare", None)

    # Combine with eclass phases
    src_prepare = custom_src_prepare if custom_src_prepare else eclass_config.get("src_prepare", "")


    ebuild_package(
        name = name,
        source = ":" + src_name,
        version = version,
        src_prepare = src_prepare,
        src_configure = eclass_config["src_configure"],
        src_compile = eclass_config["src_compile"],
        src_install = eclass_config["src_install"],
        rdepend = rdepend,
        bdepend = bdepend,
        env = env,
        maintainers = maintainers,
        use_flags = effective_use,
        use_bootstrap = use_bootstrap,
        **filtered_kwargs
    )

# -----------------------------------------------------------------------------
# Binary Package Helper Functions
# -----------------------------------------------------------------------------

def binary_install_bins(bins: list[str], src_dir: str = "$SRCS") -> str:
    """
    Helper to install binary executables from source directory to /usr/bin.

    Usage in install_script:
        install_script = binary_install_bins(["myapp", "mytool"])
    """
    cmds = ['mkdir -p "$OUT/usr/bin"']
    for b in bins:
        cmds.append('install -m 0755 "{}/{}" "$OUT/usr/bin/"'.format(src_dir, b))
    return "\n".join(cmds)

def binary_install_libs(libs: list[str], src_dir: str = "$SRCS") -> str:
    """
    Helper to install shared libraries from source directory to /usr/lib64.

    Usage in install_script:
        install_script = binary_install_libs(["libfoo.so", "libbar.so.1"])
    """
    cmds = ['mkdir -p "$OUT/usr/lib64"']
    for lib in libs:
        cmds.append('install -m 0755 "{}/{}" "$OUT/usr/lib64/"'.format(src_dir, lib))
    return "\n".join(cmds)

def binary_extract_tarball(tarball: str, dest: str = "/usr", strip: int = 1) -> str:
    """
    Helper to extract a tarball to a destination directory.

    Usage in install_script:
        install_script = binary_extract_tarball("app-1.0.tar.gz", "/opt/app", strip=1)
    """
    return '''
mkdir -p "$OUT{dest}"
tar -xf "$SRCS/{tarball}" -C "$OUT{dest}" --strip-components={strip}
'''.format(tarball = tarball, dest = dest, strip = strip)

def binary_copy_tree(src_subdir: str = "", dest: str = "/usr") -> str:
    """
    Helper to copy a directory tree from source to destination.

    Usage in install_script:
        install_script = binary_copy_tree("bin", "/usr/bin")
    """
    src = "$SRCS" if not src_subdir else "$SRCS/{}".format(src_subdir)
    return '''
mkdir -p "$OUT{dest}"
cp -r {src}/* "$OUT{dest}/" 2>/dev/null || true
'''.format(src = src, dest = dest)

def binary_create_wrapper(name: str, target: str, env_vars: dict[str, str] = {}) -> str:
    """
    Helper to create a wrapper script for a binary with environment setup.

    Usage in install_script:
        install_script = binary_create_wrapper("java", "/usr/lib/jvm/bin/java", {"JAVA_HOME": "/usr/lib/jvm"})
    """
    env_exports = "\n".join(['export {}="{}"'.format(k, v) for k, v in env_vars.items()])
    return '''
mkdir -p "$OUT/usr/bin"
cat > "$OUT/usr/bin/{name}" << 'WRAPPER_EOF'
#!/bin/bash
{env}
exec "{target}" "$@"
WRAPPER_EOF
chmod 0755 "$OUT/usr/bin/{name}"
'''.format(name = name, target = target, env = env_exports)

def binary_install_manpages(manpages: list[str], src_dir: str = "$SRCS") -> str:
    """
    Helper to install man pages from a binary package.

    Usage in install_script:
        install_script = binary_install_manpages(["app.1", "app.conf.5"])
    """
    cmds = []
    for man in manpages:
        # Extract section from filename (e.g., "app.1" -> section 1)
        cmds.append('''
_manfile="{src_dir}/{man}"
_section="${{_manfile##*.}}"
mkdir -p "$OUT/usr/share/man/man$_section"
install -m 0644 "$_manfile" "$OUT/usr/share/man/man$_section/"
'''.format(src_dir = src_dir, man = man))
    return "\n".join(cmds)

def binary_make_symlinks(symlinks: dict[str, str]) -> str:
    """
    Helper to create symbolic links.

    Usage in install_script:
        install_script = binary_make_symlinks({"/usr/bin/vi": "/usr/bin/vim"})
    """
    cmds = []
    for link, target in symlinks.items():
        cmds.append('mkdir -p "$OUT/$(dirname "{}")"'.format(link))
        cmds.append('ln -sf "{}" "$OUT/{}"'.format(target, link))
    return "\n".join(cmds)

def bootstrap_compiler_install(
        bootstrap_tarball: str,
        source_dir: str,
        build_cmd: str,
        install_prefix: str = "/usr",
        bins: list[str] = []) -> str:
    """
    Helper for bootstrap-style compiler installations (Go, GHC, Rust, etc.).

    Usage in install_script:
        install_script = bootstrap_compiler_install(
            bootstrap_tarball = "go1.21.6.linux-amd64.tar.gz",
            source_dir = "go",
            build_cmd = "cd src && ./make.bash",
            install_prefix = "/usr/local/go",
            bins = ["go", "gofmt"]
        )
    """
    bin_symlinks = "\n".join([
        'ln -sf "{}/bin/{}" "$OUT/usr/bin/{}"'.format(install_prefix, b, b)
        for b in bins
    ]) if bins else ""

    return '''
# Setup bootstrap
mkdir -p $WORK/bootstrap
tar -xf "$SRCS/{bootstrap_tarball}" -C $WORK/bootstrap --strip-components=1
export PATH="$WORK/bootstrap/bin:$PATH"

# Build from source
cd "$SRCS/{source_dir}"
{build_cmd}

# Install
mkdir -p "$OUT{install_prefix}"
cp -r "$SRCS/{source_dir}"/* "$OUT{install_prefix}/"

# Create bin symlinks
mkdir -p "$OUT/usr/bin"
{bin_symlinks}
'''.format(
        bootstrap_tarball = bootstrap_tarball,
        source_dir = source_dir,
        build_cmd = build_cmd,
        install_prefix = install_prefix,
        bin_symlinks = bin_symlinks,
    )

# -----------------------------------------------------------------------------
# Binary Package Convenience Macros
# -----------------------------------------------------------------------------

def simple_binary_package(
        name: str,
        version: str,
        src_uri: str,
        sha256: str,
        bins: list[str] = [],
        libs: list[str] = [],
        extract_to: str = "/usr",
        symlinks: dict[str, str] = {},
        deps: list[str] = [],
        maintainers: list[str] = [],
        patches: list[str] = [],
        exclude_patterns: list[str] = [],
        **kwargs):
    """
    Convenience macro for simple precompiled binary packages.

    This is the easiest way to package a precompiled binary - just specify
    the binaries and libraries to install.

    Example:
        simple_binary_package(
            name = "ripgrep",
            version = "14.1.0",
            src_uri = "https://github.com/BurntSushi/ripgrep/releases/download/14.1.0/ripgrep-14.1.0-x86_64-unknown-linux-musl.tar.gz",
            sha256 = "...",
            bins = ["rg"],
        )
    """
    src_name = name + "-src"

    download_source(
        name = src_name,
        src_uri = src_uri,
        sha256 = sha256,
        exclude_patterns = exclude_patterns,
    )

    # Build install script
    install_cmds = []
    if bins:
        install_cmds.append(binary_install_bins(bins))
    if libs:
        install_cmds.append(binary_install_libs(libs))
    if symlinks:
        install_cmds.append(binary_make_symlinks(symlinks))
    if not bins and not libs:
        install_cmds.append(binary_copy_tree("", extract_to))

    binary_package(
        name = name,
        srcs = [":" + src_name],
        version = version,
        install_script = "\n".join(install_cmds),
        deps = deps,
        maintainers = maintainers,
        **kwargs
    )

def bootstrap_package(
        name: str,
        version: str,
        src_uri: str,
        sha256: str,
        bootstrap_uri: str,
        bootstrap_sha256: str,
        build_cmd: str,
        install_prefix: str = "/usr",
        bins: list[str] = [],
        deps: list[str] = [],
        maintainers: list[str] = [],
        patches: list[str] = [],
        exclude_patterns: list[str] = [],
        bootstrap_exclude_patterns: list[str] = [],
        **kwargs):
    """
    Convenience macro for bootstrap-compiled packages (compilers that need
    a previous version to build).

    Example:
        bootstrap_package(
            name = "go",
            version = "1.22.0",
            src_uri = "https://go.dev/dl/go1.22.0.src.tar.gz",
            sha256 = "...",
            bootstrap_uri = "https://go.dev/dl/go1.21.6.linux-amd64.tar.gz",
            bootstrap_sha256 = "...",
            build_cmd = "cd src && ./make.bash",
            install_prefix = "/usr/local/go",
            bins = ["go", "gofmt"],
        )
    """
    src_name = name + "-src"
    bootstrap_name = name + "-bootstrap-src"

    download_source(
        name = src_name,
        src_uri = src_uri,
        sha256 = sha256,
        exclude_patterns = exclude_patterns,
    )

    download_source(
        name = bootstrap_name,
        src_uri = bootstrap_uri,
        sha256 = bootstrap_sha256,
        exclude_patterns = bootstrap_exclude_patterns,
    )

    # Derive bootstrap tarball name from URI
    bootstrap_tarball = bootstrap_uri.split("/")[-1]

    binary_package(
        name = name,
        srcs = [":" + src_name, ":" + bootstrap_name],
        version = version,
        install_script = bootstrap_compiler_install(
            bootstrap_tarball = bootstrap_tarball,
            source_dir = name,
            build_cmd = build_cmd,
            install_prefix = install_prefix,
            bins = bins,
        ),
        deps = deps,
        maintainers = maintainers,
        **kwargs
    )

