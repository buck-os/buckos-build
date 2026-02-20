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
])

BootstrapStageInfo = provider(fields = [
    "stage",            # int: 1, 2, or 3
    "cc",               # artifact: the C compiler binary
    "cxx",              # artifact: the C++ compiler binary
    "ar",               # artifact
    "sysroot",          # artifact
    "target_triple",    # str
])
