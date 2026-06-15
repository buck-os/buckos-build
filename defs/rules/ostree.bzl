"""ostree_commit rule: turn a built filesystem tree into a content-addressed
ostree commit, reproducibly.

SPEC-006 (atomic image-based updates): each system version is an ostree
commit.  This rule runs the buckos-built `ostree` CLI inside a buck2 action
to commit a rootfs tree into a repo; the commit checksum is byte-stable
across builders (fixed timestamp + normalised ownership), so it can anchor
shared caching and signed releases.

Outputs:
- DefaultInfo: the repo directory (+ the commit-checksum file as other_output).
- OstreeRepoInfo: repo dir, checksum file, and branch for downstream rules.
"""

load("//defs:providers.bzl", "BuildToolchainInfo", "PackageInfo")
load("//defs:toolchain_helpers.bzl", "TOOLCHAIN_ATTRS")
load("//defs/rules:_common.bzl", "add_flag_file", "write_lib_dirs")

OstreeRepoInfo = provider(fields = [
    "repo",    # artifact: the ostree repo directory
    "commit",  # artifact: text file holding the 64-char commit checksum
    "branch",  # str: the ref the commit lives on
])

def _ld_linux(ctx):
    """The seed dynamic loader used to launch the buckos ostree PIE."""
    tc = ctx.attrs._toolchain[BuildToolchainInfo]
    if not tc.sysroot:
        fail("ostree_commit requires a toolchain sysroot (the ld-linux loader)")
    sub = "lib/ld-linux-aarch64.so.1" if tc.target_triple.startswith("aarch64") else "lib64/ld-linux-x86-64.so.2"
    return tc.sysroot.project(sub)

def _ostree_commit_impl(ctx):
    ostree = ctx.attrs.ostree[PackageInfo]
    tree = ctx.attrs.tree[DefaultInfo].default_outputs[0]
    repo = ctx.actions.declare_output("repo", dir = True)
    checksum = ctx.actions.declare_output("commit.checksum")

    cmd = cmd_args(ctx.attrs._ostree_tool[RunInfo])
    cmd.add("--ld-linux", _ld_linux(ctx))
    cmd.add("--ostree", ostree.prefix.project("usr/bin/ostree"))
    cmd.add("--tree", tree)
    cmd.add("--repo", repo.as_output())
    cmd.add("--checksum-out", checksum.as_output())
    cmd.add("--branch", ctx.attrs.branch)
    cmd.add("--subject", ctx.attrs.subject)
    cmd.add("--timestamp", str(ctx.attrs.timestamp))
    cmd.add("--mode", ctx.attrs.mode)
    if ctx.attrs.signing_key:
        cmd.add("--key-file", ctx.attrs.signing_key)
    if ctx.attrs.preserve_xattrs:
        # Real OS commits must keep file capabilities (setuid/security.capability
        # on ping, sudo, ...); fixtures without xattrs leave this off.
        cmd.add("--preserve-xattrs")

    # Dep lib closure -> --library-path.  add_flag_file registers the tset
    # projection as a hidden input, so Buck2 materialises every lib dir
    # (libostree, glib, curl, openssl, util-linux, ...) before ostree runs.
    add_flag_file(cmd, "--lib-dirs-file", write_lib_dirs(ctx, ostree.path_info))

    # Materialise the ostree install prefix (the binary itself).
    cmd.add(cmd_args(hidden = ostree.prefix))

    ctx.actions.run(cmd, category = "ostree_commit", identifier = ctx.attrs.branch)

    return [
        DefaultInfo(default_output = repo, other_outputs = [checksum]),
        OstreeRepoInfo(repo = repo, commit = checksum, branch = ctx.attrs.branch),
    ]

