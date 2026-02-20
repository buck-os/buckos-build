"""
Package convenience macro for BuckOS.

Most package BUCK files call package() instead of invoking build rules and
transform rules directly.  The macro wires up:

  1a. Private patch registry merge  (public patches first, then private)
  1b. Source target creation        (http_file/export_file + extract_source)
  2.  Build rule dispatch           (autotools, cmake, meson, cargo, go)
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
load("//defs:use_helpers.bzl", "use_bool", "use_configure_arg", "use_dep")
load("//defs/rules:autotools.bzl", "autotools_package")
load("//defs/rules:cargo.bzl", "cargo_package")
load("//defs/rules:cmake.bzl", "cmake_package")
load("//defs/rules:go.bzl", "go_package")
load("//defs/rules:meson.bzl", "meson_package")
load("//defs/rules:source.bzl", "extract_source")
load("//defs/rules:transforms.bzl", "ima_sign_package", "stamp_package", "strip_package")

# Build rule dispatch table.
# Each build system has a top-level load() and an entry here.
_BUILD_RULES = {
    "autotools": autotools_package,
    "cargo": cargo_package,
    "cmake": cmake_package,
    "go": go_package,
    "meson": meson_package,
}

# Transform name -> (rule function, target suffix).
_TRANSFORM_MAP = {
    "strip": (strip_package, "stripped"),
    "stamp": (stamp_package, "stamped"),
    "ima": (ima_sign_package, "signed"),
}

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
    all_configure_args = list(configure_args) + private.get("extra_configure_args", [])
    all_cflags = list(extra_cflags) + private.get("extra_cflags", [])

    return all_patches, all_configure_args, all_cflags

def package(
        name,
        build_rule,
        version,
        url,
        sha256,
        filename = None,
        strip_components = 1,
        format = None,
        transforms = [],
        use_transforms = {},
        use_deps = {},
        use_configure = {},
        patches = [],
        configure_args = [],
        extra_cflags = [],
        **build_kwargs):
    """Create a package target with optional transform chain.

    Args:
        name:              Target name.  The build target is "{name}-build";
                           the final alias is "{name}".
        build_rule:        Build system name: "autotools", "cmake", "meson",
                           "cargo", or "go".
        version:           Upstream version string.
        url:               Upstream source URL.
        sha256:            Source archive sha256.
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
        use_deps:          Dict mapping USE flag name to a dep target.
                           Each is expanded via use_dep() and appended to
                           the deps list.
        use_configure:     Dict mapping USE flag name to either a single
                           string (on-arg only) or a tuple of two strings
                           (on-arg, off-arg).  Expanded via
                           use_configure_arg() and appended to
                           configure_args.
        patches:           Public patches from the package directory.
        configure_args:    Static configure arguments.
        extra_cflags:      Extra CFLAGS.
        **build_kwargs:    Remaining keyword arguments forwarded to the
                           build rule (source, version, deps, libraries,
                           license, etc.).
    """

    # -- 1. Merge private patch registry ------------------------------------
    all_patches, all_configure_args, all_cflags = _merge_private_registry(
        name,
        patches,
        configure_args,
        extra_cflags,
    )

    # -- 1b. Auto-create source targets from inline parameters --------------
    _filename = filename or url.rsplit("/", 1)[-1]

    if "source" not in build_kwargs:
        _mode = read_config("mirror", "mode", "upstream")
        _mirror_base = read_config("mirror", "base_url", "")
        _vendor_dir = read_config("mirror", "vendor_dir", "")

        if _mode == "vendor" and _vendor_dir:
            native.export_file(
                name = name + "-archive",
                src = "{}/{}".format(_vendor_dir, _filename),
            )
        else:
            _urls = []
            if _mirror_base:
                _urls.append("{}/{}".format(_mirror_base, _filename))
            _urls.append(url)

            native.http_file(
                name = name + "-archive",
                urls = _urls,
                sha256 = sha256,
                out = _filename,
            )

        extract_source(
            name = name + "-src",
            source = ":" + name + "-archive",
            strip_components = strip_components,
            format = format,
        )
        build_kwargs["source"] = ":" + name + "-src"

    # Auto-populate SBOM fields unless explicitly overridden
    build_kwargs.setdefault("version", version)
    build_kwargs.setdefault("src_uri", url)
    build_kwargs.setdefault("src_sha256", sha256)

    # -- 2. Resolve USE-conditional deps ------------------------------------
    all_deps = list(build_kwargs.pop("deps", []))
    for flag, dep in use_deps.items():
        all_deps += use_dep(flag, dep)

    # -- 3. Resolve USE-conditional configure args --------------------------
    for flag, args in use_configure.items():
        if type(args) == "tuple" and len(args) == 2:
            all_configure_args += use_configure_arg(flag, args[0], args[1])
        else:
            all_configure_args += use_configure_arg(flag, args)

    # -- Auto-inject labels ------------------------------------------------
    _auto_labels = ["buckos:compile"]
    _label_map = {
        "autotools": "buckos:build:autotools",
        "cmake": "buckos:build:cmake",
        "meson": "buckos:build:meson",
        "cargo": "buckos:build:cargo",
        "go": "buckos:build:go",
    }
    if build_rule in _label_map:
        _auto_labels.append(_label_map[build_rule])

    _all_labels = _auto_labels + build_kwargs.pop("labels", [])
    build_kwargs["labels"] = _all_labels

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
        visibility = ["PUBLIC"],
    )
