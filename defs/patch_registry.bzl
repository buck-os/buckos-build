"""
Private Patch Registry for BuckOS.

Maps Buck2 targets to private patches and build overrides.
Users maintain a private patches/registry.bzl (gitignored) to
apply custom patches without modifying the open-source build graph.

Usage in .buckconfig (optional):
    [buckos]
    patch_registry_enabled = false   # To disable all registry patches

The registry maps package names to override configs:

    # patches/registry.bzl
    PATCH_REGISTRY = {
        "musl": {
            "patches": ["//patches/core/musl:fix-locale.patch"],
        },
        "curl": {
            "patches": ["//patches/network/curl:internal-ca.patch"],
            "env": {"CFLAGS": "-DCUSTOM_FLAG"},
            "extra_configure_args": "--with-custom-ca-bundle=/etc/ssl/certs/ca.pem",
            "pre_configure": "sed -i 's/old/new/' configure.ac",
        },
    }
"""

# Load the custom registry (always exists - stub committed, user overrides locally)
load("//patches:registry.bzl", "PATCH_REGISTRY")

def get_patch_registry():
    """Return the effective patch registry.

    Checks if the registry is disabled via .buckconfig.
    Default: enabled (registry is active whenever PATCH_REGISTRY is non-empty).

    Returns:
        Dict mapping package names to override configs.
    """
    enabled = read_config("buckos", "patch_registry_enabled", "")
    if enabled == "false":
        return {}
    return PATCH_REGISTRY

def lookup_patches(name):
    """Look up registry overrides for a package by name.

    Args:
        name: Package name (the 'name' parameter of the package macro,
              e.g., "musl", "curl", "openssl")

    Returns:
        Override config dict or None if not registered.
        Config may contain:
          - patches: list of patch file targets (e.g., ["//patches:fix.patch"])
          - env: dict of environment variable overrides
          - extra_configure_args: string of additional configure arguments
          - pre_configure: string of additional pre-configure shell commands
          - src_prepare: string to replace src_prepare phase
    """
    registry = get_patch_registry()
    return registry.get(name, None)

def apply_registry_overrides(name, patches, env, src_prepare, pre_configure, src_configure):
    """Apply registry overrides to package build parameters.

    Merges registered patches and overrides with the package's
    existing configuration. Registry values are additive (patches
    are appended, env is merged, scripts are appended).

    Args:
        name: Package name
        patches: Existing patches list
        env: Existing env dict
        src_prepare: Existing src_prepare string
        pre_configure: Existing pre_configure string
        src_configure: Existing src_configure string

    Returns:
        Tuple of (patches, env, src_prepare, pre_configure, src_configure)
    """
    overrides = lookup_patches(name)
    if not overrides:
        return (patches, env, src_prepare, pre_configure, src_configure)

    # Merge patches (append registry patches after existing)
    merged_patches = list(patches)
    if "patches" in overrides:
        merged_patches.extend(overrides["patches"])

    # Merge env (registry overrides existing keys)
    merged_env = dict(env)
    if "env" in overrides:
        merged_env.update(overrides["env"])

    # Append pre_configure commands
    merged_pre_configure = pre_configure
    if "pre_configure" in overrides:
        if merged_pre_configure:
            merged_pre_configure += "\n" + overrides["pre_configure"]
        else:
            merged_pre_configure = overrides["pre_configure"]

    # Replace or keep src_prepare
    merged_src_prepare = src_prepare
    if "src_prepare" in overrides:
        merged_src_prepare = overrides["src_prepare"]

    # Append extra configure args
    merged_src_configure = src_configure
    if "extra_configure_args" in overrides:
        extra = overrides["extra_configure_args"]
        if merged_src_configure:
            merged_src_configure += " " + extra
        else:
            # Inject into EXTRA_ECONF env var instead
            existing_econf = merged_env.get("EXTRA_ECONF", "")
            if existing_econf:
                merged_env["EXTRA_ECONF"] = existing_econf + " " + extra
            else:
                merged_env["EXTRA_ECONF"] = extra

    return (merged_patches, merged_env, merged_src_prepare, merged_pre_configure, merged_src_configure)
