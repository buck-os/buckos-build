"""
Package convenience macro for BuckOS.

Most package BUCK files call package() instead of invoking build rules and
transform rules directly.  The macro wires up:

  1a. Private patch registry merge  (public patches first, then private)
  1b. Source target creation        (http_file/export_file + extract_source)
  2.  Build rule dispatch           (autotools, cmake, meson, cargo, go, python, binary)
  3.  Transform chain               (strip, stamp, ima -- unconditional or USE-gated)
  4.  Final alias                   (name -> last target in the chain)

All intermediate targets are visible and independently buildable:

    :name-archive    http_file or export_file (downloaded/vendored archive)
    :name-src        extract_source (extracted source directory)
    :name-build      build rule output
    :name-stripped    after strip transform
    :name-stamped    after stamp transform
    :name-signed     after IMA signing transform
    :name            alias to the last target in the chain
"""

load("//defs:empty_registry.bzl", "PATCH_REGISTRY")
load("//defs:use_helpers.bzl", "use_bool", "use_configure_arg", "use_dep", "use_feature")
load("//defs/rules:autotools.bzl", "autotools_package")
load("//defs/rules:binary.bzl", "binary_package")
load("//defs/rules:cargo.bzl", "cargo_package")
load("//defs/rules:cmake.bzl", "cmake_package")
load("//defs/rules:go.bzl", "go_package")
load("//defs/rules:meson.bzl", "meson_package")
load("//defs/rules:perl.bzl", "perl_module")
load("//defs/rules:mozbuild.bzl", "mozbuild_package")
load("//defs/rules:python.bzl", "python_package")
load("//defs/rules:source.bzl", "extract_source")
load("//defs/rules:transforms.bzl", "ima_sign_package", "stamp_package", "strip_package")
load("//tc/bootstrap/host-tools:packages.bzl", "HOST_TOOL_PACKAGES")

# Labels of all packages the seed ships in host-tools.  Used to gate
# explicit host_deps in seed mode — the seed's hermetic PATH provides
# these at runtime, so they don't need to be built as exec_deps.
_SEED_HOST_TOOL_LABELS = HOST_TOOL_PACKAGES

# Build rule dispatch table.
# Each build system has a top-level load() and an entry here.
_BUILD_RULES = {
    "autotools": autotools_package,
    "binary": binary_package,
    "cargo": cargo_package,
    "cmake": cmake_package,
    "go": go_package,
    "meson": meson_package,
    "perl": perl_module,
    "mozbuild": mozbuild_package,
    "python": python_package,
}

# Transform name -> (rule function, target suffix).
_TRANSFORM_MAP = {
    "strip": (strip_package, "stripped"),
    "stamp": (stamp_package, "stamped"),
    "ima": (ima_sign_package, "signed"),
}

# ── Mirror configuration (read once at module load) ──────────────────
_MIRROR_MODE = read_config("mirror", "mode", "upstream")
_MIRROR_BASE_URL = read_config("mirror", "base_url", "")
_MIRROR_VENDOR_DIR = read_config("mirror", "vendor_dir", "")
_MIRROR_PREFIX = read_config("mirror", "prefix", "")
_MIRROR_PARAMS = read_config("mirror", "params", "")
_MIRROR_COMPOUND_EXTS = (".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst", ".tar.lz4", ".tar.lz")

# ── Seed detection (read once at module load) ─────────────────────────
# Seed present: seed_path (local archive) or seed_url (remote).
# When a seed is present, its host-tools/bin provides build tools
# via hermetic PATH.  When absent, tools are built from source.
_HAS_PREBUILT_SEED = bool(
    read_config("buckos", "seed_path", "") or
    read_config("buckos", "seed_url", ""),
)
_SOURCE_MODE = not _HAS_PREBUILT_SEED

# ── Compiler cache configuration (read once at module load) ───────────
_CACHE_MODE = read_config("buckos.cache", "mode", "enabled")
_CACHE_LOCATION = read_config("buckos.cache", "location", "homedir")
_CCACHE_SIZE = read_config("buckos.cache", "ccache_size", "100G")
_CACHE_ENABLED = _CACHE_MODE == "enabled"

