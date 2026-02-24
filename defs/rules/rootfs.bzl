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

    # Build rootfs_helper command
    cmd = cmd_args(ctx.attrs._rootfs_tool[RunInfo])
    cmd.add("--output-dir", rootfs_dir.as_output())
    for pkg_dir in pkg_dirs:
        cmd.add("--package-dir", pkg_dir)
    cmd.add("--version", ctx.attrs.version)

    # Write version to a file that contributes to action cache key.
    # Bumping the version forces a rootfs rebuild.
    version_key = ctx.actions.write(
        "version_key.txt",
        "version={}\n".format(ctx.attrs.version),
    )
    cmd.add(cmd_args(hidden = [version_key]))

    # Force deep content tracking of all package directories.
    # A manifest action computes content hashes so the rootfs cache key
    # changes when any package content changes.
    manifest_file = ctx.actions.declare_output("package_manifest.txt")
    manifest_cmd = cmd_args(ctx.attrs._rootfs_tool[RunInfo])
    manifest_cmd.add("--output-dir", rootfs_dir)
    manifest_cmd.add("--manifest-output", manifest_file.as_output())
    for pkg_dir in pkg_dirs:
        manifest_cmd.add("--package-dir", pkg_dir)

    # Use a lightweight bash command for the manifest since the Python
    # helper needs to build the full rootfs; compute it separately.
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

    manifest_cmd2 = cmd_args(["bash", manifest_script, manifest_file.as_output()])
    for pkg_dir in pkg_dirs:
        manifest_cmd2.add(pkg_dir)

    ctx.actions.run(
        manifest_cmd2,
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
        "_rootfs_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:rootfs_helper"),
        ),
    },
)

def rootfs(labels = [], **kwargs):
    _rootfs_rule(labels = labels, **kwargs)
