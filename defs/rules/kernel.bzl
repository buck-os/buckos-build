"""
Kernel build rules for BuckOS.

Rules:
  kernel_config — merge kernel configuration fragments into a single .config
  kernel_build  — build Linux kernel with custom configuration
"""

load("//defs:empty_registry.bzl", "PATCH_REGISTRY")
load("//defs:providers.bzl", "KernelInfo")

# ── kernel_config ────────────────────────────────────────────────────

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

_kernel_config_rule = rule(
    impl = _kernel_config_impl,
    attrs = {
        "fragments": attrs.list(attrs.source()),
        "source": attrs.option(attrs.dep(), default = None),
        "version": attrs.option(attrs.string(), default = None),
        "defconfig": attrs.option(attrs.string(), default = None),
        "arch": attrs.string(default = "x86_64"),
        "labels": attrs.list(attrs.string(), default = []),
    },
)

def kernel_config(labels = [], **kwargs):
    _kernel_config_rule(
        labels = labels,
        **kwargs
    )

# ── kernel_build ─────────────────────────────────────────────────────

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
unset CDPATH
# Live kernel: loop, sr, piix, iso9660, squashfs, overlayfs built-in

# Arguments:
# $1 = install directory (output)
# $2 = source directory (input)
# $3 = build scratch directory (output, for writable build)
# $4 = target architecture (x86_64 or aarch64)
# $5 = config file (optional)
# $6 = cross-toolchain directory (optional, for cross-compilation)

# Save absolute paths before changing directory
SRC_DIR="$(cd "$2" && pwd)"

# Build scratch directory - passed from Buck2 for hermetic builds
BUILD_DIR="$3"

# Target architecture
TARGET_ARCH="$4"

# Cross-toolchain directory (optional)
CROSS_TOOLCHAIN_DIR="$6"

# Set up cross-toolchain PATH if provided
if [ -n "$CROSS_TOOLCHAIN_DIR" ] && [ -d "$CROSS_TOOLCHAIN_DIR" ]; then
    # Look for toolchain bin directories
    for subdir in $(find "$CROSS_TOOLCHAIN_DIR" -type d -name bin 2>/dev/null); do
        export PATH="$subdir:$PATH"
    done
    echo "Cross-toolchain added to PATH"
fi

# Set architecture-specific variables
case "$TARGET_ARCH" in
    aarch64)
        KERNEL_ARCH="arm64"
        KERNEL_IMAGE="arch/arm64/boot/Image"
        # Try buckos cross-compiler first, then standard prefix
        if command -v aarch64-buckos-linux-gnu-gcc >/dev/null 2>&1; then
            CROSS_COMPILE="aarch64-buckos-linux-gnu-"
        else
            CROSS_COMPILE="aarch64-linux-gnu-"
        fi
        ;;
    x86_64|*)
        KERNEL_ARCH="x86"
        KERNEL_IMAGE="arch/x86/boot/bzImage"
        CROSS_COMPILE=""
        ;;
esac

echo "Building kernel for $TARGET_ARCH (ARCH=$KERNEL_ARCH, image=$KERNEL_IMAGE)"

