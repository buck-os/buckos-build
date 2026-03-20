"""
Standalone download_file macro for BuckOS.

Provides a mirror-aware http_file wrapper that can be used outside
of the package() macro — e.g. in toolchain BUCK files that need to
download source archives directly.
"""

# ── Mirror configuration (same knobs as package.bzl) ──────────────────
_MIRROR_MODE = read_config("mirror", "mode", "upstream")
_MIRROR_BASE_URL = read_config("mirror", "base_url", "")
_MIRROR_VENDOR_DIR = read_config("mirror", "vendor_dir", "")
_MIRROR_PREFIX = read_config("mirror", "prefix", "")
_MIRROR_PARAMS = read_config("mirror", "params", "")
_MIRROR_COMPOUND_EXTS = (".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst", ".tar.lz4", ".tar.lz")

def download_file(
        name,
        urls,
        sha256,
        version = "",
        filename = None,
        visibility = None):
    """Download a file with mirror-aware URL resolution.

    This is the standalone equivalent of the archive download logic
    inside package().  Use it when you need to download a source
    archive without going through the full package() macro.

    Args:
        name:       Target name (typically ending in "-archive").
        urls:       List of upstream URLs.  The first URL is used to
                    derive the filename when filename is not set.
        sha256:     Expected SHA-256 hash of the download.
        version:    Version string, used when constructing mirror
                    filenames.
        filename:   Override the archive filename.  Defaults to the
                    basename of the first URL.
        visibility: Buck2 visibility list.
    """
    if not urls:
        fail("download_file '{}' requires at least one URL".format(name))

    _filename = filename or urls[0].rsplit("/", 1)[-1]

    # Derive a short package name for labels/mirror paths.
    _pkg_name = name.removesuffix("-archive") if name.endswith("-archive") else name

    _dl_labels = ["buckos:download"]
    _dl_host = urls[0].split("://")[-1].split("/")[0]
    _dl_labels.append("buckos:source:" + _dl_host)
    _dl_labels.append("buckos:url:" + urls[0])
    _dl_labels.append("buckos:sig:none")
    _dl_labels.append("buckos:sha256:" + sha256)

    kwargs = {}
    if visibility != None:
        kwargs["visibility"] = visibility

    if _MIRROR_MODE == "vendor" and _MIRROR_VENDOR_DIR:
        native.export_file(
            name = name,
            src = "{}/{}".format(_MIRROR_VENDOR_DIR, _filename),
            labels = _dl_labels,
            **kwargs
        )
    elif _MIRROR_PREFIX:
        _ext = ""
        for _ce in _MIRROR_COMPOUND_EXTS:
            if _filename.endswith(_ce):
                _ext = _ce
                break
        if not _ext:
            _ext = "." + _filename.rsplit(".", 1)[-1] if "." in _filename else ""
        _dl_filename = "{}-{}-{}{}".format(_pkg_name, version, sha256[:12], _ext)

        _url = "{}/{}/{}{}".format(
            _MIRROR_PREFIX,
            _pkg_name[0],
            _dl_filename,
            _MIRROR_PARAMS,
        )

        native.http_file(
            name = name,
            urls = [_url],
            sha256 = sha256,
            out = _dl_filename,
            labels = _dl_labels,
            **kwargs
        )
    else:
        _resolved_urls = []
        if _MIRROR_BASE_URL:
            _resolved_urls.append("{}/{}".format(_MIRROR_BASE_URL, _filename))
        _resolved_urls.extend(urls)
        native.http_file(
            name = name,
            urls = _resolved_urls,
            sha256 = sha256,
            out = _filename,
            labels = _dl_labels,
            **kwargs
        )
