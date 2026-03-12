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
        # Exec toolchain: uses seed's native gcc (host-tools/bin/gcc)
        # for building exec deps (tools that run on the host).  Provides
        # hermetic PATH from host-tools so exec deps don't need host
        # make/lzip/python/etc.
        toolchain_import(
            name = "seed-exec-toolchain",
            archive = archive,
            target_triple = "x86_64-buckos-linux-gnu",
            has_host_tools = True,
            exec_mode = True,
            labels = ["buckos:seed-exec"],
            visibility = ["PUBLIC"],
        )
    else:
        # Source mode: no prebuilt seed, bootstrap from scratch.
        # Mirror stage3-toolchain config so packages get the stage2
        # cross-compiler with sysroot ld-linux + RPATH specs.
        # Host tools (make, sed, etc.) come from per-rule exec_deps
        # via auto_tool_deps in package.bzl.  The dynamic linker
        # comes from the sysroot directly (via gen_specs).
        buckos_bootstrap_toolchain(
            name = "seed-toolchain",
            bootstrap_stage = "//tc/bootstrap/stage2:stage2",
            extra_cflags = ["-march=x86-64-v3"],
            extra_ldflags = [
                "-Wl,-rpath,$ORIGIN/../lib64:$ORIGIN/../lib",
            ],
            visibility = ["PUBLIC"],
        )
        # Exec deps use the same bootstrap toolchain so exec_dep
        # binaries (awk, sed, bash, etc.) use buckos ld-linux and
        # buckos glibc.  Without this, exec_dep tools built against
        # buckos libs fail on hosts with older glibc.
        buckos_bootstrap_toolchain(
            name = "seed-exec-toolchain",
            bootstrap_stage = "//tc/bootstrap/stage2:stage2",
            extra_cflags = ["-march=x86-64-v3"],
            extra_ldflags = [
                "-Wl,-rpath,$ORIGIN/../lib64:$ORIGIN/../lib",
            ],
            visibility = ["PUBLIC"],
        )