ostree_commit = rule(
    impl = _ostree_commit_impl,
    attrs = {
        "tree": attrs.dep(),
        "ostree": attrs.dep(
            providers = [PackageInfo],
            default = "//packages/linux/system/ostree:ostree",
        ),
        "branch": attrs.string(),
        "subject": attrs.string(default = ""),
        # Fixed commit time (epoch seconds) keeps the checksum reproducible.
        "timestamp": attrs.int(default = 0),
        "mode": attrs.string(default = "archive"),
        "preserve_xattrs": attrs.bool(default = False),
        "signing_key": attrs.option(attrs.source(), default = None),
        "_ostree_tool": attrs.exec_dep(default = "//tools:ostree_helper"),
    } | TOOLCHAIN_ATTRS,
)

# ── ostree_rootfs ─────────────────────────────────────────────────────
# Composable transform: any rootfs tree -> an ostree-shaped tree (immutable
# /usr, /etc as /usr/etc defaults, /var emptied, mutable dirs symlinked into
# /var).  Pure file reshaping (no toolchain), so it composes freely:
#   ostree_commit(tree = ostree_rootfs(<some buckos-rootfs>))
# The normal rootfs rule and its targets are untouched.

def _ostree_rootfs_impl(ctx):
    tree = ctx.attrs.tree[DefaultInfo].default_outputs[0]
    output = ctx.actions.declare_output("ostree-rootfs", dir = True)
    cmd = cmd_args(ctx.attrs._reshape_tool[RunInfo])
    cmd.add("--input", tree)
    cmd.add("--output", output.as_output())
    ctx.actions.run(cmd, category = "ostree_rootfs", identifier = ctx.attrs.name)
    return [DefaultInfo(default_output = output)]

ostree_rootfs = rule(
    impl = _ostree_rootfs_impl,
    attrs = {
        "tree": attrs.dep(),
        "_reshape_tool": attrs.exec_dep(default = "//tools:ostree_rootfs_helper"),
    },
)

# ── ostree_sysroot ────────────────────────────────────────────────────
# Composable: an ostree commit -> a deployed, bootable sysroot tree
# (/ostree repo + stateroot + a checked-out deployment + /boot loader
# entries).  Runs `ostree admin deploy` in a user namespace (build user ->
# uid 0) so the bare-repo import + root-owned checkout work without real root.
# The committed image must contain a kernel (/usr/lib/modules/<kver>/vmlinuz).

def _ostree_sysroot_impl(ctx):
    ostree = ctx.attrs.ostree[PackageInfo]
    repo_info = ctx.attrs.commit[OstreeRepoInfo]
    sysroot = ctx.actions.declare_output("sysroot", dir = True)

    cmd = cmd_args(ctx.attrs._sysroot_tool[RunInfo])
    cmd.add("--ld-linux", _ld_linux(ctx))
    cmd.add("--ostree", ostree.prefix.project("usr/bin/ostree"))
    cmd.add("--commit-repo", repo_info.repo)
    cmd.add("--branch", repo_info.branch)
    cmd.add("--sysroot", sysroot.as_output())
    cmd.add("--os", ctx.attrs.os)
    for karg in ctx.attrs.kargs:
        cmd.add("--karg", karg)

    add_flag_file(cmd, "--lib-dirs-file", write_lib_dirs(ctx, ostree.path_info))
    cmd.add(cmd_args(hidden = ostree.prefix))

    ctx.actions.run(cmd, category = "ostree_sysroot", identifier = ctx.attrs.os)
    return [DefaultInfo(default_output = sysroot)]

ostree_sysroot = rule(
    impl = _ostree_sysroot_impl,
    attrs = {
        "commit": attrs.dep(providers = [OstreeRepoInfo]),
        "ostree": attrs.dep(
            providers = [PackageInfo],
            default = "//packages/linux/system/ostree:ostree",
        ),
        "os": attrs.string(default = "buckos"),
        "kargs": attrs.list(attrs.string(), default = ["rw"]),
        "_sysroot_tool": attrs.exec_dep(default = "//tools:ostree_sysroot_helper"),
    } | TOOLCHAIN_ATTRS,
)
