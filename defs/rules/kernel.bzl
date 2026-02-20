"""
kernel_build + kernel_config rules for BuckOS.

kernel_config merges Kconfig fragments into a single .config file.

kernel_build compiles a Linux kernel.  Six discrete cacheable actions --
Buck2 can skip any phase whose inputs haven't changed.

1. src_unpack  -- obtain source artifact from source dep
2. src_prepare -- apply patches (zero-cost passthrough when no patches)
3. configure   -- copy/generate .config, run make olddefconfig
4. compile     -- make bzImage modules (or arch-appropriate image target)
5. install     -- copy kernel image, System.map, .config; modules_install; headers_install
6. modules_ext -- build and install external out-of-tree modules (skipped when empty)

Returns: DefaultInfo + KernelInfo.
"""

# ── KernelInfo provider ──────────────────────────────────────────────

KernelInfo = provider(fields = [
    "bzimage",      # artifact: kernel image (bzImage or Image depending on arch)
    "modules_dir",  # artifact: lib/modules/<krelease>/ directory
    "version",      # str: kernel version string
])

# ── Architecture helpers ─────────────────────────────────────────────

_ARCH_MAP = {
    "x86_64": struct(
        kernel_arch = "x86",
        image_target = "bzImage",
        image_path = "arch/x86/boot/bzImage",
        cross_compile = "",
    ),
    "aarch64": struct(
        kernel_arch = "arm64",
        image_target = "Image",
        image_path = "arch/arm64/boot/Image",
        cross_compile = "aarch64-linux-gnu-",
    ),
}

# ── kernel_config rule ───────────────────────────────────────────────

