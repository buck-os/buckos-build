"""Optional offline cargo registry archive for the buckos Rust tools.

crates.io is unreachable in network-isolated / remote-execution builds, so
buckos-cli / buckos-installer (which shell out to raw `cargo build`) can build
against a mirror-hosted cargo registry snapshot (registry cache + index)
instead of fetching from the network.

OPT-IN: the targets are only defined when `buckos.cargo_registry_sha256` is
set, in which case the archive is fetched from the configured mirror (by
content hash) and extracted as a buck input.  When unset (the default), no
targets are defined and the tools just `cargo build` from the network.

Generate/publish the archive with scripts/gen-cargo-registry.sh, then set
`buckos.cargo_registry_sha256` to its sha256.
"""

load("//defs:download.bzl", "download_file")
load("//defs/rules:source.bzl", "extract_source")

def cargo_registry_targets(name, version):
    """Define <name>-archive + <name>-src when an offline registry is configured.

    No-op (defines nothing) when buckos.cargo_registry_sha256 is unset, so
    consumers must gate their `cargo_registry =` reference on the same config.
    """
    sha256 = read_config("buckos", "cargo_registry_sha256", "")
    if not sha256:
        return
    filename = "{}-{}.tar.zst".format(name, version)
    download_file(
        name = name + "-archive",
        urls = ["https://buckos.invalid/" + filename],
        sha256 = sha256,
        version = version,
        out = filename,
    )
    extract_source(
        name = name + "-src",
        source = ":" + name + "-archive",
        strip_components = 0,
    )