# Convert install paths to absolute
if [[ "$1" = /* ]]; then
    INSTALL_BASE="$1"
else
    INSTALL_BASE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
fi

export INSTALL_PATH="$INSTALL_BASE/boot"
export INSTALL_MOD_PATH="$INSTALL_BASE"
mkdir -p "$INSTALL_PATH"

if [ -n "$5" ]; then
    # Convert config path to absolute if it's relative
    if [[ "$5" = /* ]]; then
        CONFIG_PATH="$5"
    else
        CONFIG_PATH="$(pwd)/$5"
    fi
fi

# $7 = config_base (e.g., "tinyconfig", "allnoconfig", or empty)
CONFIG_BASE="$7"

# Collect variable-length arguments: inject files, patches, module sources
INJECT_COUNT="${8:-0}"
shift 8 2>/dev/null || shift $#
INJECT_FILES=()
for ((i=0; i<INJECT_COUNT; i++)); do
    INJECT_DEST="$1"
    INJECT_SRC="$2"
    shift 2
    INJECT_FILES+=("$INJECT_DEST:$INJECT_SRC")
done

PATCH_COUNT="${1:-0}"
shift
PATCH_FILES=()
for ((i=0; i<PATCH_COUNT; i++)); do
    PATCH_FILES+=("$1")
    shift
done

MODULE_COUNT="${1:-0}"
shift
MODULE_DIRS=()
for ((i=0; i<MODULE_COUNT; i++)); do
    MODULE_DIRS+=("$1")
    shift
done

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

# Inject extra files into source tree (cwd is BUILD_DIR)
if [ ${#INJECT_FILES[@]} -gt 0 ]; then
    for entry in "${INJECT_FILES[@]}"; do
        IFS=: read -r dest src <<< "$entry"
        if [[ "$src" != /* ]]; then
            src="$OLDPWD/$src"
        fi
        mkdir -p "$(dirname "$dest")"
        cp "$src" "$dest"
    done
    echo "Injected ${#INJECT_FILES[@]} file(s) into source tree"
fi

# Apply patches to kernel source
if [ ${#PATCH_FILES[@]} -gt 0 ]; then
    echo "Applying ${#PATCH_FILES[@]} patch(es) to kernel source..."
    for patch_file in "${PATCH_FILES[@]}"; do
        if [ -n "$patch_file" ]; then
            echo "  Applying $(basename "$patch_file")..."
            if [[ "$patch_file" != /* ]]; then
                patch_file="$OLDPWD/$patch_file"
            fi
            patch -p1 < "$patch_file" || { echo "Patch failed: $patch_file"; exit 1; }
        fi
    done
    echo "All patches applied successfully"
fi

# Set up cross-compilation if building for different architecture
MAKE_ARCH_OPTS="ARCH=$KERNEL_ARCH"
if [ -n "$CROSS_COMPILE" ]; then
    # Check if cross-compiler is available
    if command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
        MAKE_ARCH_OPTS="$MAKE_ARCH_OPTS CROSS_COMPILE=$CROSS_COMPILE"
        echo "Cross-compiling with $CROSS_COMPILE"
    else
        echo "Warning: Cross-compiler ${CROSS_COMPILE}gcc not found, attempting native build"
        CROSS_COMPILE=""
    fi
fi

# Apply config
if [ -n "$CONFIG_BASE" ]; then
    # Start from a base config target (e.g., tinyconfig, allnoconfig)
    make $MAKE_CC_OVERRIDE $MAKE_ARCH_OPTS $CONFIG_BASE
    if [ -n "$CONFIG_PATH" ]; then
        # Merge config fragment on top of base
        scripts/kconfig/merge_config.sh -m .config "$CONFIG_PATH"
        make $MAKE_CC_OVERRIDE $MAKE_ARCH_OPTS olddefconfig
    fi
elif [ -n "$CONFIG_PATH" ]; then
    cp "$CONFIG_PATH" .config
    # Ensure config is complete with olddefconfig (non-interactive)
    make $MAKE_CC_OVERRIDE $MAKE_ARCH_OPTS olddefconfig

    # If hardware-specific config fragment exists, merge it
    HARDWARE_CONFIG="$(dirname "$SRC_DIR")/../../hardware-kernel.config"
    if [ -f "$HARDWARE_CONFIG" ]; then
        echo "Merging hardware-specific kernel config..."
        scripts/kconfig/merge_config.sh -m .config "$HARDWARE_CONFIG"
        make $MAKE_CC_OVERRIDE $MAKE_ARCH_OPTS olddefconfig
    fi
else
    make $MAKE_CC_OVERRIDE $MAKE_ARCH_OPTS defconfig
fi

# Build kernel
# -Wno-unterminated-string-initialization: suppresses ACPI driver warnings about truncated strings
# GCC wrapper (if GCC 14+) appends -std=gnu11 to all compilations via CC override
KCFLAGS_EXTRA="${KCFLAGS_EXTRA:--Wno-unterminated-string-initialization}"
make $MAKE_CC_OVERRIDE $MAKE_ARCH_OPTS -j${MAKEOPTS:-$(nproc)} WERROR=0 KCFLAGS="$KCFLAGS_EXTRA"

# Manual install to avoid system kernel-install scripts that try to write to /boot, run dracut, etc.
# Get kernel release version
KRELEASE=$(make $MAKE_CC_OVERRIDE $MAKE_ARCH_OPTS -s kernelrelease)
echo "Installing kernel version: $KRELEASE"

# Install kernel image
mkdir -p "$INSTALL_PATH"
cp "$KERNEL_IMAGE" "$INSTALL_PATH/vmlinuz-$KRELEASE"
cp System.map "$INSTALL_PATH/System.map-$KRELEASE"
cp .config "$INSTALL_PATH/config-$KRELEASE"

# Install modules
make $MAKE_CC_OVERRIDE $MAKE_ARCH_OPTS INSTALL_MOD_PATH="$INSTALL_BASE" modules_install

# Install headers (useful for out-of-tree modules)
mkdir -p "$INSTALL_BASE/usr/src/linux-$KRELEASE"
make $MAKE_CC_OVERRIDE $MAKE_ARCH_OPTS INSTALL_HDR_PATH="$INSTALL_BASE/usr" headers_install

# Build and install external kernel modules
if [ ${#MODULE_DIRS[@]} -gt 0 ]; then
    echo "Building ${#MODULE_DIRS[@]} external module(s)..."
    for mod_src_dir in "${MODULE_DIRS[@]}"; do
        if [ -n "$mod_src_dir" ] && [ -d "$mod_src_dir" ]; then
            # Convert to absolute path
            if [[ "$mod_src_dir" != /* ]]; then
                mod_src_dir="$(cd "$mod_src_dir" && pwd)"
            fi

            MOD_NAME=$(basename "$mod_src_dir")
            echo "  Building external module: $MOD_NAME"

            # Copy module source to writable location (Buck2 inputs are read-only)
            MOD_BUILD="$BUILD_DIR/.modules/$MOD_NAME"
            mkdir -p "$MOD_BUILD"
            cp -a "$mod_src_dir"/. "$MOD_BUILD/"
            chmod -R u+w "$MOD_BUILD"

            # Build module against our kernel tree
            make $MAKE_CC_OVERRIDE $MAKE_ARCH_OPTS \
                -C "$BUILD_DIR" M="$MOD_BUILD" -j${MAKEOPTS:-$(nproc)} modules

            # Install module .ko files
            mkdir -p "$INSTALL_BASE/lib/modules/$KRELEASE/extra"
            find "$MOD_BUILD" -name '*.ko' -exec \
                install -m 644 {} "$INSTALL_BASE/lib/modules/$KRELEASE/extra/" \;

            echo "  Installed module: $MOD_NAME"
        fi
    done
    echo "All external modules built and installed"
fi

# Run depmod to generate module dependency metadata
if command -v depmod >/dev/null 2>&1; then
    echo "Running depmod for $KRELEASE..."
    depmod -b "$INSTALL_BASE" "$KRELEASE" 2>/dev/null || true
fi
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
        ctx.attrs.arch,  # Target architecture
    ])

    # Add config file if present, otherwise add empty string placeholder
    if config_file:
        cmd.add(config_file)
    else:
        cmd.add("")

    # Add cross-toolchain directory if present, otherwise empty placeholder
    if ctx.attrs.cross_toolchain:
        toolchain_dir = ctx.attrs.cross_toolchain[DefaultInfo].default_outputs[0]
        cmd.add(toolchain_dir)
    else:
        cmd.add("")

    # Add config_base (or empty placeholder)
    cmd.add(ctx.attrs.config_base or "")

    # Add inject file count and dest/src pairs
    cmd.add(str(len(ctx.attrs.inject_files)))
    for dest_path, src_file in ctx.attrs.inject_files.items():
        cmd.add(dest_path)
        cmd.add(src_file)

    # Add patch count and patch file paths
    cmd.add(str(len(ctx.attrs.patches)))
    for patch in ctx.attrs.patches:
        cmd.add(patch)

    # Add module count and module source directories
    cmd.add(str(len(ctx.attrs.modules)))
    for mod in ctx.attrs.modules:
        mod_dir = mod[DefaultInfo].default_outputs[0]
        cmd.add(mod_dir)

    # Ensure all attributes contribute to the action cache key
    cache_key = ctx.actions.write(
        "cache_key.txt",
        "version={}\n".format(ctx.attrs.version),
    )
    cmd.add(cmd_args(hidden = [cache_key]))

    env = {}
    if ctx.attrs.kcflags:
        env["KCFLAGS_EXTRA"] = ctx.attrs.kcflags

    ctx.actions.run(
        cmd,
        env = env,
        category = "kernel",
        identifier = ctx.attrs.name,
    )

    return [DefaultInfo(default_output = install_dir)]

_kernel_build_rule = rule(
    impl = _kernel_build_impl,
    attrs = {
        "source": attrs.dep(),
        "version": attrs.string(),
        "config": attrs.option(attrs.source(), default = None),
        "config_dep": attrs.option(attrs.dep(), default = None),
        "arch": attrs.string(default = "x86_64"),  # Target architecture: x86_64 or aarch64
        "cross_toolchain": attrs.option(attrs.dep(), default = None),  # Cross-toolchain for cross-compilation
        "patches": attrs.list(attrs.source(), default = []),  # Patches to apply to kernel source
        "modules": attrs.list(attrs.dep(), default = []),  # External module sources to build
        "config_base": attrs.option(attrs.string(), default = None),
        "inject_files": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "kcflags": attrs.option(attrs.string(), default = None),
        "labels": attrs.list(attrs.string(), default = []),
    },
)

def kernel_build(
        name,
        source,
        version,
        config = None,
        config_dep = None,
        arch = "x86_64",
        cross_toolchain = None,
        patches = [],
        modules = [],
        config_base = None,
        inject_files = {},
        kcflags = None,
        labels = [],
        visibility = []):
    """Build Linux kernel with optional patches and external modules.

    This macro wraps _kernel_build_rule to integrate with the private
    patch registry (patches/registry.bzl).

    Args:
        name: Target name
        source: Kernel source dependency (download_source target)
        version: Kernel version string
        config: Optional direct path to .config file
        config_dep: Optional dependency providing generated .config (from kernel_config)
        arch: Target architecture (x86_64 or aarch64)
        cross_toolchain: Optional cross-compilation toolchain dependency
        patches: List of patch files to apply to kernel source before build
        modules: List of external module source dependencies (download_source targets) to compile
        visibility: Target visibility
    """
    # Apply private patch registry overrides
    merged_patches = list(patches)
    private = PATCH_REGISTRY.get(name, {})
    if "patches" in private:
        merged_patches.extend(private["patches"])

    _kernel_build_rule(
        name = name,
        source = source,
        version = version,
        config = config,
        config_dep = config_dep,
        arch = arch,
        cross_toolchain = cross_toolchain,
        patches = merged_patches,
        modules = modules,
        config_base = config_base,
        inject_files = inject_files,
        kcflags = kcflags,
        labels = labels,
        visibility = visibility,
    )

# ── kernel_headers ──────────────────────────────────────────────────

def _kernel_headers_impl(ctx: AnalysisContext) -> list[Provider]:
    """Install kernel headers for userspace (glibc, musl, BPF)."""
    install_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)
    src_dir = ctx.attrs.source[DefaultInfo].default_outputs[0]
    config_file = ctx.attrs.config[DefaultInfo].default_outputs[0] if ctx.attrs.config else None

    script = ctx.actions.write(
        "install_headers.sh",
        """#!/bin/bash
set -e
SRC_DIR="$(cd "$2" && pwd)"
BUILD_DIR=$(mktemp -d)
cp -a "$SRC_DIR"/. "$BUILD_DIR/"
cd "$BUILD_DIR"
if [ -n "$3" ]; then
    cp "$3" .config
    make ARCH=x86 olddefconfig
fi
make ARCH=x86 INSTALL_HDR_PATH="$1/usr" headers_install
rm -rf "$BUILD_DIR"
""",
        is_executable = True,
    )

    cmd = cmd_args(["bash", script, install_dir.as_output(), src_dir])
    if config_file:
        cmd.add(config_file)

    ctx.actions.run(cmd, category = "kernel_headers", identifier = ctx.attrs.name)

    return [DefaultInfo(default_output = install_dir)]

_kernel_headers_rule = rule(
    impl = _kernel_headers_impl,
    attrs = {
        "source": attrs.dep(),
        "config": attrs.option(attrs.dep(), default = None),
        "version": attrs.string(default = ""),
        "labels": attrs.list(attrs.string(), default = []),
    },
)

def kernel_headers(name, source, version = "", config = None, labels = [], visibility = []):
    _kernel_headers_rule(
        name = name,
        source = source,
        config = config,
        version = version,
        labels = labels,
        visibility = visibility,
    )

# ── kernel_btf_headers ──────────────────────────────────────────────

def _kernel_btf_headers_impl(ctx: AnalysisContext) -> list[Provider]:
    """Generate vmlinux.h from a built kernel (for BPF CO-RE / sched_ext)."""
    install_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)
    kernel_dir = ctx.attrs.kernel[DefaultInfo].default_outputs[0]

    script = ctx.actions.write(
        "gen_btf.sh",
        """#!/bin/bash
set -e
KERNEL_DIR="$2"
OUT="$1"
mkdir -p "$OUT/usr/include/linux"

# Find vmlinux with BTF info
VMLINUX=""
for candidate in "$KERNEL_DIR"/boot/vmlinuz-* "$KERNEL_DIR"/boot/vmlinux-*; do
    [ -f "$candidate" ] && VMLINUX="$candidate" && break
done

if [ -z "$VMLINUX" ]; then
    echo "Warning: vmlinux not found, creating empty vmlinux.h"
    touch "$OUT/usr/include/linux/vmlinux.h"
    exit 0
fi

# Generate vmlinux.h using bpftool if available
if command -v bpftool >/dev/null 2>&1; then
    bpftool btf dump file "$VMLINUX" format c > "$OUT/usr/include/linux/vmlinux.h" 2>/dev/null || \
        touch "$OUT/usr/include/linux/vmlinux.h"
else
    echo "Warning: bpftool not found, creating empty vmlinux.h"
    touch "$OUT/usr/include/linux/vmlinux.h"
fi
""",
        is_executable = True,
    )

    cmd = cmd_args(["bash", script, install_dir.as_output(), kernel_dir])
    ctx.actions.run(cmd, category = "kernel_btf", identifier = ctx.attrs.name)

    return [DefaultInfo(default_output = install_dir)]

_kernel_btf_headers_rule = rule(
    impl = _kernel_btf_headers_impl,
    attrs = {
        "kernel": attrs.dep(),
        "labels": attrs.list(attrs.string(), default = []),
    },
)

def kernel_btf_headers(name, kernel, labels = [], visibility = []):
    _kernel_btf_headers_rule(
        name = name,
        kernel = kernel,
        labels = labels,
        visibility = visibility,
    )

# ── kernel_modules_install ──────────────────────────────────────────

def _kernel_modules_install_impl(ctx: AnalysisContext) -> list[Provider]:
    """Install kernel modules with optional extra out-of-tree modules."""
    install_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)
    kernel_dir = ctx.attrs.kernel[DefaultInfo].default_outputs[0]

    script = ctx.actions.write(
        "install_modules.sh",
        """#!/bin/bash
set -e
KERNEL_DIR="$2"
OUT="$1"
VERSION="$3"
shift 3

# Copy in-tree modules from kernel build
if [ -d "$KERNEL_DIR/lib/modules" ]; then
    mkdir -p "$OUT/lib"
    cp -a "$KERNEL_DIR/lib/modules" "$OUT/lib/"
fi

# Install extra out-of-tree modules
for mod_dir in "$@"; do
    if [ -d "$mod_dir" ]; then
        KRELEASE=$(ls "$OUT/lib/modules/" 2>/dev/null | head -1)
        if [ -n "$KRELEASE" ]; then
            mkdir -p "$OUT/lib/modules/$KRELEASE/extra"
            find "$mod_dir" -name '*.ko' -exec cp {} "$OUT/lib/modules/$KRELEASE/extra/" \;
        fi
    fi
done

# Run depmod if modules exist
KRELEASE=$(ls "$OUT/lib/modules/" 2>/dev/null | head -1)
if [ -n "$KRELEASE" ] && command -v depmod >/dev/null 2>&1; then
    depmod -b "$OUT" "$KRELEASE" 2>/dev/null || true
fi
""",
        is_executable = True,
    )

    cmd = cmd_args(["bash", script, install_dir.as_output(), kernel_dir, ctx.attrs.version])
    for mod in ctx.attrs.extra_modules:
        cmd.add(mod[DefaultInfo].default_outputs[0])

    ctx.actions.run(cmd, category = "kernel_modules", identifier = ctx.attrs.name)

    return [DefaultInfo(default_output = install_dir)]

_kernel_modules_install_rule = rule(
    impl = _kernel_modules_install_impl,
    attrs = {
        "kernel": attrs.dep(),
        "version": attrs.string(default = ""),
        "extra_modules": attrs.list(attrs.dep(), default = []),
        "labels": attrs.list(attrs.string(), default = []),
    },
)

def kernel_modules_install(name, kernel, version = "", extra_modules = [], labels = [], visibility = []):
    _kernel_modules_install_rule(
        name = name,
        kernel = kernel,
        version = version,
        extra_modules = extra_modules,
        labels = labels,
        visibility = visibility,
    )
