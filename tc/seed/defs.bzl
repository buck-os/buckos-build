"""Seed toolchain resolution helper."""

load("//tc:toolchain_rules.bzl", "buckos_bootstrap_toolchain")
load("//defs/rules:toolchain_import.bzl", "toolchain_import")

def seed_toolchain():
    """Declare the seed-toolchain target based on .buckconfig.

    When a prebuilt seed is configured (seed_url or seed_path),
    declares a toolchain_import that unpacks the archive into a
    BuildToolchainInfo with hermetic host tools.

    When building from source (neither configured), declares a
    buckos_bootstrap_toolchain wrapping stage 1 with host PATH.
    The full seed archive (//tc/bootstrap:seed-export) must be
    built explicitly — it cannot be the seed-toolchain dep because
    seed-export → host-tools → packages → seed-toolchain would
    create a configured target cycle.
    """
    url = read_config("buckos", "seed_url", "")
    path = read_config("buckos", "seed_path", "")
    if url:
        archive = ":seed-archive"
    elif path:
        archive = ":seed-local-archive"
    else:
        archive = None

    if archive:
        toolchain_import(
            name = "seed-toolchain",
            archive = archive,
            target_triple = "x86_64-buckos-linux-gnu",
            has_host_tools = True,
            extra_cflags = ["-march=x86-64-v3"],
            labels = ["buckos:seed"],
            visibility = ["PUBLIC"],
        )
    else:
        buckos_bootstrap_toolchain(
            name = "seed-toolchain",
            bootstrap_stage = "//tc/bootstrap/stage1:stage1",
            extra_cflags = ["-march=x86-64-v3"],
            visibility = ["PUBLIC"],
        )
