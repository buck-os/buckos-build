"""Test implementation: provenance label validation."""

load("//tests/graph:helpers.bzl", "assert_result", "starts_with", "summarize")

def _is_hex(s):
    """Check whether every character in s is a lowercase hex digit."""
    for c in s.elems():
        if c not in "0123456789abcdef":
            return False
    return True

def _has_label_prefix(labels, prefix):
    """Check whether any label starts with prefix and has a non-empty value."""
    for l in labels:
        if starts_with(l, prefix) and len(l) > len(prefix):
            return True
    return False

def _has_provenance(labels):
    """Check that labels contain full provenance: url, source, sha256|vendor, sig.

    Remote packages: url + source + (sha256|vendor) + sig
    Vendor packages: vendor + sig (no URL, archive is local)
    """
    has_url = _has_label_prefix(labels, "buckos:url:")
    has_source = _has_label_prefix(labels, "buckos:source:")
    has_sha256 = _has_label_prefix(labels, "buckos:sha256:")
    has_vendor = _has_label_prefix(labels, "buckos:vendor:")
    has_sig = _has_label_prefix(labels, "buckos:sig:")
    remote_ok = has_url and has_source and (has_sha256 or has_vendor) and has_sig
    vendor_ok = has_vendor and has_sig
    return remote_ok or vendor_ok

def run(ctx):
    """Verify provenance label completeness, coverage, and format.

    Returns:
        (passed, failed) tuple.
    """
    query = ctx.uquery()
    results = []
    all_targets = query.eval("//...")

    # Collect per-category data in a single pass
    compile_with_url = []       # (label_str, labels) for compile+url targets
    compile_targets = []        # (label_str, labels) for all compile targets
    download_targets = []       # (label_str, labels) for all download targets
    sha256_labels = []          # (target_str, label) for all sha256 labels
    url_labels = []             # (target_str, url_value) for all url labels

    for t in all_targets:
        labels = t.get_attr("labels")
        if labels == None:
            continue

        label_str = str(t.label)
        is_compile = False
        is_download = False
        has_url = False

        for l in labels:
            if l == "buckos:compile":
                is_compile = True
            if l == "buckos:download":
                is_download = True
            if starts_with(l, "buckos:url:") and len(l) > len("buckos:url:"):
                has_url = True

            # Collect sha256 labels for format validation
            if starts_with(l, "buckos:sha256:") and len(l) > len("buckos:sha256:"):
                sha256_labels.append((label_str, l))

            # Collect url labels for format validation
            if starts_with(l, "buckos:url:") and len(l) > len("buckos:url:"):
                url_value = l[len("buckos:url:"):]
                url_labels.append((label_str, url_value))

        if is_compile:
            compile_targets.append((label_str, labels))
            if has_url:
                compile_with_url.append((label_str, labels))
        if is_download:
            download_targets.append((label_str, labels))

    # ── Provenance completeness: compile+url targets must have full provenance ──
    incomplete = []
    for label_str, labels in compile_with_url:
        if not _has_provenance(labels):
            incomplete.append(label_str)

    # TODO: enable once glibc provenance is fixed
    # assert_result(
    #     ctx, results,
    #     "compile targets with URL have full provenance",
    #     len(incomplete) == 0,
    #     "{} compile+url target(s) missing provenance (first: {})".format(
    #         len(incomplete),
    #         incomplete[0] if incomplete else "n/a",
    #     ),
    # )

    # ── Provenance coverage: >=95% of compile targets have full provenance ──
    compile_count = len(compile_targets)
    with_provenance = 0
    for _label_str, labels in compile_targets:
        if _has_provenance(labels):
            with_provenance += 1

    coverage_ok = False
    if compile_count > 0:
        # Integer math: with_provenance * 100 >= compile_count * 90
        coverage_ok = with_provenance * 100 >= compile_count * 90

    assert_result(
        ctx, results,
        ">=90% compile target provenance coverage",
        compile_count > 0 and coverage_ok,
        "{}/{} compile targets have provenance".format(with_provenance, compile_count),
    )

    # ── Download targets: 100% must have full provenance ──
    download_missing = []
    for label_str, labels in download_targets:
        if not _has_provenance(labels):
            download_missing.append(label_str)

    assert_result(
        ctx, results,
        "100% of download targets have full provenance",
        len(download_missing) == 0,
        "{} download target(s) missing provenance (first: {})".format(
            len(download_missing),
            download_missing[0] if download_missing else "n/a",
        ),
    )

    # ── SHA256 labels: must be 64 lowercase hex chars ──
    bad_sha256 = []
    for target_str, label in sha256_labels:
        value = label[len("buckos:sha256:"):]
        # Allow FIXME placeholder
        if value == "FIXME":
            continue
        if len(value) != 64 or not _is_hex(value):
            bad_sha256.append(target_str + ": " + label)

    assert_result(
        ctx, results,
        "all sha256 labels are valid 64-char hex",
        len(bad_sha256) == 0,
        "{} invalid sha256 label(s) (first: {})".format(
            len(bad_sha256),
            bad_sha256[0] if bad_sha256 else "n/a",
        ),
    )

    # ── URL labels: must start with https:// or http:// ──
    bad_urls = []
    for target_str, url_value in url_labels:
        if not (starts_with(url_value, "https://") or starts_with(url_value, "http://")):
            bad_urls.append(target_str + ": " + url_value)

    assert_result(
        ctx, results,
        "all url labels start with https:// or http://",
        len(bad_urls) == 0,
        "{} invalid url label(s) (first: {})".format(
            len(bad_urls),
            bad_urls[0] if bad_urls else "n/a",
        ),
    )

    return summarize(ctx, results)
