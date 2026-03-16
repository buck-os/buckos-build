"""Test implementation: verify no duplicate download sources.

Ensures that when multiple targets share the same sha256 (same upstream
archive), there is exactly one canonical download target.  Duplicate
download names cause the mirror syncer to upload under the wrong path.
"""

load("//tests/graph:helpers.bzl", "assert_result", "summarize")

def run(ctx):
    """Scan all http_file archive targets for sha256 collisions.

    Two targets with different names but the same sha256 indicate the
    same upstream archive is downloaded under multiple names — the
    mirror naming scheme (name-version-hash.ext) would produce
    different filenames for the same content.

    Returns:
        (passed, failed, fail_details) tuple.
    """
    query = ctx.uquery()
    results = []

    # Find all targets under packages// and tc//
    all_targets = query.eval("//packages/... + //tc/...")

    # Collect sha256 -> list of (target_label, name) for archive targets
    by_sha = {}
    for target in all_targets:
        name = str(target.label.name)
        if not name.endswith("-archive"):
            continue

        sha256 = target.get_attr("sha256")
        if not sha256 or sha256 == "":
            continue

        label = str(target.label)
        pkg_name = name[:-len("-archive")]

        if sha256 not in by_sha:
            by_sha[sha256] = []
        by_sha[sha256].append((label, pkg_name))

    # Check for collisions: same sha256, different package names
    for sha256, entries in by_sha.items():
        if len(entries) <= 1:
            continue

        names = [pkg_name for _, pkg_name in entries]
        unique_names = {}
        for n in names:
            unique_names[n] = True

        if len(unique_names) > 1:
            labels_str = ", ".join([l for l, _ in entries])
            names_str = ", ".join(unique_names.keys())
            assert_result(
                ctx, results,
                "sha256 {} has unique download name".format(sha256[:12]),
                False,
                "same archive downloaded under multiple names [{}]: {}".format(
                    names_str, labels_str,
                ),
            )
        else:
            assert_result(
                ctx, results,
                "sha256 {} consistent name ({})".format(
                    sha256[:12], names[0],
                ),
                True,
                "",
            )

    assert_result(
        ctx, results,
        "source dedup scan completed ({} unique archives)".format(len(by_sha)),
        True,
        "",
    )

    # ── Verify packages// never depends on tc// source targets ──────
    # tc/bootstrap will be dropped on subcell import, so packages//
    # must not reference tc// -src or -archive targets.
    pkg_targets = query.eval("//packages/...")
    tc_src_violations = []
    for target in pkg_targets:
        label = str(target.label)
        for attr_name in ("source", "actual"):
            attr_val = target.get_attr(attr_name)
            if attr_val == None:
                continue
            attr_str = str(attr_val)
            if "//tc/" in attr_str and ("-src" in attr_str or "-archive" in attr_str):
                tc_src_violations.append((label, attr_name, attr_str))

    for label, attr_name, attr_str in tc_src_violations:
        assert_result(
            ctx, results,
            "{} does not use tc// source".format(label),
            False,
            "attr {} references tc// source: {}".format(attr_name, attr_str),
        )

    if not tc_src_violations:
        assert_result(
            ctx, results,
            "no packages// -> tc// source dependencies",
            True,
            "",
        )

    # ── Verify no raw http_file targets in packages// ────────────────
    # All downloads must go through package() for mirror support.
    # http_file targets bypass the mirror prefix configuration.
    raw_http_files = []
    for target in pkg_targets:
        label = str(target.label)
        # http_file targets have "urls" attr but not "src_uri".
        # package()-created archives have a "buckos:download" label.
        urls = target.get_attr("urls")
        src_uri = target.get_attr("src_uri")
        if urls and not src_uri:
            labels = target.get_attr("labels")
            has_download_label = False
            if labels:
                for l in labels:
                    if l == "buckos:download":
                        has_download_label = True
            if not has_download_label:
                raw_http_files.append(label)

    for label in raw_http_files:
        assert_result(
            ctx, results,
            "{} is not a raw http_file".format(label),
            False,
            "raw http_file in packages// bypasses mirror; use package() instead",
        )

    if not raw_http_files:
        assert_result(
            ctx, results,
            "no raw http_file targets in packages//",
            True,
            "",
        )

    return summarize(ctx, results)
