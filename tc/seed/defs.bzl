"""Seed toolchain resolution helper."""

load("//tc:toolchain_rules.bzl", "buckos_bootstrap_toolchain", "buckos_toolchain")
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
      1. buckos.seed_path  — local archive (export_file)
      2. buckos.seed_url   — remote URL (http_file)
      3. neither           — bootstrap from source (stage 1 cross-compiler)

    The full seed archive (//tc/bootstrap:seed-export) must be built
    explicitly — it cannot be the seed-toolchain dep because
    seed-export → host-tools → packages → seed-toolchain creates a
    configured target cycle.
    """
    path = read_config("buckos", "seed_path", "")
    url = read_config("buckos", "seed_url", "")

    if path:
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

    _triple = select({
        "//platforms:is_aarch64": "aarch64-buckos-linux-gnu",
        "DEFAULT": "x86_64-buckos-linux-gnu",
    })
    _march = select({
        "//platforms:is_aarch64": [],
        "DEFAULT": ["-march=x86-64-v3"],
    })

    if archive:
        native.alias(
            name = "seed-archive-ref",
            actual = archive,
            visibility = ["PUBLIC"],
        )
        toolchain_import(
            name = "seed-toolchain",
            archive = archive,
            target_triple = _triple,
            has_host_tools = True,
            extra_cflags = _march,
            labels = ["buckos:seed"],
            visibility = ["PUBLIC"],
        )
        # Exec toolchain: uses seed's native gcc (host-tools/bin/gcc)
        # for building exec deps (tools that run on the host).  Provides
        # hermetic PATH from host-tools so exec deps don't need host
        # make/lzip/python/etc.
        toolchain_import(
            name = "seed-exec-toolchain",
            archive = archive,
            target_triple = _triple,
            has_host_tools = True,
            exec_mode = True,
            labels = ["buckos:seed-exec"],
            visibility = ["PUBLIC"],
        )
    else:
        # Source mode: no prebuilt seed, bootstrap from scratch.
        # Uses stage2 cross-compiler with sysroot ld-linux + RPATH specs.
        # Host tools (make, sed, bash, etc.) come from host-tools-exec
        # (bootstrap-built, interpreter-patched).  allows_host_path = False
        # because host_tools is provided — no host fallback, fully hermetic.
        #
        # The host-tools-aggregator uses bootstrap_transition to build its
        # packages with the host-PATH toolchain, breaking the cycle:
        # seed-toolchain → host-tools-exec → host-tools → packages →
        # (bootstrap-toolchain, not seed-toolchain).
        buckos_bootstrap_toolchain(
            name = "seed-toolchain",
            bootstrap_stage = "//tc/bootstrap/stage2:stage2",
            host_tools = "//tc/bootstrap:host-tools-exec",
            extra_cflags = _march,
            extra_ldflags = [
                "-Wl,-rpath,$ORIGIN/../lib64:$ORIGIN/../lib",
            ],
            visibility = ["PUBLIC"],
        )
        buckos_bootstrap_toolchain(
            name = "seed-exec-toolchain",
            bootstrap_stage = "//tc/bootstrap/stage2:stage2",
            host_tools = "//tc/bootstrap:host-tools-exec",
            extra_cflags = _march,
            extra_ldflags = [
                "-Wl,-rpath,$ORIGIN/../lib64:$ORIGIN/../lib",
            ],
            visibility = ["PUBLIC"],
        )
