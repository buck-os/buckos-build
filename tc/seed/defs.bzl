"""Seed toolchain resolution helper."""

def seed_archive_label():
    """Return the label for the seed archive based on buckconfig.

    When buckos.seed_url is set, returns ":seed-archive" (declared by
    the caller as http_file).  When buckos.seed_path is set, returns
    ":seed-local-archive" (declared as export_file).  Otherwise falls
    back to building stage 1 from source (host tools are built
    separately via the stage 2 → stage 3 pipeline).
    """
    url = read_config("buckos", "seed_url", "")
    path = read_config("buckos", "seed_path", "")
    if url:
        return ":seed-archive"
    elif path:
        return ":seed-local-archive"
    else:
        return "//tc/bootstrap:export"
