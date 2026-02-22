"""
Typed providers for BuckOS package rules.

PackageInfo is the contract between packages: every package rule returns it.
BuildToolchainInfo is provided by toolchain rules in the tc/ subcell.
BootstrapStageInfo is returned by bootstrap stage rules.
"""

PackageInfo = provider(fields = [
    # Identity
    "name",             # str
    "version",          # str

    # Build outputs
    "prefix",           # artifact: the install prefix directory
    "include_dirs",     # list[artifact]: paths to installed headers
    "lib_dirs",         # list[artifact]: paths to installed libraries
    "bin_dirs",         # list[artifact]: paths to installed binaries
    "libraries",        # list[str]: library names for -l flags
    "pkg_config_path",  # artifact | None: path to .pc files

    # Extra flags this package requires consumers to use
    "cflags",           # list[str]
    "ldflags",          # list[str]

    # SBOM metadata
    "license",          # str: SPDX expression ("MIT", "GPL-2.0-only", "Apache-2.0 OR MIT")
    "src_uri",          # str: upstream source URL
    "src_sha256",       # str: source archive checksum
    "homepage",         # str | None
    "supplier",         # str: default "Organization: BuckOS"
    "description",      # str
    "cpe",              # str | None: CPE identifier for vulnerability matching
])

BuildToolchainInfo = provider(fields = [
    "cc",               # RunInfo
    "cxx",              # RunInfo
    "ar",               # RunInfo
    "strip",            # RunInfo
    "make",             # RunInfo
    "pkg_config",       # RunInfo
    "target_triple",    # str
    "sysroot",          # artifact | None: buckos-built sysroot (musl/glibc headers + libs)
    "python",           # RunInfo | None: bootstrap Python interpreter
    "extra_cflags",     # list[str]: toolchain-injected CFLAGS (e.g. hardening flags)
    "extra_ldflags",    # list[str]: toolchain-injected LDFLAGS (e.g. -fuse-ld=mold)
])

BootstrapStageInfo = provider(fields = [
    "stage",            # int: 1, 2, or 3
    "cc",               # artifact: the C compiler binary
    "cxx",              # artifact: the C++ compiler binary
    "ar",               # artifact
    "sysroot",          # artifact
    "target_triple",    # str
    "python",           # artifact | None: bootstrap Python interpreter
    "python_version",   # str | None: Python version (e.g., "3.12.1")
])

# ── Kernel providers ────────────────────────────────────────────────

KernelInfo = provider(fields = [
    "vmlinux",          # artifact: uncompressed kernel ELF (with BTF if CONFIG_DEBUG_INFO_BTF=y)
    "bzimage",          # artifact: compressed bootable image
    "modules_dir",      # artifact: built module tree (lib/modules/<version>/)
    "build_tree",       # artifact: full build tree for out-of-tree module compilation
    "module_symvers",   # artifact: Module.symvers for module ABI checking
    "config",           # artifact: the finalized .config
    "headers",          # artifact: installed kernel headers tree
    "version",          # str: kernel version string (e.g. 6.12.0-buckos)
])

KernelHeadersInfo = provider(fields = [
    "headers",          # artifact: installed headers tree (usr/include/)
    "version",          # str: kernel version string
])

KernelConfigInfo = provider(fields = [
    "config",           # artifact: finalized .config file
    "version",          # str: kernel version string
])

KernelBtfInfo = provider(fields = [
    "vmlinux_h",        # artifact: vmlinux.h generated from kernel BTF data (for BPF CO-RE)
    "version",          # str: kernel version string
])

# ── Image providers ────────────────────────────────────────────────

Stage3Info = provider(fields = [
    "tarball",          # artifact: the stage3 tarball
    "checksum",         # artifact: sha256 checksum file
    "contents",         # artifact: CONTENTS.gz listing
    "arch",             # str: architecture (amd64, arm64)
    "variant",          # str: variant (minimal, base, developer, complete)
    "libc",             # str: C library (glibc, musl)
    "version",          # str: version string
])

# ── Language toolchain providers ──────────────────────────────────

GoToolchainInfo = provider(fields = {
    "goroot": provider_field(typing.Any),  # Artifact: Go installation root
    "version": provider_field(str),
})

RustToolchainInfo = provider(fields = {
    "rust_root": provider_field(typing.Any),  # Artifact: Rust installation root
    "version": provider_field(str),
})