def _cache_env(build_rule, name = ""):
    """Return env dict entries for ccache/sccache when caching is enabled."""
    if not _CACHE_ENABLED:
        return {}
    _CACHE_BLOCKLIST = ("ccache", "sccache")
    if name in _CACHE_BLOCKLIST:
        return {}
    ccache_dir = ".buckos/cache/ccache" if _CACHE_LOCATION == "projectdir" else "~/.buckos/caches/ccache"
    env = {
        "BUCKOS_CCACHE": "1",
        "CCACHE_DIR": ccache_dir,
        "CCACHE_COMPILERCHECK": "content",
        "CCACHE_NOHASHDIR": "1",
        "CCACHE_MAXSIZE": _CCACHE_SIZE,
        "CCACHE_SLOPPINESS": "pch_defines,time_macros,include_file_mtime",
    }
    return env


def _merge_private_registry(name, patches, configure_args, extra_cflags):
    """Merge public args with private patch registry entries.

    Public patches come first; private patches are appended.
    Same ordering for configure_args and cflags.

    The PATCH_REGISTRY symbol is loaded from defs/empty_registry.bzl by
    default (empty dict).  Users who maintain private patches create
    patches/registry.bzl and update the load path in a local override,
    or the repo can swap the load target via buckconfig once the patches/
    cell is wired up.
    """
    private = PATCH_REGISTRY.get(name, {})

    all_patches = list(patches) + private.get("patches", [])
    all_configure_args = configure_args + private.get("extra_configure_args", [])
    all_cflags = list(extra_cflags) + private.get("extra_cflags", [])

    return all_patches, all_configure_args, all_cflags



