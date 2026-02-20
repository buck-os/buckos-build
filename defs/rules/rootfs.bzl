"""
rootfs + initramfs rules for BuckOS.

rootfs assembles packages into a root filesystem.  Takes a list of deps
(each having DefaultInfo with a prefix directory), merges their contents
into a single root with merged-usr layout, account merging, and ldconfig.

initramfs builds a cpio archive from a rootfs directory, suitable for
booting as a Linux initramfs.
"""

# ── rootfs rule ──────────────────────────────────────────────────────

def _rootfs_impl(ctx):
    """Assemble a root filesystem from packages."""
    rootfs_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)

    # Collect all package directories from deps.
    # Each dep contributes its DefaultInfo default_output (the install prefix).
    pkg_dirs = []
    for pkg in ctx.attrs.packages:
        default_outputs = pkg[DefaultInfo].default_outputs[0]s
        for output in default_outputs:
            pkg_dirs.append(output)

    # The assembly script is the battle-tested logic from the existing
    # rootfs implementation: merged-usr layout, merged-bin, acct-user/
    # acct-group merging, ldconfig, permissions.
    script_content = """\
#!/bin/bash
set -e
ROOTFS="$1"
shift

# Create base directory structure
# Note: Don't create /bin, /sbin, /lib, /lib64 here - baselayout provides them as symlinks (merged-usr)
mkdir -p "$ROOTFS"/{usr/{bin,sbin,lib},etc,var,tmp,proc,sys,dev,run,root,home}

# Function to recursively merge package directories
merge_package() {
    local src="$1"
    local dst="$ROOTFS"

    # If src is a symlink to a directory, follow it
    if [ -L "$src" ]; then
        src="$(readlink -f "$src")"
    fi

    if [ ! -d "$src" ]; then
        return
    fi

    # Check if this looks like a package directory (has usr/, lib/, bin/, etc.)
    # If it does, merge its contents directly
    if [ -d "$src/usr" ] || [ -d "$src/bin" ] || [ -d "$src/lib" ] || [ -d "$src/etc" ]; then
        # Use tar to properly merge directory trees (handles nested directories correctly)
        # --keep-directory-symlink preserves symlinks like /lib -> /usr/lib
        tar -C "$src" -c . | tar -C "$dst" -x --keep-directory-symlink 2>/dev/null || true
    else
        # This is a meta-package directory with subdirs that are package names
        # Recursively process each subdirectory
        for subdir in "$src"/*; do
            if [ -d "$subdir" ] || [ -L "$subdir" ]; then
                merge_package "$subdir"
            fi
        done
    fi
}

# Copy packages
for pkg_dir in "$@"; do
    if [ -d "$pkg_dir" ] || [ -L "$pkg_dir" ]; then
        merge_package "$pkg_dir"
    fi
done

# Fix merged-usr layout: if /bin, /sbin, /lib ended up as directories instead of symlinks,
# move their contents to /usr and recreate symlinks
if [ -d "$ROOTFS/bin" ] && [ ! -L "$ROOTFS/bin" ]; then
    mkdir -p "$ROOTFS/usr/bin"
    cp -a "$ROOTFS/bin/"* "$ROOTFS/usr/bin/" 2>/dev/null || true
    rm -rf "$ROOTFS/bin"
    ln -s usr/bin "$ROOTFS/bin"
fi
if [ -d "$ROOTFS/sbin" ] && [ ! -L "$ROOTFS/sbin" ]; then
    mkdir -p "$ROOTFS/usr/sbin"
    cp -a "$ROOTFS/sbin/"* "$ROOTFS/usr/sbin/" 2>/dev/null || true
    rm -rf "$ROOTFS/sbin"
    ln -s usr/sbin "$ROOTFS/sbin"
fi
if [ -d "$ROOTFS/lib" ] && [ ! -L "$ROOTFS/lib" ]; then
    mkdir -p "$ROOTFS/usr/lib"
    cp -a "$ROOTFS/lib/"* "$ROOTFS/usr/lib/" 2>/dev/null || true
    rm -rf "$ROOTFS/lib"
    ln -s usr/lib "$ROOTFS/lib"
fi

# Fix /var/run and /var/lock symlinks: if they ended up as directories, move contents and recreate symlinks
if [ -d "$ROOTFS/var/run" ] && [ ! -L "$ROOTFS/var/run" ]; then
    mkdir -p "$ROOTFS/run"
    cp -a "$ROOTFS/var/run/"* "$ROOTFS/run/" 2>/dev/null || true
    rm -rf "$ROOTFS/var/run"
    ln -s ../run "$ROOTFS/var/run"
    echo "Fixed /var/run symlink (was directory, moved contents to /run)"
fi
if [ -d "$ROOTFS/var/lock" ] && [ ! -L "$ROOTFS/var/lock" ]; then
    mkdir -p "$ROOTFS/run/lock"
    cp -a "$ROOTFS/var/lock/"* "$ROOTFS/run/lock/" 2>/dev/null || true
    rm -rf "$ROOTFS/var/lock"
    ln -s ../run/lock "$ROOTFS/var/lock"
    echo "Fixed /var/lock symlink (was directory, moved contents to /run/lock)"
fi

# Fix merged-bin layout: systemd recommends /usr/sbin -> bin (merged-bin)
# Merge /usr/sbin into /usr/bin and create symlink
if [ -d "$ROOTFS/usr/sbin" ] && [ ! -L "$ROOTFS/usr/sbin" ]; then
    mkdir -p "$ROOTFS/usr/bin"
    cp -a "$ROOTFS/usr/sbin/"* "$ROOTFS/usr/bin/" 2>/dev/null || true
    rm -rf "$ROOTFS/usr/sbin"
    ln -s bin "$ROOTFS/usr/sbin"
    echo "Merged /usr/sbin into /usr/bin (systemd merged-bin layout)"
fi

# Update /sbin symlink to point to usr/bin (not usr/sbin) for consistency
if [ -L "$ROOTFS/sbin" ]; then
    rm -f "$ROOTFS/sbin"
    ln -s usr/bin "$ROOTFS/sbin"
fi

# Create compatibility symlinks for /bin -> /usr/bin
for cmd in sh bash; do
    if [ -f "$ROOTFS/usr/bin/$cmd" ] && [ ! -e "$ROOTFS/bin/$cmd" ]; then
        ln -sf ../usr/bin/$cmd "$ROOTFS/bin/$cmd"
    fi
done

# Set permissions
chmod 1777 "$ROOTFS/tmp"
chmod 755 "$ROOTFS/root"

# Automatically merge acct-user and acct-group files into /etc/passwd, /etc/group, /etc/shadow
if [ -d "$ROOTFS/usr/share/acct-group" ] || [ -d "$ROOTFS/usr/share/acct-user" ]; then
    echo "Merging system users and groups from acct packages..."

    # Merge groups from acct-group packages
    if [ -d "$ROOTFS/usr/share/acct-group" ]; then
        for group_file in "$ROOTFS/usr/share/acct-group"/*.group; do
            if [ -f "$group_file" ]; then
                group_name=$(cut -d: -f1 "$group_file")
                if ! grep -q "^${group_name}:" "$ROOTFS/etc/group" 2>/dev/null; then
                    cat "$group_file" >> "$ROOTFS/etc/group"
                    echo "  Added group: $group_name"
                fi
            fi
        done
    fi

    # Merge users from acct-user packages
    if [ -d "$ROOTFS/usr/share/acct-user" ]; then
        for passwd_file in "$ROOTFS/usr/share/acct-user"/*.passwd; do
            if [ -f "$passwd_file" ]; then
                user_name=$(cut -d: -f1 "$passwd_file")
                if ! grep -q "^${user_name}:" "$ROOTFS/etc/passwd" 2>/dev/null; then
                    cat "$passwd_file" >> "$ROOTFS/etc/passwd"
                    echo "  Added user: $user_name"
                fi
            fi
        done

        # Merge shadow entries
        for shadow_file in "$ROOTFS/usr/share/acct-user"/*.shadow; do
            if [ -f "$shadow_file" ]; then
                user_name=$(cut -d: -f1 "$shadow_file")
                if [ -f "$ROOTFS/etc/shadow" ]; then
                    if ! grep -q "^${user_name}:" "$ROOTFS/etc/shadow" 2>/dev/null; then
                        cat "$shadow_file" >> "$ROOTFS/etc/shadow"
                    fi
                fi
            fi
        done
    fi

    # Add users to supplementary groups (done AFTER all groups and users are merged)
    if [ -d "$ROOTFS/usr/share/acct-user" ]; then
        for groups_file in "$ROOTFS/usr/share/acct-user"/*.groups; do
            [ -f "$groups_file" ] || continue
            user_name=$(basename "$groups_file" .groups)

            supp_groups=$(cat "$groups_file")
            [ -n "$supp_groups" ] || continue

            IFS=',' read -ra GROUP_ARRAY <<< "$supp_groups"
            for group_name in "${GROUP_ARRAY[@]}"; do
                if ! grep -q "^${group_name}:" "$ROOTFS/etc/group" 2>/dev/null; then
                    continue
                fi

                if grep -q "^${group_name}:.*[:,]${user_name}\\(,\\|[[:space:]]\\|\$\\)" "$ROOTFS/etc/group" 2>/dev/null; then
                    continue
                fi

                awk -F: -v group="$group_name" -v user="$user_name" '
                BEGIN { OFS=":" }
                $1 == group {
                    if ($4 == "") {
                        $4 = user
                    } else {
                        $4 = $4 "," user
                    }
                }
                { print }
                ' "$ROOTFS/etc/group" > "$ROOTFS/etc/group.tmp"

                mv "$ROOTFS/etc/group.tmp" "$ROOTFS/etc/group"
                echo "  Added $user_name to group: $group_name"
            done
        done
    fi
fi

# Run ldconfig to generate dynamic linker cache (ld.so.cache)
if [ -f "$ROOTFS/etc/ld.so.conf" ]; then
    ldconfig -r "$ROOTFS" 2>/dev/null || true
fi
"""

    script = ctx.actions.write("assemble.sh", script_content, is_executable = True)

    cmd = cmd_args(["bash", script, rootfs_dir.as_output()])
    for pkg_dir in pkg_dirs:
        cmd.add(pkg_dir)

    # Write version to a file that contributes to action cache key.
    # Bumping the version forces a rootfs rebuild.
    version_key = ctx.actions.write(
        "version_key.txt",
        "version={}\n".format(ctx.attrs.version),
    )
    cmd.add(cmd_args(hidden = [version_key]))

    # Force deep content tracking of all package directories.
    # Buck2's default directory fingerprinting may not detect changes to
    # files inside directories.  A manifest action computes content
    # hashes so the rootfs cache key changes when any package content
    # changes.
    manifest_script = ctx.actions.write(
        "compute_manifest.sh",
        """\
#!/bin/bash
set -e
OUT="$1"
shift
{
    echo "# Package content manifest for rootfs cache invalidation"
    for pkg_dir in "$@"; do
        if [ -d "$pkg_dir" ]; then
            HASH=$(find "$pkg_dir" -type f -exec stat -c '%n %s %Y' {} \\; 2>/dev/null | LC_ALL=C sort | sha256sum | cut -d' ' -f1)
            echo "$pkg_dir: $HASH"
        fi
    done
} > "$OUT"
""",
        is_executable = True,
    )

    manifest_file = ctx.actions.declare_output("package_manifest.txt")
    manifest_cmd = cmd_args(["bash", manifest_script, manifest_file.as_output()])
    for pkg_dir in pkg_dirs:
        manifest_cmd.add(pkg_dir)

    ctx.actions.run(
        manifest_cmd,
        category = "rootfs_manifest",
        identifier = ctx.attrs.name + "-manifest",
    )

    # Include manifest as hidden input to force cache invalidation
    cmd.add(cmd_args(hidden = [manifest_file]))

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
        "version": attrs.string(default = "1"),
    },
)

