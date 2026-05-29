"""
download_file macro: mirror-aware wrapper around http_file.

Drop-in replacement for native.http_file() that routes through the
configured mirror when mirror.prefix is set in .buckconfig.

Mirror naming convention (matches package.bzl):
    {prefix}/{first_char}/{name}-{version}-{sha256[:12]}{ext}

Usage:
    load("//defs:download.bzl", "download_file")

    download_file(
        name = "foo-archive",
        urls = ["https://example.com/foo-1.0.tar.gz"],
        sha256 = "abc123...",
        version = "1.0",
    )
"""

_MIRROR_MODE = read_config("mirror", "mode", "upstream")
_MIRROR_PREFIX = read_config("mirror", "prefix", "")
_MIRROR_PARAMS = read_config("mirror", "params", "")
_MIRROR_BASE_URL = read_config("mirror", "base_url", "")
_MIRROR_VENDOR_DIR = read_config("mirror", "vendor_dir", "")
_COMPOUND_EXTS = (".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst", ".tar.lz4", ".tar.lz")

def download_file(name, urls, sha256, version = "", out = None, labels = None, **kwargs):
    """Download a file, using the configured mirror when available.

    Args:
        name:    Target name (conventionally ends with -archive).
        urls:    List of upstream URLs (first is used for filename derivation).
        sha256:  Expected SHA256 hash.
        version: Package version (used in mirror filename).
        out:     Output filename override.
        labels:  Target labels.
        **kwargs: Forwarded to http_file.
    """
    _filename = out or (urls[0].rsplit("/", 1)[-1] if urls else None)
    _labels = labels or []

    # Strip -archive suffix for mirror path derivation
    _base_name = name
    if _base_name.endswith("-archive"):
        _base_name = _base_name[:-8]

    if _MIRROR_MODE == "vendor" and _MIRROR_VENDOR_DIR:
        native.export_file(
            name = name,
            src = "{}/{}".format(_MIRROR_VENDOR_DIR, _filename),
            labels = _labels,
        )
    elif _MIRROR_PREFIX and version and sha256:
        _ext = ""
        for _ce in _COMPOUND_EXTS:
            if _filename and _filename.endswith(_ce):
                _ext = _ce
                break
        if not _ext and _filename and "." in _filename:
            _ext = "." + _filename.rsplit(".", 1)[-1]
        _dl_filename = "{}-{}-{}{}".format(_base_name, version, sha256[:12], _ext)

        _url = "{}/{}/{}{}".format(
            _MIRROR_PREFIX,
            _dl_filename[0].lower(),
            _dl_filename,
            _MIRROR_PARAMS,
        )

        native.http_file(
            name = name,
            urls = [_url],
            sha256 = sha256,
            out = _dl_filename,
            labels = _labels,
            **kwargs
        )
    else:
        _urls = []
        if _MIRROR_BASE_URL and _filename:
            _urls.append("{}/{}".format(_MIRROR_BASE_URL, _filename))
        _urls.extend(urls)
        native.http_file(
            name = name,
            urls = _urls,
            sha256 = sha256,
            out = _filename or (urls[0].rsplit("/", 1)[-1] if urls else "download"),
            labels = _labels,
            **kwargs
        )
