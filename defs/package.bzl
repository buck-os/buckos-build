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
load("//defs/rules:python.bzl", "python_package")
load("//defs/rules:source.bzl", "extract_source")
load("//defs/rules:transforms.bzl", "ima_sign_package", "stamp_package", "strip_package")

# Build rule dispatch table.
# Each build system has a top-level load() and an entry here.
_BUILD_RULES = {
    "autotools": autotools_package,
    "binary": binary_package,
    "cargo": cargo_package,
    "cmake": cmake_package,
    "go": go_package,
    "meson": meson_package,
    "python": python_package,
}

# Transform name -> (rule function, target suffix).
_TRANSFORM_MAP = {
    "strip": (strip_package, "stripped"),
    "stamp": (stamp_package, "stamped"),
    "ima": (ima_sign_package, "signed"),
}

# Fields that are accepted by package() for documentation/compat but
# silently dropped before forwarding to the build rule.
_IGNORED_FIELDS = [
    "signature_required",
    "signature_sha256",
    "gpg_key",
    "gpg_keyring",
    "exclude_patterns",
    "iuse",
    "use_defaults",
    "compat_tags",
    "maintainers",
    "exec_bdepend",
    "bdepend",
    "depend",
    "pdepend",
    "src_unpack",
    "src_test",
    "run_tests",
    "pre_configure",
    "src_configure",
    "src_compile",
    "src_install",
    "post_install",
    "category",
    "slot",
    "bootstrap_sysroot",
    "bootstrap_stage",
    "use_cmake",
    "use_meson",
    "use_cargo",
    # Legacy make_package kwargs
    "make_install_args",
    "config_in_options",
    "cc_as_make_arg",
    "destvar",
    "use_make",
    # Legacy simple_package / binary kwargs
    "build_commands",
    "bins",
    "extract_to",
    "build_cmd",
    "install_cmd",
    "build_env",
    "install_cmds",
    "libs",
    "libdir",
    "srcs",
    "src",
    "packages",
    "cargo_args",
    # Legacy python kwargs
    "build_backend",
    "python_deps",
    "extras",
    # Legacy cmake kwargs
    "use_options",
    "cmake_source_dir",
    # Legacy build system kwargs
    "autoreconf",
    "autoreconf_args",
    "configure_flags",
    "extra_sources",
    "go_build_args",
    "install_args",
    "python",
    "rdepend",
    # "source_subdir" is now forwarded to meson/cmake rules
    "src_prepare",
    "src_subdir",
    "subdir",
    "use_bdepend",
    "use_bootstrap",
    "use_extras",
    # Buck2 built-in (not a rule attr)
    "default_target_platform",
]

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

def _split_flag_value(value):
    """Split a space-separated flag string into a list, pass lists through."""
    if type(value) == "list":
        return value
    if type(value) == "string" and " " in value:
        return value.split(" ")
    return value

def _normalize_use_configure(use_configure):
    """Normalize old-style +/- USE configure to new tuple format.

    Old format:
        {"ssl": "--with-ssl", "-ssl": "--without-ssl"}

    New format:
        {"ssl": ("--with-ssl", "--without-ssl")}

    Also handles the already-correct tuple format passthrough,
    and splits space-separated multi-flag strings into lists.
    """
    result = {}
    negative_keys = {}

    # First pass: collect negative keys
    for key, value in use_configure.items():
        if key.startswith("-"):
            flag = key[1:]  # strip the "-" prefix
            negative_keys[flag] = _split_flag_value(value)

    # Second pass: build normalized dict
    for key, value in use_configure.items():
        if key.startswith("-"):
            continue  # skip, handled via positive key
        if type(value) == "tuple":
            on_val = _split_flag_value(value[0])
            off_val = _split_flag_value(value[1]) if len(value) > 1 else None
            result[key] = (on_val, off_val) if off_val != None else (on_val,)
        else:
            value = _split_flag_value(value)
            off_arg = negative_keys.get(key)
            if off_arg:
                result[key] = (value, off_arg)
            else:
                result[key] = value  # on-arg only, no off-arg

    return result