def _kernel_config_impl(ctx):
    """Merge kernel configuration fragments into a single .config file."""
    output = ctx.actions.declare_output(ctx.attrs.name + ".config")

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
        while IFS= read -r line || [ -n "$line" ]; do
            # Skip empty lines and comments for processing
            if [[ -z "$line" ]] || [[ "$line" =~ ^# ]]; then
                echo "$line" >> "$OUTPUT"
                continue
            fi

            # Extract config option name
            if [[ "$line" =~ ^(CONFIG_[A-Za-z0-9_]+)= ]]; then
                opt="${BASH_REMATCH[1]}"
                sed -i "/^$opt=/d" "$OUTPUT"
                sed -i "/^# $opt is not set/d" "$OUTPUT"
            elif [[ "$line" =~ ^#[[:space:]]*(CONFIG_[A-Za-z0-9_]+)[[:space:]]is[[:space:]]not[[:space:]]set ]]; then
                opt="${BASH_REMATCH[1]}"
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
        cmd_args(["bash", script, output.as_output()] + list(ctx.attrs.fragments)),
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

# ── kernel_build phase helpers ───────────────────────────────────────

def _src_prepare(ctx, source):
    """Apply patches.  Separate action so unpatched source stays cached."""
    if not ctx.attrs.patches:
        return source  # No patches -- zero-cost passthrough

    output = ctx.actions.declare_output("prepared", dir = True)
    cmd = cmd_args(ctx.attrs._patch_tool[RunInfo])
    cmd.add("--source-dir", source)
    cmd.add("--output-dir", output.as_output())
    for p in ctx.attrs.patches:
        cmd.add("--patch", p)

    ctx.actions.run(cmd, category = "prepare", identifier = ctx.attrs.name)
    return output

def _kernel_configure(ctx, source):
    """Copy .config into the source tree and run make olddefconfig.

    If neither config nor config_dep is provided, falls back to make defconfig.
    The source tree is copied to a writable build directory.  The GCC 14+
    wrapper (appending -std=gnu11) is installed when needed to avoid C23
    bool/true/false keyword conflicts in older kernel code.
    """
    arch_info = _ARCH_MAP.get(ctx.attrs.arch, _ARCH_MAP["x86_64"])

    config_file_arg = ""
    config_hidden = []
    if ctx.attrs.config:
        config_file_arg = "CONFIG_FILE"
        config_hidden = [ctx.attrs.config]
    elif ctx.attrs.config_dep:
        config_file_arg = "CONFIG_FILE"
        dep_output = ctx.attrs.config_dep[DefaultInfo].default_outputs[0]
        config_hidden = [dep_output]

    output = ctx.actions.declare_output("configured", dir = True)

    script = ctx.actions.write(
        "kernel_configure.sh",
        """\
#!/bin/bash
set -e
unset CDPATH

SRC_DIR="$1"
OUT_DIR="$2"
KERNEL_ARCH="$3"
CONFIG_PATH="$4"

# Copy source to writable build directory
cp -a "$SRC_DIR"/. "$OUT_DIR/"
cd "$OUT_DIR"

# GCC 14+ workaround: create wrapper that appends -std=gnu11.
# GCC 14+ defaults to C23 where bool/true/false are keywords,
# breaking older kernel code.
CC_BIN="${CC:-gcc}"
CC_VER=$($CC_BIN --version 2>/dev/null | head -1)
echo "Compiler version: $CC_VER"
MAKE_CC_OVERRIDE=""
if echo "$CC_VER" | grep -iq gcc; then
    GCC_MAJOR=$(echo "$CC_VER" | grep -oE '[0-9]+\\.[0-9]+' | head -1 | cut -d. -f1)
    echo "Detected GCC major version: $GCC_MAJOR"
    if [ -n "$GCC_MAJOR" ] && [ "$GCC_MAJOR" -ge 14 ] 2>/dev/null; then
        echo "GCC 14+ detected, creating wrapper to append -std=gnu11"
        WRAPPER_DIR="$(pwd)/.cc-wrapper"
        mkdir -p "$WRAPPER_DIR"
        cat > "$WRAPPER_DIR/gcc" << 'WRAPPER'
#!/bin/bash
exec /usr/bin/gcc "$@" -std=gnu11
WRAPPER
        chmod +x "$WRAPPER_DIR/gcc"
        MAKE_CC_OVERRIDE="CC=$WRAPPER_DIR/gcc HOSTCC=$WRAPPER_DIR/gcc"
        echo "Will use: $MAKE_CC_OVERRIDE"
    fi
fi

# Write the CC override to a file so later phases can pick it up
echo "$MAKE_CC_OVERRIDE" > .buckos-cc-override

# Apply config
if [ -n "$CONFIG_PATH" ] && [ -f "$CONFIG_PATH" ]; then
    cp "$CONFIG_PATH" .config
    make $MAKE_CC_OVERRIDE ARCH=$KERNEL_ARCH olddefconfig
else
    make $MAKE_CC_OVERRIDE ARCH=$KERNEL_ARCH defconfig
fi

echo "Kernel configured for ARCH=$KERNEL_ARCH"
""",
        is_executable = True,
    )

    cmd = cmd_args(["bash", script, source, output.as_output(), arch_info.kernel_arch])

    # Add config file path or empty placeholder
    if ctx.attrs.config:
        cmd.add(ctx.attrs.config)
    elif ctx.attrs.config_dep:
        cmd.add(ctx.attrs.config_dep[DefaultInfo].default_outputs[0])
    else:
        cmd.add("")

    # Set up cross-compilation PATH if cross_toolchain is provided
    if ctx.attrs.cross_toolchain:
        toolchain_dir = ctx.attrs.cross_toolchain[DefaultInfo].default_outputs[0]
        cmd.add(cmd_args(hidden = [toolchain_dir]))

    ctx.actions.run(cmd, category = "configure", identifier = ctx.attrs.name)
    return output

def _kernel_compile(ctx, configured):
    """Run make to build the kernel image and modules.

    Reads the CC override written during the configure phase to ensure
    the same GCC wrapper is used for compilation.
    """
    arch_info = _ARCH_MAP.get(ctx.attrs.arch, _ARCH_MAP["x86_64"])

    output = ctx.actions.declare_output("built", dir = True)

    # Determine cross-compile prefix
    cross_compile = ""
    if ctx.attrs.arch == "aarch64":
        cross_compile = arch_info.cross_compile

    script = ctx.actions.write(
        "kernel_compile.sh",
        """\
#!/bin/bash
set -e
unset CDPATH

CONFIGURED_DIR="$1"
OUT_DIR="$2"
KERNEL_ARCH="$3"
CROSS_COMPILE_PREFIX="$4"
CROSS_TOOLCHAIN_DIR="$5"

# Copy configured tree to build output
cp -a "$CONFIGURED_DIR"/. "$OUT_DIR/"
cd "$OUT_DIR"

# Set up cross-toolchain PATH if provided
if [ -n "$CROSS_TOOLCHAIN_DIR" ] && [ -d "$CROSS_TOOLCHAIN_DIR" ]; then
    for subdir in $(find "$CROSS_TOOLCHAIN_DIR" -type d -name bin 2>/dev/null); do
        export PATH="$subdir:$PATH"
    done
    echo "Cross-toolchain added to PATH"
fi

# Restore CC override from configure phase
MAKE_CC_OVERRIDE=""
if [ -f .buckos-cc-override ]; then
    MAKE_CC_OVERRIDE=$(cat .buckos-cc-override)
fi

# Set up cross-compilation
MAKE_ARCH_OPTS="ARCH=$KERNEL_ARCH"
if [ -n "$CROSS_COMPILE_PREFIX" ]; then
    if command -v "${CROSS_COMPILE_PREFIX}gcc" >/dev/null 2>&1; then
        MAKE_ARCH_OPTS="$MAKE_ARCH_OPTS CROSS_COMPILE=$CROSS_COMPILE_PREFIX"
        echo "Cross-compiling with $CROSS_COMPILE_PREFIX"
    else
        echo "Warning: Cross-compiler ${CROSS_COMPILE_PREFIX}gcc not found, attempting native build"
    fi
fi

echo "Building kernel for ARCH=$KERNEL_ARCH"

# Build kernel image and modules
# -Wno-unterminated-string-initialization: suppresses ACPI driver warnings
make $MAKE_CC_OVERRIDE $MAKE_ARCH_OPTS -j$(nproc) WERROR=0 KCFLAGS="-Wno-unterminated-string-initialization"

echo "Kernel build complete"
""",
        is_executable = True,
    )

    cmd = cmd_args([
        "bash",
        script,
        configured,
        output.as_output(),
        arch_info.kernel_arch,
        cross_compile,
    ])

    # Cross-toolchain directory (or empty placeholder)
    if ctx.attrs.cross_toolchain:
        cmd.add(ctx.attrs.cross_toolchain[DefaultInfo].default_outputs[0])
    else:
        cmd.add("")

    ctx.actions.run(cmd, category = "compile", identifier = ctx.attrs.name)
    return output

def _kernel_install(ctx, built):
    """Install kernel image, System.map, .config, modules, and headers.

    Manual install avoids system kernel-install scripts that try to write
    to /boot, run dracut, etc.
    """
    arch_info = _ARCH_MAP.get(ctx.attrs.arch, _ARCH_MAP["x86_64"])

    output = ctx.actions.declare_output("installed", dir = True)

    # Determine cross-compile prefix
    cross_compile = ""
    if ctx.attrs.arch == "aarch64":
        cross_compile = arch_info.cross_compile

    script = ctx.actions.write(
        "kernel_install.sh",
        """\
#!/bin/bash
set -e
unset CDPATH

BUILD_DIR="$1"
INSTALL_BASE="$2"
KERNEL_ARCH="$3"
KERNEL_IMAGE_PATH="$4"
CROSS_COMPILE_PREFIX="$5"
CROSS_TOOLCHAIN_DIR="$6"

cd "$BUILD_DIR"

# Set up cross-toolchain PATH if provided
if [ -n "$CROSS_TOOLCHAIN_DIR" ] && [ -d "$CROSS_TOOLCHAIN_DIR" ]; then
    for subdir in $(find "$CROSS_TOOLCHAIN_DIR" -type d -name bin 2>/dev/null); do
        export PATH="$subdir:$PATH"
    done
fi

# Restore CC override from configure phase
MAKE_CC_OVERRIDE=""
if [ -f .buckos-cc-override ]; then
    MAKE_CC_OVERRIDE=$(cat .buckos-cc-override)
fi

MAKE_ARCH_OPTS="ARCH=$KERNEL_ARCH"
if [ -n "$CROSS_COMPILE_PREFIX" ]; then
    if command -v "${CROSS_COMPILE_PREFIX}gcc" >/dev/null 2>&1; then
        MAKE_ARCH_OPTS="$MAKE_ARCH_OPTS CROSS_COMPILE=$CROSS_COMPILE_PREFIX"
    fi
fi

# Get kernel release version
KRELEASE=$(make $MAKE_CC_OVERRIDE $MAKE_ARCH_OPTS -s kernelrelease)
echo "Installing kernel version: $KRELEASE"

# Install kernel image
INSTALL_PATH="$INSTALL_BASE/boot"
mkdir -p "$INSTALL_PATH"
cp "$KERNEL_IMAGE_PATH" "$INSTALL_PATH/vmlinuz-$KRELEASE"
cp System.map "$INSTALL_PATH/System.map-$KRELEASE"
cp .config "$INSTALL_PATH/config-$KRELEASE"

# Install modules
make $MAKE_CC_OVERRIDE $MAKE_ARCH_OPTS INSTALL_MOD_PATH="$INSTALL_BASE" modules_install

# Install headers (useful for out-of-tree modules)
mkdir -p "$INSTALL_BASE/usr/src/linux-$KRELEASE"
make $MAKE_CC_OVERRIDE $MAKE_ARCH_OPTS INSTALL_HDR_PATH="$INSTALL_BASE/usr" headers_install

# Run depmod to generate module dependency metadata
if command -v depmod >/dev/null 2>&1; then
    echo "Running depmod for $KRELEASE..."
    depmod -b "$INSTALL_BASE" "$KRELEASE" 2>/dev/null || true
fi

echo "Kernel install complete: $KRELEASE"
""",
        is_executable = True,
    )

    cmd = cmd_args([
        "bash",
        script,
        built,
        output.as_output(),
        arch_info.kernel_arch,
        arch_info.image_path,
        cross_compile,
    ])

    # Cross-toolchain directory (or empty placeholder)
    if ctx.attrs.cross_toolchain:
        cmd.add(ctx.attrs.cross_toolchain[DefaultInfo].default_outputs[0])
    else:
        cmd.add("")

    ctx.actions.run(cmd, category = "install", identifier = ctx.attrs.name)
    return output

def _kernel_modules_ext(ctx, built, installed):
    """Build and install external out-of-tree modules.

    Compiles each module source against the kernel build tree, then
    installs the resulting .ko files under lib/modules/<krelease>/extra/.
    When there are no external modules, this is a zero-cost passthrough.
    """
    if not ctx.attrs.modules:
        return installed  # No external modules -- passthrough

    arch_info = _ARCH_MAP.get(ctx.attrs.arch, _ARCH_MAP["x86_64"])

    output = ctx.actions.declare_output("with-modules", dir = True)

    cross_compile = ""
    if ctx.attrs.arch == "aarch64":
        cross_compile = arch_info.cross_compile

    script = ctx.actions.write(
        "kernel_modules_ext.sh",
        """\
#!/bin/bash
set -e
unset CDPATH

BUILD_DIR="$1"
INSTALLED_DIR="$2"
OUT_DIR="$3"
KERNEL_ARCH="$4"
CROSS_COMPILE_PREFIX="$5"
CROSS_TOOLCHAIN_DIR="$6"
shift 6

# Copy installed tree to output
cp -a "$INSTALLED_DIR"/. "$OUT_DIR/"

cd "$BUILD_DIR"

# Set up cross-toolchain PATH if provided
if [ -n "$CROSS_TOOLCHAIN_DIR" ] && [ -d "$CROSS_TOOLCHAIN_DIR" ]; then
    for subdir in $(find "$CROSS_TOOLCHAIN_DIR" -type d -name bin 2>/dev/null); do
        export PATH="$subdir:$PATH"
    done
fi

# Restore CC override
MAKE_CC_OVERRIDE=""
if [ -f .buckos-cc-override ]; then
    MAKE_CC_OVERRIDE=$(cat .buckos-cc-override)
fi

MAKE_ARCH_OPTS="ARCH=$KERNEL_ARCH"
if [ -n "$CROSS_COMPILE_PREFIX" ]; then
    if command -v "${CROSS_COMPILE_PREFIX}gcc" >/dev/null 2>&1; then
        MAKE_ARCH_OPTS="$MAKE_ARCH_OPTS CROSS_COMPILE=$CROSS_COMPILE_PREFIX"
    fi
fi

KRELEASE=$(make $MAKE_CC_OVERRIDE $MAKE_ARCH_OPTS -s kernelrelease)

# Build and install each external module
echo "Building external modules..."
for mod_src_dir in "$@"; do
    if [ -n "$mod_src_dir" ] && [ -d "$mod_src_dir" ]; then
        MOD_NAME=$(basename "$mod_src_dir")
        echo "  Building external module: $MOD_NAME"

        # Copy module source to writable location (Buck2 inputs are read-only)
        MOD_BUILD="$BUILD_DIR/.modules/$MOD_NAME"
        mkdir -p "$MOD_BUILD"
        cp -a "$mod_src_dir"/. "$MOD_BUILD/"
        chmod -R u+w "$MOD_BUILD"

        # Build module against our kernel tree
        make $MAKE_CC_OVERRIDE $MAKE_ARCH_OPTS \
            -C "$BUILD_DIR" M="$MOD_BUILD" -j$(nproc) modules

        # Install module .ko files
        mkdir -p "$OUT_DIR/lib/modules/$KRELEASE/extra"
        find "$MOD_BUILD" -name '*.ko' -exec \
            install -m 644 {} "$OUT_DIR/lib/modules/$KRELEASE/extra/" \;

        echo "  Installed module: $MOD_NAME"
    fi
done

# Re-run depmod with external modules included
if command -v depmod >/dev/null 2>&1; then
    depmod -b "$OUT_DIR" "$KRELEASE" 2>/dev/null || true
fi

echo "All external modules built and installed"
""",
        is_executable = True,
    )

    cmd = cmd_args([
        "bash",
        script,
        built,
        installed,
        output.as_output(),
        arch_info.kernel_arch,
        cross_compile,
    ])

    # Cross-toolchain directory (or empty placeholder)
    if ctx.attrs.cross_toolchain:
        cmd.add(ctx.attrs.cross_toolchain[DefaultInfo].default_outputs[0])
    else:
        cmd.add("")

    # Module source directories
    for mod in ctx.attrs.modules:
        cmd.add(mod[DefaultInfo].default_outputs[0])

    ctx.actions.run(cmd, category = "modules_ext", identifier = ctx.attrs.name)
    return output

# ── kernel_build rule implementation ─────────────────────────────────

def _kernel_build_impl(ctx):
    arch_info = _ARCH_MAP.get(ctx.attrs.arch, _ARCH_MAP["x86_64"])

    # Phase 1: src_unpack -- obtain source from dep
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]

    # Phase 2: src_prepare -- apply patches
    prepared = _src_prepare(ctx, source)

    # Phase 3: configure -- .config + olddefconfig
    configured = _kernel_configure(ctx, prepared)

    # Phase 4: compile -- make bzImage modules
    built = _kernel_compile(ctx, configured)

    # Phase 5: install -- copy image, modules_install, headers_install
    installed = _kernel_install(ctx, built)

    # Phase 6: modules_ext -- build/install external modules (passthrough when empty)
    final = _kernel_modules_ext(ctx, built, installed)

    # Ensure version contributes to the action cache key
    cache_key = ctx.actions.write(
        "cache_key.txt",
        "version={}\n".format(ctx.attrs.version),
    )

    kernel_info = KernelInfo(
        bzimage = final.project("boot"),
        modules_dir = final.project("lib/modules"),
        version = ctx.attrs.version,
    )

    return [
        DefaultInfo(
            default_output = final,
            other_outputs = [cache_key],
        ),
        kernel_info,
    ]

# ── kernel_build rule definition ─────────────────────────────────────

kernel_build = rule(
    impl = _kernel_build_impl,
    attrs = {
        # Source and identity
        "source": attrs.dep(),
        "version": attrs.string(),

        # Configuration
        "config": attrs.option(attrs.source(), default = None),
        "config_dep": attrs.option(attrs.dep(), default = None),

        # Architecture and cross-compilation
        "arch": attrs.string(default = "x86_64"),
        "cross_toolchain": attrs.option(attrs.dep(), default = None),

        # Patches and external modules
        "patches": attrs.list(attrs.source(), default = []),
        "modules": attrs.list(attrs.dep(), default = []),

        # Tool deps (hidden -- resolved automatically)
        "_patch_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:patch_helper"),
        ),
    },
)
