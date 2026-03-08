"""Seed toolchain resolution helper."""

load("//tc:toolchain_rules.bzl", "buckos_bootstrap_toolchain")
load("//defs/rules:toolchain_import.bzl", "toolchain_import")

def maybe_export_seed():
    """Conditionally export the local seed archive at the root package level.

    Called from the root BUCK file.  Declares export_file(name=seed_path)
    so that //:<seed_path> is a valid label for tc/seed:seed-toolchain to
    depend on.  No-op when seed_path is not configured.
    """
    path = read_config("buckos", "seed_path", "")
    if path:
        native.export_file(
            name = path,
            visibility = ["PUBLIC"],
        )

def seed_toolchain():
    """Declare the seed-toolchain target based on .buckconfig.

    Priority (highest first):
      1. buckos.source_mode = true  — force bootstrap regardless of seed config
      2. buckos.seed_path           — local archive (export_file)
      3. buckos.seed_url            — remote download (http_file)
      4. neither                    — bootstrap from source (stage 1 cross-compiler)

    The full seed archive (//tc/bootstrap:seed-export) must be built
    explicitly — it cannot be the seed-toolchain dep because
    seed-export → host-tools → packages → seed-toolchain creates a
    configured target cycle.
    """
    source_mode = read_config("buckos", "source_mode", "") in ("true", "1", "yes")
    url = read_config("buckos", "seed_url", "")
    path = read_config("buckos", "seed_path", "")

    if source_mode:
        archive = None
    elif path:
        archive = "//:" + path
    elif url:
        native.http_file(
            name = "seed-archive",
            urls = [url],
            sha256 = read_config("buckos", "seed_sha256", ""),
            out = "buckos-seed.tar.zst",
        )
        archive = ":seed-archive"
    else:
        archive = None

    if archive:
        native.alias(
            name = "seed-archive-ref",
            actual = archive,
            visibility = ["PUBLIC"],
        )
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