def package(
        name,
        build_rule,
        version,
        url = None,
        sha256 = None,
        local_only = False,
        filename = None,
        strip_components = 1,
        format = None,
        transforms = [],
        use_transforms = {},
        use_deps = {},
        use_configure = {},
        use_features = {},
        patches = [],
        configure_args = [],
        extra_cflags = [],
        exclude_patterns = [],
        **build_kwargs):
    """Create a package target with optional transform chain.

    Args:
        name:              Target name.  The build target is "{name}-build";
                           the final alias is "{name}".
        build_rule:        Build system name: "autotools", "cmake", "meson",
                           "cargo", "go", "python", or "binary".
        version:           Upstream version string.
        url:               Upstream source URL.  Optional when local_only=True.
        sha256:            Source archive sha256.  Optional when local_only=True.
        local_only:        If True, package has no public download URL
                           (vendor/proprietary).  Requires filename and
                           mirror.mode=vendor (or explicit source).
        filename:          Archive filename.  Defaults to the basename of url.
        strip_components:  tar strip-components (default: 1).
        format:            Override archive format auto-detection.
        transforms:        List of transforms always applied in order.
                           Values: "strip", "stamp", "ima".
        use_transforms:    Dict mapping USE flag name to transform name.
                           The transform target is created with
                           enabled = use_bool(flag), so it exists in the
                           graph unconditionally but is a zero-cost
                           passthrough when the flag is off.
        use_deps:          Dict mapping USE flag name to a dep target,
                           a list of dep targets, or a tuple of
                           (on_dep, off_dep).  Appended to deps via
                           select().
        use_configure:     Dict mapping USE flag name to a string
                           (on-arg only), a list, or a tuple of
                           (on-arg, off-arg).  Expanded via
                           use_configure_arg() into configure_args.
        patches:           Public patches from the package directory.
        configure_args:    Static configure arguments.
        extra_cflags:      Extra CFLAGS.
        **build_kwargs:    Remaining keyword arguments forwarded to the
                           build rule (source, version, deps, libraries,
                           license, etc.).
    """

    # -- 0. Validate url/sha256 vs local_only ---------------------------------
    if local_only:
        if "source" not in build_kwargs and not filename:
            fail("local_only package '{}' requires 'filename' (no url to derive it from)".format(name))
    elif url == None and "source" not in build_kwargs:
        fail("package '{}' requires 'url', 'source', or local_only = True".format(name))

    # -- 1. Merge private patch registry ------------------------------------
    all_patches, all_configure_args, all_cflags = _merge_private_registry(
        name,
        patches,
        configure_args,
        extra_cflags,
    )

    # -- 1b. Auto-create source targets from inline parameters --------------
    _filename = filename or (url.rsplit("/", 1)[-1] if url else None)

    _has_source = "source" in build_kwargs

    # Create -archive target when url/sha256 are provided, even if
    # source is already set (e.g. ca-certificates uses source to skip
    # extraction while still needing the mirror-aware download).
    if url and sha256:
        _dl_labels = ["buckos:download"]
        _dl_host = url.split("://")[-1].split("/")[0]
        _dl_labels.append("buckos:source:" + _dl_host)
        _dl_labels.append("buckos:url:" + url)
        _dl_labels.append("buckos:sig:none")
        _dl_labels.append("buckos:sha256:" + sha256)

        if _MIRROR_MODE == "vendor" and _MIRROR_VENDOR_DIR:
            native.export_file(
                name = name + "-archive",
                src = "{}/{}".format(_MIRROR_VENDOR_DIR, _filename),
                labels = _dl_labels,
            )
        elif _MIRROR_PREFIX:
            _ext = ""
            for _ce in _MIRROR_COMPOUND_EXTS:
                if _filename.endswith(_ce):
                    _ext = _ce
                    break
            if not _ext:
                _ext = "." + _filename.rsplit(".", 1)[-1] if "." in _filename else ""
            _dl_filename = "{}-{}-{}{}".format(name, version, sha256[:12], _ext)

            _url = "{}/{}/{}{}".format(
                _MIRROR_PREFIX,
                name[0],
                _dl_filename,
                _MIRROR_PARAMS,
            )

            native.http_file(
                name = name + "-archive",
                urls = [_url],
                sha256 = sha256,
                out = _dl_filename,
                labels = _dl_labels,
            )
        else:
            _urls = []
            if _MIRROR_BASE_URL:
                _urls.append("{}/{}".format(_MIRROR_BASE_URL, _filename))
            _urls.append(url)
            native.http_file(
                name = name + "-archive",
                urls = _urls,
                sha256 = sha256,
                out = _filename,
                labels = _dl_labels,
            )
    elif not _has_source and local_only:
        _dl_labels = ["buckos:download"]
        if local_only and not url:
            _dl_labels.append("buckos:vendor:" + name)
            _dl_labels.append("buckos:sig:none")
        if _MIRROR_MODE == "vendor" and _MIRROR_VENDOR_DIR:
            native.export_file(
                name = name + "-archive",
                src = "{}/{}".format(_MIRROR_VENDOR_DIR, _filename),
                labels = _dl_labels,
            )
        else:
            native.genrule(
                name = name + "-archive",
                out = _filename,
                cmd = "echo 'ERROR: local_only package \"{}\" requires mirror.mode=vendor (or provide source explicitly)' >&2 && exit 1".format(name),
                labels = _dl_labels,
            )

    # Create -src (extraction) and wire it up, unless source is
    # already provided (e.g. for raw files that can't be extracted).
    if not _has_source:
        extract_source(
            name = name + "-src",
            source = ":" + name + "-archive",
            strip_components = strip_components,
            format = format,
            exclude_patterns = exclude_patterns,
        )
        build_kwargs["source"] = ":" + name + "-src"

    # Auto-populate SBOM fields unless explicitly overridden
    build_kwargs.setdefault("version", version)
    if url != None:
        build_kwargs.setdefault("src_uri", url)
    if sha256 != None:
        build_kwargs.setdefault("src_sha256", sha256)

    # -- Auto-create vendor deps for cargo/go packages ----------------------
    # When vendor_deps is a sha256 string (64 hex chars), download the
    # vendor archive from the mirror and create extraction targets.
    # When in vendor mirror mode without explicit vendor_deps, auto-wire
    # from the vendor directory.
    if build_rule in ("cargo", "go") and "vendor_deps" in build_kwargs:
        _vendor_sha = build_kwargs["vendor_deps"]
        if type(_vendor_sha) == "string" and len(_vendor_sha) == 64:
            build_kwargs.pop("vendor_deps")
            if _MIRROR_PREFIX:
                _vendor_filename = "{}-{}-vendor.tar.zst".format(name, version)
                _vendor_labels = ["buckos:download", "buckos:{}-vendor".format(build_rule)]
                _vendor_urls = ["{}/{}/{}{}".format(
                    _MIRROR_PREFIX,
                    _vendor_filename[0].lower(),
                    _vendor_filename,
                    _MIRROR_PARAMS,
                )]
                native.http_file(
                    name = name + "-vendor-archive",
                    urls = _vendor_urls,
                    sha256 = _vendor_sha,
                    out = _vendor_filename,
                    labels = _vendor_labels,
                )
                extract_source(
                    name = name + "-vendor-src",
                    source = ":" + name + "-vendor-archive",
                    strip_components = 0,
                )
                build_kwargs["vendor_deps"] = ":" + name + "-vendor-src"

    if build_rule == "cargo" and "vendor_deps" not in build_kwargs and url and sha256:
        _vendor_filename = "{}-{}-vendor.tar.zst".format(name, version)
        _vendor_labels = ["buckos:download", "buckos:cargo-vendor"]
        _have_vendor = False

        if _MIRROR_MODE == "vendor" and _MIRROR_VENDOR_DIR:
            native.export_file(
                name = name + "-vendor-archive",
                src = "{}/{}".format(_MIRROR_VENDOR_DIR, _vendor_filename),
                labels = _vendor_labels,
            )
            _have_vendor = True

        if _have_vendor:
            extract_source(
                name = name + "-vendor-src",
                source = ":" + name + "-vendor-archive",
                strip_components = 1,
            )
            build_kwargs["vendor_deps"] = ":" + name + "-vendor-src"

    # -- Auto-inject build host tools for isolation from host /usr/bin --------
    # Without this, configure/make/ninja find host python, perl, sh, sed,
    # coreutils, etc.  Host python crashes on ABI mismatches; host tools
    # don't exist on RE.  Inject buckos-built tools so they appear first
    # in PATH via tset_bin_dirs.txt.
    #
    # Blocklist = union of all injected tools' dep closures (prevents cycles).
    # Queried via: buck2 query 'deps(//pkg)' for each tool.
    _TOOL_BLOCKLIST = (
        # The injected tools themselves
        "bash", "perl", "python-host", "python", "make",
        "coreutils", "findutils", "sed", "gawk", "grep",
        "diffutils", "patch", "tar", "gzip", "xz", "bzip2",
        "m4", "pkg-config", "meson", "ninja", "cmake",
        # Compiler cache (prevent self-cycle)
        "ccache",
        # Deps of the above (would create cycles if injected)
        "zlib", "expat", "libffi", "ncurses", "readline", "pcre2",
        "sqlite",  # dep of python-host (_sqlite3)
        "acl", "attr", "libcap", "gettext", "autoconf", "automake", "libtool",
        "libxcrypt", "help2man",
        "fmt", "xxhash",  # deps of ccache
    )

    _CONFIGURABLE_RULES = ("autotools", "meson", "cmake", "mozbuild")
    _auto_tool_deps = []
    if name not in _TOOL_BLOCKLIST and build_rule in _CONFIGURABLE_RULES:
        # Core POSIX utilities (sh, coreutils, text processing)
        _auto_tool_deps.extend([
            "//packages/linux/core/bash:bash",
            "//packages/linux/system/apps/coreutils:coreutils",
            "//packages/linux/system/apps/findutils:findutils",
            "//packages/linux/editors/sed:sed",
            "//packages/linux/editors/gawk:gawk",
            "//packages/linux/editors/grep:grep",
            "//packages/linux/editors/diffutils:diffutils",
            "//packages/linux/editors/patch:patch",
            "//packages/linux/system/apps/tar:tar",
            "//packages/linux/system/libs/compression/gzip:gzip",
            "//packages/linux/system/libs/compression/xz:xz",
            "//packages/linux/system/libs/compression/bzip2:bzip2",
            # Build tool interpreters
            "//packages/linux/lang/python:python-host",
            "//packages/linux/lang/perl:perl",
            # Build system tools
            "//packages/linux/dev-tools/build-systems/m4:m4",
            "//packages/linux/dev-tools/build-systems/make:make",
            "//packages/linux/dev-tools/build-systems/pkg-config:pkg-config",
        ])
    if name not in _TOOL_BLOCKLIST:
        if build_rule in ("meson", "mozbuild"):
            _auto_tool_deps.extend([
                "//packages/linux/dev-tools/build-systems/meson:meson",
                "//packages/linux/dev-tools/build-systems/ninja:ninja",
            ])
        if build_rule == "cmake":
            _auto_tool_deps.extend([
                "//packages/linux/dev-tools/build-systems/cmake:cmake",
                "//packages/linux/dev-tools/build-systems/ninja:ninja",
            ])
        # Compiler caches when [buckos.cache] mode = enabled.
        # ccache for C/C++ (all configurable rules).
        # Separate blocklist for cache tools — ccache's own deps (zstd)
        # must not get ccache injected (cycle), but still get their
        # normal build tools (meson, ninja, etc.).
        _CACHE_BLOCKLIST = _TOOL_BLOCKLIST + ("zstd",)
        if _CACHE_ENABLED and name not in _CACHE_BLOCKLIST and build_rule in _CONFIGURABLE_RULES:
            _auto_tool_deps.append(
                "//packages/linux/dev-tools/dev-utils/ccache:ccache",
            )

    # Auto-inject build host tools.  In source mode, tools must be built
    # as exec_deps since the host may not have them.  With a prebuilt
    # seed, the seed's hermetic PATH provides tools — auto_tool_deps
    # are only needed in source mode.
    raw_host_deps = build_kwargs.pop("host_deps", [])

    # Gate explicit host_deps that the seed already provides.  Without
    # this, packages with e.g. host_deps=["mold", "llvm-native"] force
    # a from-source build of those tools even though the seed ships them.
    # Import the package list to build the gate set.
    if _HAS_PREBUILT_SEED and raw_host_deps and type(raw_host_deps) != "Select":
        _SEED_PROVIDES = {p.split(":")[-1]: True for p in _SEED_HOST_TOOL_LABELS}
        raw_host_deps = [d for d in raw_host_deps if d.split(":")[-1] not in _SEED_PROVIDES]

    # In bootstrap/host-tools mode, ALL host tools come from host PATH —
    # explicit host_deps would create cycles back to seed-exec-toolchain
    # via their exec_dep resolution.
    if _SOURCE_MODE and (type(raw_host_deps) == "Select" or raw_host_deps):
        raw_host_deps = select({
            "//tc/exec:is-bootstrap-mode": [],
            "//tc/exec:is-host-tools-mode": [],
            "DEFAULT": raw_host_deps,
        })

    if _auto_tool_deps:
        if _SOURCE_MODE:
            # In bootstrap/host-tools mode, tools come from host PATH —
            # no exec_deps needed.  Injecting them would create a cycle
            # back through the not-yet-built seed.
            staged_auto_deps = select({
                "//tc/exec:is-bootstrap-mode": [],
                "//tc/exec:is-host-tools-mode": [],
                "DEFAULT": _auto_tool_deps,
            })
        else:
            # With a prebuilt seed, hermetic PATH provides all tools.
            staged_auto_deps = []
        # staged_auto_deps may be a select — always merge it
        if type(raw_host_deps) == "Select":
            all_host_deps = raw_host_deps + staged_auto_deps
        elif raw_host_deps:
            all_host_deps = list(raw_host_deps) + staged_auto_deps
        else:
            all_host_deps = staged_auto_deps
        build_kwargs["host_deps"] = all_host_deps
    elif type(raw_host_deps) == "Select" or raw_host_deps:
        build_kwargs["host_deps"] = raw_host_deps

    # -- 2. Resolve USE-conditional deps -------------------------------------
    raw_deps = build_kwargs.pop("deps", [])
    all_deps = raw_deps if type(raw_deps) == "Select" else list(raw_deps)
    for flag, dep in use_deps.items():
        if type(dep) == "tuple":
            # (on_dep, off_dep) — select between them
            on_dep, off_dep = dep
            all_deps += select({
                "//use/constraints:{}-on".format(flag): [on_dep] if type(on_dep) == "string" else (on_dep or []),
                "//use/constraints:{}-off".format(flag): [off_dep] if type(off_dep) == "string" else (off_dep or []),
                "DEFAULT": [off_dep] if type(off_dep) == "string" else (off_dep or []),
            })
        elif type(dep) == "list":
            # Multiple deps gated on a single flag
            all_deps += select({
                "//use/constraints:{}-on".format(flag): dep,
                "//use/constraints:{}-off".format(flag): [],
                "DEFAULT": [],
            })
        else:
            all_deps += use_dep(flag, dep)

    # -- 3. Resolve USE-conditional configure args ----------------------------
    for flag, args in use_configure.items():
        if type(args) == "tuple" and len(args) == 2:
            all_configure_args += use_configure_arg(flag, args[0], args[1])
        else:
            all_configure_args += use_configure_arg(flag, args)

    # -- 4. Resolve USE-conditional cargo features ---------------------------
    if use_features:
        all_features = list(build_kwargs.pop("features", []))
        for flag, feature in use_features.items():
            all_features += use_feature(flag, feature)
        build_kwargs["features"] = all_features

    # -- Auto-inject labels ------------------------------------------------
    _auto_labels = ["buckos:compile"]
    if local_only:
        _auto_labels.append("buckos:local_only")
    _label_map = {
        "autotools": "buckos:build:autotools",
        "binary": "buckos:build:binary",
        "cmake": "buckos:build:cmake",
        "meson": "buckos:build:meson",
        "cargo": "buckos:build:cargo",
        "go": "buckos:build:go",
        "perl": "buckos:build:perl",
        "python": "buckos:build:python",
        "mozbuild": "buckos:build:mozbuild",
    }
    if build_rule in _label_map:
        _auto_labels.append(_label_map[build_rule])

    # Provenance labels
    if url:
        _host = url.split("://")[-1].split("/")[0]
        _auto_labels.append("buckos:source:" + _host)
        _auto_labels.append("buckos:url:" + url)
        _auto_labels.append("buckos:sig:none")
    if sha256:
        _auto_labels.append("buckos:sha256:" + sha256)

    # USE flag labels: declare available flags (buckos:iuse:FLAG)
    _all_use_flags = {}
    for flag in use_deps.keys():
        _all_use_flags[flag] = True
    for flag in use_configure.keys():
        _all_use_flags[flag] = True
    for flag in use_features.keys():
        _all_use_flags[flag] = True
    for flag in use_transforms.keys():
        _all_use_flags[flag] = True
    for flag in _all_use_flags.keys():
        _auto_labels.append("buckos:iuse:" + flag)

    _all_labels = _auto_labels + build_kwargs.pop("labels", [])
    build_kwargs["labels"] = _all_labels

    # -- Inject compiler cache env vars (ccache/sccache) ---------------------
    _cache = _cache_env(build_rule, name)
    if _cache:
        _existing_env = build_kwargs.pop("env", {})
        # Cache env vars go first, package-specific env can override
        _merged_env = dict(_cache)
        _merged_env.update(_existing_env)
        build_kwargs["env"] = _merged_env

    # -- 4. Create the build target -----------------------------------------
    build_target = name + "-build"
    rule_fn = _BUILD_RULES.get(build_rule)
    if rule_fn == None:
        fail(
            "Unknown or unavailable build_rule '{}'. ".format(build_rule) +
            "Available: {}. ".format(", ".join(_BUILD_RULES.keys())) +
            "Add the rule's load() and _BUILD_RULES entry to defs/package.bzl.",
        )

    rule_fn(
        name = build_target,
        patches = all_patches,
        configure_args = all_configure_args,
        extra_cflags = all_cflags,
        deps = all_deps,
        **build_kwargs
    )

    # -- 5. Create transform chain ------------------------------------------
    #
    # Each transform depends on the previous target.  Unconditional
    # transforms (from `transforms`) are always enabled.  USE-gated
    # transforms (from `use_transforms`) pass enabled = use_bool(flag)
    # so the target always exists but is a zero-cost passthrough when
    # the flag is off.

    prev_target = ":" + build_target

    for t in transforms:
        if t not in _TRANSFORM_MAP:
            fail("Unknown transform '{}'. Known: {}".format(
                t,
                ", ".join(_TRANSFORM_MAP.keys()),
            ))
        rule_fn_t, suffix = _TRANSFORM_MAP[t]
        target_name = name + "-" + suffix
        rule_fn_t(
            name = target_name,
            package = prev_target,
            enabled = True,
        )
        prev_target = ":" + target_name

    for flag, t in use_transforms.items():
        if t not in _TRANSFORM_MAP:
            fail("Unknown transform '{}' for USE flag '{}'. Known: {}".format(
                t,
                flag,
                ", ".join(_TRANSFORM_MAP.keys()),
            ))
        rule_fn_t, suffix = _TRANSFORM_MAP[t]
        target_name = name + "-" + suffix
        rule_fn_t(
            name = target_name,
            package = prev_target,
            enabled = use_bool(flag),
        )
        prev_target = ":" + target_name

    # -- 6. Final alias -----------------------------------------------------
    native.alias(
        name = name,
        actual = prev_target,
    )
