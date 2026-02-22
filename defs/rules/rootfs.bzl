"""
rootfs rule: assemble a root filesystem from packages.
"""

load("//defs:providers.bzl", "KernelInfo")

# ── rootfs rule ──────────────────────────────────────────────────────

def _rootfs_impl(ctx):
    """Assemble a root filesystem from packages."""
    rootfs_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)

    # Collect all package outputs (explicit list only, no auto-resolution)
    pkg_dirs = []
    for pkg in ctx.attrs.packages:
        pkg_dirs.append(pkg[DefaultInfo].default_outputs[0])

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
        # Handle merged-usr: if package has /bin, /sbin, or /lib and destination has them as symlinks,
        # copy the contents into the symlink target instead of trying to replace the symlink
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
# This handles cases where packages create /var/run/* before baselayout's symlink is applied
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

# Note: lib64 handling removed - on x86_64, /lib64/ld-linux-x86-64.so.2 must exist
# aarch64-specific builds should handle lib64 merging in their own assembly if needed

# Fix merged-bin layout: systemd now recommends /usr/sbin -> bin (merged-bin)
# This eliminates the "unmerged-bin" taint
# Merge /usr/sbin into /usr/bin and create symlink
if [ -d "$ROOTFS/usr/sbin" ] && [ ! -L "$ROOTFS/usr/sbin" ]; then
    mkdir -p "$ROOTFS/usr/bin"
    # Move all binaries from /usr/sbin to /usr/bin
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
# Many scripts expect common utilities in /bin (especially /bin/sh)
for cmd in sh bash; do
    if [ -f "$ROOTFS/usr/bin/$cmd" ] && [ ! -e "$ROOTFS/bin/$cmd" ]; then
        ln -sf ../usr/bin/$cmd "$ROOTFS/bin/$cmd"
    fi
done

# Set permissions
chmod 1777 "$ROOTFS/tmp"
chmod 755 "$ROOTFS/root"

# Automatically merge acct-user and acct-group files into /etc/passwd, /etc/group, /etc/shadow
# This processes all installed acct-user and acct-group packages
if [ -d "$ROOTFS/usr/share/acct-group" ] || [ -d "$ROOTFS/usr/share/acct-user" ]; then
    echo "Merging system users and groups from acct packages..."

    # Merge groups from acct-group packages
    if [ -d "$ROOTFS/usr/share/acct-group" ]; then
        for group_file in "$ROOTFS/usr/share/acct-group"/*.group; do
            if [ -f "$group_file" ]; then
                group_name=$(cut -d: -f1 "$group_file")
                # Only add if not already in /etc/group
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
                # Only add if not already in /etc/passwd
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
                # Only add if not already in /etc/shadow
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

            # Read supplementary groups (comma-separated)
            supp_groups=$(cat "$groups_file")
            [ -n "$supp_groups" ] || continue

            # Process each group
            IFS=',' read -ra GROUP_ARRAY <<< "$supp_groups"
            for group_name in "${GROUP_ARRAY[@]}"; do
                # Check if group exists
                if ! grep -q "^${group_name}:" "$ROOTFS/etc/group" 2>/dev/null; then
                    continue
                fi

                # Check if user already in group (avoid duplicates)
                if grep -q "^${group_name}:.*[:,]${user_name}\\(,\\|[[:space:]]\\|\$\\)" "$ROOTFS/etc/group" 2>/dev/null; then
                    continue
                fi

                # Use awk to append user to group members - more reliable than sed
                awk -F: -v group="$group_name" -v user="$user_name" '
                BEGIN { OFS=":" }
                $1 == group {
                    # If members list is empty, just add the user
                    if ($4 == "") {
                        $4 = user
                    } else {
                        # Otherwise append with comma
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
# This ensures shared libraries are found at boot time
if [ -f "$ROOTFS/etc/ld.so.conf" ]; then
    ldconfig -r "$ROOTFS" 2>/dev/null || true
fi

# Note: C.UTF-8 locale is built into glibc and doesn't need generation
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

_rootfs_rule = rule(
    impl = _rootfs_impl,
    attrs = {
        "packages": attrs.list(attrs.dep()),
        "version": attrs.string(default = "1"),
        "labels": attrs.list(attrs.string(), default = []),
    },
)

def rootfs(labels = [], **kwargs):
    _rootfs_rule(labels = labels, **kwargs)