# ── initramfs rule ───────────────────────────────────────────────────

def _initramfs_impl(ctx):
    """Create an initramfs cpio archive from a rootfs."""
    # Determine compression command and output suffix
    compression = ctx.attrs.compression
    if compression == "xz":
        compress_cmd = "xz -9 --check=crc32"
    elif compression == "lz4":
        compress_cmd = "lz4 -l -9"
    elif compression == "zstd":
        compress_cmd = "zstd -19"
    else:
        # Default to gzip
        compress_cmd = "gzip -9"

    initramfs_file = ctx.actions.declare_output(ctx.attrs.name + ".cpio." + compression)

    rootfs_dir = ctx.attrs.rootfs[DefaultInfo].default_outputs[0]

    init_path = ctx.attrs.init if ctx.attrs.init else "/sbin/init"

    init_script_src = None
    if ctx.attrs.init_script:
        init_script_src = ctx.attrs.init_script[DefaultInfo].default_outputs[0]

    script = ctx.actions.write(
        "create_initramfs.sh",
        """\
#!/bin/bash
set -e

ROOTFS="$1"
OUTPUT="$(realpath -m "$2")"
INIT_PATH="{init_path}"
INIT_SCRIPT="$3"
mkdir -p "$(dirname "$OUTPUT")"

# Create a temporary directory for initramfs modifications
WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT

# Copy rootfs to work directory
cp -a "$ROOTFS"/* "$WORK"/

# Fix aarch64 library paths - merge lib64 into lib and create symlinks
if [ -d "$WORK/lib64" ] && [ ! -L "$WORK/lib64" ]; then
    mkdir -p "$WORK/lib"
    cp -a "$WORK/lib64/"* "$WORK/lib/" 2>/dev/null || true
    rm -rf "$WORK/lib64"
    ln -sf lib "$WORK/lib64"
fi
if [ -d "$WORK/usr/lib64" ] && [ ! -L "$WORK/usr/lib64" ]; then
    mkdir -p "$WORK/usr/lib"
    cp -a "$WORK/usr/lib64/"* "$WORK/usr/lib/" 2>/dev/null || true
    rm -rf "$WORK/usr/lib64"
    ln -sf lib "$WORK/usr/lib64"
fi

# Install custom init script if provided
if [ -n "$INIT_SCRIPT" ] && [ -f "$INIT_SCRIPT" ]; then
    mkdir -p "$(dirname "$WORK$INIT_PATH")"
    cp "$INIT_SCRIPT" "$WORK$INIT_PATH"
    chmod +x "$WORK$INIT_PATH"
elif [ ! -e "$WORK$INIT_PATH" ]; then
    # Try to find busybox or create a minimal init
    if [ -x "$WORK/bin/busybox" ]; then
        mkdir -p "$WORK/sbin"
        ln -sf /bin/busybox "$WORK/sbin/init"
    elif [ -x "$WORK/bin/sh" ]; then
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

# CRITICAL: Create /init at root for kernel to find
if [ ! -e "$WORK/init" ]; then
    if [ -e "$WORK$INIT_PATH" ]; then
        ln -sf "$INIT_PATH" "$WORK/init"
    elif [ -x "$WORK/sbin/init" ]; then
        ln -sf /sbin/init "$WORK/init"
    elif [ -x "$WORK/bin/sh" ]; then
        cat > "$WORK/init" << 'INIT_EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
exec /bin/sh
INIT_EOF
        chmod +x "$WORK/init"
    fi
fi

# Create the cpio archive
cd "$WORK"
find . -print0 | cpio --null -o -H newc | {compress_cmd} > "$OUTPUT"

echo "Created initramfs: $OUTPUT"
""".format(init_path = init_path, compress_cmd = compress_cmd),
        is_executable = True,
    )

    cmd = cmd_args([
        "bash",
        script,
        rootfs_dir,
        initramfs_file.as_output(),
        init_script_src if init_script_src else "",
    ])

    ctx.actions.run(
        cmd,
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
        "init_script": attrs.option(attrs.dep(), default = None),
    },
)