def _normalize_use_deps(use_deps):
    """Normalize old-style use_deps to new format.

    Handles two old patterns:

    1. List values:
        {"ssl": ["//path:openssl"]}  ->  {"ssl": "//path:openssl"}

    2. Negative flag keys (Gentoo-style):
        {"systemd": "//path:systemd", "-systemd": "//path:eudev"}
        ->  {"systemd": ("//path:systemd", "//path:eudev")}

    A tuple value means (on_dep, off_dep) — include on_dep when flag is
    on, off_dep when flag is off.
    """

    # First pass: unwrap single-element lists
    unwrapped = {}
    for key, value in use_deps.items():
        if type(value) == "list":
            if len(value) == 1:
                unwrapped[key] = value[0]
            elif len(value) > 1:
                unwrapped[key] = value[0]
            # empty list = no dep, skip
        else:
            unwrapped[key] = value

    # Second pass: pair positive and negative keys
    negative_keys = {}
    for key, value in unwrapped.items():
        if key.startswith("-"):
            negative_keys[key[1:]] = value

    result = {}
    for key, value in unwrapped.items():
        if key.startswith("-"):
            continue  # handled via positive key lookup
        off_dep = negative_keys.get(key)
        if off_dep:
            result[key] = (value, off_dep)
        else:
            result[key] = value

    # Handle negative keys without a matching positive key
    for neg_flag, dep in negative_keys.items():
        if neg_flag not in result:
            # No positive key — dep only when flag is off
            result[neg_flag] = (None, dep)

    return result

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
        use_deps:          Dict mapping USE flag name to a dep target
                           (or list of dep targets for backwards compat).
                           Each is expanded via use_dep() and appended to
                           the deps list.
        use_configure:     Dict mapping USE flag name to either a single
                           string (on-arg only), a tuple of two strings
                           (on-arg, off-arg), or old-style separate +/-
                           keys.  Expanded via use_configure_arg() and
                           appended to configure_args.
        patches:           Public patches from the package directory.
        configure_args:    Static configure arguments.
        extra_cflags:      Extra CFLAGS.
        **build_kwargs:    Remaining keyword arguments forwarded to the
                           build rule (source, version, deps, libraries,
                           license, etc.).
    """

    # -- 0. Strip ignored fields -----------------------------------------------
    for field in _IGNORED_FIELDS:
        build_kwargs.pop(field, None)

    # -- 0a. Validate url/sha256 vs local_only --------------------------------
    if local_only:
        if "source" not in build_kwargs and not filename:
            fail("local_only package '{}' requires 'filename' (no url to derive it from)".format(name))
    elif url == None:
        fail("package '{}' requires 'url' (or set local_only = True)".format(name))

    # -- 1. Merge private patch registry ------------------------------------
    all_patches, all_configure_args, all_cflags = _merge_private_registry(
        name,
        patches,
        configure_args,
        extra_cflags,
    )

    # -- 1b. Auto-create source targets from inline parameters --------------
    _filename = filename or (url.rsplit("/", 1)[-1] if url else None)

    if "source" not in build_kwargs:
        _mode = read_config("mirror", "mode", "upstream")
        _mirror_base = read_config("mirror", "base_url", "")
        _vendor_dir = read_config("mirror", "vendor_dir", "")

        if _mode == "vendor" and _vendor_dir:
            native.export_file(
                name = name + "-archive",
                src = "{}/{}".format(_vendor_dir, _filename),
            )
        elif local_only:
            # Stub target that exists in the graph but fails at build time.
            # Allows graph queries (buck2 targets //...) to succeed while
            # making it clear the package needs vendor mode to build.
            native.genrule(
                name = name + "-archive",
                out = _filename,
                cmd = "echo 'ERROR: local_only package \"{}\" requires mirror.mode=vendor (or provide source explicitly)' >&2 && exit 1".format(name),
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
    if url != None:
        build_kwargs.setdefault("src_uri", url)
    if sha256 != None:
        build_kwargs.setdefault("src_sha256", sha256)

    # -- 2. Normalize and resolve USE-conditional deps ----------------------
    normalized_use_deps = _normalize_use_deps(use_deps)
    all_deps = list(build_kwargs.pop("deps", []))
    for flag, dep in normalized_use_deps.items():
        if type(dep) == "tuple":
            on_dep, off_dep = dep
            if on_dep and off_dep:
                # Both on and off deps: select between them
                all_deps += select({
                    "//use/constraints:{}-on".format(flag): [on_dep],
                    "//use/constraints:{}-off".format(flag): [off_dep],
                    "DEFAULT": [off_dep],
                })
            elif on_dep:
                all_deps += use_dep(flag, on_dep)
            else:
                # off_dep only: include when flag is off
                all_deps += select({
                    "//use/constraints:{}-on".format(flag): [],
                    "//use/constraints:{}-off".format(flag): [off_dep],
                    "DEFAULT": [off_dep],
                })
        else:
            all_deps += use_dep(flag, dep)

    # -- 3. Normalize and resolve USE-conditional configure args ------------
    normalized_use_configure = _normalize_use_configure(use_configure)
    for flag, args in normalized_use_configure.items():
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
        "python": "buckos:build:python",
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

    _all_labels = _auto_labels + build_kwargs.pop("labels", [])
    build_kwargs["labels"] = _all_labels

    # -- Remap old kwarg names to new rule attrs ----------------------------
    # cmake_args -> configure_args (cmake rule accepts both)
    if "cmake_args" in build_kwargs and build_rule == "cmake":
        # cmake_args are specific cmake flags; keep configure_args separate
        pass
    if "meson_args" in build_kwargs and build_rule == "meson":
        pass

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
