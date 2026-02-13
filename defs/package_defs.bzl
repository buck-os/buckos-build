"""
Package build rules for BuckOs Linux Distribution.
Similar to Gentoo's ebuild system but using Buck2.
"""

load("//defs:eclasses.bzl", "ECLASSES", "inherit")
load("//defs:use_flags.bzl",
     "get_effective_use",
     "use_dep",
     "use_cmake_options",
     "use_meson_options",
     "use_configure_args",
     "use_cargo_args",
     "use_go_build_args")
load("//defs:distro_constraints.bzl",
     "validate_compat_tags",
     "get_distro_constraints",
     "DISTRO_BUCKOS")
load("//defs:fhs_mapping.bzl",
     "get_configure_args_for_layout")
load("//config:fedora_build_flags.bzl",
     "get_fedora_build_env")
load("//defs:toolchain_providers.bzl",
     "GoToolchainInfo",
     "RustToolchainInfo")
load("//defs:patch_registry.bzl", "apply_registry_overrides")

# Bootstrap toolchain target path (for use in package definitions)
# All packages will use this by default to ensure they link against BuckOS glibc
# rather than the host system's libraries.
# Note: Uses toolchains// cell prefix per buck2 cell configuration
BOOTSTRAP_TOOLCHAIN = "toolchains//bootstrap:bootstrap-toolchain"
BOOTSTRAP_TOOLCHAIN_AARCH64 = "toolchains//bootstrap:bootstrap-toolchain-aarch64"

# Detect host architecture from host_info()
# This helps choose the right toolchain when building on native aarch64
def _is_host_aarch64():
    """Check if we're running on an aarch64 host."""
    return host_info().arch.is_aarch64

# Architecture-aware bootstrap toolchain selection
def get_bootstrap_toolchain():
    """Return the appropriate bootstrap toolchain for the target architecture.

    On aarch64 hosts, we prefer the aarch64 toolchain by default since we can't
    build x86_64 cross-compilers on aarch64.
    """
    if _is_host_aarch64():
        # On aarch64 host, default to aarch64 toolchain
        return select({
            "//platforms:is_x86_64": BOOTSTRAP_TOOLCHAIN,
            "DEFAULT": BOOTSTRAP_TOOLCHAIN_AARCH64,
        })
    else:
        # On x86_64 host, default to x86_64 toolchain
        return select({
            "//platforms:is_aarch64": BOOTSTRAP_TOOLCHAIN_AARCH64,
            "DEFAULT": BOOTSTRAP_TOOLCHAIN,
        })

# Language toolchain target paths
LLVM_TOOLCHAIN = "toolchains//bootstrap/llvm:llvm-toolchain"

# First-class Buck2 toolchain targets (typed provider wrappers)
GO_BUCKOS_TOOLCHAIN = "toolchains//bootstrap/go:go-buckos-toolchain"
RUST_BUCKOS_TOOLCHAIN = "toolchains//bootstrap/rust:rust-buckos-toolchain"

# Valid kwargs that can be passed through to ebuild_package_rule
# Wrapper functions (autotools_package, make_package, cmake_package, etc.) use this
# to filter out unsupported parameters from BUCK files
VALID_EBUILD_KWARGS = [
    "category", "slot", "description", "homepage", "license",
    "src_unpack", "src_test", "pre_configure", "run_tests",
    "depend", "pdepend", "exec_bdepend", "local_only", "bootstrap_sysroot", "bootstrap_stage",
    "visibility", "patches",
]

def filter_ebuild_kwargs(kwargs, src_install = None):
    """
    Filter kwargs to only include parameters that ebuild_package_rule accepts.
    Also handles post_install by appending it to src_install.

    Args:
        kwargs: The kwargs dict from a wrapper function
        src_install: The current src_install script (if any)

    Returns:
        tuple: (filtered_kwargs dict, updated src_install string)
    """
    filtered = {k: v for k, v in kwargs.items() if k in VALID_EBUILD_KWARGS}

    # Handle post_install by appending to src_install
    post_install = kwargs.get("post_install")
    if post_install:
        if src_install:
            src_install = src_install + "\n" + post_install
        else:
            src_install = post_install

    return filtered, src_install

def get_toolchain_dep():
    """
    Returns the bootstrap toolchain dependency, or None if host toolchain is enabled.

    When use_host_toolchain config is enabled, returns None so the bootstrap
    toolchain is not added to the dependency graph and won't be built.

    Uses architecture-aware selection to pick the correct toolchain based on
    target platform.
    """
    if _should_use_host_toolchain():
        return None
    return get_bootstrap_toolchain()

def _should_use_host_toolchain():
    """
    Check if host toolchain should be used instead of bootstrap toolchain.

    Returns True if:
    1. buckos.use_host_toolchain config is explicitly set to true/false
    2. Auto-detected as running in an external monorepo by checking if the
       buckos cell is defined (indicates buckos is imported as a dependency)

    When integrated into a larger monorepo, we use the host/system toolchains
    since the bootstrap toolchain cell name may conflict with existing cells.

    NOTE: In Buck2, read_config reads from the cell context where the BUCK file
    is being evaluated.
    """
    # Explicit config override takes precedence
    use_host = read_config("buckos", "use_host_toolchain", "")
    if use_host.lower() in ["true", "1", "yes"]:
        return True
    if use_host.lower() in ["false", "0", "no"]:
        return False

    # Auto-detect external monorepo integration
    # If buckos cell is explicitly defined, we're imported into another project
    # In standalone mode, there's no "buckos" cell - it's just the root
    buckos_cell = read_config("cells", "buckos", "")
    if buckos_cell:
        return True

    # Default: use bootstrap toolchain (standalone mode)
    return False

def get_go_typed_toolchain_dep():
    """
    Returns the typed Go toolchain dependency (with GoToolchainInfo provider),
    or None if host toolchain is enabled.
    """
    if _should_use_host_toolchain():
        return None
    return GO_BUCKOS_TOOLCHAIN

def get_rust_typed_toolchain_dep():
    """
    Returns the typed Rust toolchain dependency (with RustToolchainInfo provider),
    or None if host toolchain is enabled.
    """
    if _should_use_host_toolchain():
        return None
    return RUST_BUCKOS_TOOLCHAIN

def get_llvm_toolchain_dep():
    """
    Returns the LLVM bootstrap toolchain dependency, or None if host toolchain is enabled.

    When use_host_toolchain config is enabled, returns None so the bootstrap
    LLVM toolchain is not added to the dependency graph and host LLVM is used.
    """
    if _should_use_host_toolchain():
        return None
    return LLVM_TOOLCHAIN

def _get_download_proxy():
    """
    Get the HTTP proxy for downloading sources.
    Reads from download.proxy config in .buckconfig.
    """
    return read_config("download", "proxy", "")

def _get_vendor_prefer():
    """
    Check if vendored sources should be preferred over downloads.
    Reads from vendor.prefer_vendored config in .buckconfig.
    """
    return read_config("vendor", "prefer_vendored", "true") == "true"

def _get_vendor_require():
    """
    Check if vendored sources are required (strict offline mode).
    Reads from vendor.require_vendored config in .buckconfig.
    """
    return read_config("vendor", "require_vendored", "false") == "true"

def _get_vendor_dir():
    """
    Get the vendor directory path.
    Reads from vendor.dir config in .buckconfig.

    Returns the configured vendor directory (default: "vendor").
    """
    return read_config("vendor", "dir", "vendor")

def get_vendor_path(package_path: str, filename: str) -> str:
    """
    Get the vendor path for a source file.

    Args:
        package_path: The package path (e.g., "packages/linux/core/bash") - unused, kept for API compatibility
        filename: The source filename (e.g., "bash-5.2.tar.gz")

    Returns:
        The path where the vendored source should be stored: vendor/<filename>
    """
    vendor_dir = _get_vendor_dir()
    return "{}/{}".format(vendor_dir, filename)

def _get_download_max_concurrent():
    """
    Get the maximum concurrent downloads setting.
    Reads from download.max_concurrent config in .buckconfig.
    """
    return read_config("download", "max_concurrent", "4")

def _get_download_env():
    """
    Get environment variables for download actions.
    Returns a dict with BUCKOS_MAX_CONCURRENT_DOWNLOADS set.
    """
    return {
        "BUCKOS_MAX_CONCURRENT_DOWNLOADS": _get_download_max_concurrent(),
    }

# Platform constraint values for target_compatible_with
# Only macOS packages need constraints to prevent building on Linux
# Linux packages don't need constraints since we're building on Linux
# Uses prelude OS constraint which is automatically detected from host
_MACOS_CONSTRAINT = "prelude//os/constraints:macos"

def _get_platform_constraints():
    """
    Detect the target platform from the package path and return appropriate
    target_compatible_with constraints. Only macOS packages get constraints
    to prevent them from building on Linux. Linux packages have no constraints.
    """
    pkg = native.package_name()
    if pkg.startswith("packages/mac/"):
        return [_MACOS_CONSTRAINT]
    # Linux packages and others: no constraints (builds on Linux)
    return []

def _apply_platform_constraints(kwargs):
    """
    Apply platform constraints to kwargs if not already specified.
    This should be called at the start of each package macro.
    """
    if "target_compatible_with" not in kwargs:
        constraints = _get_platform_constraints()
        if constraints:
            kwargs["target_compatible_with"] = constraints
    return kwargs

# Package metadata structure
PackageInfo = provider(fields = [
    "name",
    "version",
    "description",
    "homepage",
    "license",
    "src_uri",
    "checksum",
    "dependencies",
    "build_dependencies",
    "maintainers",  # List of maintainer IDs for package support contacts
])

# -----------------------------------------------------------------------------
# Language Library Providers (for pre-downloaded dependencies)
# -----------------------------------------------------------------------------

GoLibraryInfo = provider(fields = ["module_path", "version", "vendor_dir"])
RustCrateInfo = provider(fields = ["crate_name", "version", "crate_dir", "features"])
PythonLibraryInfo = provider(fields = ["package_name", "version", "site_packages"])
RubyGemInfo = provider(fields = ["gem_name", "version", "gem_dir"])
PerlModuleInfo = provider(fields = ["module_name", "version", "lib_dir"])
NpmPackageInfo = provider(fields = ["package_name", "version", "node_modules"])
Stage3Info = provider(fields = ["tarball", "checksum", "contents", "arch", "variant", "libc", "version"])

# -----------------------------------------------------------------------------
# Dependency Collection Helper
# -----------------------------------------------------------------------------

def _collect_dep_dirs(deps: list) -> list:
    """
    Collect output directories from a list of dependencies.
    Simple list-based approach that works reliably across all cells.
    """
    dep_dirs = []
    for dep in deps:
        outputs = dep[DefaultInfo].default_outputs
        for output in outputs:
            dep_dirs.append(output)
    return dep_dirs

# -----------------------------------------------------------------------------
# Signature Download Rule (tries .sig, .asc, .sign extensions)
# -----------------------------------------------------------------------------

def _http_file_with_proxy_impl(ctx: AnalysisContext) -> list[Provider]:
    """Download a file using curl with proxy support, checking for vendored sources first."""
    out_file = ctx.actions.declare_output(ctx.attrs.out)

    # Build curl command with proxy
    proxy = ctx.attrs.proxy
    proxy_args = "--proxy {}".format(proxy) if proxy else ""

    # Calculate vendor path using configurable vendor directory
    # ctx.label.package gives us the package path (e.g., "packages/linux/core/bash")
    vendor_path = get_vendor_path(ctx.label.package, ctx.attrs.out)

    # Get vendor configuration
    prefer_vendored = "true" if _get_vendor_prefer() else "false"
    require_vendored = "true" if _get_vendor_require() else "false"

    # Create download script that checks for vendored source first
    script_content = """#!/bin/bash
set -e
OUT_FILE="$1"
URL="$2"
EXPECTED_SHA256="$3"
PROXY_ARGS="$4"
VENDOR_PATH="$5"
PREFER_VENDORED="$6"
REQUIRE_VENDORED="$7"

# Function to verify SHA256
verify_sha256() {
    local file="$1"
    local expected="$2"
    if [ -n "$expected" ]; then
        local actual=$(sha256sum "$file" | cut -d' ' -f1)
        if [ "$actual" != "$expected" ]; then
            return 1
        fi
    fi
    return 0
}

# Check for vendored source if prefer_vendored is enabled
if [ "$PREFER_VENDORED" = "true" ] && [ -n "$VENDOR_PATH" ]; then
    # Find the repo root (walk up until we find .buckconfig)
    REPO_ROOT="$PWD"
    while [ ! -f "$REPO_ROOT/.buckconfig" ] && [ "$REPO_ROOT" != "/" ]; do
        REPO_ROOT="$(dirname "$REPO_ROOT")"
    done

    VENDORED_FILE="$REPO_ROOT/$VENDOR_PATH"
    if [ -f "$VENDORED_FILE" ]; then
        echo "Found vendored source: $VENDORED_FILE"
        if verify_sha256 "$VENDORED_FILE" "$EXPECTED_SHA256"; then
            echo "SHA256 verified, using vendored source"
            cp "$VENDORED_FILE" "$OUT_FILE"
            exit 0
        else
            echo "WARNING: Vendored source checksum mismatch, falling back to download"
        fi
    fi
fi

# If require_vendored is set, fail if we get here
if [ "$REQUIRE_VENDORED" = "true" ]; then
    echo "ERROR: Vendored source required but not found or invalid: $VENDOR_PATH" >&2
    echo "Run: ./tools/vendor-sources --target <target> to vendor sources" >&2
    exit 1
fi

# Download with curl
curl -fsSL --retry 3 --retry-delay 2 $PROXY_ARGS -o "$OUT_FILE" "$URL"

# Verify SHA256 if provided
if [ -n "$EXPECTED_SHA256" ]; then
    ACTUAL_SHA256=$(sha256sum "$OUT_FILE" | cut -d' ' -f1)
    if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
        echo "SHA256 mismatch!" >&2
        echo "  Expected: $EXPECTED_SHA256" >&2
        echo "  Actual:   $ACTUAL_SHA256" >&2
        rm -f "$OUT_FILE"
        exit 1
    fi
    echo "SHA256 verified: $ACTUAL_SHA256"
fi
"""

    script = ctx.actions.write("download.sh", script_content, is_executable = True)

    cmd = cmd_args([
        "bash",
        script,
        out_file.as_output(),
        ctx.attrs.urls[0],  # Use first URL
        ctx.attrs.sha256,
        proxy_args,
        vendor_path,
        prefer_vendored,
        require_vendored,
    ])

    ctx.actions.run(
        cmd,
        category = "http_file",
        identifier = ctx.attrs.name,
        local_only = True,  # Network access needed (unless vendored)
        env = _get_download_env(),
    )

    return [DefaultInfo(default_output = out_file)]

_http_file_with_proxy = rule(
    impl = _http_file_with_proxy_impl,
    attrs = {
        "urls": attrs.list(attrs.string(), doc = "URLs to download from"),
        "sha256": attrs.string(doc = "Expected SHA256 checksum"),
        "out": attrs.string(doc = "Output filename"),
        "proxy": attrs.string(default = "", doc = "HTTP proxy URL"),
    },
)

def _download_signature_impl(ctx: AnalysisContext) -> list[Provider]:
    """Download GPG signature, trying multiple extensions, checking for vendored signature first."""
    out_file = ctx.actions.declare_output(ctx.attrs.out)

    # Calculate vendor path for signature using configurable vendor directory
    vendor_path = get_vendor_path(ctx.label.package, ctx.attrs.out)

    # Get vendor configuration
    prefer_vendored = "true" if _get_vendor_prefer() else "false"
    require_vendored = "true" if _get_vendor_require() else "false"

    # Create a wrapper script that checks vendored first, then falls back to download script
    wrapper_content = """#!/bin/bash
set -e
OUT_FILE="$1"
BASE_URL="$2"
EXPECTED_SHA256="$3"
PROXY="$4"
VENDOR_PATH="$5"
PREFER_VENDORED="$6"
REQUIRE_VENDORED="$7"
DOWNLOAD_SCRIPT="$8"

# Function to verify SHA256
verify_sha256() {
    local file="$1"
    local expected="$2"
    if [ -n "$expected" ]; then
        local actual=$(sha256sum "$file" | cut -d' ' -f1)
        if [ "$actual" != "$expected" ]; then
            return 1
        fi
    fi
    return 0
}

# Check for vendored signature if prefer_vendored is enabled
if [ "$PREFER_VENDORED" = "true" ] && [ -n "$VENDOR_PATH" ]; then
    # Find the repo root (walk up until we find .buckconfig)
    REPO_ROOT="$PWD"
    while [ ! -f "$REPO_ROOT/.buckconfig" ] && [ "$REPO_ROOT" != "/" ]; do
        REPO_ROOT="$(dirname "$REPO_ROOT")"
    done

    VENDORED_FILE="$REPO_ROOT/$VENDOR_PATH"
    if [ -f "$VENDORED_FILE" ]; then
        echo "Found vendored signature: $VENDORED_FILE"
        if verify_sha256 "$VENDORED_FILE" "$EXPECTED_SHA256"; then
            echo "SHA256 verified, using vendored signature"
            cp "$VENDORED_FILE" "$OUT_FILE"
            exit 0
        else
            echo "WARNING: Vendored signature checksum mismatch, falling back to download"
        fi
    fi
fi

# If require_vendored is set, fail if we get here
if [ "$REQUIRE_VENDORED" = "true" ]; then
    echo "ERROR: Vendored signature required but not found or invalid: $VENDOR_PATH" >&2
    echo "Run: ./tools/vendor-sources --target <target> to vendor sources" >&2
    exit 1
fi

# Fall back to original download script
exec bash "$DOWNLOAD_SCRIPT" "$OUT_FILE" "$BASE_URL" "$EXPECTED_SHA256" "$PROXY"
"""

    wrapper_script = ctx.actions.write("download_sig_wrapper.sh", wrapper_content, is_executable = True)
    download_script = ctx.attrs._download_script[DefaultInfo].default_outputs[0]

    cmd = cmd_args([
        "bash",
        wrapper_script,
        out_file.as_output(),
        ctx.attrs.src_uri,
        ctx.attrs.sha256,
        ctx.attrs.proxy,
        vendor_path,
        prefer_vendored,
        require_vendored,
        download_script,
    ])

    ctx.actions.run(
        cmd,
        category = "download_signature",
        identifier = ctx.attrs.name,
        local_only = True,  # Network access needed (unless vendored)
        env = _get_download_env(),
    )

    return [DefaultInfo(default_output = out_file)]

_download_signature = rule(
    impl = _download_signature_impl,
    attrs = {
        "src_uri": attrs.string(doc = "Base URL of the source archive (extension will be appended)"),
        "sha256": attrs.string(doc = "Expected SHA256 of the signature file"),
        "out": attrs.string(doc = "Output filename"),
        "proxy": attrs.string(default = "", doc = "HTTP proxy URL for downloads"),
        "_download_script": attrs.dep(default = "//defs/scripts:download-signature"),
    },
)

# Source Extraction Rule (used with http_file for downloads)
# -----------------------------------------------------------------------------

def _extract_source_impl(ctx: AnalysisContext) -> list[Provider]:
    """Extract archive and optionally verify GPG signature."""
    out_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)

    # Get the archive file from http_file dependency
    archive_file = ctx.attrs.archive[DefaultInfo].default_outputs[0]

    # Get optional signature file from http_file dependency
    sig_file = ""
    if ctx.attrs.signature:
        sig_file = ctx.attrs.signature[DefaultInfo].default_outputs[0]

    # GPG verification parameters
    gpg_key = ctx.attrs.gpg_key if ctx.attrs.gpg_key else ""
    gpg_keyring = ctx.attrs.gpg_keyring if ctx.attrs.gpg_keyring else ""

    # Build exclude patterns for tar (no quotes - the script handles glob protection)
    exclude_args = " ".join(["--exclude={}".format(pattern) for pattern in ctx.attrs.exclude_patterns])

    # Get strip_components value (default is 1 for backward compatibility)
    strip_components = ctx.attrs.strip_components

    # Get extract setting (default True)
    do_extract = "1" if ctx.attrs.extract else "0"

    # Get the external extraction script
    script = ctx.attrs._extract_script[DefaultInfo].default_outputs[0]

    cmd = cmd_args([
        "bash",
        script,
        out_dir.as_output(),
        archive_file,
    ])

    # Add optional arguments
    if sig_file:
        cmd.add(sig_file)
    else:
        cmd.add("")

    cmd.add([
        gpg_key,
        gpg_keyring,
        exclude_args,
        str(strip_components),
        do_extract,
    ])

    ctx.actions.run(
        cmd,
        category = "extract",
        identifier = ctx.attrs.name,
        local_only = True,  # http_file outputs may need local execution
    )

    return [DefaultInfo(default_output = out_dir)]

_extract_source = rule(
    impl = _extract_source_impl,
    attrs = {
        "archive": attrs.dep(doc = "http_file dependency for the archive"),
        "signature": attrs.option(attrs.dep(), default = None, doc = "http_file dependency for GPG signature"),
        "gpg_key": attrs.option(attrs.string(), default = None),
        "gpg_keyring": attrs.option(attrs.string(), default = None),
        "exclude_patterns": attrs.list(attrs.string(), default = []),
        "strip_components": attrs.int(default = 1),
        "extract": attrs.bool(default = True),
        "_extract_script": attrs.dep(default = "//defs/scripts:extract-source"),
    },
)

def download_source(
        name: str,
        src_uri: str,
        sha256: str,
        version: str | None = None,
        signature_sha256: str | None = None,
        signature_required: bool = False,
        gpg_key: str | None = None,
        gpg_keyring: str | None = None,
        exclude_patterns: list[str] = [],
        strip_components: int = 1,
        extract: bool = True,
        visibility: list[str] = ["PUBLIC"]):
    """
    Download and extract source archives using Buck2's native http_file.

    This macro creates:
    1. An http_file target for the main archive
    2. An http_file target for the GPG signature (if signature_sha256 provided)
    3. An _extract_source rule that extracts and optionally verifies GPG

    Signature verification workflow:
    - Set signature_required=True (default) to require signature verification
    - Run `./tools/update_checksums.py --populate-signatures` to auto-discover signatures
      and populate signature_sha256 values
    - Build will fail if signature_required=True but signature_sha256 is missing

    Args:
        name: Target name for the extracted source
        src_uri: URL to download the source archive from
        sha256: SHA256 checksum of the archive
        version: Optional version string for documentation and tooling
        signature_sha256: SHA256 checksum of the signature file. Use update_checksums.py
                         to populate. When provided, tries .asc/.sig/.sign extensions.
        signature_required: If True (default), fails when signature_sha256 is missing.
                           Set to False to disable signature verification entirely.
        gpg_key: GPG key ID to verify against
        gpg_keyring: Path to GPG keyring file
        exclude_patterns: Patterns to exclude from extraction
        strip_components: Number of leading path components to strip (default: 1)
        extract: Whether to extract the archive (default: True)
        visibility: Target visibility

    The src_uri can contain ${VERSION} which will be replaced with the version value.
    Example: src_uri = "https://example.com/foo-${VERSION}.tar.gz"
    """
    # Substitute ${VERSION} in src_uri if version is provided
    if version:
        src_uri = src_uri.replace("${VERSION}", version)

    # Extract filename from URL to preserve extension
    # Handle URLs with query params like gitweb (?p=...) or GitHub (/archive/...)
    url_path = src_uri.split("?")[0]  # Remove query string
    archive_filename = url_path.split("/")[-1]

    # If filename is empty or doesn't look like an archive, derive from name
    if not archive_filename or "." not in archive_filename:
        # Try to detect extension from URL params (e.g., sf=tgz)
        ext = ".tar.gz"  # Default
        if "sf=tgz" in src_uri or ".tgz" in src_uri:
            ext = ".tar.gz"
        elif "sf=tbz2" in src_uri or ".tar.bz2" in src_uri:
            ext = ".tar.bz2"
        elif "sf=txz" in src_uri or ".tar.xz" in src_uri:
            ext = ".tar.xz"
        elif ".zip" in src_uri:
            ext = ".zip"
        archive_filename = name + ext

    # Create http_file for the main archive (using custom rule with proxy support)
    archive_target = name + "-archive"
    _http_file_with_proxy(
        name = archive_target,
        urls = [src_uri],
        sha256 = sha256,
        out = archive_filename,
        proxy = _get_download_proxy(),
    )

    # Create signature download rule if signature_required and signature_sha256 provided
    # This rule tries .sig, .asc, .sign extensions automatically
    sig_target = None
    if signature_required and not signature_sha256:
        fail("signature_required=True but signature_sha256 not provided for {}. Run ./tools/update_checksums.py".format(name))
    if signature_required and signature_sha256:
        sig_target = name + "-sig"
        _download_signature(
            name = sig_target,
            src_uri = src_uri,
            sha256 = signature_sha256,
            out = archive_filename + ".sig",
            proxy = _get_download_proxy(),
        )

    # Create extraction rule
    _extract_source(
        name = name,
        archive = ":" + archive_target,
        signature = (":" + sig_target) if sig_target else None,
        gpg_key = gpg_key,
        gpg_keyring = gpg_keyring,
        exclude_patterns = exclude_patterns,
        strip_components = strip_components,
        extract = extract,
        visibility = visibility,
    )

def _kernel_config_impl(ctx: AnalysisContext) -> list[Provider]:
    """Merge kernel configuration fragments into a single .config file."""
    output = ctx.actions.declare_output(ctx.attrs.name + ".config")

    # Collect all config fragments
    config_files = []
    for frag in ctx.attrs.fragments:
        config_files.append(frag)

    script = ctx.actions.write(
        "merge_config.sh",
        """#!/bin/bash
set -e
OUTPUT="$1"
shift

# Start with empty config
> "$OUTPUT"

# Merge all config fragments
# Later fragments override earlier ones
for config in "$@"; do
    if [ -f "$config" ]; then
        # Read each line from the fragment
        while IFS= read -r line || [ -n "$line" ]; do
            # Skip empty lines and comments for processing
            if [[ -z "$line" ]] || [[ "$line" =~ ^# ]]; then
                echo "$line" >> "$OUTPUT"
                continue
            fi

            # Extract config option name
            if [[ "$line" =~ ^(CONFIG_[A-Za-z0-9_]+)= ]]; then
                opt="${BASH_REMATCH[1]}"
                # Remove any existing setting for this option
                sed -i "/^$opt=/d" "$OUTPUT"
                sed -i "/^# $opt is not set/d" "$OUTPUT"
            elif [[ "$line" =~ ^#[[:space:]]*(CONFIG_[A-Za-z0-9_]+)[[:space:]]is[[:space:]]not[[:space:]]set ]]; then
                opt="${BASH_REMATCH[1]}"
                # Remove any existing setting for this option
                sed -i "/^$opt=/d" "$OUTPUT"
                sed -i "/^# $opt is not set/d" "$OUTPUT"
            fi

            echo "$line" >> "$OUTPUT"
        done < "$config"
    fi
done
""",
        is_executable = True,
    )

    ctx.actions.run(
        cmd_args([
            "bash",
            script,
            output.as_output(),
        ] + config_files),
        category = "kernel_config",
        identifier = ctx.attrs.name,
    )

    return [DefaultInfo(default_output = output)]

kernel_config = rule(
    impl = _kernel_config_impl,
    attrs = {
        "fragments": attrs.list(attrs.source()),
    },
)

def _kernel_build_impl(ctx: AnalysisContext) -> list[Provider]:
    """Build Linux kernel with custom configuration."""
    install_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)
    src_dir = ctx.attrs.source[DefaultInfo].default_outputs[0]

    # Kernel config - can be a source file or output from kernel_config
    config_file = None
    if ctx.attrs.config:
        config_file = ctx.attrs.config
    elif ctx.attrs.config_dep:
        config_file = ctx.attrs.config_dep[DefaultInfo].default_outputs[0]

    script = ctx.actions.write(
        "build_kernel.sh",
        """#!/bin/bash
set -e
unset CDPATH
# Live kernel: loop, sr, piix, iso9660, squashfs, overlayfs built-in

# Arguments:
# $1 = install directory (output)
# $2 = source directory (input)
# $3 = build scratch directory (output, for writable build)
# $4 = target architecture (x86_64 or aarch64)
# $5 = config file (optional)
# $6 = cross-toolchain directory (optional, for cross-compilation)

# Save absolute paths before changing directory
SRC_DIR="$(cd "$2" && pwd)"

# Build scratch directory - passed from Buck2 for hermetic builds
BUILD_DIR="$3"

# Target architecture
TARGET_ARCH="$4"

# Cross-toolchain directory (optional)
CROSS_TOOLCHAIN_DIR="$6"

# Set up cross-toolchain PATH if provided
if [ -n "$CROSS_TOOLCHAIN_DIR" ] && [ -d "$CROSS_TOOLCHAIN_DIR" ]; then
    # Look for toolchain bin directories
    for subdir in $(find "$CROSS_TOOLCHAIN_DIR" -type d -name bin 2>/dev/null); do
        export PATH="$subdir:$PATH"
    done
    echo "Cross-toolchain added to PATH"
fi

# Set architecture-specific variables
case "$TARGET_ARCH" in
    aarch64)
        KERNEL_ARCH="arm64"
        KERNEL_IMAGE="arch/arm64/boot/Image"
        # Try buckos cross-compiler first, then standard prefix
        if command -v aarch64-buckos-linux-gnu-gcc >/dev/null 2>&1; then
            CROSS_COMPILE="aarch64-buckos-linux-gnu-"
        else
            CROSS_COMPILE="aarch64-linux-gnu-"
        fi
        ;;
    x86_64|*)
        KERNEL_ARCH="x86"
        KERNEL_IMAGE="arch/x86/boot/bzImage"
        CROSS_COMPILE=""
        ;;
esac

echo "Building kernel for $TARGET_ARCH (ARCH=$KERNEL_ARCH, image=$KERNEL_IMAGE)"

# Convert install paths to absolute
if [[ "$1" = /* ]]; then
    INSTALL_BASE="$1"
else
    INSTALL_BASE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
fi

export INSTALL_PATH="$INSTALL_BASE/boot"
export INSTALL_MOD_PATH="$INSTALL_BASE"
mkdir -p "$INSTALL_PATH"

if [ -n "$5" ]; then
    # Convert config path to absolute if it's relative
    if [[ "$5" = /* ]]; then
        CONFIG_PATH="$5"
    else
        CONFIG_PATH="$(pwd)/$5"
    fi
fi

# Copy source to writable build directory (buck2 inputs are read-only)
# BUILD_DIR is passed as $3 from Buck2 for hermetic, deterministic builds
mkdir -p "$BUILD_DIR"

# Check if we need to force GNU11 standard for GCC 14+ (C23 conflicts with kernel's bool/true/false)
# GCC 14+ defaults to C23 where bool/true/false are keywords, breaking older kernel code
CC_BIN="${CC:-gcc}"
CC_VER=$($CC_BIN --version 2>/dev/null | head -1)
echo "Compiler version: $CC_VER"
MAKE_CC_OVERRIDE=""
if echo "$CC_VER" | grep -iq gcc; then
    # Extract version number - handles "gcc (GCC) 15.2.1" or "gcc (Fedora 14.2.1-6) 14.2.1" formats
    GCC_MAJOR=$(echo "$CC_VER" | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1)
    echo "Detected GCC major version: $GCC_MAJOR"
    if [ -n "$GCC_MAJOR" ] && [ "$GCC_MAJOR" -ge 14 ] 2>/dev/null; then
        echo "GCC 14+ detected, creating wrapper to append -std=gnu11"
        # Create a gcc wrapper that appends -std=gnu11 as the LAST argument
        # This ensures it overrides any -std= flags set by kernel Makefiles
        WRAPPER_DIR="$(cd "$BUILD_DIR" && pwd)/.cc-wrapper"
        mkdir -p "$WRAPPER_DIR"
        cat > "$WRAPPER_DIR/gcc" << 'WRAPPER'
#!/bin/bash
exec /usr/bin/gcc "$@" -std=gnu11
WRAPPER
        chmod +x "$WRAPPER_DIR/gcc"
        # Pass CC explicitly on make command line with absolute path
        MAKE_CC_OVERRIDE="CC=$WRAPPER_DIR/gcc HOSTCC=$WRAPPER_DIR/gcc"
        echo "Will use: $MAKE_CC_OVERRIDE"
    fi
fi
echo "Copying kernel source to build directory: $BUILD_DIR"
cp -a "$SRC_DIR"/. "$BUILD_DIR/"
cd "$BUILD_DIR"

# Set up cross-compilation if building for different architecture
MAKE_ARCH_OPTS="ARCH=$KERNEL_ARCH"
if [ -n "$CROSS_COMPILE" ]; then
    # Check if cross-compiler is available
    if command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
        MAKE_ARCH_OPTS="$MAKE_ARCH_OPTS CROSS_COMPILE=$CROSS_COMPILE"
        echo "Cross-compiling with $CROSS_COMPILE"
    else
        echo "Warning: Cross-compiler ${CROSS_COMPILE}gcc not found, attempting native build"
        CROSS_COMPILE=""
    fi
fi

# Apply config
if [ -n "$CONFIG_PATH" ]; then
    cp "$CONFIG_PATH" .config
    # Ensure config is complete with olddefconfig (non-interactive)
    make $MAKE_CC_OVERRIDE $MAKE_ARCH_OPTS olddefconfig

    # If hardware-specific config fragment exists, merge it
    HARDWARE_CONFIG="$(dirname "$SRC_DIR")/../../hardware-kernel.config"
    if [ -f "$HARDWARE_CONFIG" ]; then
        echo "Merging hardware-specific kernel config..."
        # Use kernel's merge script to combine base config with hardware fragment
        scripts/kconfig/merge_config.sh -m .config "$HARDWARE_CONFIG"
        # Update config with new options (non-interactive)
        make $MAKE_CC_OVERRIDE $MAKE_ARCH_OPTS olddefconfig
    fi
else
    make $MAKE_CC_OVERRIDE $MAKE_ARCH_OPTS defconfig
fi

# Build kernel
# -Wno-unterminated-string-initialization: suppresses ACPI driver warnings about truncated strings
# GCC wrapper (if GCC 14+) appends -std=gnu11 to all compilations via CC override
make $MAKE_CC_OVERRIDE $MAKE_ARCH_OPTS -j${MAKEOPTS:-$(nproc)} WERROR=0 KCFLAGS="-Wno-unterminated-string-initialization"

# Manual install to avoid system kernel-install scripts that try to write to /boot, run dracut, etc.
# Get kernel release version
KRELEASE=$(make $MAKE_CC_OVERRIDE $MAKE_ARCH_OPTS -s kernelrelease)
echo "Installing kernel version: $KRELEASE"

# Install kernel image
mkdir -p "$INSTALL_PATH"
cp "$KERNEL_IMAGE" "$INSTALL_PATH/vmlinuz-$KRELEASE"
cp System.map "$INSTALL_PATH/System.map-$KRELEASE"
cp .config "$INSTALL_PATH/config-$KRELEASE"

# Install modules
make $MAKE_CC_OVERRIDE $MAKE_ARCH_OPTS INSTALL_MOD_PATH="$INSTALL_BASE" modules_install

# Install headers (useful for out-of-tree modules)
mkdir -p "$INSTALL_BASE/usr/src/linux-$KRELEASE"
make $MAKE_CC_OVERRIDE $MAKE_ARCH_OPTS INSTALL_HDR_PATH="$INSTALL_BASE/usr" headers_install
""",
        is_executable = True,
    )

    # Declare a scratch directory for the kernel build (Buck2 inputs are read-only)
    # Using a declared output ensures deterministic paths instead of /tmp or $$
    build_scratch_dir = ctx.actions.declare_output(ctx.attrs.name + "-build-scratch", dir = True)

    # Build command arguments
    cmd = cmd_args([
        "bash",
        script,
        install_dir.as_output(),
        src_dir,
        build_scratch_dir.as_output(),
        ctx.attrs.arch,  # Target architecture
    ])

    # Add config file if present, otherwise add empty string placeholder
    if config_file:
        cmd.add(config_file)
    else:
        cmd.add("")

    # Add cross-toolchain directory if present
    if ctx.attrs.cross_toolchain:
        toolchain_dir = ctx.attrs.cross_toolchain[DefaultInfo].default_outputs[0]
        cmd.add(toolchain_dir)

    ctx.actions.run(
        cmd,
        category = "kernel",
        identifier = ctx.attrs.name,
    )

    return [DefaultInfo(default_output = install_dir)]

kernel_build = rule(
    impl = _kernel_build_impl,
    attrs = {
        "source": attrs.dep(),
        "version": attrs.string(),
        "config": attrs.option(attrs.source(), default = None),
        "config_dep": attrs.option(attrs.dep(), default = None),
        "arch": attrs.string(default = "x86_64"),  # Target architecture: x86_64 or aarch64
        "cross_toolchain": attrs.option(attrs.dep(), default = None),  # Cross-toolchain for cross-compilation
    },
)

def _binary_package_impl(ctx: AnalysisContext) -> list[Provider]:
    """
    Create a package from pre-built binaries with custom installation script.

    This rule is designed for packages that:
    - Download precompiled binaries
    - Require bootstrap compilation (like Go, GHC, Rust)
    - Need custom installation logic

    Environment variables available in install_script:
    - $SRCS: Directory containing extracted source files from all srcs dependencies
    - $OUT: Output/installation directory (like $DESTDIR)
    - $WORK: Working directory for temporary files
    - $BUILD_DIR: Build subdirectory
    - $PN: Package name
    - $PV: Package version
    """
    install_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)

    # Collect source directories from dependencies
    src_dirs = []
    for src in ctx.attrs.srcs:
        src_dirs.append(src[DefaultInfo].default_outputs[0])

    # Collect all dependency directories
    all_deps = ctx.attrs.deps + ctx.attrs.build_deps
    dep_dirs = _collect_dep_dirs(all_deps)

    # Build the installation script
    install_script = ctx.attrs.install_script if ctx.attrs.install_script else """
        # Default: copy all source contents to output
        cp -r $SRCS/* $OUT/ 2>/dev/null || true
    """

    # Pre-install commands
    pre_install = ctx.attrs.pre_install if ctx.attrs.pre_install else ""

    # Post-install commands
    post_install = ctx.attrs.post_install if ctx.attrs.post_install else ""

    script = ctx.actions.write(
        "install_binary.sh",
        """#!/bin/bash
set -e
unset CDPATH

# Package variables
export PN="{name}"
export PV="{version}"
export PACKAGE_NAME="{name}"

# Directory setup
mkdir -p "$1"
mkdir -p "$2"
export OUT="$(cd "$1" && pwd)"
export WORK="$(cd "$2" && pwd)"
export SRCS="$(cd "$3" && pwd)"
export BUILD_DIR="$WORK/build"
shift 3  # Remove OUT, WORK, SRCS from args, remaining are dependency dirs

# Set up PATH, LD_LIBRARY_PATH, PKG_CONFIG_PATH from dependency directories
DEP_PATH=""
DEP_LD_PATH=""
DEP_PKG_CONFIG_PATH=""
PYTHON_HOME=""
PYTHON_LIB64=""

echo "=== binary_package dependency setup for {name} ==="
echo "Processing $# dependency directories..."

# Store all dependency base directories for packages that need them (e.g., GCC)
export DEP_BASE_DIRS=""

for dep_dir in "$@"; do
    # Convert to absolute path if relative
    if [[ "$dep_dir" != /* ]]; then
        dep_dir="$(cd "$dep_dir" 2>/dev/null && pwd)" || continue
    fi

    echo "  Checking dependency: $dep_dir"

    # Store base directory
    DEP_BASE_DIRS="${{DEP_BASE_DIRS:+$DEP_BASE_DIRS:}}$dep_dir"

    # Check all standard include directories (including tools/include for bootstrap toolchain)
    for inc_subdir in tools/include usr/include include; do
        if [ -d "$dep_dir/$inc_subdir" ]; then
            DEP_CPATH="${{DEP_CPATH:+$DEP_CPATH:}}$dep_dir/$inc_subdir"
            echo "    Found include dir: $dep_dir/$inc_subdir"
        fi
    done

    # Check all standard bin directories (including tools/ for bootstrap toolchain)
    for bin_subdir in tools/bin usr/bin bin usr/sbin sbin; do
        if [ -d "$dep_dir/$bin_subdir" ]; then
            DEP_PATH="${{DEP_PATH:+$DEP_PATH:}}$dep_dir/$bin_subdir"
            echo "    Found bin dir: $dep_dir/$bin_subdir"
            # List executables for debugging
            ls "$dep_dir/$bin_subdir" 2>/dev/null | head -5 | while read f; do echo "      - $f"; done
        fi
    done

    # Check all standard lib directories (including tools/lib for bootstrap toolchain)
    for lib_subdir in tools/lib tools/lib64 usr/lib usr/lib64 lib lib64; do
        if [ -d "$dep_dir/$lib_subdir" ]; then
            DEP_LD_PATH="${{DEP_LD_PATH:+$DEP_LD_PATH:}}$dep_dir/$lib_subdir"
            echo "    Found lib dir: $dep_dir/$lib_subdir"
        fi
    done

    # Check for pkgconfig directories
    for pc_subdir in usr/lib64/pkgconfig usr/lib/pkgconfig usr/share/pkgconfig lib/pkgconfig lib64/pkgconfig; do
        if [ -d "$dep_dir/$pc_subdir" ]; then
            DEP_PKG_CONFIG_PATH="${{DEP_PKG_CONFIG_PATH:+$DEP_PKG_CONFIG_PATH:}}$dep_dir/$pc_subdir"
            echo "    Found pkgconfig dir: $dep_dir/$pc_subdir"
        fi
    done

    # Detect Python installation (any version)
    for py_dir in "$dep_dir"/usr/lib/python3.* "$dep_dir"/usr/lib64/python3.*; do
        if [ -d "$py_dir" ]; then
            py_version=$(basename "$py_dir")
            if [ -z "$PYTHON_HOME" ]; then
                PYTHON_HOME="$dep_dir/usr"
                echo "    Found PYTHONHOME: $PYTHON_HOME (from $py_version)"
            fi
            if [ -d "$py_dir/lib-dynload" ] && [ -z "$PYTHON_LIB64" ]; then
                PYTHON_LIB64="$py_dir"
                echo "    Found Python lib-dynload: $py_dir/lib-dynload"
            fi
        fi
    done
done

echo "=== Environment setup ==="
if [ -n "$DEP_PATH" ]; then
    export PATH="$DEP_PATH:$PATH"
    echo "PATH=$PATH"
fi
if [ -n "$DEP_LD_PATH" ]; then
    # Only use dependency library paths - do NOT inherit from host
    export LD_LIBRARY_PATH="$DEP_LD_PATH"
    export LIBRARY_PATH="$DEP_LD_PATH"
    echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
    echo "LIBRARY_PATH=$LIBRARY_PATH"

    # Add -L and -rpath flags to LDFLAGS for linker isolation
    DEP_LDFLAGS=""
    IFS=':' read -ra LIB_DIRS <<< "$DEP_LD_PATH"
    for lib_dir in "${{LIB_DIRS[@]}}"; do
        DEP_LDFLAGS="${{DEP_LDFLAGS}} -L$lib_dir -Wl,-rpath-link,$lib_dir"
    done
    export LDFLAGS="${{DEP_LDFLAGS}} ${{LDFLAGS:-}}"
    echo "LDFLAGS=$LDFLAGS"
fi
# Set CPATH for C/C++ include paths - do NOT inherit from host
if [ -n "$DEP_CPATH" ]; then
    export CPATH="$DEP_CPATH"
    export C_INCLUDE_PATH="$DEP_CPATH"
    export CPLUS_INCLUDE_PATH="$DEP_CPATH"
    echo "CPATH=$CPATH"

    # CRITICAL: Use -isystem instead of -I for dependency includes
    # -isystem paths are searched BEFORE the compiler's built-in system paths
    # This ensures our dependency headers are found before host system headers,
    # preventing version mismatches (e.g., compiling against host pcre2.h 10.47
    # but linking against our pcre2 library with different symbol versions)
    DEP_ISYSTEM_FLAGS=""
    IFS=':' read -ra INC_DIRS <<< "$DEP_CPATH"
    for inc_dir in "${{INC_DIRS[@]}}"; do
        DEP_ISYSTEM_FLAGS="${{DEP_ISYSTEM_FLAGS}} -isystem $inc_dir"
    done
    export CFLAGS="${{DEP_ISYSTEM_FLAGS}} ${{CFLAGS:-}}"
    export CXXFLAGS="${{DEP_ISYSTEM_FLAGS}} ${{CXXFLAGS:-}}"
    echo "CFLAGS=$CFLAGS"
fi
# Export DEP_BASE_DIRS for packages that need direct access to dependency prefixes
echo "DEP_BASE_DIRS=$DEP_BASE_DIRS"
if [ -n "$PYTHON_HOME" ]; then
    export PYTHONHOME="$PYTHON_HOME"
    echo "PYTHONHOME=$PYTHONHOME"
fi
# Set PYTHONPATH to include lib-dynload if it exists
if [ -n "$PYTHON_LIB64" ] && [ -d "$PYTHON_LIB64/lib-dynload" ]; then
    export PYTHONPATH="$PYTHON_LIB64/lib-dynload${{PYTHONPATH:+:$PYTHONPATH}}"
    echo "PYTHONPATH=$PYTHONPATH"
fi
# Also add site-packages directories from dependencies to PYTHONPATH
for dep_dir in $DEP_BASE_DIRS; do
    for sp_dir in "$dep_dir"/usr/lib/python*/site-packages "$dep_dir"/usr/lib64/python*/site-packages; do
        if [ -d "$sp_dir" ]; then
            export PYTHONPATH="${{PYTHONPATH:+$PYTHONPATH:}}$sp_dir"
        fi
    done
done
if [ -n "$PYTHONPATH" ]; then
    echo "PYTHONPATH=$PYTHONPATH"
fi
# CRITICAL: Use PKG_CONFIG_LIBDIR instead of PKG_CONFIG_PATH
# PKG_CONFIG_PATH *appends* to the default search (still finds /usr/lib64/pkgconfig)
# PKG_CONFIG_LIBDIR *replaces* the default search (only finds our dependencies)
if [ -n "$DEP_PKG_CONFIG_PATH" ]; then
    export PKG_CONFIG_LIBDIR="$DEP_PKG_CONFIG_PATH"
    unset PKG_CONFIG_PATH
    unset PKG_CONFIG_SYSROOT_DIR
    echo "PKG_CONFIG_LIBDIR=$PKG_CONFIG_LIBDIR"

    # Create pkg-config wrapper that rewrites paths from .pc files
    # Problem: .pc files contain prefix=/usr, so pkg-config returns -I/usr/include
    # which finds host headers instead of our dependency headers in buck-out.
    mkdir -p "$WORK/bin"
    cat > "$WORK/bin/pkg-config" << 'PKGCONFIG_WRAPPER_EOF'
#!/bin/bash
REAL_PKGCONFIG=""
for p in $(type -ap pkg-config); do
    if [ "$p" != "$0" ] && [[ "$p" != */WORK/bin/pkg-config ]] && [[ "$p" != *-work/bin/pkg-config ]]; then
        REAL_PKGCONFIG="$p"
        break
    fi
done
[ -z "$REAL_PKGCONFIG" ] && REAL_PKGCONFIG="/usr/bin/pkg-config"
[ ! -x "$REAL_PKGCONFIG" ] && {{ echo "pkg-config wrapper: cannot find real pkg-config" >&2; exit 1; }}

OUTPUT=$("$REAL_PKGCONFIG" "$@")
RC=$?
[ $RC -ne 0 ] && exit $RC
[ -z "$OUTPUT" ] && exit 0

case "$*" in
    *--cflags*|*--libs*|*--variable*)
        PKG_NAME=""
        for arg in "$@"; do
            case "$arg" in --*) ;; *) PKG_NAME="$arg"; break ;; esac
        done
        if [ -n "$PKG_NAME" ] && [ -n "$PKG_CONFIG_LIBDIR" ]; then
            IFS=':' read -ra PC_DIRS <<< "$PKG_CONFIG_LIBDIR"
            for pc_dir in "${{PC_DIRS[@]}}"; do
                if [ -f "$pc_dir/$PKG_NAME.pc" ]; then
                    DEP_ROOT="${{pc_dir%/usr/lib64/pkgconfig}}"
                    DEP_ROOT="${{DEP_ROOT%/usr/lib/pkgconfig}}"
                    DEP_ROOT="${{DEP_ROOT%/usr/share/pkgconfig}}"
                    DEP_ROOT="${{DEP_ROOT%/lib64/pkgconfig}}"
                    DEP_ROOT="${{DEP_ROOT%/lib/pkgconfig}}"
                    if [ "$DEP_ROOT" != "$pc_dir" ]; then
                        OUTPUT=$(echo "$OUTPUT" | sed -e "s|-I/usr/include|-I$DEP_ROOT/usr/include|g" \
                                                      -e "s|-L/usr/lib64|-L$DEP_ROOT/usr/lib64|g" \
                                                      -e "s|-L/usr/lib|-L$DEP_ROOT/usr/lib|g" \
                                                      -e "s| /usr/include| $DEP_ROOT/usr/include|g" \
                                                      -e "s| /usr/lib| $DEP_ROOT/usr/lib|g")
                    fi
                    break
                fi
            done
        fi
        ;;
esac
echo "$OUTPUT"
PKGCONFIG_WRAPPER_EOF
    chmod +x "$WORK/bin/pkg-config"
    export PATH="$WORK/bin:$PATH"
    echo "Installed pkg-config wrapper at $WORK/bin/pkg-config"
fi

# Ensure CC/CXX are set to proper compiler names
# This handles ccache/sccache setups where CC might be inherited as just the wrapper name
# Meson and other build systems need proper compiler names like "gcc" or "ccache gcc"
if [ -z "${{CC:-}}" ] || [ "$CC" = "cc" ]; then
    export CC="gcc"
fi
if [ -z "${{CXX:-}}" ] || [ "$CXX" = "c++" ]; then
    export CXX="g++"
fi
# Fix malformed CC/CXX that contain only wrapper name (e.g., "sccache cc" -> "sccache gcc")
case "$CC" in
    "sccache cc"|"ccache cc") export CC="${{CC%cc}}gcc" ;;
    "sccache c++"|"ccache c++") export CC="${{CC%c++}}gcc" ;;
esac
case "$CXX" in
    "sccache c++"|"ccache c++") export CXX="${{CXX%c++}}g++" ;;
    "sccache cc"|"ccache cc") export CXX="${{CXX%cc}}g++" ;;
esac
echo "CC=$CC"
echo "CXX=$CXX"

# Set CBUILD and CHOST to match the toolchain target triplet
# This ensures configure scripts use the correct triplet rather than auto-detecting
# from the host gcc (which returns the wrong triplet when using bootstrap toolchain)
if [ -z "${{CBUILD:-}}" ]; then
    # Run gcc -dumpmachine AFTER PATH is set to get the bootstrap toolchain's triplet
    if command -v gcc >/dev/null 2>&1; then
        export CBUILD="$(gcc -dumpmachine)"
        echo "CBUILD=$CBUILD (auto-detected from gcc)"
    fi
fi
if [ -z "${{CHOST:-}}" ]; then
    export CHOST="${{CBUILD:-$(uname -m)-unknown-linux-gnu}}"
    echo "CHOST=$CHOST"
fi

# Verify key tools are available
echo "=== Verifying tools ==="
MISSING_TOOLS=""
for tool in cmake python3 cc gcc ninja make; do
    if command -v $tool >/dev/null 2>&1; then
        tool_path=$(command -v $tool)
        tool_version=$($tool --version 2>&1 | head -1 || echo "unknown")
        echo "  $tool: $tool_path ($tool_version)"
    else
        echo "  $tool: NOT FOUND"
        MISSING_TOOLS="${{MISSING_TOOLS}} $tool"
    fi
done

# Show warning for missing tools that might be needed
if [ -n "$MISSING_TOOLS" ]; then
    echo ""
    echo "WARNING: The following tools were not found:$MISSING_TOOLS"
    echo "If build fails, ensure these tools are in dependencies."
fi

echo "=== End dependency setup ($(date '+%Y-%m-%d %H:%M:%S')) ==="
echo ""

# Save replay script for debugging failed builds
REPLAY_SCRIPT="$WORK/replay-build.sh"
cat > "$REPLAY_SCRIPT" << 'REPLAY_EOF'
#!/bin/bash
# Replay script for {name} {version}
# Generated: $(date)
# Re-run this script to reproduce the build environment

set -e
export OUT="REPLAY_OUT_PLACEHOLDER"
export WORK="REPLAY_WORK_PLACEHOLDER"
export SRCS="REPLAY_SRCS_PLACEHOLDER"
export BUILD_DIR="$WORK/build"
REPLAY_EOF

# Add environment variables
echo "export PATH=\"$PATH\"" >> "$REPLAY_SCRIPT"
echo "export LD_LIBRARY_PATH=\"$LD_LIBRARY_PATH\"" >> "$REPLAY_SCRIPT"
[ -n "$PYTHONHOME" ] && echo "export PYTHONHOME=\"$PYTHONHOME\"" >> "$REPLAY_SCRIPT"
[ -n "$PYTHONPATH" ] && echo "export PYTHONPATH=\"$PYTHONPATH\"" >> "$REPLAY_SCRIPT"
[ -n "$PKG_CONFIG_PATH" ] && echo "export PKG_CONFIG_PATH=\"$PKG_CONFIG_PATH\"" >> "$REPLAY_SCRIPT"
echo "" >> "$REPLAY_SCRIPT"
echo "cd \"\$WORK\"" >> "$REPLAY_SCRIPT"
echo "echo 'Environment ready. Run your commands here.'" >> "$REPLAY_SCRIPT"
echo "exec bash -i" >> "$REPLAY_SCRIPT"

# Replace placeholders with actual paths
sed -i "s|REPLAY_OUT_PLACEHOLDER|$OUT|g" "$REPLAY_SCRIPT"
sed -i "s|REPLAY_WORK_PLACEHOLDER|$WORK|g" "$REPLAY_SCRIPT"
sed -i "s|REPLAY_SRCS_PLACEHOLDER|$SRCS|g" "$REPLAY_SCRIPT"
chmod +x "$REPLAY_SCRIPT"
echo "Replay script saved to: $REPLAY_SCRIPT"

mkdir -p "$BUILD_DIR"

# Change to working directory
cd "$WORK"

# Build timing
BUILD_START=$(date +%s)

# Pre-install hook
PRE_START=$(date +%s)
{pre_install}
PRE_END=$(date +%s)
echo "[TIMING] Pre-install: $((PRE_END - PRE_START)) seconds"

# Main installation script
MAIN_START=$(date +%s)
{install_script}
MAIN_END=$(date +%s)
echo "[TIMING] Main install: $((MAIN_END - MAIN_START)) seconds"

# Post-install hook
POST_START=$(date +%s)
{post_install}
POST_END=$(date +%s)
echo "[TIMING] Post-install: $((POST_END - POST_START)) seconds"

# Global cleanup: Remove libtool .la files to prevent host path leakage
# Modern systems use pkg-config instead, and .la files often contain
# absolute paths to host libraries that break cross-compilation
LA_COUNT=$(find "$DESTDIR" -name "*.la" -type f 2>/dev/null | wc -l)
if [ "$LA_COUNT" -gt 0 ]; then
    echo "Removing $LA_COUNT libtool .la files (using pkg-config instead)"
    find "$DESTDIR" -name "*.la" -type f -delete 2>/dev/null || true
fi

BUILD_END=$(date +%s)
echo "[TIMING] Total build time: $((BUILD_END - BUILD_START)) seconds"

# =============================================================================
# Post-build verification: Ensure package produced output
# =============================================================================
echo ""
echo "📋 Verifying build output..."

# Check if OUT has any files
FILE_COUNT=$(find "$OUT" -type f 2>/dev/null | wc -l)
DIR_COUNT=$(find "$OUT" -type d 2>/dev/null | wc -l)

if [ "$FILE_COUNT" -eq 0 ]; then
    echo "" >&2
    echo "✗ BUILD VERIFICATION FAILED: No files were installed" >&2
    echo "  Package: {name}-{version}" >&2
    echo "  Output directory: $OUT" >&2
    echo "" >&2
    echo "  This usually means:" >&2
    echo "  1. The install_script didn't copy files to \$OUT" >&2
    echo "  2. The build succeeded but installation paths are wrong" >&2
    echo "  3. DESTDIR or prefix wasn't set correctly" >&2
    echo "" >&2
    echo "  Check the install_script in the BUCK file" >&2
    exit 1
fi

echo "✓ Build verification passed: $FILE_COUNT files in $DIR_COUNT directories"

# Post-build summary
echo ""
echo "=== Build summary for {name} {version} ==="
echo "Output directory: $OUT"
echo "Installed directories:"
find "$OUT" -type d -maxdepth 3 | head -20
echo ""
echo "Installed binaries (first 10):"
find "$OUT" -type f -executable -name "*" | head -10
echo ""
echo "Total files: $FILE_COUNT"
echo "Total size: $(du -sh "$OUT" 2>/dev/null | cut -f1)"
echo "=== End build summary ($(date '+%Y-%m-%d %H:%M:%S')) ==="
""".format(
            name = ctx.attrs.name,
            version = ctx.attrs.version,
            pre_install = pre_install,
            install_script = install_script,
            post_install = post_install,
        ),
        is_executable = True,
    )

    # Build command with all source directories
    # We create a combined source directory
    combine_script = ctx.actions.write(
        "combine_sources.sh",
        """#!/bin/bash
set -e
COMBINED_DIR="$1"
shift
mkdir -p "$COMBINED_DIR"
for src_dir in "$@"; do
    if [ -d "$src_dir" ]; then
        cp -r "$src_dir"/* "$COMBINED_DIR/" 2>/dev/null || true
    fi
done
""",
        is_executable = True,
    )

    # Create intermediate combined sources directory
    combined_srcs = ctx.actions.declare_output(ctx.attrs.name + "-combined-srcs", dir = True)
    work_dir = ctx.actions.declare_output(ctx.attrs.name + "-work", dir = True)

    # First combine the sources
    combine_cmd = cmd_args(["bash", combine_script, combined_srcs.as_output()])
    for src_dir in src_dirs:
        combine_cmd.add(src_dir)

    ctx.actions.run(
        combine_cmd,
        category = "combine",
        identifier = ctx.attrs.name + "-combine",
    )

    # Then run the installation
    install_cmd = cmd_args([
        "bash",
        script,
        install_dir.as_output(),
        work_dir.as_output(),
        combined_srcs,
    ])

    # Add dependency directories
    for dep_dir in dep_dirs:
        install_cmd.add(dep_dir)

    ctx.actions.run(
        install_cmd,
        category = "binary_install",
        identifier = ctx.attrs.name,
    )

    return [
        DefaultInfo(default_output = install_dir),
        PackageInfo(
            name = ctx.attrs.name,
            version = ctx.attrs.version,
            description = ctx.attrs.description,
            homepage = ctx.attrs.homepage,
            license = ctx.attrs.license,
            src_uri = "",
            checksum = "",
            dependencies = ctx.attrs.deps,
            build_dependencies = ctx.attrs.build_deps,
            maintainers = ctx.attrs.maintainers,
        ),
    ]

binary_package = rule(
    impl = _binary_package_impl,
    attrs = {
        "srcs": attrs.list(attrs.dep(), default = []),
        "install_script": attrs.string(default = ""),
        "pre_install": attrs.string(default = ""),
        "post_install": attrs.string(default = ""),
        "version": attrs.string(default = "1.0"),
        "description": attrs.string(default = ""),
        "homepage": attrs.string(default = ""),
        "license": attrs.string(default = ""),
        "deps": attrs.list(attrs.dep(), default = []),
        "build_deps": attrs.list(attrs.dep(), default = []),
        "maintainers": attrs.list(attrs.string(), default = []),
    },
)

# -----------------------------------------------------------------------------
# Precompiled Binary Package Rule
# -----------------------------------------------------------------------------

def _precompiled_package_impl(ctx: AnalysisContext) -> list[Provider]:
    """
    Simple rule for packages that are downloaded as precompiled binaries
    and just need to be extracted to the right location.

    This is simpler than binary_package when you just need to:
    - Download a binary tarball
    - Extract it to a specific location
    - Optionally create symlinks
    """
    install_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)

    # Get source directory from dependency
    src_dir = ctx.attrs.source[DefaultInfo].default_outputs[0]

    # Build the installation script
    extract_to = ctx.attrs.extract_to if ctx.attrs.extract_to else "/usr"

    # Generate symlink commands
    symlink_cmds = []
    for link, target in ctx.attrs.symlinks.items():
        symlink_cmds.append('mkdir -p "$OUT/$(dirname "{}")"'.format(link))
        symlink_cmds.append('ln -sf "{}" "$OUT/{}"'.format(target, link))
    symlinks_script = "\n".join(symlink_cmds)

    script = ctx.actions.write(
        "install_precompiled.sh",
        """#!/bin/bash
set -e

export OUT="$1"
export SRC="$2"

# Create target directory
mkdir -p "$OUT{extract_to}"

# Copy precompiled files
cp -r "$SRC"/* "$OUT{extract_to}/" 2>/dev/null || true

# Create symlinks
{symlinks}
""".format(
            extract_to = extract_to,
            symlinks = symlinks_script,
        ),
        is_executable = True,
    )

    ctx.actions.run(
        cmd_args([
            "bash",
            script,
            install_dir.as_output(),
            src_dir,
        ]),
        category = "precompiled",
        identifier = ctx.attrs.name,
    )

    return [
        DefaultInfo(default_output = install_dir),
        PackageInfo(
            name = ctx.attrs.name,
            version = ctx.attrs.version,
            description = ctx.attrs.description,
            homepage = ctx.attrs.homepage,
            license = ctx.attrs.license,
            src_uri = "",
            checksum = "",
            dependencies = ctx.attrs.deps,
            build_dependencies = [],
            maintainers = ctx.attrs.maintainers,
        ),
    ]

precompiled_package = rule(
    impl = _precompiled_package_impl,
    attrs = {
        "source": attrs.dep(),
        "version": attrs.string(),
        "extract_to": attrs.string(default = "/usr"),
        "symlinks": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "description": attrs.string(default = ""),
        "homepage": attrs.string(default = ""),
        "license": attrs.string(default = ""),
        "deps": attrs.list(attrs.dep(), default = []),
        "maintainers": attrs.list(attrs.string(), default = []),
    },
)

def _rootfs_impl(ctx: AnalysisContext) -> list[Provider]:
    """Assemble a root filesystem from packages."""
    rootfs_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)

    # Recursively collect all packages and their runtime dependencies
    all_packages = {}  # Use dict to avoid duplicates

    def collect_package_deps(pkg):
        """Recursively collect a package and its runtime dependencies."""
        # Get default outputs
        default_outputs = pkg[DefaultInfo].default_outputs

        # Add all outputs to our collection
        for output in default_outputs:
            pkg_key = str(output)
            if pkg_key not in all_packages:
                all_packages[pkg_key] = output

        # Try to collect runtime dependencies if this target has PackageInfo
        # Use get() method which returns None if provider doesn't exist
        pkg_info = pkg.get(PackageInfo)
        if pkg_info and pkg_info.dependencies:
            for dep in pkg_info.dependencies:
                collect_package_deps(dep)

    # Collect all packages starting from the explicitly listed ones
    for pkg in ctx.attrs.packages:
        collect_package_deps(pkg)

    # Convert to list for command arguments
    pkg_dirs = list(all_packages.values())

    # Create assembly script
    script_content = """#!/bin/bash
set -e
ROOTFS="$1"
shift

# Create base directory structure
# Note: Don't create /bin, /sbin, /lib, /lib64 here - baselayout provides them as symlinks (merged-usr)
mkdir -p "$ROOTFS"/{usr/{bin,sbin,lib},etc,var,tmp,proc,sys,dev,run,root,home}

# Function to recursively merge package directories
merge_package() {
    local src="$1"
    local dst="$ROOTFS"

    # If src is a symlink to a directory, follow it
    if [ -L "$src" ]; then
        src="$(readlink -f "$src")"
    fi

    if [ ! -d "$src" ]; then
        return
    fi

    # Check if this looks like a package directory (has usr/, lib/, bin/, etc.)
    # If it does, merge its contents directly
    if [ -d "$src/usr" ] || [ -d "$src/bin" ] || [ -d "$src/lib" ] || [ -d "$src/etc" ]; then
        # Handle merged-usr: if package has /bin, /sbin, or /lib and destination has them as symlinks,
        # copy the contents into the symlink target instead of trying to replace the symlink
        # Use tar to properly merge directory trees (handles nested directories correctly)
        # --keep-directory-symlink preserves symlinks like /lib -> /usr/lib
        tar -C "$src" -c . | tar -C "$dst" -x --keep-directory-symlink 2>/dev/null || true
    else
        # This is a meta-package directory with subdirs that are package names
        # Recursively process each subdirectory
        for subdir in "$src"/*; do
            if [ -d "$subdir" ] || [ -L "$subdir" ]; then
                merge_package "$subdir"
            fi
        done
    fi
}

# Copy packages
for pkg_dir in "$@"; do
    if [ -d "$pkg_dir" ] || [ -L "$pkg_dir" ]; then
        merge_package "$pkg_dir"
    fi
done

# Fix merged-usr layout: if /bin, /sbin, /lib ended up as directories instead of symlinks,
# move their contents to /usr and recreate symlinks
if [ -d "$ROOTFS/bin" ] && [ ! -L "$ROOTFS/bin" ]; then
    mkdir -p "$ROOTFS/usr/bin"
    cp -a "$ROOTFS/bin/"* "$ROOTFS/usr/bin/" 2>/dev/null || true
    rm -rf "$ROOTFS/bin"
    ln -s usr/bin "$ROOTFS/bin"
fi
if [ -d "$ROOTFS/sbin" ] && [ ! -L "$ROOTFS/sbin" ]; then
    mkdir -p "$ROOTFS/usr/sbin"
    cp -a "$ROOTFS/sbin/"* "$ROOTFS/usr/sbin/" 2>/dev/null || true
    rm -rf "$ROOTFS/sbin"
    ln -s usr/sbin "$ROOTFS/sbin"
fi
if [ -d "$ROOTFS/lib" ] && [ ! -L "$ROOTFS/lib" ]; then
    mkdir -p "$ROOTFS/usr/lib"
    cp -a "$ROOTFS/lib/"* "$ROOTFS/usr/lib/" 2>/dev/null || true
    rm -rf "$ROOTFS/lib"
    ln -s usr/lib "$ROOTFS/lib"
fi

# Fix /var/run and /var/lock symlinks: if they ended up as directories, move contents and recreate symlinks
# This handles cases where packages create /var/run/* before baselayout's symlink is applied
if [ -d "$ROOTFS/var/run" ] && [ ! -L "$ROOTFS/var/run" ]; then
    mkdir -p "$ROOTFS/run"
    cp -a "$ROOTFS/var/run/"* "$ROOTFS/run/" 2>/dev/null || true
    rm -rf "$ROOTFS/var/run"
    ln -s ../run "$ROOTFS/var/run"
    echo "Fixed /var/run symlink (was directory, moved contents to /run)"
fi
if [ -d "$ROOTFS/var/lock" ] && [ ! -L "$ROOTFS/var/lock" ]; then
    mkdir -p "$ROOTFS/run/lock"
    cp -a "$ROOTFS/var/lock/"* "$ROOTFS/run/lock/" 2>/dev/null || true
    rm -rf "$ROOTFS/var/lock"
    ln -s ../run/lock "$ROOTFS/var/lock"
    echo "Fixed /var/lock symlink (was directory, moved contents to /run/lock)"
fi

# Note: lib64 handling removed - on x86_64, /lib64/ld-linux-x86-64.so.2 must exist
# aarch64-specific builds should handle lib64 merging in their own assembly if needed

# Fix merged-bin layout: systemd now recommends /usr/sbin -> bin (merged-bin)
# This eliminates the "unmerged-bin" taint
# Merge /usr/sbin into /usr/bin and create symlink
if [ -d "$ROOTFS/usr/sbin" ] && [ ! -L "$ROOTFS/usr/sbin" ]; then
    mkdir -p "$ROOTFS/usr/bin"
    # Move all binaries from /usr/sbin to /usr/bin
    cp -a "$ROOTFS/usr/sbin/"* "$ROOTFS/usr/bin/" 2>/dev/null || true
    rm -rf "$ROOTFS/usr/sbin"
    ln -s bin "$ROOTFS/usr/sbin"
    echo "Merged /usr/sbin into /usr/bin (systemd merged-bin layout)"
fi

# Update /sbin symlink to point to usr/bin (not usr/sbin) for consistency
if [ -L "$ROOTFS/sbin" ]; then
    rm -f "$ROOTFS/sbin"
    ln -s usr/bin "$ROOTFS/sbin"
fi

# Create compatibility symlinks for /bin -> /usr/bin
# Many scripts expect common utilities in /bin (especially /bin/sh)
for cmd in sh bash; do
    if [ -f "$ROOTFS/usr/bin/$cmd" ] && [ ! -e "$ROOTFS/bin/$cmd" ]; then
        ln -sf ../usr/bin/$cmd "$ROOTFS/bin/$cmd"
    fi
done

# Set permissions
chmod 1777 "$ROOTFS/tmp"
chmod 755 "$ROOTFS/root"

# Automatically merge acct-user and acct-group files into /etc/passwd, /etc/group, /etc/shadow
# This processes all installed acct-user and acct-group packages
if [ -d "$ROOTFS/usr/share/acct-group" ] || [ -d "$ROOTFS/usr/share/acct-user" ]; then
    echo "Merging system users and groups from acct packages..."

    # Merge groups from acct-group packages
    if [ -d "$ROOTFS/usr/share/acct-group" ]; then
        for group_file in "$ROOTFS/usr/share/acct-group"/*.group; do
            if [ -f "$group_file" ]; then
                group_name=$(cut -d: -f1 "$group_file")
                # Only add if not already in /etc/group
                if ! grep -q "^${group_name}:" "$ROOTFS/etc/group" 2>/dev/null; then
                    cat "$group_file" >> "$ROOTFS/etc/group"
                    echo "  Added group: $group_name"
                fi
            fi
        done
    fi

    # Merge users from acct-user packages
    if [ -d "$ROOTFS/usr/share/acct-user" ]; then
        for passwd_file in "$ROOTFS/usr/share/acct-user"/*.passwd; do
            if [ -f "$passwd_file" ]; then
                user_name=$(cut -d: -f1 "$passwd_file")
                # Only add if not already in /etc/passwd
                if ! grep -q "^${user_name}:" "$ROOTFS/etc/passwd" 2>/dev/null; then
                    cat "$passwd_file" >> "$ROOTFS/etc/passwd"
                    echo "  Added user: $user_name"
                fi
            fi
        done

        # Merge shadow entries
        for shadow_file in "$ROOTFS/usr/share/acct-user"/*.shadow; do
            if [ -f "$shadow_file" ]; then
                user_name=$(cut -d: -f1 "$shadow_file")
                # Only add if not already in /etc/shadow
                if [ -f "$ROOTFS/etc/shadow" ]; then
                    if ! grep -q "^${user_name}:" "$ROOTFS/etc/shadow" 2>/dev/null; then
                        cat "$shadow_file" >> "$ROOTFS/etc/shadow"
                    fi
                fi
            fi
        done
    fi

    # Add users to supplementary groups (done AFTER all groups and users are merged)
    if [ -d "$ROOTFS/usr/share/acct-user" ]; then
        for groups_file in "$ROOTFS/usr/share/acct-user"/*.groups; do
            [ -f "$groups_file" ] || continue
            user_name=$(basename "$groups_file" .groups)

            # Read supplementary groups (comma-separated)
            supp_groups=$(cat "$groups_file")
            [ -n "$supp_groups" ] || continue

            # Process each group
            IFS=',' read -ra GROUP_ARRAY <<< "$supp_groups"
            for group_name in "${GROUP_ARRAY[@]}"; do
                # Check if group exists
                if ! grep -q "^${group_name}:" "$ROOTFS/etc/group" 2>/dev/null; then
                    continue
                fi

                # Check if user already in group (avoid duplicates)
                if grep -q "^${group_name}:.*[:,]${user_name}\\(,\\|[[:space:]]\\|\$\\)" "$ROOTFS/etc/group" 2>/dev/null; then
                    continue
                fi

                # Use awk to append user to group members - more reliable than sed
                awk -F: -v group="$group_name" -v user="$user_name" '
                BEGIN { OFS=":" }
                $1 == group {
                    # If members list is empty, just add the user
                    if ($4 == "") {
                        $4 = user
                    } else {
                        # Otherwise append with comma
                        $4 = $4 "," user
                    }
                }
                { print }
                ' "$ROOTFS/etc/group" > "$ROOTFS/etc/group.tmp"

                mv "$ROOTFS/etc/group.tmp" "$ROOTFS/etc/group"
                echo "  Added $user_name to group: $group_name"
            done
        done
    fi
fi

# Run ldconfig to generate dynamic linker cache (ld.so.cache)
# This ensures shared libraries are found at boot time
if [ -f "$ROOTFS/etc/ld.so.conf" ]; then
    ldconfig -r "$ROOTFS" 2>/dev/null || true
fi

# Note: C.UTF-8 locale is built into glibc and doesn't need generation
"""

    script = ctx.actions.write("assemble.sh", script_content, is_executable = True)

    cmd = cmd_args(["bash", script, rootfs_dir.as_output()])
    for pkg_dir in pkg_dirs:
        cmd.add(pkg_dir)

    ctx.actions.run(
        cmd,
        category = "rootfs",
        identifier = ctx.attrs.name,
    )

    return [DefaultInfo(default_output = rootfs_dir)]

rootfs = rule(
    impl = _rootfs_impl,
    attrs = {
        "packages": attrs.list(attrs.dep()),
    },
)

def _initramfs_impl(ctx: AnalysisContext) -> list[Provider]:
    """Create an initramfs cpio archive from a rootfs."""
    initramfs_file = ctx.actions.declare_output(ctx.attrs.name + ".cpio.gz")

    # Get rootfs directory from dependency
    rootfs_dir = ctx.attrs.rootfs[DefaultInfo].default_outputs[0]

    # Compression type
    compression = ctx.attrs.compression
    if compression == "gz":
        compress_cmd = "gzip -9"
        suffix = ".gz"
    elif compression == "xz":
        compress_cmd = "xz -9 --check=crc32"
        suffix = ".xz"
    elif compression == "lz4":
        compress_cmd = "lz4 -l -9"
        suffix = ".lz4"
    elif compression == "zstd":
        compress_cmd = "zstd -19"
        suffix = ".zstd"
    else:
        compress_cmd = "gzip -9"
        suffix = ".gz"

    # Init binary path
    init_path = ctx.attrs.init if ctx.attrs.init else "/sbin/init"

    # Optional custom init script (e.g. live-init for live CDs)
    init_script_src = None
    if ctx.attrs.init_script:
        init_script_src = ctx.attrs.init_script[DefaultInfo].default_outputs[0]

    script = ctx.actions.write(
        "create_initramfs.sh",
        """#!/bin/bash
set -e

ROOTFS="$1"
OUTPUT="$(realpath -m "$2")"
INIT_PATH="{init_path}"
INIT_SCRIPT="$3"
mkdir -p "$(dirname "$OUTPUT")"

# Create a temporary directory for initramfs modifications
WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT

# Copy rootfs to work directory
cp -a "$ROOTFS"/* "$WORK"/

# Fix aarch64 library paths - merge lib64 into lib and create symlinks
# aarch64 dynamic linker searches /lib and /usr/lib, not lib64
if [ -d "$WORK/lib64" ] && [ ! -L "$WORK/lib64" ]; then
    mkdir -p "$WORK/lib"
    cp -a "$WORK/lib64/"* "$WORK/lib/" 2>/dev/null || true
    rm -rf "$WORK/lib64"
    ln -sf lib "$WORK/lib64"
fi
if [ -d "$WORK/usr/lib64" ] && [ ! -L "$WORK/usr/lib64" ]; then
    mkdir -p "$WORK/usr/lib"
    cp -a "$WORK/usr/lib64/"* "$WORK/usr/lib/" 2>/dev/null || true
    rm -rf "$WORK/usr/lib64"
    ln -sf lib "$WORK/usr/lib64"
fi

# Install custom init script if provided
if [ -n "$INIT_SCRIPT" ] && [ -f "$INIT_SCRIPT" ]; then
    mkdir -p "$(dirname "$WORK$INIT_PATH")"
    cp "$INIT_SCRIPT" "$WORK$INIT_PATH"
    chmod +x "$WORK$INIT_PATH"
elif [ ! -e "$WORK$INIT_PATH" ]; then
    # Try to find busybox or create a minimal init
    if [ -x "$WORK/bin/busybox" ]; then
        mkdir -p "$WORK/sbin"
        ln -sf /bin/busybox "$WORK/sbin/init"
    elif [ -x "$WORK/bin/sh" ]; then
        # Create minimal init script
        cat > "$WORK/sbin/init" << 'INIT_EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
exec /bin/sh
INIT_EOF
        chmod +x "$WORK/sbin/init"
    fi
fi

# CRITICAL: Create /init at root for kernel to find
# The kernel looks for /init by default when booting from initramfs
if [ ! -e "$WORK/init" ]; then
    if [ -e "$WORK$INIT_PATH" ]; then
        # Create symlink from /init to the actual init
        ln -sf "$INIT_PATH" "$WORK/init"
    elif [ -x "$WORK/sbin/init" ]; then
        ln -sf /sbin/init "$WORK/init"
    elif [ -x "$WORK/bin/sh" ]; then
        # Fallback: create minimal /init script
        cat > "$WORK/init" << 'INIT_EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
exec /bin/sh
INIT_EOF
        chmod +x "$WORK/init"
    fi
fi

# Create the cpio archive
cd "$WORK"
find . -print0 | cpio --null -o -H newc | {compress_cmd} > "$OUTPUT"

echo "Created initramfs: $OUTPUT"
""".format(init_path = init_path, compress_cmd = compress_cmd),
        is_executable = True,
    )

    cmd = cmd_args([
        "bash",
        script,
        rootfs_dir,
        initramfs_file.as_output(),
        init_script_src if init_script_src else "",
    ])

    ctx.actions.run(
        cmd,
        category = "initramfs",
        identifier = ctx.attrs.name,
    )

    return [DefaultInfo(default_output = initramfs_file)]

initramfs = rule(
    impl = _initramfs_impl,
    attrs = {
        "rootfs": attrs.dep(),
        "compression": attrs.string(default = "gz"),
        "init": attrs.string(default = "/sbin/init"),
        "init_script": attrs.option(attrs.dep(), default = None),
    },
)

def _qemu_boot_script_impl(ctx: AnalysisContext) -> list[Provider]:
    """Generate a QEMU boot script for testing."""
    boot_script = ctx.actions.declare_output(ctx.attrs.name + ".sh")

    # Get kernel and initramfs
    kernel_dir = ctx.attrs.kernel[DefaultInfo].default_outputs[0]
    initramfs_file = ctx.attrs.initramfs[DefaultInfo].default_outputs[0]

    # QEMU options
    memory = ctx.attrs.memory
    cpus = ctx.attrs.cpus
    arch = ctx.attrs.arch
    extra_args = " ".join(ctx.attrs.extra_args) if ctx.attrs.extra_args else ""
    kernel_args = ctx.attrs.kernel_args if ctx.attrs.kernel_args else "console=ttyS0 quiet"

    # Determine QEMU binary based on architecture
    if arch == "x86_64":
        qemu_bin = "qemu-system-x86_64"
        machine = "q35"
    elif arch == "aarch64":
        qemu_bin = "qemu-system-aarch64"
        machine = "virt"
    elif arch == "riscv64":
        qemu_bin = "qemu-system-riscv64"
        machine = "virt"
    else:
        qemu_bin = "qemu-system-x86_64"
        machine = "q35"

    # Create a generator script that receives artifact paths as arguments
    generator_script = ctx.actions.write(
        "generate_qemu_script.sh",
        """#!/bin/bash
set -e
KERNEL_DIR="$1"
INITRAMFS="$2"
OUTPUT="$3"

cat > "$OUTPUT" << 'SCRIPT_EOF'
#!/bin/bash
# QEMU Boot Script for BuckOs
# Generated by Buck2 build system

set -e
unset CDPATH

# Find project root by locating buck-out directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
while [ "$PROJECT_ROOT" != "/" ]; do
    if [ -d "$PROJECT_ROOT/buck-out" ] && [ -f "$PROJECT_ROOT/.buckroot" -o -f "$PROJECT_ROOT/.buckconfig" ]; then
        break
    fi
    PROJECT_ROOT="$(dirname "$PROJECT_ROOT")"
done

if [ "$PROJECT_ROOT" = "/" ]; then
    # Fallback: assume script is in buck-out, find root by walking up past buck-out
    PROJECT_ROOT="$SCRIPT_DIR"
    while [[ "$PROJECT_ROOT" == *"/buck-out/"* ]]; do
        PROJECT_ROOT="$(dirname "$PROJECT_ROOT")"
    done
    PROJECT_ROOT="$(dirname "$PROJECT_ROOT")"
fi

cd "$PROJECT_ROOT"

# Paths to built artifacts (relative to project root)
KERNEL_DIR="KERNEL_DIR_PLACEHOLDER"
INITRAMFS="INITRAMFS_PLACEHOLDER"

# Find kernel image
KERNEL=""
for k in "$KERNEL_DIR/boot/vmlinuz"* "$KERNEL_DIR/boot/bzImage" "$KERNEL_DIR/vmlinuz"*; do
    if [ -f "$k" ]; then
        KERNEL="$k"
        break
    fi
done

if [ -z "$KERNEL" ]; then
    echo "Error: Cannot find kernel image in $KERNEL_DIR"
    echo "Searched patterns:"
    echo "  $KERNEL_DIR/boot/vmlinuz*"
    echo "  $KERNEL_DIR/boot/bzImage"
    echo "  $KERNEL_DIR/vmlinuz*"
    echo "Project root: $PROJECT_ROOT"
    exit 1
fi

echo "Booting BuckOs with QEMU..."
echo "  Kernel: $KERNEL"
echo "  Initramfs: $INITRAMFS"
echo ""
echo "Press Ctrl-A X to exit QEMU"
echo ""

{qemu_bin} \\
    -machine {machine} \\
    -m {memory} \\
    -smp {cpus} \\
    -kernel "$KERNEL" \\
    -initrd "$INITRAMFS" \\
    -append "{kernel_args}" \\
    -nographic \\
    -no-reboot \\
    {extra_args} \\
    "$@"
SCRIPT_EOF

# Replace placeholders with actual paths
sed -i "s|KERNEL_DIR_PLACEHOLDER|$KERNEL_DIR|g" "$OUTPUT"
sed -i "s|INITRAMFS_PLACEHOLDER|$INITRAMFS|g" "$OUTPUT"
chmod +x "$OUTPUT"
""".format(
            qemu_bin = qemu_bin,
            machine = machine,
            memory = memory,
            cpus = cpus,
            kernel_args = kernel_args,
            extra_args = extra_args,
        ),
        is_executable = True,
    )

    cmd = cmd_args([
        "bash",
        generator_script,
        kernel_dir,
        initramfs_file,
        boot_script.as_output(),
    ])

    ctx.actions.run(
        cmd,
        category = "qemu_boot_script",
        identifier = ctx.attrs.name,
    )

    return [DefaultInfo(default_output = boot_script)]

qemu_boot_script = rule(
    impl = _qemu_boot_script_impl,
    attrs = {
        "kernel": attrs.dep(),
        "initramfs": attrs.dep(),
        "arch": attrs.string(default = "x86_64"),
        "memory": attrs.string(default = "512M"),
        "cpus": attrs.string(default = "2"),
        "kernel_args": attrs.string(default = "console=ttyS0 quiet"),
        "extra_args": attrs.list(attrs.string(), default = []),
    },
)

# =============================================================================
# Cloud Hypervisor Boot Script Rule
# =============================================================================

def _ch_boot_script_impl(ctx: AnalysisContext) -> list[Provider]:
    """Generate a Cloud Hypervisor boot script with multiple boot modes."""
    boot_script = ctx.actions.declare_output(ctx.attrs.name + ".sh")

    # Get kernel (required for direct and virtiofs modes)
    kernel_dir = None
    if ctx.attrs.kernel:
        kernel_dir = ctx.attrs.kernel[DefaultInfo].default_outputs[0]

    # Get firmware if provided
    firmware_file = None
    if ctx.attrs.firmware:
        firmware_file = ctx.attrs.firmware[DefaultInfo].default_outputs[0]

    # Get disk image if provided
    disk_image_file = None
    if ctx.attrs.disk_image:
        disk_image_file = ctx.attrs.disk_image[DefaultInfo].default_outputs[0]

    # Get initramfs if provided
    initramfs_file = None
    if ctx.attrs.initramfs:
        initramfs_file = ctx.attrs.initramfs[DefaultInfo].default_outputs[0]

    # Boot mode configuration
    boot_mode = ctx.attrs.boot_mode
    memory = ctx.attrs.memory
    cpus = ctx.attrs.cpus
    kernel_args = ctx.attrs.kernel_args
    extra_args = " ".join(ctx.attrs.extra_args) if ctx.attrs.extra_args else ""

    # Network configuration
    network_mode = ctx.attrs.network_mode
    tap_name = ctx.attrs.tap_name

    # VirtioFS configuration
    virtiofs_socket = ctx.attrs.virtiofs_socket
    virtiofs_tag = ctx.attrs.virtiofs_tag
    virtiofs_path = ctx.attrs.virtiofs_path

    # Serial console
    serial_console = ctx.attrs.serial_console

    # Build kernel path detection
    kernel_section = ""
    if kernel_dir:
        kernel_section = """
# Find kernel image
KERNEL=""
for k in "$KERNEL_DIR/boot/vmlinuz"* "$KERNEL_DIR/boot/bzImage" "$KERNEL_DIR/vmlinuz"* "$KERNEL_DIR/vmlinux"*; do
    if [ -f "$k" ]; then
        KERNEL="$k"
        break
    fi
done

if [ -z "$KERNEL" ]; then
    echo "Error: Cannot find kernel image in $KERNEL_DIR"
    exit 1
fi
echo "  Kernel: $KERNEL"
"""

    # Build disk image section
    disk_section = ""
    if disk_image_file:
        disk_section = """
# Check disk image
if [ ! -f "{disk_image}" ]; then
    echo "Error: Disk image not found: {disk_image}"
    exit 1
fi
echo "  Disk: {disk_image}"
DISK_ARGS="--disk path={disk_image}"
""".format(disk_image = disk_image_file)
    else:
        disk_section = """
DISK_ARGS=""
"""

    # Build initramfs section
    initramfs_section = ""
    if initramfs_file:
        initramfs_section = """
# Check initramfs
if [ ! -f "{initramfs}" ]; then
    echo "Error: Initramfs not found: {initramfs}"
    exit 1
fi
echo "  Initramfs: {initramfs}"
INITRAMFS_ARGS="--initramfs {initramfs}"
""".format(initramfs = initramfs_file)
    else:
        initramfs_section = """
INITRAMFS_ARGS=""
"""

    # Build firmware section
    firmware_section = ""
    if firmware_file and boot_mode == "firmware":
        firmware_section = """
# Check firmware
FIRMWARE="{firmware}"
if [ ! -f "$FIRMWARE" ]; then
    echo "Error: Firmware not found: $FIRMWARE"
    exit 1
fi
echo "  Firmware: $FIRMWARE"
""".format(firmware = firmware_file)

    # Build network section
    network_section = ""
    if network_mode == "tap":
        network_section = """
# Network configuration (TAP)
# Note: TAP device must be created beforehand:
#   sudo ip tuntap add dev {tap_name} mode tap
#   sudo ip addr add 192.168.100.1/24 dev {tap_name}
#   sudo ip link set {tap_name} up
if [ ! -e "/sys/class/net/{tap_name}" ]; then
    echo "Warning: TAP device {tap_name} not found. Create with:"
    echo "  sudo ip tuntap add dev {tap_name} mode tap"
    echo "  sudo ip addr add 192.168.100.1/24 dev {tap_name}"
    echo "  sudo ip link set {tap_name} up"
fi
NET_ARGS="--net tap={tap_name},mac=12:34:56:78:9a:bc"
""".format(tap_name = tap_name)
    else:
        network_section = """
NET_ARGS=""
"""

    # Build VirtioFS section
    virtiofs_section = ""
    if boot_mode == "virtiofs":
        virtiofs_section = """
# VirtioFS configuration
# Start virtiofsd in background if not already running
VIRTIOFS_SOCKET="{socket}"
VIRTIOFS_PATH="${{VIRTIOFS_PATH:-{default_path}}}"

if [ ! -S "$VIRTIOFS_SOCKET" ]; then
    echo "Starting virtiofsd..."
    echo "  Socket: $VIRTIOFS_SOCKET"
    echo "  Share path: $VIRTIOFS_PATH"

    # Ensure socket directory exists
    mkdir -p "$(dirname "$VIRTIOFS_SOCKET")"

    # Start virtiofsd
    virtiofsd --socket-path="$VIRTIOFS_SOCKET" \\
        --shared-dir="$VIRTIOFS_PATH" \\
        --cache=auto \\
        --sandbox=chroot &
    VIRTIOFS_PID=$!
    echo "  virtiofsd PID: $VIRTIOFS_PID"

    # Wait for socket
    for i in $(seq 1 10); do
        if [ -S "$VIRTIOFS_SOCKET" ]; then
            break
        fi
        sleep 0.5
    done

    if [ ! -S "$VIRTIOFS_SOCKET" ]; then
        echo "Error: virtiofsd failed to start"
        exit 1
    fi
fi

FS_ARGS="--fs tag={tag},socket=$VIRTIOFS_SOCKET"
# VirtioFS requires shared memory
MEMORY_ARGS="size={memory},shared=on"
""".format(
            socket = virtiofs_socket,
            default_path = virtiofs_path,
            tag = virtiofs_tag,
            memory = memory,
        )
    else:
        virtiofs_section = """
FS_ARGS=""
MEMORY_ARGS="size={memory}"
""".format(memory = memory)

    # Build the command based on boot mode
    if boot_mode == "direct":
        # Direct kernel boot (PVH or standard)
        boot_cmd = """
# Direct kernel boot
exec cloud-hypervisor \\
    --cpus boot={cpus} \\
    --memory $MEMORY_ARGS \\
    --kernel "$KERNEL" \\
    $INITRAMFS_ARGS \\
    --cmdline "{kernel_args}" \\
    $DISK_ARGS \\
    $NET_ARGS \\
    $FS_ARGS \\
    --serial {serial} \\
    --console off \\
    {extra_args} \\
    "$@"
""".format(
            cpus = cpus,
            kernel_args = kernel_args,
            serial = serial_console,
            extra_args = extra_args,
        )
    elif boot_mode == "firmware":
        # Boot via firmware (rust-hypervisor-firmware or EDK2)
        boot_cmd = """
# Firmware boot
exec cloud-hypervisor \\
    --cpus boot={cpus} \\
    --memory $MEMORY_ARGS \\
    --kernel "$FIRMWARE" \\
    $DISK_ARGS \\
    $NET_ARGS \\
    $FS_ARGS \\
    --serial {serial} \\
    --console off \\
    {extra_args} \\
    "$@"
""".format(
            cpus = cpus,
            serial = serial_console,
            extra_args = extra_args,
        )
    elif boot_mode == "virtiofs":
        # VirtioFS rootfs boot (no disk image)
        boot_cmd = """
# VirtioFS boot (rootfs via shared filesystem)
exec cloud-hypervisor \\
    --cpus boot={cpus} \\
    --memory $MEMORY_ARGS \\
    --kernel "$KERNEL" \\
    $INITRAMFS_ARGS \\
    --cmdline "{kernel_args} root={tag} rootfstype=virtiofs rw" \\
    $NET_ARGS \\
    $FS_ARGS \\
    --serial {serial} \\
    --console off \\
    {extra_args} \\
    "$@"
""".format(
            cpus = cpus,
            kernel_args = kernel_args,
            tag = virtiofs_tag,
            serial = serial_console,
            extra_args = extra_args,
        )
    else:
        boot_cmd = """
echo "Error: Unknown boot mode: {boot_mode}"
exit 1
""".format(boot_mode = boot_mode)

    script_content = """#!/bin/bash
# Cloud Hypervisor Boot Script for BuckOs
# Generated by Buck2 build system
# Boot mode: {boot_mode}

set -e
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Paths to built artifacts
{kernel_dir_var}

echo "Booting BuckOs with Cloud Hypervisor..."
echo "  Boot mode: {boot_mode}"
{kernel_section}
{disk_section}
{initramfs_section}
{firmware_section}
{network_section}
{virtiofs_section}

echo ""
echo "Press Ctrl-C to stop Cloud Hypervisor"
echo ""

{boot_cmd}
""".format(
        boot_mode = boot_mode,
        kernel_dir_var = 'KERNEL_DIR="{}"'.format(kernel_dir) if kernel_dir else "",
        kernel_section = kernel_section,
        disk_section = disk_section,
        initramfs_section = initramfs_section,
        firmware_section = firmware_section,
        network_section = network_section,
        virtiofs_section = virtiofs_section,
        boot_cmd = boot_cmd,
    )

    ctx.actions.write(
        boot_script.as_output(),
        script_content,
        is_executable = True,
    )

    return [DefaultInfo(default_output = boot_script)]

ch_boot_script = rule(
    impl = _ch_boot_script_impl,
    attrs = {
        "kernel": attrs.option(attrs.dep(), default = None),
        "firmware": attrs.option(attrs.dep(), default = None),
        "disk_image": attrs.option(attrs.dep(), default = None),
        "initramfs": attrs.option(attrs.dep(), default = None),
        "boot_mode": attrs.string(default = "direct"),  # direct, firmware, virtiofs
        "memory": attrs.string(default = "512M"),
        "cpus": attrs.string(default = "2"),
        "kernel_args": attrs.string(default = "console=ttyS0 quiet"),
        "network_mode": attrs.string(default = "none"),  # none, tap
        "tap_name": attrs.string(default = "tap0"),
        "virtiofs_socket": attrs.string(default = "/tmp/virtiofs.sock"),
        "virtiofs_tag": attrs.string(default = "rootfs"),
        "virtiofs_path": attrs.string(default = "/tmp/rootfs"),
        "serial_console": attrs.string(default = "tty"),
        "extra_args": attrs.list(attrs.string(), default = []),
    },
)

# =============================================================================
# Raw Disk Image Rule
# =============================================================================

def _raw_disk_image_impl(ctx: AnalysisContext) -> list[Provider]:
    """Create a raw disk image from a rootfs (for Cloud Hypervisor)."""
    image_file = ctx.actions.declare_output(ctx.attrs.name + ".raw")

    # Get rootfs directory
    rootfs_dir = ctx.attrs.rootfs[DefaultInfo].default_outputs[0]

    # Configuration
    size = ctx.attrs.size
    filesystem = ctx.attrs.filesystem
    label = ctx.attrs.label if ctx.attrs.label else ctx.attrs.name
    partition_table = ctx.attrs.partition_table

    # Build the script to create the disk image
    if partition_table:
        # GPT partition table with EFI system partition
        script_content = """#!/bin/bash
set -e

ROOTFS="$1"
OUTPUT="$2"
SIZE="{size}"
FS="{filesystem}"
LABEL="{label}"

echo "Creating raw disk image with GPT partition table..."
echo "  Size: $SIZE"
echo "  Filesystem: $FS"
echo "  Label: $LABEL"

# Create sparse file
truncate -s "$SIZE" "$OUTPUT"

# Create GPT partition table
# Partition 1: EFI System Partition (100M)
# Partition 2: Root filesystem (rest)
sgdisk -Z "$OUTPUT"
sgdisk -n 1:2048:+100M -t 1:EF00 -c 1:"EFI" "$OUTPUT"
sgdisk -n 2:0:0 -t 2:8300 -c 2:"$LABEL" "$OUTPUT"

# Get partition offsets
EFI_START=$((2048 * 512))
EFI_SIZE=$((100 * 1024 * 1024))
ROOT_START=$(($(sgdisk -p "$OUTPUT" | grep "^ *2" | awk '{{print $2}}') * 512))

# Create filesystems using loop device
LOOP=$(losetup --find --show --partscan "$OUTPUT")
trap "losetup -d $LOOP" EXIT

# Wait for partitions to appear
sleep 1

# Format EFI partition
mkfs.vfat -F 32 -n EFI "${{LOOP}}p1"

# Format root partition
case "$FS" in
    ext4)
        mkfs.ext4 -F -L "$LABEL" "${{LOOP}}p2"
        ;;
    xfs)
        mkfs.xfs -f -L "$LABEL" "${{LOOP}}p2"
        ;;
    btrfs)
        mkfs.btrfs -f -L "$LABEL" "${{LOOP}}p2"
        ;;
    *)
        echo "Unsupported filesystem: $FS"
        exit 1
        ;;
esac

# Mount and copy rootfs
MOUNT_DIR=$(mktemp -d)
trap "umount -R $MOUNT_DIR 2>/dev/null || true; rm -rf $MOUNT_DIR; losetup -d $LOOP" EXIT

mount "${{LOOP}}p2" "$MOUNT_DIR"
mkdir -p "$MOUNT_DIR/boot/efi"
mount "${{LOOP}}p1" "$MOUNT_DIR/boot/efi"

# Copy rootfs
cp -a "$ROOTFS"/* "$MOUNT_DIR"/ || true

# Unmount
sync
umount "$MOUNT_DIR/boot/efi"
umount "$MOUNT_DIR"

echo "Disk image created: $OUTPUT"
""".format(
            size = size,
            filesystem = filesystem,
            label = label,
        )
    else:
        # Simple raw image without partition table
        script_content = """#!/bin/bash
set -e

ROOTFS="$1"
OUTPUT="$2"
SIZE="{size}"
FS="{filesystem}"
LABEL="{label}"

echo "Creating raw disk image..."
echo "  Size: $SIZE"
echo "  Filesystem: $FS"
echo "  Label: $LABEL"

# Create sparse file
truncate -s "$SIZE" "$OUTPUT"

# Create filesystem directly on the image
case "$FS" in
    ext4)
        mkfs.ext4 -F -L "$LABEL" "$OUTPUT"
        ;;
    xfs)
        mkfs.xfs -f -L "$LABEL" "$OUTPUT"
        ;;
    btrfs)
        mkfs.btrfs -f -L "$LABEL" "$OUTPUT"
        ;;
    *)
        echo "Unsupported filesystem: $FS"
        exit 1
        ;;
esac

# Mount and copy rootfs
MOUNT_DIR=$(mktemp -d)
trap "umount $MOUNT_DIR 2>/dev/null || true; rm -rf $MOUNT_DIR" EXIT

mount -o loop "$OUTPUT" "$MOUNT_DIR"

# Copy rootfs
cp -a "$ROOTFS"/* "$MOUNT_DIR"/ || true

# Unmount
sync
umount "$MOUNT_DIR"

echo "Disk image created: $OUTPUT"
""".format(
            size = size,
            filesystem = filesystem,
            label = label,
        )

    script = ctx.actions.write("create_disk.sh", script_content, is_executable = True)

    # Note: This requires root/fakeroot to create the filesystem
    # In practice, this would be run with appropriate privileges
    # Build the command properly with cmd_args for Buck2
    cmd = cmd_args()
    cmd.add("bash")
    cmd.add(script)
    cmd.add(rootfs_dir)
    cmd.add(image_file.as_output())

    ctx.actions.run(
        cmd,
        category = "disk_image",
        identifier = ctx.attrs.name,
    )

    return [DefaultInfo(default_output = image_file)]

raw_disk_image = rule(
    impl = _raw_disk_image_impl,
    attrs = {
        "rootfs": attrs.dep(),
        "size": attrs.string(default = "2G"),
        "filesystem": attrs.string(default = "ext4"),  # ext4, xfs, btrfs
        "label": attrs.option(attrs.string(), default = None),
        "partition_table": attrs.bool(default = False),  # True for GPT with EFI
    },
)

def _iso_image_impl(ctx: AnalysisContext) -> list[Provider]:
    """Create a bootable ISO image from kernel, initramfs, and optional rootfs."""
    iso_file = ctx.actions.declare_output(ctx.attrs.name + ".iso")

    # Get kernel and initramfs
    kernel_dir = ctx.attrs.kernel[DefaultInfo].default_outputs[0]
    initramfs_file = ctx.attrs.initramfs[DefaultInfo].default_outputs[0]

    # Optional rootfs for live system
    rootfs_dir = None
    if ctx.attrs.rootfs:
        rootfs_dir = ctx.attrs.rootfs[DefaultInfo].default_outputs[0]

    # Boot mode configuration
    boot_mode = ctx.attrs.boot_mode
    volume_label = ctx.attrs.volume_label
    kernel_args = ctx.attrs.kernel_args if ctx.attrs.kernel_args else "quiet"
    arch = ctx.attrs.arch if ctx.attrs.arch else "x86_64"

    # Architecture-specific EFI configuration
    if arch == "aarch64":
        efi_boot_file = "BOOTAA64.EFI"
        grub_format = "arm64-efi"
        # ARM64 doesn't use BIOS boot, force EFI if BIOS was requested
        if boot_mode == "bios":
            boot_mode = "efi"
    else:
        efi_boot_file = "BOOTX64.EFI"
        grub_format = "x86_64-efi"

    # GRUB configuration for EFI boot
    # Add serial console settings for aarch64 (needed for QEMU headless testing)
    if arch == "aarch64":
        grub_cfg = """
# GRUB configuration for BuckOS ISO (aarch64)
# Serial console for headless boot (QEMU virt uses ttyAMA0)
serial --unit=0 --speed=115200
terminal_input serial console
terminal_output serial console

set timeout=5
set default=0

menuentry "BuckOS Linux" {{
    linux /boot/vmlinuz {kernel_args} init=/init console=ttyAMA0,115200 console=tty0
    initrd /boot/initramfs.img
}}

menuentry "BuckOS Linux (recovery mode)" {{
    linux /boot/vmlinuz {kernel_args} init=/init console=ttyAMA0,115200 console=tty0 single
    initrd /boot/initramfs.img
}}

menuentry "BuckOS Linux (serial console only)" {{
    linux /boot/vmlinuz {kernel_args} init=/init console=ttyAMA0,115200
    initrd /boot/initramfs.img
}}
""".format(kernel_args = kernel_args)
    else:
        grub_cfg = """
# GRUB configuration for BuckOS ISO
set timeout=5
set default=0

menuentry "BuckOS Linux" {{
    linux /boot/vmlinuz {kernel_args}
    initrd /boot/initramfs.img
}}

menuentry "BuckOS Linux (recovery mode)" {{
    linux /boot/vmlinuz {kernel_args} single
    initrd /boot/initramfs.img
}}
""".format(kernel_args = kernel_args)

    # Isolinux configuration for BIOS boot
    isolinux_cfg = """
DEFAULT buckos
TIMEOUT 50
PROMPT 1

LABEL buckos
    MENU LABEL BuckOS Linux
    LINUX /boot/vmlinuz
    INITRD /boot/initramfs.img
    APPEND {kernel_args}

LABEL recovery
    MENU LABEL BuckOS Linux (recovery mode)
    LINUX /boot/vmlinuz
    INITRD /boot/initramfs.img
    APPEND {kernel_args} single
""".format(kernel_args = kernel_args)

    # Determine if we should include squashfs rootfs
    include_rootfs = "yes" if rootfs_dir else ""

    script = ctx.actions.write(
        "create_iso.sh",
        """#!/bin/bash
set -e

ISO_OUT="$1"
KERNEL_DIR="$2"
INITRAMFS="$3"
ROOTFS_DIR="$4"
BOOT_MODE="{boot_mode}"
VOLUME_LABEL="{volume_label}"
EFI_BOOT_FILE="{efi_boot_file}"
GRUB_FORMAT="{grub_format}"
TARGET_ARCH="{arch}"

# Create ISO working directory
WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT

mkdir -p "$WORK/boot"
mkdir -p "$WORK/boot/grub"
mkdir -p "$WORK/isolinux"
mkdir -p "$WORK/EFI/BOOT"

# Find and copy kernel
KERNEL=""
for k in "$KERNEL_DIR/boot/vmlinuz"* "$KERNEL_DIR/boot/bzImage" "$KERNEL_DIR/boot/Image" "$KERNEL_DIR/vmlinuz"* "$KERNEL_DIR/Image"*; do
    if [ -f "$k" ]; then
        KERNEL="$k"
        break
    fi
done

if [ -z "$KERNEL" ]; then
    echo "Error: Cannot find kernel image in $KERNEL_DIR"
    exit 1
fi

cp "$KERNEL" "$WORK/boot/vmlinuz"
cp "$INITRAMFS" "$WORK/boot/initramfs.img"

# Create GRUB configuration
cat > "$WORK/boot/grub/grub.cfg" << 'GRUBCFG'
{grub_cfg}
GRUBCFG

# Create isolinux configuration
cat > "$WORK/isolinux/isolinux.cfg" << 'ISOCFG'
{isolinux_cfg}
ISOCFG

# Include rootfs as squashfs if provided
if [ -n "{include_rootfs}" ] && [ -d "$ROOTFS_DIR" ]; then
    echo "Creating squashfs from rootfs..."
    mkdir -p "$WORK/live"

    # Create a working copy of rootfs to add kernel modules
    ROOTFS_WORK=$(mktemp -d)
    cp -a "$ROOTFS_DIR/." "$ROOTFS_WORK/"

    # Copy kernel modules from kernel build to rootfs
    if [ -d "$KERNEL_DIR/lib/modules" ]; then
        echo "Copying kernel modules to rootfs..."
        mkdir -p "$ROOTFS_WORK/lib/modules"
        cp -a "$KERNEL_DIR/lib/modules/." "$ROOTFS_WORK/lib/modules/"
        # Run depmod to generate modules.dep
        KVER=$(ls "$KERNEL_DIR/lib/modules" | head -1)
        if [ -n "$KVER" ] && command -v depmod >/dev/null 2>&1; then
            echo "Running depmod for kernel $KVER..."
            depmod -b "$ROOTFS_WORK" "$KVER" 2>/dev/null || true
        fi
    fi

    if command -v mksquashfs >/dev/null 2>&1; then
        mksquashfs "$ROOTFS_WORK" "$WORK/live/filesystem.squashfs" -comp xz -no-progress
    else
        echo "Warning: mksquashfs not found, skipping rootfs inclusion"
    fi

    rm -rf "$ROOTFS_WORK"
fi

# Create the ISO image based on boot mode
echo "Creating ISO image with boot mode: $BOOT_MODE"

if [ "$BOOT_MODE" = "bios" ] || [ "$BOOT_MODE" = "hybrid" ]; then
    # Check for isolinux/syslinux
    ISOLINUX_BIN=""
    for path in /usr/lib/syslinux/bios/isolinux.bin /usr/share/syslinux/isolinux.bin /usr/lib/ISOLINUX/isolinux.bin; do
        if [ -f "$path" ]; then
            ISOLINUX_BIN="$path"
            break
        fi
    done

    if [ -n "$ISOLINUX_BIN" ]; then
        cp "$ISOLINUX_BIN" "$WORK/isolinux/"

        # Copy ldlinux.c32 if available
        LDLINUX=""
        for path in /usr/lib/syslinux/bios/ldlinux.c32 /usr/share/syslinux/ldlinux.c32 /usr/lib/syslinux/ldlinux.c32; do
            if [ -f "$path" ]; then
                LDLINUX="$path"
                break
            fi
        done
        [ -n "$LDLINUX" ] && cp "$LDLINUX" "$WORK/isolinux/"
    fi
fi

# Create ISO using xorriso (preferred) or genisoimage
if command -v xorriso >/dev/null 2>&1; then
    case "$BOOT_MODE" in
        bios)
            ISOHDPFX=""
            for mbr in /usr/lib/syslinux/bios/isohdpfx.bin /usr/share/syslinux/isohdpfx.bin; do
                if [ -f "$mbr" ]; then ISOHDPFX="$mbr"; break; fi
            done
            xorriso -as mkisofs \\
                -o "$ISO_OUT" \\
                ${{ISOHDPFX:+-isohybrid-mbr "$ISOHDPFX"}} \\
                -c isolinux/boot.cat \\
                -b isolinux/isolinux.bin \\
                -no-emul-boot \\
                -boot-load-size 4 \\
                -boot-info-table \\
                -V "$VOLUME_LABEL" \\
                "$WORK"
            ;;
        efi)
            # Create EFI boot image
            mkdir -p "$WORK/EFI/BOOT"
            GRUB_MKIMAGE=""
            if command -v grub2-mkimage >/dev/null 2>&1; then
                GRUB_MKIMAGE="grub2-mkimage"
            elif command -v grub-mkimage >/dev/null 2>&1; then
                GRUB_MKIMAGE="grub-mkimage"
            fi
            if [ -n "$GRUB_MKIMAGE" ]; then
                $GRUB_MKIMAGE -o "$WORK/EFI/BOOT/$EFI_BOOT_FILE" -O $GRUB_FORMAT -p /boot/grub \\
                    part_gpt part_msdos fat iso9660 normal boot linux configfile loopback chain \\
                    efifwsetup efi_gop ls search search_label search_fs_uuid search_fs_file \\
                    gfxterm gfxterm_background gfxterm_menu test all_video loadenv exfat ext2 ntfs serial \\
                    2>/dev/null || echo "Warning: $GRUB_MKIMAGE failed"
            else
                echo "Warning: neither grub-mkimage nor grub2-mkimage found"
            fi

            # Create EFI boot image file
            dd if=/dev/zero of="$WORK/boot/efi.img" bs=1M count=10
            if command -v mkfs.vfat >/dev/null 2>&1; then
                mkfs.vfat "$WORK/boot/efi.img"
            elif command -v mformat >/dev/null 2>&1; then
                mformat -i "$WORK/boot/efi.img" -F ::
            fi
            mmd -i "$WORK/boot/efi.img" ::/EFI ::/EFI/BOOT
            mcopy -i "$WORK/boot/efi.img" "$WORK/EFI/BOOT/$EFI_BOOT_FILE" ::/EFI/BOOT/ 2>/dev/null || true

            xorriso -as mkisofs \\
                -o "$ISO_OUT" \\
                -e boot/efi.img \\
                -no-emul-boot \\
                -V "$VOLUME_LABEL" \\
                "$WORK"
            ;;
        hybrid|*)
            # Hybrid BIOS+EFI boot
            # Create EFI boot image
            mkdir -p "$WORK/EFI/BOOT"
            GRUB_MKIMAGE=""
            if command -v grub2-mkimage >/dev/null 2>&1; then
                GRUB_MKIMAGE="grub2-mkimage"
            elif command -v grub-mkimage >/dev/null 2>&1; then
                GRUB_MKIMAGE="grub-mkimage"
            fi
            if [ -n "$GRUB_MKIMAGE" ]; then
                $GRUB_MKIMAGE -o "$WORK/EFI/BOOT/$EFI_BOOT_FILE" -O $GRUB_FORMAT -p /boot/grub \\
                    part_gpt part_msdos fat iso9660 normal boot linux configfile loopback chain \\
                    efifwsetup efi_gop ls search search_label search_fs_uuid search_fs_file \\
                    gfxterm gfxterm_background gfxterm_menu test all_video loadenv exfat ext2 ntfs serial \\
                    2>/dev/null || echo "Warning: $GRUB_MKIMAGE failed"
            else
                echo "Warning: neither grub-mkimage nor grub2-mkimage found"
            fi

            # Create EFI boot image file
            dd if=/dev/zero of="$WORK/boot/efi.img" bs=1M count=10
            if command -v mkfs.vfat >/dev/null 2>&1; then
                mkfs.vfat "$WORK/boot/efi.img"
            elif command -v mformat >/dev/null 2>&1; then
                mformat -i "$WORK/boot/efi.img" -F ::
            else
                echo "Warning: No FAT formatter found (mkfs.vfat or mformat)"
            fi
            if command -v mmd >/dev/null 2>&1; then
                mmd -i "$WORK/boot/efi.img" ::/EFI ::/EFI/BOOT
                mcopy -i "$WORK/boot/efi.img" "$WORK/EFI/BOOT/$EFI_BOOT_FILE" ::/EFI/BOOT/ 2>/dev/null || true
            fi

            # Build ISO - detect available boot methods
            ISOHDPFX=""
            for mbr in /usr/lib/syslinux/bios/isohdpfx.bin /usr/share/syslinux/isohdpfx.bin; do
                if [ -f "$mbr" ]; then ISOHDPFX="$mbr"; break; fi
            done

            HAS_BIOS=false
            if [ -f "$WORK/isolinux/isolinux.bin" ]; then
                HAS_BIOS=true
            fi

            HAS_EFI=false
            if [ -f "$WORK/boot/efi.img" ]; then
                HAS_EFI=true
            fi

            if $HAS_BIOS && $HAS_EFI; then
                # Full hybrid: BIOS + EFI
                xorriso -as mkisofs \\
                    -o "$ISO_OUT" \\
                    ${{ISOHDPFX:+-isohybrid-mbr "$ISOHDPFX"}} \\
                    -c isolinux/boot.cat \\
                    -b isolinux/isolinux.bin \\
                    -no-emul-boot \\
                    -boot-load-size 4 \\
                    -boot-info-table \\
                    -eltorito-alt-boot \\
                    -e boot/efi.img \\
                    -no-emul-boot \\
                    -isohybrid-gpt-basdat \\
                    -V "$VOLUME_LABEL" \\
                    "$WORK"
            elif $HAS_EFI; then
                # EFI only
                xorriso -as mkisofs \\
                    -o "$ISO_OUT" \\
                    -e boot/efi.img \\
                    -no-emul-boot \\
                    -isohybrid-gpt-basdat \\
                    -V "$VOLUME_LABEL" \\
                    "$WORK"
            elif $HAS_BIOS; then
                # BIOS only
                xorriso -as mkisofs \\
                    -o "$ISO_OUT" \\
                    ${{ISOHDPFX:+-isohybrid-mbr "$ISOHDPFX"}} \\
                    -c isolinux/boot.cat \\
                    -b isolinux/isolinux.bin \\
                    -no-emul-boot \\
                    -boot-load-size 4 \\
                    -boot-info-table \\
                    -V "$VOLUME_LABEL" \\
                    "$WORK"
            else
                # No bootloader available, create data-only ISO
                echo "Warning: No BIOS or EFI boot images found, creating non-bootable ISO"
                xorriso -as mkisofs \\
                    -o "$ISO_OUT" \\
                    -V "$VOLUME_LABEL" \\
                    -J -R \\
                    "$WORK"
            fi
            ;;
    esac
elif command -v genisoimage >/dev/null 2>&1; then
    genisoimage \\
        -o "$ISO_OUT" \\
        -b isolinux/isolinux.bin \\
        -c isolinux/boot.cat \\
        -no-emul-boot \\
        -boot-load-size 4 \\
        -boot-info-table \\
        -V "$VOLUME_LABEL" \\
        -J -R \\
        "$WORK"
elif command -v mkisofs >/dev/null 2>&1; then
    mkisofs \\
        -o "$ISO_OUT" \\
        -b isolinux/isolinux.bin \\
        -c isolinux/boot.cat \\
        -no-emul-boot \\
        -boot-load-size 4 \\
        -boot-info-table \\
        -V "$VOLUME_LABEL" \\
        -J -R \\
        "$WORK"
else
    echo "Error: No ISO creation tool found (xorriso, genisoimage, or mkisofs required)"
    exit 1
fi

echo "Created ISO image: $ISO_OUT"
ls -lh "$ISO_OUT"
""".format(
            boot_mode = boot_mode,
            volume_label = volume_label,
            grub_cfg = grub_cfg,
            isolinux_cfg = isolinux_cfg,
            include_rootfs = include_rootfs,
            efi_boot_file = efi_boot_file,
            grub_format = grub_format,
            arch = arch,
        ),
        is_executable = True,
    )

    rootfs_arg = rootfs_dir if rootfs_dir else ""

    ctx.actions.run(
        cmd_args([
            "bash",
            script,
            iso_file.as_output(),
            kernel_dir,
            initramfs_file,
            rootfs_arg,
        ]),
        category = "iso",
        identifier = ctx.attrs.name,
    )

    return [DefaultInfo(default_output = iso_file)]

iso_image = rule(
    impl = _iso_image_impl,
    attrs = {
        "kernel": attrs.dep(),
        "initramfs": attrs.dep(),
        "rootfs": attrs.option(attrs.dep(), default = None),
        "boot_mode": attrs.string(default = "hybrid"),  # bios, efi, or hybrid
        "volume_label": attrs.string(default = "BUCKOS"),
        "kernel_args": attrs.string(default = "quiet"),
        "arch": attrs.string(default = "x86_64"),  # x86_64 or aarch64
    },
)

# =============================================================================
# STAGE3 TARBALL
# =============================================================================
# Creates a stage3 tarball from a rootfs for distribution.
# Stage3 tarballs are self-contained root filesystems with a complete
# toolchain that can be used to bootstrap new BuckOS installations.

def _stage3_tarball_impl(ctx: AnalysisContext) -> list[Provider]:
    """Create a stage3 tarball from a rootfs with metadata."""

    # Determine compression settings
    compression = ctx.attrs.compression
    compress_opts = {
        "xz": ("-J", ".tar.xz", "xz -9 -T0"),
        "gz": ("-z", ".tar.gz", "gzip -9"),
        "zstd": ("--zstd", ".tar.zst", "zstd -19 -T0"),
    }

    if compression not in compress_opts:
        fail("Unsupported compression: {}. Use xz, gz, or zstd".format(compression))

    compress_flag, suffix, compress_cmd = compress_opts[compression]

    # Build tarball filename: stage3-{arch}-{variant}-{libc}-{date}.tar.{ext}
    arch = ctx.attrs.arch
    variant = ctx.attrs.variant
    libc = ctx.attrs.libc
    version = ctx.attrs.version

    tarball_basename = "stage3-{}-{}-{}".format(arch, variant, libc)
    if version:
        tarball_basename += "-" + version

    # Declare outputs
    tarball_file = ctx.actions.declare_output(tarball_basename + suffix)
    sha256_file = ctx.actions.declare_output(tarball_basename + suffix + ".sha256")
    contents_file = ctx.actions.declare_output(tarball_basename + ".CONTENTS.gz")

    # Get rootfs directory
    rootfs_dir = ctx.attrs.rootfs[DefaultInfo].default_outputs[0]

    # Create the stage3 assembly script
    script_content = '''#!/bin/bash
set -e

ROOTFS="$1"
TARBALL="$2"
SHA256_FILE="$3"
CONTENTS_FILE="$4"
ARCH="{arch}"
VARIANT="{variant}"
LIBC="{libc}"
VERSION="{version}"
BUILD_DATE=$(date -u +%Y%m%dT%H%M%SZ)
DATE_STAMP=$(date -u +%Y%m%d)

echo "Creating stage3 tarball..."
echo "  Architecture: $ARCH"
echo "  Variant: $VARIANT"
echo "  Libc: $LIBC"
echo "  Version: $VERSION"

# Create a working copy of rootfs to add metadata
WORKDIR=$(mktemp -d)
trap "rm -rf $WORKDIR" EXIT

# Copy rootfs to working directory
cp -a "$ROOTFS"/. "$WORKDIR/"

# Create metadata directory
mkdir -p "$WORKDIR/etc/buckos"

# Generate STAGE3_INFO file
cat > "$WORKDIR/etc/buckos/stage3-info" << EOF
# BuckOS Stage3 Information
# Generated: $BUILD_DATE

[stage3]
variant=$VARIANT
arch=$ARCH
libc=$LIBC
date=$DATE_STAMP
version=$VERSION

[build]
build_date=$BUILD_DATE

[packages]
# Package count will be updated after build
EOF

# Generate CONTENTS file (list of all files with types)
echo "Generating CONTENTS file..."
(
    cd "$WORKDIR"
    find . -mindepth 1 | sort | while read -r path; do
        # Remove leading ./
        relpath="${{path#./}}"
        if [ -L "$path" ]; then
            target=$(readlink "$path")
            echo "sym /$relpath -> $target"
        elif [ -d "$path" ]; then
            echo "dir /$relpath"
        elif [ -f "$path" ]; then
            # Get file hash
            hash=$(sha256sum "$path" 2>/dev/null | cut -d' ' -f1 || echo "0")
            echo "obj /$relpath $hash"
        fi
    done
) | gzip -9 > "$CONTENTS_FILE"

# Create the tarball
echo "Creating tarball with {compression} compression..."
(
    cd "$WORKDIR"
    # Use numeric owner to ensure reproducibility
    tar --numeric-owner --owner=0 --group=0 \\
        --sort=name \\
        {compress_flag} \\
        -cf "$TARBALL" .
)

# Generate SHA256 checksum
echo "Generating SHA256 checksum..."
(
    cd "$(dirname "$TARBALL")"
    sha256sum "$(basename "$TARBALL")" > "$SHA256_FILE"
)

echo "Stage3 tarball created successfully!"
echo "  Tarball: $TARBALL"
echo "  Checksum: $SHA256_FILE"
echo "  Contents: $CONTENTS_FILE"
'''.format(
        arch = arch,
        variant = variant,
        libc = libc,
        version = version if version else "0.1",
        compression = compression,
        compress_flag = compress_flag,
    )

    script = ctx.actions.write("create_stage3.sh", script_content, is_executable = True)

    cmd = cmd_args([
        "bash",
        script,
        rootfs_dir,
        tarball_file.as_output(),
        sha256_file.as_output(),
        contents_file.as_output(),
    ])

    ctx.actions.run(
        cmd,
        category = "stage3",
        identifier = ctx.attrs.name,
    )

    return [
        DefaultInfo(default_outputs = [tarball_file, sha256_file, contents_file]),
        Stage3Info(
            tarball = tarball_file,
            checksum = sha256_file,
            contents = contents_file,
            arch = arch,
            variant = variant,
            libc = libc,
            version = version if version else "0.1",
        ),
    ]

stage3_tarball = rule(
    impl = _stage3_tarball_impl,
    attrs = {
        "rootfs": attrs.dep(),
        "variant": attrs.string(default = "base"),      # minimal, base, developer, complete
        "arch": attrs.string(default = "amd64"),        # amd64, arm64
        "libc": attrs.string(default = "glibc"),        # glibc, musl
        "compression": attrs.string(default = "xz"),    # xz, gz, zstd
        "version": attrs.string(default = ""),          # Optional version string
    },
)

# =============================================================================
# EBUILD-STYLE HELPER FUNCTIONS
# =============================================================================
# These helpers mirror Gentoo's ebuild system functionality for Buck2

# -----------------------------------------------------------------------------
# Logging and Output Helpers
# -----------------------------------------------------------------------------

def einfo(msg: str) -> str:
    """Print an informational message (green asterisk)."""
    return 'echo -e "\\033[32m * \\033[0m{}"'.format(msg)

def ewarn(msg: str) -> str:
    """Print a warning message (yellow asterisk)."""
    return 'echo -e "\\033[33m * \\033[0mWARNING: {}"'.format(msg)

def eerror(msg: str) -> str:
    """Print an error message (red asterisk)."""
    return 'echo -e "\\033[31m * \\033[0mERROR: {}"'.format(msg)

def ebegin(msg: str) -> str:
    """Print a message indicating start of a process."""
    return 'echo -e "\\033[32m * \\033[0m{}..."'.format(msg)

def eend(retval: str = "$?") -> str:
    """Print success/failure based on return value."""
    return '''
if [ {} -eq 0 ]; then
    echo -e "\\033[32m [ ok ]\\033[0m"
else
    echo -e "\\033[31m [ !! ]\\033[0m"
fi
'''.format(retval)

def die(msg: str) -> str:
    """Print error and exit with failure."""
    return '{}\nexit 1'.format(eerror(msg))

# -----------------------------------------------------------------------------
# Installation Directory Helpers
# -----------------------------------------------------------------------------

def into(dir: str) -> str:
    """Set the installation prefix for subsequent do* commands."""
    return 'export INSDESTTREE="{}"'.format(dir)

def insinto(dir: str) -> str:
    """Set installation directory for doins."""
    return 'export INSDESTTREE="{}"'.format(dir)

def exeinto(dir: str) -> str:
    """Set installation directory for doexe."""
    return 'export EXEDESTTREE="{}"'.format(dir)

def docinto(dir: str) -> str:
    """Set installation subdirectory for dodoc."""
    return 'export DOCDESTTREE="{}"'.format(dir)

# -----------------------------------------------------------------------------
# File Installation Helpers
# -----------------------------------------------------------------------------

def dobin(files: list[str]) -> str:
    """Install executables into /usr/bin."""
    cmds = ['mkdir -p "$DESTDIR/usr/bin"']
    for f in files:
        cmds.append('install -m 0755 "{}" "$DESTDIR/usr/bin/"'.format(f))
    return "\n".join(cmds)

def dosbin(files: list[str]) -> str:
    """Install system executables into /usr/sbin."""
    cmds = ['mkdir -p "$DESTDIR/usr/sbin"']
    for f in files:
        cmds.append('install -m 0755 "{}" "$DESTDIR/usr/sbin/"'.format(f))
    return "\n".join(cmds)

def dolib_so(files: list[str]) -> str:
    """Install shared libraries into /usr/lib64 (or /usr/lib)."""
    cmds = ['mkdir -p "$DESTDIR/${LIBDIR:-usr/lib64}"']
    for f in files:
        cmds.append('install -m 0755 "{}" "$DESTDIR/${{LIBDIR:-usr/lib64}}/"'.format(f))
    return "\n".join(cmds)

def dolib_a(files: list[str]) -> str:
    """Install static libraries into /usr/lib64 (or /usr/lib)."""
    cmds = ['mkdir -p "$DESTDIR/${LIBDIR:-usr/lib64}"']
    for f in files:
        cmds.append('install -m 0644 "{}" "$DESTDIR/${{LIBDIR:-usr/lib64}}/"'.format(f))
    return "\n".join(cmds)

def newlib_so(src: str, dst: str) -> str:
    """Install shared library with new name."""
    return '''mkdir -p "$DESTDIR/${{LIBDIR:-usr/lib64}}"
install -m 0755 "{}" "$DESTDIR/${{LIBDIR:-usr/lib64}}/{}"'''.format(src, dst)

def newlib_a(src: str, dst: str) -> str:
    """Install static library with new name."""
    return '''mkdir -p "$DESTDIR/${{LIBDIR:-usr/lib64}}"
install -m 0644 "{}" "$DESTDIR/${{LIBDIR:-usr/lib64}}/{}"'''.format(src, dst)

def doins(files: list[str]) -> str:
    """Install files into INSDESTTREE (default: /usr/share)."""
    cmds = ['mkdir -p "$DESTDIR/${INSDESTTREE:-usr/share}"']
    for f in files:
        cmds.append('install -m 0644 "{}" "$DESTDIR/${{INSDESTTREE:-usr/share}}/"'.format(f))
    return "\n".join(cmds)

def newins(src: str, dst: str) -> str:
    """Install file with new name into INSDESTTREE."""
    return '''mkdir -p "$DESTDIR/${{INSDESTTREE:-usr/share}}"
install -m 0644 "{}" "$DESTDIR/${{INSDESTTREE:-usr/share}}/{}"'''.format(src, dst)

def doexe(files: list[str]) -> str:
    """Install executables into EXEDESTTREE."""
    cmds = ['mkdir -p "$DESTDIR/${EXEDESTTREE:-usr/bin}"']
    for f in files:
        cmds.append('install -m 0755 "{}" "$DESTDIR/${{EXEDESTTREE:-usr/bin}}/"'.format(f))
    return "\n".join(cmds)

def newexe(src: str, dst: str) -> str:
    """Install executable with new name."""
    return '''mkdir -p "$DESTDIR/${{EXEDESTTREE:-usr/bin}}"
install -m 0755 "{}" "$DESTDIR/${{EXEDESTTREE:-usr/bin}}/{}"'''.format(src, dst)

def doheader(files: list[str]) -> str:
    """Install header files into /usr/include."""
    cmds = ['mkdir -p "$DESTDIR/usr/include"']
    for f in files:
        cmds.append('install -m 0644 "{}" "$DESTDIR/usr/include/"'.format(f))
    return "\n".join(cmds)

def newheader(src: str, dst: str) -> str:
    """Install header file with new name."""
    return '''mkdir -p "$DESTDIR/usr/include"
install -m 0644 "{}" "$DESTDIR/usr/include/{}"'''.format(src, dst)

def doconfd(files: list[str]) -> str:
    """Install config files into /etc/conf.d."""
    cmds = ['mkdir -p "$DESTDIR/etc/conf.d"']
    for f in files:
        cmds.append('install -m 0644 "{}" "$DESTDIR/etc/conf.d/"'.format(f))
    return "\n".join(cmds)

def doenvd(files: list[str]) -> str:
    """Install environment files into /etc/env.d."""
    cmds = ['mkdir -p "$DESTDIR/etc/env.d"']
    for f in files:
        cmds.append('install -m 0644 "{}" "$DESTDIR/etc/env.d/"'.format(f))
    return "\n".join(cmds)

def doinitd(files: list[str]) -> str:
    """Install init scripts into /etc/init.d."""
    cmds = ['mkdir -p "$DESTDIR/etc/init.d"']
    for f in files:
        cmds.append('install -m 0755 "{}" "$DESTDIR/etc/init.d/"'.format(f))
    return "\n".join(cmds)

def dosym(target: str, link: str) -> str:
    """Create a symbolic link."""
    return '''mkdir -p "$DESTDIR/$(dirname "{}")"
ln -sf "{}" "$DESTDIR/{}"'''.format(link, target, link)

def dosym_rel(target: str, link: str) -> str:
    """Create a relative symbolic link."""
    return '''mkdir -p "$DESTDIR/$(dirname "{}")"
ln -srf "$DESTDIR/{}" "$DESTDIR/{}"'''.format(link, target, link)

def newbin(src: str, dst: str) -> str:
    """Install executable with new name into /usr/bin."""
    return '''mkdir -p "$DESTDIR/usr/bin"
install -m 0755 "{}" "$DESTDIR/usr/bin/{}"'''.format(src, dst)

def newsbin(src: str, dst: str) -> str:
    """Install system executable with new name into /usr/sbin."""
    return '''mkdir -p "$DESTDIR/usr/sbin"
install -m 0755 "{}" "$DESTDIR/usr/sbin/{}"'''.format(src, dst)

# -----------------------------------------------------------------------------
# Documentation Helpers
# -----------------------------------------------------------------------------

def dodoc(files: list[str]) -> str:
    """Install documentation files."""
    cmds = ['mkdir -p "$DESTDIR/usr/share/doc/${PN:-$PACKAGE_NAME}/${DOCDESTTREE:-}"']
    for f in files:
        cmds.append('install -m 0644 "{}" "$DESTDIR/usr/share/doc/${{PN:-$PACKAGE_NAME}}/${{DOCDESTTREE:-}}/"'.format(f))
    return "\n".join(cmds)

def newdoc(src: str, dst: str) -> str:
    """Install documentation file with new name."""
    return '''mkdir -p "$DESTDIR/usr/share/doc/${{PN:-$PACKAGE_NAME}}/${{DOCDESTTREE:-}}"
install -m 0644 "{}" "$DESTDIR/usr/share/doc/${{PN:-$PACKAGE_NAME}}/${{DOCDESTTREE:-}}/{}"'''.format(src, dst)

def doman(files: list[str]) -> str:
    """Install man pages."""
    cmds = []
    for f in files:
        # Detect man section from filename
        cmds.append('''
_manfile="{}"
_section="${{_manfile##*.}}"
mkdir -p "$DESTDIR/usr/share/man/man$_section"
install -m 0644 "$_manfile" "$DESTDIR/usr/share/man/man$_section/"
'''.format(f))
    return "\n".join(cmds)

def newman(src: str, dst: str) -> str:
    """Install man page with new name."""
    return '''
_section="${{{1}##*.}}"
mkdir -p "$DESTDIR/usr/share/man/man$_section"
install -m 0644 "{}" "$DESTDIR/usr/share/man/man$_section/{}"
'''.format(dst, src, dst)

def doinfo(files: list[str]) -> str:
    """Install GNU info files."""
    cmds = ['mkdir -p "$DESTDIR/usr/share/info"']
    for f in files:
        cmds.append('install -m 0644 "{}" "$DESTDIR/usr/share/info/"'.format(f))
    return "\n".join(cmds)

def dohtml(files: list[str], recursive: bool = False) -> str:
    """Install HTML documentation."""
    cmds = ['mkdir -p "$DESTDIR/usr/share/doc/${PN:-$PACKAGE_NAME}/html"']
    if recursive:
        for f in files:
            cmds.append('cp -r "{}" "$DESTDIR/usr/share/doc/${{PN:-$PACKAGE_NAME}}/html/"'.format(f))
    else:
        for f in files:
            cmds.append('install -m 0644 "{}" "$DESTDIR/usr/share/doc/${{PN:-$PACKAGE_NAME}}/html/"'.format(f))
    return "\n".join(cmds)

# -----------------------------------------------------------------------------
# Directory and Permission Helpers
# -----------------------------------------------------------------------------

def dodir(dirs: list[str]) -> str:
    """Create directories in DESTDIR."""
    cmds = []
    for d in dirs:
        cmds.append('mkdir -p "$DESTDIR/{}"'.format(d))
    return "\n".join(cmds)

def keepdir(dirs: list[str]) -> str:
    """Create directories and add .keep files to preserve empty dirs."""
    cmds = []
    for d in dirs:
        cmds.append('mkdir -p "$DESTDIR/{}"'.format(d))
        cmds.append('touch "$DESTDIR/{}/.keep"'.format(d))
    return "\n".join(cmds)

def fowners(owner: str, files: list[str]) -> str:
    """Change file ownership (recorded for package manager)."""
    cmds = []
    for f in files:
        cmds.append('chown {} "$DESTDIR/{}"'.format(owner, f))
    return "\n".join(cmds)

def fperms(mode: str, files: list[str]) -> str:
    """Change file permissions."""
    cmds = []
    for f in files:
        cmds.append('chmod {} "$DESTDIR/{}"'.format(mode, f))
    return "\n".join(cmds)

# -----------------------------------------------------------------------------
# pkg-config Helpers
# -----------------------------------------------------------------------------

def gen_pkgconfig(
        name: str,
        description: str,
        libs: str = "",
        cflags: str = "",
        requires: str = "",
        requires_private: str = "",
        libs_private: str = "",
        url: str = "",
        destvar: str = "OUT",
        prefix: str = "/usr",
        libdir: str = "lib64") -> str:
    """
    Generate a pkg-config .pc file with proper version handling.

    Uses $PV for version (set by BuckOS build system) so version is always correct.

    Args:
        name: Package name (used for filename and Name field)
        description: Package description
        libs: Link flags (e.g., "-lfoo" or "-L${libdir} -lfoo")
        cflags: Compiler flags (e.g., "-I${includedir}/foo")
        requires: Required packages (comma-separated)
        requires_private: Private required packages
        libs_private: Private link flags
        url: Package URL
        destvar: Shell variable for destination (OUT for binary_package, DESTDIR for ebuild)
        prefix: Installation prefix (default: /usr)
        libdir: Library directory name (default: lib64)

    Returns:
        Shell script to generate the .pc file

    Example:
        install_script = gen_pkgconfig(
            name = "mylib",
            description = "My awesome library",
            libs = "-lmylib",
        ) + '''
        # rest of installation...
        '''
    """
    # Build optional fields
    optional_fields = ""
    if url:
        optional_fields += "URL: {}\n".format(url)
    if requires:
        optional_fields += "Requires: {}\n".format(requires)
    if requires_private:
        optional_fields += "Requires.private: {}\n".format(requires_private)
    if libs_private:
        optional_fields += "Libs.private: {}\n".format(libs_private)

    # Use EOF without quotes to allow $PV expansion
    return '''
mkdir -p "${destvar}/{prefix}/{libdir}/pkgconfig"
cat > "${destvar}/{prefix}/{libdir}/pkgconfig/{name}.pc" << EOF
prefix={prefix}
exec_prefix=${{prefix}}
libdir=${{prefix}}/{libdir}
includedir=${{prefix}}/include

Name: {name}
Description: {description}
Version: $PV
{optional_fields}Libs: {libs}
Cflags: {cflags}
EOF
'''.format(
        name = name,
        description = description,
        libs = libs if libs else "-L${{libdir}} -l{}".format(name),
        cflags = cflags if cflags else "-I${includedir}",
        optional_fields = optional_fields,
        destvar = "$" + destvar,
        prefix = prefix,
        libdir = libdir,
    )

def gen_pkgconfig_headeronly(
        name: str,
        description: str,
        includedir: str = "${includedir}",
        url: str = "",
        requires: str = "",
        destvar: str = "OUT",
        prefix: str = "/usr",
        libdir: str = "lib") -> str:
    """
    Generate a pkg-config .pc file for header-only libraries.

    Args:
        name: Package name
        description: Package description
        includedir: Include directory path (default: ${includedir})
        url: Package URL
        requires: Required packages (e.g., "cuda")
        destvar: Shell variable for destination (OUT for binary_package, DESTDIR for ebuild)
        prefix: Installation prefix (default: /usr)
        libdir: Directory for pkgconfig files (default: lib)

    Returns:
        Shell script to generate the .pc file
    """
    url_field = "URL: {}\n".format(url) if url else ""
    requires_field = "Requires: {}\n".format(requires) if requires else ""
    return '''
mkdir -p "${destvar}/{prefix}/{libdir}/pkgconfig"
cat > "${destvar}/{prefix}/{libdir}/pkgconfig/{name}.pc" << EOF
prefix={prefix}
exec_prefix=${{prefix}}
includedir=${{prefix}}/include

Name: {name}
Description: {description}
Version: $PV
{url_field}{requires_field}Cflags: -I{includedir}
EOF
'''.format(
        name = name,
        description = description,
        includedir = includedir,
        url_field = url_field,
        requires_field = requires_field,
        destvar = "$" + destvar,
        prefix = prefix,
        libdir = libdir,
    )

# -----------------------------------------------------------------------------
# Compilation Helpers
# -----------------------------------------------------------------------------

def emake(args: list[str] = []) -> str:
    """Run make with standard parallel jobs and arguments."""
    args_str = " ".join(args) if args else ""
    return 'make -j${{MAKEOPTS:-$(nproc)}} {}'.format(args_str)

def econf(args: list[str] = []) -> str:
    """Run configure with standard arguments."""
    args_str = " ".join(args) if args else ""
    return '''
ECONF_SOURCE="${{ECONF_SOURCE:-.}}"
"$ECONF_SOURCE/configure" \\
    --prefix="${{EPREFIX:-/usr}}" \\
    --build="${{CBUILD:-$(gcc -dumpmachine)}}" \\
    --host="${{CHOST:-$(gcc -dumpmachine)}}" \\
    --mandir="${{EPREFIX:-/usr}}/share/man" \\
    --infodir="${{EPREFIX:-/usr}}/share/info" \\
    --datadir="${{EPREFIX:-/usr}}/share" \\
    --sysconfdir="${{EPREFIX:-/etc}}" \\
    --localstatedir="${{EPREFIX:-/var}}" \\
    --libdir="${{EPREFIX:-/usr}}/${{LIBDIR_SUFFIX:-lib64}}" \\
    {}
'''.format(args_str)

def einstall(args: list[str] = []) -> str:
    """Run make install with DESTDIR."""
    args_str = " ".join(args) if args else ""
    return 'make DESTDIR="$DESTDIR" {} install'.format(args_str)

def eautoreconf() -> str:
    """Run autoreconf to regenerate autotools files."""
    return '''
{begin}
if [ -f configure.ac ] || [ -f configure.in ]; then
    autoreconf -fiv
fi
{end}
'''.format(begin = ebegin("Running autoreconf"), end = eend())

def elibtoolize() -> str:
    """Run libtoolize to update libtool scripts."""
    return '''
{begin}
if [ -f configure.ac ] || [ -f configure.in ]; then
    libtoolize --copy --force
fi
{end}
'''.format(begin = ebegin("Running libtoolize"), end = eend())

# -----------------------------------------------------------------------------
# Patch Helpers
# -----------------------------------------------------------------------------

def epatch(patches: list[str], strip: int = 1) -> str:
    """Apply patches to source."""
    cmds = []
    for p in patches:
        cmds.append('{}\npatch -p{} < "{}"'.format(
            ebegin("Applying patch {}".format(p)),
            strip,
            p,
        ))
    return "\n".join(cmds)

def eapply(patches: list[str], strip: int = 1) -> str:
    """Modern patch application (EAPI 6+)."""
    cmds = []
    for p in patches:
        cmds.append('''
{begin}
if [ -d "{patch}" ]; then
    for _p in "{patch}"/*.patch; do
        patch -p{strip} < "$_p" || die "Patch failed: $_p"
    done
else
    patch -p{strip} < "{patch}" || die "Patch failed: {patch}"
fi
'''.format(begin = ebegin("Applying {}".format(p)), patch = p, strip = strip))
    return "\n".join(cmds)

def eapply_user() -> str:
    """Apply user patches from /etc/portage/patches."""
    return '''
# Apply user patches if they exist
_user_patches="${{EPREFIX:-}}/etc/portage/patches/${{CATEGORY}}/${{PN}}"
if [ -d "$_user_patches" ]; then
    {}
    for _p in "$_user_patches"/*.patch; do
        [ -f "$_p" ] && patch -p1 < "$_p"
    done
fi
'''.format(ebegin("Applying user patches"))

# -----------------------------------------------------------------------------
# USE Flag Helpers
# -----------------------------------------------------------------------------

def use_enable(flag: str, option: str = "") -> str:
    """Generate --enable-X or --disable-X based on USE flag."""
    opt = option if option else flag
    return '''
if use {}; then
    echo "--enable-{}"
else
    echo "--disable-{}"
fi
'''.format(flag, opt, opt)

def use_with(flag: str, option: str = "") -> str:
    """Generate --with-X or --without-X based on USE flag."""
    opt = option if option else flag
    return '''
if use {}; then
    echo "--with-{}"
else
    echo "--without-{}"
fi
'''.format(flag, opt, opt)

def usev(flag: str, value: str = "") -> str:
    """Echo value if USE flag is enabled."""
    val = value if value else flag
    return '''
if use {}; then
    echo "{}"
fi
'''.format(flag, val)

def usex(flag: str, yes_val: str = "yes", no_val: str = "no") -> str:
    """Return different values based on USE flag."""
    return '''
if use {}; then
    echo "{}"
else
    echo "{}"
fi
'''.format(flag, yes_val, no_val)

def use_check(flag: str) -> str:
    """Return shell code to check if a USE flag is set."""
    return '[[ " $USE " == *" {} "* ]]'.format(flag)

# -----------------------------------------------------------------------------
# Build System Specific Helpers
# -----------------------------------------------------------------------------

def cmake_src_configure(args: list[str] = [], build_type: str = "Release") -> str:
    """Configure CMake project."""
    args_str = " ".join(args) if args else ""
    return '''
mkdir -p "${{BUILD_DIR:-build}}"
cd "${{BUILD_DIR:-build}}"
cmake \\
    -DCMAKE_INSTALL_PREFIX="${{EPREFIX:-/usr}}" \\
    -DCMAKE_BUILD_TYPE={build_type} \\
    -DCMAKE_INSTALL_LIBDIR="${{LIBDIR:-lib64}}" \\
    -DCMAKE_C_FLAGS="${{CFLAGS:-}}" \\
    -DCMAKE_CXX_FLAGS="${{CXXFLAGS:-}}" \\
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \\
    {args} \\
    ..
'''.format(build_type = build_type, args = args_str)

def cmake_src_compile(args: list[str] = []) -> str:
    """Build CMake project."""
    args_str = " ".join(args) if args else ""
    return '''
cd "${{BUILD_DIR:-build}}"
cmake --build . -j${{MAKEOPTS:-$(nproc)}} {}
'''.format(args_str)

def cmake_src_install(args: list[str] = []) -> str:
    """Install CMake project."""
    args_str = " ".join(args) if args else ""
    return '''
cd "${{BUILD_DIR:-build}}"
DESTDIR="$DESTDIR" cmake --install . {}
'''.format(args_str)

def meson_src_configure(args: list[str] = [], build_type: str = "release") -> str:
    """Configure Meson project."""
    args_str = " ".join(args) if args else ""
    return '''
meson setup "${{BUILD_DIR:-build}}" \\
    --prefix="${{EPREFIX:-/usr}}" \\
    --libdir="${{LIBDIR:-lib64}}" \\
    --buildtype={build_type} \\
    {}
'''.format(args_str, build_type = build_type)

def meson_src_compile() -> str:
    """Build Meson project."""
    return 'meson compile -C "${BUILD_DIR:-build}" -j${MAKEOPTS:-$(nproc)}'

def meson_src_install() -> str:
    """Install Meson project."""
    return 'DESTDIR="$DESTDIR" meson install -C "${BUILD_DIR:-build}"'

def cargo_src_configure(args: list[str] = []) -> str:
    """Configure Cargo/Rust project."""
    args_str = " ".join(args) if args else ""
    return '''
export CARGO_HOME="${{CARGO_HOME:-$PWD/.cargo}}"
mkdir -p "$CARGO_HOME"
# Configure offline mode if vendor dir exists
if [ -d vendor ]; then
    mkdir -p .cargo
    cat > .cargo/config.toml << 'CARGO_EOF'
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor"
CARGO_EOF
fi
{}
'''.format(args_str)

def cargo_src_compile(args: list[str] = []) -> str:
    """Build Cargo/Rust project."""
    args_str = " ".join(args) if args else ""
    # Unset CARGO_BUILD_RUSTC_WRAPPER to avoid sccache path length issues in buck-out
    return '''
CARGO_BUILD_RUSTC_WRAPPER="" cargo build --release \\
    --jobs ${{MAKEOPTS:-$(nproc)}} \\
    {}
'''.format(args_str)

def cargo_src_install(bins: list[str] = []) -> str:
    """Install Cargo/Rust binaries."""
    if bins:
        cmds = ['mkdir -p "$DESTDIR/usr/bin"']
        for b in bins:
            cmds.append('install -m 0755 "target/release/{}" "$DESTDIR/usr/bin/"'.format(b))
        return "\n".join(cmds)
    return '''
mkdir -p "$DESTDIR/usr/bin"
find target/release -maxdepth 1 -type f -executable ! -name "*.d" -exec install -m 0755 {{}} "$DESTDIR/usr/bin/" \\;
'''

def go_src_compile(packages: list[str] = ["."], ldflags: str = "") -> str:
    """Build Go project."""
    pkgs = " ".join(packages)
    return '''
export GOPATH="${{GOPATH:-$PWD/go}}"
export GOCACHE="${{GOCACHE:-$PWD/.cache/go-build}}"
export CGO_ENABLED="${{CGO_ENABLED:-1}}"
go build \\
    -v \\
    -p ${{MAKEOPTS:-$(nproc)}} \\
    -ldflags="-s -w {ldflags}" \\
    -o "${{BUILD_DIR:-build}}/" \\
    {packages}
'''.format(ldflags = ldflags, packages = pkgs)

def go_src_install(bins: list[str] = []) -> str:
    """Install Go binaries."""
    if bins:
        cmds = ['mkdir -p "$DESTDIR/usr/bin"']
        for b in bins:
            cmds.append('install -m 0755 "${{BUILD_DIR:-build}}/{}" "$DESTDIR/usr/bin/"'.format(b))
        return "\n".join(cmds)
    return '''
mkdir -p "$DESTDIR/usr/bin"
find "${{BUILD_DIR:-build}}" -maxdepth 1 -type f -executable -exec install -m 0755 {{}} "$DESTDIR/usr/bin/" \\;
'''

def ninja_src_compile(args: list[str] = []) -> str:
    """Build with Ninja."""
    args_str = " ".join(args) if args else ""
    return 'ninja -C "${{BUILD_DIR:-build}}" -j${{MAKEOPTS:-$(nproc)}} {}'.format(args_str)

def ninja_src_install() -> str:
    """Install with Ninja."""
    return 'DESTDIR="$DESTDIR" ninja -C "${BUILD_DIR:-build}" install'

def python_src_install(python: str = "python3") -> str:
    """Install Python package."""
    return '''
{python} setup.py install \\
    --prefix=/usr \\
    --root="$DESTDIR" \\
    --optimize=1 \\
    --skip-build
'''.format(python = python)

def pip_src_install(python: str = "python3") -> str:
    """Install Python package with pip."""
    return '''
{python} -m pip install \\
    --prefix=/usr \\
    --root="$DESTDIR" \\
    --no-deps \\
    --no-build-isolation \\
    .
'''.format(python = python)

# -----------------------------------------------------------------------------
# VCS Source Helpers
# -----------------------------------------------------------------------------

def git_src_unpack(repo: str, branch: str = "main", depth: int = 1) -> str:
    """Clone git repository."""
    return '''
git clone \\
    --depth={depth} \\
    --branch={branch} \\
    "{repo}" \\
    "${{S:-source}}"
'''.format(repo = repo, branch = branch, depth = depth)

def git_src_prepare() -> str:
    """Prepare git source (submodules, etc.)."""
    return '''
cd "${S:-source}"
if [ -f .gitmodules ]; then
    git submodule update --init --recursive --depth=1
fi
'''

def svn_src_unpack(repo: str, revision: str = "HEAD") -> str:
    """Checkout SVN repository."""
    return '''
svn checkout \\
    -r {revision} \\
    "{repo}" \\
    "${{S:-source}}"
'''.format(repo = repo, revision = revision)

def hg_src_unpack(repo: str, branch: str = "default") -> str:
    """Clone Mercurial repository."""
    return '''
hg clone \\
    -b {branch} \\
    "{repo}" \\
    "${{S:-source}}"
'''.format(repo = repo, branch = branch)

# -----------------------------------------------------------------------------
# Test Helpers
# -----------------------------------------------------------------------------

def default_src_test() -> str:
    """Default test phase implementation."""
    return '''
if [ -f Makefile ] || [ -f GNUmakefile ] || [ -f makefile ]; then
    if make -q check 2>/dev/null; then
        emake check
    elif make -q test 2>/dev/null; then
        emake test
    fi
fi
'''

def python_test(args: list[str] = []) -> str:
    """Run Python tests with pytest."""
    args_str = " ".join(args) if args else ""
    return 'python3 -m pytest {} -v'.format(args_str)

def go_test(packages: list[str] = ["./..."]) -> str:
    """Run Go tests."""
    pkgs = " ".join(packages)
    return 'go test -v {}'.format(pkgs)

def cargo_test(args: list[str] = []) -> str:
    """Run Cargo tests."""
    args_str = " ".join(args) if args else ""
    return 'cargo test --release {}'.format(args_str)

# -----------------------------------------------------------------------------
# Environment Setup Helpers
# -----------------------------------------------------------------------------

# Toolchain detection shell functions (Gentoo-style tc-* helpers)
# These are embedded into build scripts to provide runtime toolchain detection
TC_FUNCS = '''
# Gentoo-style toolchain helper functions
tc-getCC() { echo "${CC:-gcc}"; }
tc-getCXX() { echo "${CXX:-g++}"; }
tc-getLD() { echo "${LD:-ld}"; }
tc-getAR() { echo "${AR:-ar}"; }
tc-getRANLIB() { echo "${RANLIB:-ranlib}"; }
tc-getNM() { echo "${NM:-nm}"; }
tc-getSTRIP() { echo "${STRIP:-strip}"; }
tc-getOBJCOPY() { echo "${OBJCOPY:-objcopy}"; }
tc-getPKG_CONFIG() { echo "${PKG_CONFIG:-pkg-config}"; }

tc-is-gcc() {
    local cc="$(tc-getCC)"
    local ver=$($cc --version 2>/dev/null | head -1)
    echo "$ver" | grep -iq "gcc"
}

tc-is-clang() {
    local cc="$(tc-getCC)"
    local ver=$($cc --version 2>/dev/null | head -1)
    echo "$ver" | grep -iq "clang"
}

tc-get-compiler-type() {
    if tc-is-clang; then
        echo "clang"
    elif tc-is-gcc; then
        echo "gcc"
    else
        echo "unknown"
    fi
}

# Get GCC major version number
gcc-major-version() {
    local cc="$(tc-getCC)"
    local ver=$($cc --version 2>/dev/null | head -1)
    echo "$ver" | sed -n 's/.*[gG][cC][cC][^0-9]*\\([0-9]*\\)\\..*/\\1/p'
}

# Get Clang major version number
clang-major-version() {
    local cc="$(tc-getCC)"
    local ver=$($cc --version 2>/dev/null | head -1)
    echo "$ver" | sed -n 's/.*clang[^0-9]*\\([0-9]*\\)\\..*/\\1/p'
}

# Check if GCC version is at least N
gcc-min-version() {
    local min="$1"
    local cur=$(gcc-major-version)
    [ -n "$cur" ] && [ "$cur" -ge "$min" ] 2>/dev/null
}

# Check if Clang version is at least N
clang-min-version() {
    local min="$1"
    local cur=$(clang-major-version)
    [ -n "$cur" ] && [ "$cur" -ge "$min" ] 2>/dev/null
}

# Apply GCC 15+ C23 compatibility fix (wraps CC with -std=gnu11)
tc-fix-gcc15-c23() {
    if tc-is-gcc && gcc-min-version 15; then
        local cc="$(tc-getCC)"
        export CC="$cc -std=gnu11"
        export CXX="$(tc-getCXX) -std=gnu++17"
        echo "Applied GCC 15+ C23 compatibility fix: CC=$CC"
        return 0
    fi
    return 1
}

# Fetch a git submodule from URL to target directory
# Usage: fetch_submodule <url> <target_dir> <verify_file>
# Example: fetch_submodule "https://github.com/foo/bar/archive/main.tar.gz" "ext/bar" "ext/bar/Makefile"
fetch_submodule() {
    local url="$1"
    local target="$2"
    local check_file="$3"

    if [ ! -f "$check_file" ]; then
        echo "Fetching submodule to $target..."
        rm -rf "$target"
        mkdir -p "$target"
        local tmpfile="/tmp/submodule_$(basename "$target").tar.gz"
        wget -q "$url" -O "$tmpfile"
        tar --strip-components=1 -xf "$tmpfile" -C "$target"
        rm -f "$tmpfile"
        if [ ! -f "$check_file" ]; then
            echo "ERROR: Failed to fetch submodule - $check_file not found"
            return 1
        fi
        echo "Successfully fetched submodule to $target"
    fi
    return 0
}
'''

def tc_export(vars: list[str] = ["CC", "CXX", "LD", "AR", "RANLIB", "NM"]) -> str:
    """Export toolchain variables."""
    exports = []
    for var in vars:
        if var == "CC":
            exports.append('export CC="${CC:-gcc}"')
        elif var == "CXX":
            exports.append('export CXX="${CXX:-g++}"')
        elif var == "LD":
            exports.append('export LD="${LD:-ld}"')
        elif var == "AR":
            exports.append('export AR="${AR:-ar}"')
        elif var == "RANLIB":
            exports.append('export RANLIB="${RANLIB:-ranlib}"')
        elif var == "NM":
            exports.append('export NM="${NM:-nm}"')
        elif var == "STRIP":
            exports.append('export STRIP="${STRIP:-strip}"')
        elif var == "OBJCOPY":
            exports.append('export OBJCOPY="${OBJCOPY:-objcopy}"')
        elif var == "PKG_CONFIG":
            exports.append('export PKG_CONFIG="${PKG_CONFIG:-pkg-config}"')
    return "\n".join(exports)

def tc_funcs() -> str:
    """Return shell functions for toolchain detection."""
    return TC_FUNCS

def append_cflags(flags: list[str]) -> str:
    """Append flags to CFLAGS."""
    return 'export CFLAGS="$CFLAGS {}"'.format(" ".join(flags))

def append_cxxflags(flags: list[str]) -> str:
    """Append flags to CXXFLAGS."""
    return 'export CXXFLAGS="$CXXFLAGS {}"'.format(" ".join(flags))

def append_ldflags(flags: list[str]) -> str:
    """Append flags to LDFLAGS."""
    return 'export LDFLAGS="$LDFLAGS {}"'.format(" ".join(flags))

def filter_flags(patterns: list[str]) -> str:
    """Remove flags matching patterns from CFLAGS/CXXFLAGS."""
    cmds = []
    for pat in patterns:
        cmds.append('CFLAGS=$(echo "$CFLAGS" | sed "s/{}//g")'.format(pat))
        cmds.append('CXXFLAGS=$(echo "$CXXFLAGS" | sed "s/{}//g")'.format(pat))
    return "\n".join(cmds)

def replace_flags(old: str, new: str) -> str:
    """Replace flag in CFLAGS/CXXFLAGS."""
    return '''
CFLAGS="${{CFLAGS//{old}/{new}}}"
CXXFLAGS="${{CXXFLAGS//{old}/{new}}}"
'''.format(old = old, new = new)

# -----------------------------------------------------------------------------
# Package Information Helpers
# -----------------------------------------------------------------------------

def get_version_component_range(component_range: str, version: str) -> str:
    """Extract version components (e.g., '1-2' from '1.2.3')."""
    return '''
_ver="{version}"
_range="{range}"
echo "$_ver" | cut -d. -f"$_range"
'''.format(version = version, range = component_range)

def get_major_version(version: str) -> str:
    """Get major version number."""
    return 'echo "{}" | cut -d. -f1'.format(version)

def get_minor_version(version: str) -> str:
    """Get minor version number (major.minor)."""
    return 'echo "{}" | cut -d. -f1-2'.format(version)

def ver_cut(range: str, version: str) -> str:
    """Cut version string by components."""
    return 'echo "{}" | cut -d. -f{}'.format(version, range)

def ver_rs(sep_from: str, sep_to: str, version: str) -> str:
    """Replace version separator."""
    return 'echo "{}" | sed "s/{}/${}$/g"'.format(version, sep_from, sep_to)

# -----------------------------------------------------------------------------
# Systemd Helpers
# -----------------------------------------------------------------------------

def systemd_dounit(files: list[str]) -> str:
    """Install systemd unit files."""
    cmds = ['mkdir -p "$DESTDIR/usr/lib/systemd/system"']
    for f in files:
        cmds.append('install -m 0644 "{}" "$DESTDIR/usr/lib/systemd/system/"'.format(f))
    return "\n".join(cmds)

def systemd_newunit(src: str, dst: str) -> str:
    """Install systemd unit file with new name."""
    return '''mkdir -p "$DESTDIR/usr/lib/systemd/system"
install -m 0644 "{}" "$DESTDIR/usr/lib/systemd/system/{}"'''.format(src, dst)

def systemd_douserunit(files: list[str]) -> str:
    """Install systemd user unit files."""
    cmds = ['mkdir -p "$DESTDIR/usr/lib/systemd/user"']
    for f in files:
        cmds.append('install -m 0644 "{}" "$DESTDIR/usr/lib/systemd/user/"'.format(f))
    return "\n".join(cmds)

def systemd_enable_service(service: str, target: str = "multi-user.target") -> str:
    """Create symlink to enable systemd service."""
    return '''mkdir -p "$DESTDIR/usr/lib/systemd/system/{target}.wants"
ln -sf "../{service}" "$DESTDIR/usr/lib/systemd/system/{target}.wants/{service}"
'''.format(service = service, target = target)

# -----------------------------------------------------------------------------
# OpenRC Helpers
# -----------------------------------------------------------------------------

def openrc_doinitd(files: list[str]) -> str:
    """Install OpenRC init scripts."""
    return doinitd(files)

def openrc_doconfd(files: list[str]) -> str:
    """Install OpenRC conf.d files."""
    return doconfd(files)

def newinitd(src: str, dst: str) -> str:
    """Install OpenRC init script with new name."""
    return '''mkdir -p "$DESTDIR/etc/init.d"
install -m 0755 "{}" "$DESTDIR/etc/init.d/{}"'''.format(src, dst)

def newconfd(src: str, dst: str) -> str:
    """Install conf.d file with new name."""
    return '''mkdir -p "$DESTDIR/etc/conf.d"
install -m 0644 "{}" "$DESTDIR/etc/conf.d/{}"'''.format(src, dst)

# -----------------------------------------------------------------------------
# Portage/Package Manager Helpers
# -----------------------------------------------------------------------------

def has_version(atom: str) -> str:
    """Check if package is installed (shell condition)."""
    # This would integrate with the package manager
    return '[ -n "$(find "${{EPREFIX:-}}/var/db/pkg" -maxdepth 2 -name "{}*" 2>/dev/null)" ]'.format(atom)

def best_version(atom: str) -> str:
    """Get best matching installed version."""
    return 'find "${EPREFIX:-}/var/db/pkg" -maxdepth 2 -name "{}*" -printf "%f\\n" 2>/dev/null | sort -V | tail -1'.format(atom)

# -----------------------------------------------------------------------------
# Ebuild Phase Package Rule
# -----------------------------------------------------------------------------

def _ebuild_package_impl(ctx: AnalysisContext) -> list[Provider]:
    """
    Build a package using ebuild-style phases:
    - src_unpack: Extract sources
    - src_prepare: Apply patches, run autoreconf
    - src_configure: Run configure/cmake/meson setup
    - src_compile: Build the software
    - src_test: Run tests (optional)
    - src_install: Install to DESTDIR
    """
    install_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)

    # Read build threads from Buck2 config (default 0 = auto-detect with nproc)
    build_threads = read_config("buckos", "build_threads", "0")
    if not build_threads:
        build_threads = read_config("build", "threads", "0")

    # Get source directory from dependency
    src_dir = ctx.attrs.source[DefaultInfo].default_outputs[0]

    # Read host toolchain config
    use_host_toolchain = _should_use_host_toolchain()

    # Filter dependencies: skip bootstrap toolchain when using host toolchain
    bdepend_list = ctx.attrs.bdepend
    if use_host_toolchain:
        # Filter out bootstrap toolchain from bdepend when using host toolchain
        bdepend_list = [dep for dep in ctx.attrs.bdepend if "bootstrap-toolchain" not in str(dep.label)]

    # Collect dependency directories:
    # - Target platform dependencies (cross-compiled libraries/headers): depend + bdepend + rdepend
    # - Host platform dependencies (native build tools): exec_bdepend
    target_deps = ctx.attrs.depend + bdepend_list + ctx.attrs.rdepend
    dep_dirs = _collect_dep_dirs(target_deps)

    # Append typed language toolchain artifacts to dep_dirs
    # These flow through the same dep_dirs mechanism that ebuild.sh already scans
    if ctx.attrs._go_toolchain != None:
        dep_dirs.append(ctx.attrs._go_toolchain[GoToolchainInfo].goroot)
    if ctx.attrs._rust_toolchain != None:
        dep_dirs.append(ctx.attrs._rust_toolchain[RustToolchainInfo].rust_root)

    # Collect exec dependencies (build tools for host platform)
    exec_dep_dirs = _collect_dep_dirs(ctx.attrs.exec_bdepend)

    # Build phases (use 'true' as no-op for empty phases to avoid syntax errors)
    src_unpack = ctx.attrs.src_unpack if ctx.attrs.src_unpack else "true"
    src_prepare = ctx.attrs.src_prepare if ctx.attrs.src_prepare else "true"
    pre_configure = ctx.attrs.pre_configure if ctx.attrs.pre_configure else "true"
    src_configure = ctx.attrs.src_configure if ctx.attrs.src_configure else "true"
    src_compile = ctx.attrs.src_compile if ctx.attrs.src_compile else "make -j${MAKEOPTS:-$(nproc)}"
    src_test = ctx.attrs.src_test if ctx.attrs.src_test else "true"
    src_install = ctx.attrs.src_install if ctx.attrs.src_install else "make install DESTDIR=\"$DESTDIR\""

    # Write phase scripts to separate files to avoid format string conflicts
    # Shell scripts often contain ${VAR} which conflicts with Python's {placeholder} syntax
    # By writing to separate files, we completely avoid this issue
    phase_scripts = {}
    for phase_name, phase_content in [
        ("src_unpack", src_unpack),
        ("src_prepare", src_prepare),
        ("pre_configure", pre_configure),
        ("src_configure", src_configure),
        ("src_compile", src_compile),
        ("src_test", src_test),
        ("src_install", src_install),
    ]:
        phase_scripts[phase_name] = ctx.actions.write(
            "phases/{}.sh".format(phase_name),
            "#!/bin/bash\nset -e\n" + phase_content + "\n",
            is_executable = True,
        )

    # Environment variables
    env_setup = []
    for k, v in ctx.attrs.env.items():
        env_setup.append('export {}="{}"'.format(k, v))
    env_script = ctx.actions.write(
        "phases/env.sh",
        "#!/bin/bash\n" + "\n".join(env_setup) + "\n",
        is_executable = True,
    )

    # USE flags
    use_flags = " ".join(ctx.attrs.use_flags) if ctx.attrs.use_flags else ""

    # Check if bootstrap toolchain is being used
    use_bootstrap = ctx.attrs.use_bootstrap if hasattr(ctx.attrs, "use_bootstrap") else False
    bootstrap_sysroot = ctx.attrs.bootstrap_sysroot if hasattr(ctx.attrs, "bootstrap_sysroot") else ""
    bootstrap_stage = ctx.attrs.bootstrap_stage if hasattr(ctx.attrs, "bootstrap_stage") else ""

    # Get external scripts (tracked by Buck2 for proper cache invalidation)
    pkg_config_wrapper = ctx.attrs._pkg_config_wrapper[DefaultInfo].default_outputs[0]

    # Select appropriate ebuild script based on bootstrap stage
    # When using host toolchain, always use regular ebuild.sh (bootstrap stages are for cross-compilation)
    if use_host_toolchain or not bootstrap_stage:
        ebuild_script = ctx.attrs._ebuild_script[DefaultInfo].default_outputs[0]
    elif bootstrap_stage == "stage1":
        ebuild_script = ctx.attrs._ebuild_bootstrap_stage1_script[DefaultInfo].default_outputs[0]
    elif bootstrap_stage == "stage2":
        ebuild_script = ctx.attrs._ebuild_bootstrap_stage2_script[DefaultInfo].default_outputs[0]
    elif bootstrap_stage == "stage3":
        ebuild_script = ctx.attrs._ebuild_bootstrap_stage3_script[DefaultInfo].default_outputs[0]
    else:
        # Default: use regular ebuild script
        ebuild_script = ctx.attrs._ebuild_script[DefaultInfo].default_outputs[0]

    # Generate patch application commands if patches are provided
    # We'll pass patch files via command line arguments and copy them to the build dir
    patch_file_list = []
    if ctx.attrs.patches:
        for patch in ctx.attrs.patches:
            patch_file_list.append(patch)

    # Write wrapper script that sources external framework and defines phases
    # This approach works because Buck2 tracks both the written script AND the sourced framework
    # Patches will be applied in the wrapper script before phases run
    # Phase scripts are passed as separate files to avoid format string conflicts with shell ${VAR} syntax
    patch_count = len(patch_file_list)

    # Use @@PLACEHOLDER@@ style instead of {placeholder} to avoid conflicts with shell {} syntax
    script_template = '''#!/bin/bash
set -e

# Ensure native system tools are found first in PATH
export PATH="/usr/bin:/bin:/usr/local/bin:${PATH:-}"

# CRITICAL: Save all original arguments for potential re-execution in mount namespace
ORIGINAL_ARGS=("$@")

# Arguments: DESTDIR, SRC_DIR, PKG_CONFIG_WRAPPER, FRAMEWORK_SCRIPT, PATCH_COUNT,
#            ENV_SCRIPT, SRC_UNPACK, SRC_PREPARE, PRE_CONFIGURE, SRC_CONFIGURE,
#            SRC_COMPILE, SRC_TEST, SRC_INSTALL, HOST_TOOL_COUNT, patches..., host_tool_dirs..., dep_dirs...
# Convert paths to absolute to work in mount namespace
export _EBUILD_DESTDIR="$(readlink -f "$1")"
export _EBUILD_SRCDIR="$(readlink -f "$2")"
export _EBUILD_PKG_CONFIG_WRAPPER="$(readlink -f "$3")"
FRAMEWORK_SCRIPT="$(readlink -f "$4")"
PATCH_COUNT="$5"
shift 5

# Phase script files (passed as separate files to avoid shell/Python format conflicts)
# Must be exported so they're visible when PHASES_CONTENT is sourced by ebuild.sh
export PHASE_ENV_SCRIPT="$(readlink -f "$1")"
export PHASE_SRC_UNPACK="$(readlink -f "$2")"
export PHASE_SRC_PREPARE="$(readlink -f "$3")"
export PHASE_PRE_CONFIGURE="$(readlink -f "$4")"
export PHASE_SRC_CONFIGURE="$(readlink -f "$5")"
export PHASE_SRC_COMPILE="$(readlink -f "$6")"
export PHASE_SRC_TEST="$(readlink -f "$7")"
export PHASE_SRC_INSTALL="$(readlink -f "$8")"
HOST_TOOL_COUNT="$9"
shift 9

# Debug: Log phase script paths for troubleshooting
if [ -n "${EBUILD_DEBUG:-}" ]; then
    echo "=== Phase Script Paths ==="
    echo "  ENV:           $PHASE_ENV_SCRIPT"
    echo "  SRC_UNPACK:    $PHASE_SRC_UNPACK"
    echo "  SRC_PREPARE:   $PHASE_SRC_PREPARE"
    echo "  PRE_CONFIGURE: $PHASE_PRE_CONFIGURE"
    echo "  SRC_CONFIGURE: $PHASE_SRC_CONFIGURE"
    echo "  SRC_COMPILE:   $PHASE_SRC_COMPILE"
    echo "  SRC_TEST:      $PHASE_SRC_TEST"
    echo "  SRC_INSTALL:   $PHASE_SRC_INSTALL"
    echo "=========================="
fi

# Try to download binary package from mirror before building from source
# Enabled when BUCKOS_BINARY_MIRROR environment variable is set
# Mirror structure: $MIRROR/index.json and $MIRROR/<first-letter>/<package>.tar.gz
# Example: export BUCKOS_BINARY_MIRROR=file:///tmp/buckos-mirror
# Example: export BUCKOS_BINARY_MIRROR=https://mirror.buckos.org
# Set BUCKOS_PREFER_BINARIES=false to disable binary downloads
BUCKOS_PROXY="@@PROXY@@"
CURL_PROXY_ARGS=""
WGET_PROXY_ARGS=""
if [ -n "$BUCKOS_PROXY" ]; then
    CURL_PROXY_ARGS="--proxy $BUCKOS_PROXY"
    WGET_PROXY_ARGS="-e http_proxy=$BUCKOS_PROXY -e https_proxy=$BUCKOS_PROXY"
fi
if [ -n "$BUCKOS_BINARY_MIRROR" ] && [ "${BUCKOS_PREFER_BINARIES:-true}" = "true" ]; then
    echo "Checking binary mirror ($BUCKOS_BINARY_MIRROR) for @@NAME@@-@@VERSION@@..."

    # Simple binary download logic without complex config hash calculation
    # Query index.json and find matching package by name/version
    INDEX_URL="$BUCKOS_BINARY_MIRROR/index.json"

    if curl $CURL_PROXY_ARGS -f -s "$INDEX_URL" -o /tmp/mirror-index-$$.json 2>/dev/null || wget $WGET_PROXY_ARGS -q "$INDEX_URL" -O /tmp/mirror-index-$$.json 2>/dev/null; then
        # Find package in index using python3 or fallback to grep
        if command -v python3 &>/dev/null; then
            PACKAGE_INFO=$(python3 -c "
import json, sys
try:
    with open('/tmp/mirror-index-$$.json') as f:
        index = json.load(f)
    packages = index.get('by_name', {}).get('@@NAME@@', [])
    # Find matching version
    for pkg in packages:
        if pkg.get('version') == '@@VERSION@@':
            print(pkg.get('filename', ''))
            print(pkg.get('config_hash', ''))
            break
except: pass
" 2>/dev/null)

            if [ -n "$PACKAGE_INFO" ]; then
                FILENAME=$(echo "$PACKAGE_INFO" | head -1)
                CONFIG_HASH=$(echo "$PACKAGE_INFO" | tail -1)

                if [ -n "$FILENAME" ]; then
                    FIRST_LETTER=$(echo "@@NAME@@" | cut -c1 | tr '[:upper:]' '[:lower:]')
                    PACKAGE_URL="$BUCKOS_BINARY_MIRROR/$FIRST_LETTER/$FILENAME"
                    HASH_URL="$PACKAGE_URL.sha256"

                    echo "Downloading binary: $FILENAME..."

                    # Download package and hash
                    if (curl $CURL_PROXY_ARGS -f -s "$PACKAGE_URL" -o /tmp/pkg-$$.tar.gz && curl $CURL_PROXY_ARGS -f -s "$HASH_URL" -o /tmp/pkg-$$.tar.gz.sha256) || \
                       (wget $WGET_PROXY_ARGS -q "$PACKAGE_URL" -O /tmp/pkg-$$.tar.gz && wget $WGET_PROXY_ARGS -q "$HASH_URL" -O /tmp/pkg-$$.tar.gz.sha256); then

                        # Verify SHA256
                        EXPECTED_HASH=$(head -1 /tmp/pkg-$$.tar.gz.sha256 | awk '{print $1}')
                        if command -v sha256sum &>/dev/null; then
                            ACTUAL_HASH=$(sha256sum /tmp/pkg-$$.tar.gz | awk '{print $1}')
                        elif command -v shasum &>/dev/null; then
                            ACTUAL_HASH=$(shasum -a 256 /tmp/pkg-$$.tar.gz | awk '{print $1}')
                        fi

                        if [ "$EXPECTED_HASH" = "$ACTUAL_HASH" ]; then
                            echo "Binary verified, extracting to $_EBUILD_DESTDIR..."
                            mkdir -p "$_EBUILD_DESTDIR"
                            tar -xzf /tmp/pkg-$$.tar.gz -C "$_EBUILD_DESTDIR" --strip-components=0
                            rm -f /tmp/pkg-$$.tar.gz /tmp/pkg-$$.tar.gz.sha256 /tmp/mirror-index-$$.json
                            echo "Binary package installed successfully from mirror"
                            exit 0
                        else
                            echo "Warning: SHA256 mismatch, falling back to source build"
                        fi
                    fi
                fi
            fi
        fi
        rm -f /tmp/mirror-index-$$.json /tmp/pkg-$$.tar.gz /tmp/pkg-$$.tar.gz.sha256 2>/dev/null || true
    fi
fi

# Extract patch files from command line arguments
# Patches will be applied before building, so we can use relative paths
PATCH_FILES=()
for ((i=0; i<$PATCH_COUNT; i++)); do
    PATCH_FILES+=("$1")
    shift
done

# Extract host tool directories (build tools for host platform)
# These are compiled for the execution platform (host) and should be in PATH first
HOST_TOOL_DIRS=()
for ((i=0; i<$HOST_TOOL_COUNT; i++)); do
    HOST_TOOL_DIRS+=("$1")
    shift
done
export _EBUILD_HOST_TOOL_DIRS="${HOST_TOOL_DIRS[*]}"

# Remaining args ($@) are: target dep_dirs...
export _EBUILD_DEP_DIRS="$@"

# NOTE: Do NOT set LD_LIBRARY_PATH here!
# The dependencies may include bootstrap-toolchain which has libraries built for the
# TARGET system (e.g., glibc 2.42 for x86_64-buckos-linux-gnu). Setting LD_LIBRARY_PATH
# to include these libraries would cause HOST utilities (mkdir, rm, cp, etc.) to crash
# with GLIBC version errors or segfaults.
# LD_LIBRARY_PATH should only be set by the framework script (ebuild.sh) AFTER the
# initial source copy, and only for running cross-compiled tools, not host utilities.

# Export package variables
export PN="@@NAME@@"
export PV="@@VERSION@@"
export PACKAGE_NAME="@@NAME@@"
export CATEGORY="@@CATEGORY@@"
export SLOT="@@SLOT@@"
export USE="@@USE_FLAGS@@"
export USE_BOOTSTRAP="@@USE_BOOTSTRAP@@"
export USE_HOST_TOOLCHAIN="@@USE_HOST@@"
export BOOTSTRAP_SYSROOT="@@BOOTSTRAP_SYSROOT@@"
export BUILD_THREADS="@@BUILD_THREADS@@"

# Set MAKE_JOBS based on BUILD_THREADS
# 0 = auto-detect with nproc, otherwise use specified value
if [ "$BUILD_THREADS" = "0" ]; then
    if command -v nproc >/dev/null 2>&1; then
        export MAKE_JOBS="$(nproc)"
    else
        # nproc not available (early bootstrap), use unlimited parallelism
        export MAKE_JOBS=""
    fi
else
    export MAKE_JOBS="$BUILD_THREADS"
fi

# CRITICAL: Copy source to isolated build directory
# Buck2's download_source produces a single shared artifact - multiple packages using
# the same source would modify the same directory, causing patch conflicts.
# We MUST copy to a package-specific directory to ensure isolation.
if [ -d "$_EBUILD_SRCDIR" ]; then
    BUILD_SRCDIR="$_EBUILD_DESTDIR/../source"
    # Ensure destination is writable before removing (Buck cached artifacts may be read-only)
    if [ -d "$BUILD_SRCDIR" ]; then
        chmod -R u+w "$BUILD_SRCDIR" 2>/dev/null || true
        rm -rf "$BUILD_SRCDIR" || {
            # If rm fails, try harder with find to remove read-only files
            find "$BUILD_SRCDIR" -type f -exec chmod u+w {} \; 2>/dev/null || true
            find "$BUILD_SRCDIR" -type d -exec chmod u+w {} \; 2>/dev/null || true
            rm -rf "$BUILD_SRCDIR"
        }
    fi
    mkdir -p "$BUILD_SRCDIR"
    # Copy CONTENTS of source dir (not the dir itself) using "/." to include hidden files
    cp -a "$_EBUILD_SRCDIR/." "$BUILD_SRCDIR/"
    # Make the copy writable (source archives from Buck are often read-only)
    chmod -R u+w "$BUILD_SRCDIR"
    # Update _EBUILD_SRCDIR to point to the isolated copy
    export _EBUILD_SRCDIR="$BUILD_SRCDIR"
    echo "Source copied to: $BUILD_SRCDIR"
fi

# Apply patches BEFORE running phases (in original working directory)
# This way we can use relative patch paths without conversion
if [ ${#PATCH_FILES[@]} -gt 0 ]; then
    echo "📦 Applying patches to source..."
    cd "$_EBUILD_SRCDIR"
    for patch_file in "${PATCH_FILES[@]}"; do
        if [ -n "$patch_file" ]; then
            echo -e "\\033[32m * \\033[0mApplying $(basename "$patch_file")..."
            # Use absolute path from original directory for patch file
            if [[ "$patch_file" != /* ]]; then
                patch_file="$OLDPWD/$patch_file"
            fi
            patch -p1 < "$patch_file" || { echo "✗ Patch failed: $patch_file"; exit 1; }
        fi
    done
    cd "$OLDPWD"
    echo "✓ Patches applied successfully"
fi

# Define the phases script content using heredoc (avoids single-quote escaping issues)
# Note: read -d '' returns non-zero on EOF, so we use || true to prevent set -e from exiting
read -r -d '' PHASES_CONTENT << 'PHASES_EOF' || true
#!/bin/bash
set -e
set -o pipefail

# USE flag helper
use() {
    [[ " $USE " == *" $1 "* ]]
}

# Toolchain helper functions
tc-getCC() { echo "${CC:-gcc}"; }
tc-getCXX() { echo "${CXX:-g++}"; }

# Get GCC major version number
gcc-major-version() {
    local cc="$(tc-getCC)"
    local ver=$($cc --version 2>/dev/null | head -1)
    echo "$ver" | sed -n 's/.*[gG][cC][cC][^0-9]*\([0-9]*\)\..*/\1/p'
}

# Check if GCC version is at least N
gcc-min-version() {
    local min="$1"
    local cur=$(gcc-major-version)
    [ -n "$cur" ] && [ "$cur" -ge "$min" ] 2>/dev/null
}

# Fetch a git submodule from URL to target directory
# Usage: fetch_submodule <url> <target_dir> <verify_file>
fetch_submodule() {
    local url="$1"
    local target="$2"
    local check_file="$3"

    if [ ! -f "$check_file" ]; then
        echo "Fetching submodule to $target from $url..."
        rm -rf "$target"
        mkdir -p "$target"
        local tmpfile="/tmp/submodule_$(basename "$target").tar.gz"

        # Build curl proxy args from environment
        local curl_proxy_args=""
        if [ -n "${http_proxy:-}" ]; then
            curl_proxy_args="--proxy $http_proxy"
        elif [ -n "${https_proxy:-}" ]; then
            curl_proxy_args="--proxy $https_proxy"
        elif [ -n "${BUCKOS_PROXY:-}" ]; then
            curl_proxy_args="--proxy $BUCKOS_PROXY"
        fi

        # Use curl with -L to follow redirects, -f to fail on HTTP errors
        if ! curl -fsSL $curl_proxy_args "$url" -o "$tmpfile"; then
            echo "ERROR: Failed to download $url"
            return 1
        fi

        tar --strip-components=1 -xf "$tmpfile" -C "$target"
        rm -f "$tmpfile"
        if [ ! -f "$check_file" ]; then
            echo "ERROR: Failed to fetch submodule - $check_file not found"
            return 1
        fi
        echo "Successfully fetched submodule to $target"
    fi
    return 0
}

# Error handler
handle_phase_error() {
    local phase=$1
    local exit_code=$2
    local script_path=$3
    echo "✗ Build phase $phase FAILED (exit code: $exit_code)" >&2
    echo "  Package: $PN-$PV" >&2
    if [ -n "$script_path" ] && [ -f "$script_path" ]; then
        echo "  Phase script: $script_path" >&2
        echo "  Script content:" >&2
        cat "$script_path" | head -20 | sed 's/^/    /' >&2
    fi
    exit $exit_code
}

# Run a phase by sourcing its script file
# Args: phase_name script_path
run_phase() {
    local phase_name="$1"
    local script_path="$2"

    if [ -n "${EBUILD_DEBUG:-}" ]; then
        echo "=== Running phase: $phase_name ==="
        echo "Script: $script_path"
        echo "Content:"
        cat "$script_path" | sed 's/^/  /'
        echo "================================"
    fi

    # Source the script in a subshell for isolation
    ( source "$script_path" )
}

# Custom environment (sourced from file)
source "$PHASE_ENV_SCRIPT"

cd "$S"

# Phase: src_unpack
run_phase "src_unpack" "$PHASE_SRC_UNPACK"

# CRITICAL: Ensure source directory is writable inside the namespace
# Buck2 artifacts may be read-only, and user namespace mapping can affect permissions
# This must happen AFTER src_unpack but BEFORE any phase that writes files
chmod -R u+w . 2>/dev/null || {
    # If recursive chmod fails, try file-by-file (handles special cases)
    find . -type f -exec chmod u+w {} \; 2>/dev/null || true
    find . -type d -exec chmod u+w {} \; 2>/dev/null || true
}

# Phase: src_prepare
echo "📦 Phase: src_prepare"
if command -v tee >/dev/null 2>&1; then
    ( source "$PHASE_SRC_PREPARE" ) 2>&1 | tee "$T/src_prepare.log" || handle_phase_error "src_prepare" ${PIPESTATUS[0]} "$PHASE_SRC_PREPARE"
else
    ( source "$PHASE_SRC_PREPARE" ) > "$T/src_prepare.log" 2>&1 || handle_phase_error "src_prepare" $? "$PHASE_SRC_PREPARE"
fi

# Phase: pre_configure
echo "📦 Phase: pre_configure"
if command -v tee >/dev/null 2>&1; then
    ( source "$PHASE_PRE_CONFIGURE" ) 2>&1 | tee "$T/pre_configure.log" || handle_phase_error "pre_configure" ${PIPESTATUS[0]} "$PHASE_PRE_CONFIGURE"
else
    ( source "$PHASE_PRE_CONFIGURE" ) > "$T/pre_configure.log" 2>&1 || handle_phase_error "pre_configure" $? "$PHASE_PRE_CONFIGURE"
fi

# Phase: src_configure
echo "📦 Phase: src_configure"
if command -v tee >/dev/null 2>&1; then
    ( source "$PHASE_SRC_CONFIGURE" ) 2>&1 | tee "$T/src_configure.log" || handle_phase_error "src_configure" ${PIPESTATUS[0]} "$PHASE_SRC_CONFIGURE"
else
    ( source "$PHASE_SRC_CONFIGURE" ) > "$T/src_configure.log" 2>&1 || handle_phase_error "src_configure" $? "$PHASE_SRC_CONFIGURE"
fi

# Phase: src_compile
echo "📦 Phase: src_compile"
if command -v tee >/dev/null 2>&1; then
    ( source "$PHASE_SRC_COMPILE" ) 2>&1 | tee "$T/src_compile.log" || handle_phase_error "src_compile" ${PIPESTATUS[0]} "$PHASE_SRC_COMPILE"
else
    ( source "$PHASE_SRC_COMPILE" ) > "$T/src_compile.log" 2>&1 || handle_phase_error "src_compile" $? "$PHASE_SRC_COMPILE"
fi

# Phase: src_test
if [ -n "@@RUN_TESTS@@" ]; then
    echo "📦 Phase: src_test"
    if command -v tee >/dev/null 2>&1; then
        ( source "$PHASE_SRC_TEST" ) 2>&1 | tee "$T/src_test.log" || handle_phase_error "src_test" ${PIPESTATUS[0]} "$PHASE_SRC_TEST"
    else
        ( source "$PHASE_SRC_TEST" ) > "$T/src_test.log" 2>&1 || handle_phase_error "src_test" $? "$PHASE_SRC_TEST"
    fi
fi

# Phase: src_install
echo "📦 Phase: src_install"
if command -v tee >/dev/null 2>&1; then
    ( source "$PHASE_SRC_INSTALL" ) 2>&1 | tee "$T/src_install.log" || handle_phase_error "src_install" ${PIPESTATUS[0]} "$PHASE_SRC_INSTALL"
else
    ( source "$PHASE_SRC_INSTALL" ) > "$T/src_install.log" 2>&1 || handle_phase_error "src_install" $? "$PHASE_SRC_INSTALL"
fi
PHASES_EOF
export PHASES_CONTENT

# For bootstrap stage2, we need to set up a mount namespace to bind-mount
# the cross-gcc toolchain to /tools so the compiler can find its sysroot
if [ "@@BOOTSTRAP_STAGE@@" = "stage2" ] && [ -z "$BOOTSTRAP_NAMESPACE_ACTIVE" ]; then
    echo "=== Setting up mount namespace for stage2 bootstrap ==="

    # Find cross-gcc-pass2 and cross-binutils directories
    CROSS_GCC_DIR=""
    CROSS_BINUTILS_DIR=""
    for dep_dir in $_EBUILD_DEP_DIRS; do
        if [ -d "$dep_dir/tools/bin" ] && [ -f "$dep_dir/tools/bin/x86_64-buckos-linux-gnu-gcc" ]; then
            CROSS_GCC_DIR="$dep_dir/tools"
            echo "Found cross-gcc toolchain: $CROSS_GCC_DIR"
        fi
        if [ -d "$dep_dir/tools/bin" ] && [ -f "$dep_dir/tools/bin/x86_64-buckos-linux-gnu-ld" ]; then
            CROSS_BINUTILS_DIR="$dep_dir/tools"
            echo "Found cross-binutils toolchain: $CROSS_BINUTILS_DIR"
        fi
    done

    if [ -n "$CROSS_GCC_DIR" ] && [ -n "$CROSS_BINUTILS_DIR" ]; then
        # Export the cross-compiler paths for stage2 to use directly
        echo "Found cross-toolchain directories:"
        echo "  GCC: $CROSS_GCC_DIR"
        echo "  Binutils: $CROSS_BINUTILS_DIR"

        export BOOTSTRAP_CROSS_GCC_DIR="$CROSS_GCC_DIR"
        export BOOTSTRAP_CROSS_BINUTILS_DIR="$CROSS_BINUTILS_DIR"

        # Add both cross-compiler bin directories to PATH
        # GCC's bin needs to come first since it has the main compiler
        export PATH="$CROSS_GCC_DIR/bin:$CROSS_BINUTILS_DIR/bin:$PATH"

        # Unset LD_LIBRARY_PATH to avoid GLIBC version conflicts
        unset LD_LIBRARY_PATH

        echo "Updated PATH with cross-compiler directories"
    else
        echo "WARNING: Could not find cross-gcc toolchain"
    fi
fi

# Source the external framework (provides PATH setup, dependency handling, etc.)
source "$FRAMEWORK_SCRIPT"
'''
    # Use .replace() instead of .format() to avoid conflicts with shell {} syntax
    script_content = script_template
    script_content = script_content.replace("@@NAME@@", ctx.attrs.name)
    script_content = script_content.replace("@@VERSION@@", ctx.attrs.version)
    script_content = script_content.replace("@@CATEGORY@@", ctx.attrs.category)
    script_content = script_content.replace("@@SLOT@@", ctx.attrs.slot)
    script_content = script_content.replace("@@USE_FLAGS@@", use_flags)
    script_content = script_content.replace("@@USE_BOOTSTRAP@@", "true" if use_bootstrap else "false")
    script_content = script_content.replace("@@USE_HOST@@", "true" if use_host_toolchain else "false")
    script_content = script_content.replace("@@BOOTSTRAP_SYSROOT@@", bootstrap_sysroot)
    script_content = script_content.replace("@@BOOTSTRAP_STAGE@@", bootstrap_stage)
    script_content = script_content.replace("@@BUILD_THREADS@@", build_threads)
    script_content = script_content.replace("@@RUN_TESTS@@", "yes" if ctx.attrs.run_tests else "")
    script_content = script_content.replace("@@PROXY@@", _get_download_proxy())

    script = ctx.actions.write(
        "ebuild_wrapper.sh",
        script_content,
        is_executable = True,
    )

    # Build command - wrapper sources the external framework
    # Arguments order: DESTDIR, SRC_DIR, PKG_CONFIG_WRAPPER, FRAMEWORK_SCRIPT, PATCH_COUNT,
    #                  ENV_SCRIPT, SRC_UNPACK, SRC_PREPARE, PRE_CONFIGURE, SRC_CONFIGURE,
    #                  SRC_COMPILE, SRC_TEST, SRC_INSTALL, HOST_TOOL_COUNT, patches..., host_tool_dirs..., dep_dirs...
    cmd = cmd_args([
        "bash",
        script,
        install_dir.as_output(),
        src_dir,
        pkg_config_wrapper,
        ebuild_script,  # Framework script to be sourced
        str(patch_count),  # Number of patch files
    ])

    # Add phase scripts as inputs (properly tracked by Buck2)
    cmd.add(env_script)
    cmd.add(phase_scripts["src_unpack"])
    cmd.add(phase_scripts["src_prepare"])
    cmd.add(phase_scripts["pre_configure"])
    cmd.add(phase_scripts["src_configure"])
    cmd.add(phase_scripts["src_compile"])
    cmd.add(phase_scripts["src_test"])
    cmd.add(phase_scripts["src_install"])

    # Add host tool count (number of exec_bdepend directories)
    exec_dep_count = len(exec_dep_dirs)
    cmd.add(str(exec_dep_count))

    # Add patch files as arguments
    for patch_file in patch_file_list:
        cmd.add(patch_file)

    # Add host tool directories (exec_bdepend - tools that run on host platform)
    for exec_dep_dir in exec_dep_dirs:
        cmd.add(exec_dep_dir)

    # Add target dependency directories (cross-compiled libraries/headers)
    for dep_dir in dep_dirs:
        cmd.add(dep_dir)

    # Determine if this action should be local-only:
    # - Bootstrap packages (use_bootstrap=true) use the host compiler and tools,
    #   so they must run locally to ensure host compatibility
    # - Packages can explicitly override with local_only attribute
    local_only_attr = ctx.attrs.local_only if hasattr(ctx.attrs, "local_only") else None
    if local_only_attr != None:
        is_local_only = local_only_attr
    else:
        # Default: local_only=True for bootstrap packages
        is_local_only = use_bootstrap

    ctx.actions.run(
        cmd,
        category = "ebuild",
        identifier = ctx.attrs.name,
        local_only = is_local_only,
    )

    return [
        DefaultInfo(default_output = install_dir),
        PackageInfo(
            name = ctx.attrs.name,
            version = ctx.attrs.version,
            description = ctx.attrs.description,
            homepage = ctx.attrs.homepage,
            license = ctx.attrs.license,
            src_uri = "",
            checksum = "",
            dependencies = ctx.attrs.rdepend,
            build_dependencies = ctx.attrs.bdepend,
            maintainers = ctx.attrs.maintainers,
        ),
    ]


ebuild_package_rule = rule(
    impl = _ebuild_package_impl,
    attrs = {
        "source": attrs.dep(),
        "version": attrs.string(),
        "package_type": attrs.string(default = "unknown", doc = "Build system type (cmake, meson, autotools, make, cargo, go, python)"),
        "category": attrs.string(default = ""),
        "slot": attrs.string(default = "0"),
        "description": attrs.string(default = ""),
        "homepage": attrs.string(default = ""),
        "license": attrs.string(default = ""),
        "use_flags": attrs.list(attrs.string(), default = []),
        "src_unpack": attrs.string(default = ""),
        "src_prepare": attrs.string(default = ""),
        "pre_configure": attrs.string(default = ""),
        "src_configure": attrs.string(default = ""),
        "src_compile": attrs.string(default = ""),
        "src_test": attrs.string(default = ""),
        "src_install": attrs.string(default = ""),
        "run_tests": attrs.bool(default = False),
        "env": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "depend": attrs.list(attrs.dep(), default = []),
        "rdepend": attrs.list(attrs.dep(), default = []),
        "bdepend": attrs.list(attrs.dep(), default = []),
        "exec_bdepend": attrs.list(attrs.exec_dep(), default = []),  # Build tools for host platform
        "pdepend": attrs.list(attrs.dep(), default = []),
        "maintainers": attrs.list(attrs.string(), default = []),
        "patches": attrs.list(attrs.source(), default = []),
        # Bootstrap toolchain support
        "use_bootstrap": attrs.bool(default = False),
        "bootstrap_sysroot": attrs.string(default = ""),
        # Bootstrap stage selection (stage1, stage2, stage3, or empty for regular builds)
        # stage1: Uses host compiler to build cross-toolchain (partial isolation)
        # stage2: Uses cross-compiler to build core utilities (strong isolation)
        # stage3: Uses bootstrap toolchain to rebuild itself (complete isolation, verification)
        "bootstrap_stage": attrs.string(default = ""),
        # Remote execution control - set to True for packages that must run locally
        # (e.g., bootstrap packages that depend on host-specific tools)
        "local_only": attrs.bool(default = False),
        # Typed language toolchain attrs (first-class Buck2 toolchains)
        "_go_toolchain": attrs.option(attrs.dep(providers = [GoToolchainInfo]), default = None),
        "_rust_toolchain": attrs.option(attrs.dep(providers = [RustToolchainInfo]), default = None),
        # External scripts for proper cache invalidation
        "_pkg_config_wrapper": attrs.dep(default = "//defs/scripts:pkg-config-wrapper"),
        "_ebuild_script": attrs.dep(default = "//defs/scripts:ebuild"),
        "_ebuild_bootstrap_stage1_script": attrs.dep(default = "//defs/scripts:ebuild-bootstrap-stage1"),
        "_ebuild_bootstrap_stage2_script": attrs.dep(default = "//defs/scripts:ebuild-bootstrap-stage2"),
        "_ebuild_bootstrap_stage3_script": attrs.dep(default = "//defs/scripts:ebuild-bootstrap-stage3"),
    },
)

def ebuild_package(
        name: str,
        source: str,
        version: str,
        # USE flag support
        iuse: list[str] = [],
        use_defaults: list[str] = [],
        use_configure: dict = {},
        use_deps: dict = {},
        global_use: dict | None = None,
        package_overrides: dict | None = None,
        # Dependencies
        depend: list[str] = [],
        rdepend: list[str] = [],
        bdepend = [],  # Build-time dependencies (supports select() for arch-specific deps)
        exec_bdepend: list[str] = [],  # Build tools that run on host platform
        pdepend: list[str] = [],
        # Build phases
        src_unpack: str = "",
        src_prepare: str = "",
        pre_configure: str = "",
        src_configure: str = "",
        src_compile: str = "",
        src_test: str = "",
        src_install: str = "",
        # Other options
        env: dict = {},
        **kwargs):
    """
    Low-level ebuild package macro with USE flag support.

    This is used for packages that cannot use higher-level macros like
    autotools_package (e.g., libtool to avoid circular dependencies).

    Args:
        name: Package name
        source: Source target (e.g., ":pkg-src")
        version: Package version
        iuse: List of USE flags this package supports
        use_defaults: Default enabled USE flags
        use_configure: Dict mapping USE flag to configure argument(s)
                       Example: {"ssl": "--with-ssl", "-ssl": "--without-ssl"}
        use_deps: Dict mapping USE flag to conditional dependencies
        global_use: Global USE flag configuration
        package_overrides: Package-specific USE overrides
        depend: Runtime dependencies
        rdepend: Runtime-only dependencies
        bdepend: Build-time dependencies
        pdepend: Post-merge dependencies
        src_unpack: Custom unpack phase
        src_prepare: Custom prepare phase
        pre_configure: Pre-configure commands (appended to src_prepare)
        src_configure: Custom configure phase
        src_compile: Custom compile phase
        src_test: Custom test phase
        src_install: Custom install phase
        env: Environment variables
        **kwargs: Additional arguments passed to the rule
    """
    # Add bootstrap toolchain by default to ensure linking against BuckOS glibc
    use_bootstrap = kwargs.pop("use_bootstrap", True)
    use_host_toolchain = _should_use_host_toolchain()

    # Extract typed toolchain overrides before kwargs filtering
    rust_toolchain_override = kwargs.pop("_rust_toolchain", None)
    go_toolchain_override = kwargs.pop("_go_toolchain", None)

    # Handle bdepend - it might be a select() or a list
    # If it's a select, we can't modify it, so wrap it in a list concatenation
    # Check if bdepend is a select by checking the type name
    bdepend_type = str(type(bdepend))
    is_bdepend_select = "select" in bdepend_type.lower()
    if is_bdepend_select:
        # bdepend is already a select - use it directly, add toolchain separately
        final_bdepend = bdepend
    else:
        final_bdepend = list(bdepend)  # Make mutable copy

    bootstrap_stage = kwargs.get("bootstrap_stage", "")
    if use_bootstrap and not use_host_toolchain and not bootstrap_stage and name != "bootstrap-toolchain" and name != "bootstrap-toolchain-aarch64":
        # Use select to pick the right toolchain based on target architecture
        if is_bdepend_select:
            # Can't check membership in a select, so just add the toolchain select
            # The select will resolve to the right deps at configuration time
            final_bdepend = final_bdepend + [select({
                "//platforms:is_aarch64": BOOTSTRAP_TOOLCHAIN_AARCH64,
                "DEFAULT": BOOTSTRAP_TOOLCHAIN,
            })]
        elif BOOTSTRAP_TOOLCHAIN not in final_bdepend and BOOTSTRAP_TOOLCHAIN_AARCH64 not in final_bdepend:
            final_bdepend.append(select({
                "//platforms:is_aarch64": BOOTSTRAP_TOOLCHAIN_AARCH64,
                "DEFAULT": BOOTSTRAP_TOOLCHAIN,
            }))

    # Calculate effective USE flags if USE flags are specified
    effective_use = []
    resolved_depend = list(depend)
    # Make a mutable copy of env dict
    resolved_env = dict(env)

    if iuse:
        effective_use = get_effective_use(
            name,
            iuse,
            use_defaults,
            global_use,
            package_overrides,
        )

        # Resolve conditional dependencies
        resolved_depend.extend(use_dep(use_deps, effective_use))

        # Generate configure arguments based on USE flags and add to env
        if use_configure:
            config_args = use_configure_args(use_configure, effective_use)
            if config_args:
                existing_econf = resolved_env.get("EXTRA_ECONF", "")
                if existing_econf:
                    resolved_env["EXTRA_ECONF"] = existing_econf + " " + " ".join(config_args)
                else:
                    resolved_env["EXTRA_ECONF"] = " ".join(config_args)

    # Append pre_configure to src_prepare if provided
    final_src_prepare = src_prepare
    if pre_configure:
        if final_src_prepare:
            final_src_prepare += "\n" + pre_configure
        else:
            final_src_prepare = pre_configure

    # Apply private patch registry overrides (patches/registry.bzl)
    existing_patches = kwargs.get("patches", [])
    registry_result = apply_registry_overrides(
        name = name,
        patches = existing_patches,
        env = resolved_env,
        src_prepare = final_src_prepare,
        pre_configure = "",
        src_configure = src_configure,
    )
    registry_patches, resolved_env, final_src_prepare, _, src_configure = registry_result
    if registry_patches:
        kwargs["patches"] = registry_patches

    # Filter kwargs to only include parameters that ebuild_package_rule accepts
    filtered_kwargs, src_install = filter_ebuild_kwargs(kwargs, src_install)

    ebuild_package_rule(
        name = name,
        source = source,
        version = version,
        use_flags = effective_use,
        use_bootstrap = use_bootstrap,
        depend = resolved_depend,
        rdepend = rdepend,
        bdepend = final_bdepend,
        exec_bdepend = exec_bdepend,
        pdepend = pdepend,
        src_unpack = src_unpack,
        src_prepare = final_src_prepare,
        src_configure = src_configure,
        src_compile = src_compile,
        src_test = src_test,
        src_install = src_install,
        env = resolved_env,
        _rust_toolchain = rust_toolchain_override,
        _go_toolchain = go_toolchain_override,
        **filtered_kwargs,
    )

# -----------------------------------------------------------------------------
# Convenience Macros
# -----------------------------------------------------------------------------

def simple_package(
        name: str,
        version: str,
        src_uri: str,
        sha256: str,
        configure_args: list[str] = [],
        make_args: list[str] = [],
        deps: list[str] = [],
        maintainers: list[str] = [],
        patches: list[str] = [],
        signature_sha256: str | None = None,
        gpg_key: str | None = None,
        gpg_keyring: str | None = None,
        exclude_patterns: list[str] = [],
        **kwargs):
    """
    Convenience macro for standard autotools packages without USE flags.
    This is a simplified wrapper around autotools_package() for basic packages.

    Args:
        signature_sha256: SHA256 of GPG signature file (use update_checksums.py to populate)
        gpg_key: Optional GPG key ID or fingerprint to import and verify against
        gpg_keyring: Optional path to GPG keyring file with trusted keys
        exclude_patterns: List of patterns to exclude from source extraction (passed to tar --exclude)
    """
    # Forward to autotools_package() which supports both USE flags and simple builds
    autotools_package(
        name = name,
        version = version,
        src_uri = src_uri,
        sha256 = sha256,
        configure_args = configure_args,
        make_args = make_args,
        deps = deps,
        maintainers = maintainers,
        patches = patches,
        signature_sha256 = signature_sha256,
        gpg_key = gpg_key,
        gpg_keyring = gpg_keyring,
        exclude_patterns = exclude_patterns,
        **kwargs
    )

def cmake_package(
        name: str,
        version: str,
        src_uri: str | None = None,
        sha256: str | None = None,
        source: str | None = None,
        cmake_args: list[str] = [],
        pre_configure: str = "",
        deps: list[str] = [],
        maintainers: list[str] = [],
        patches: list[str] = [],
        # USE flag support
        iuse: list[str] = [],
        use_defaults: list[str] = [],
        use_options: dict = {},
        use_cmake: dict = {},  # Raw cmake args like use_configure: {"ssl": "-DWITH_SSL=ON", "-ssl": "-DWITH_SSL=OFF"}
        use_deps: dict = {},
        global_use: dict | None = None,
        package_overrides: dict | None = None,
        # Distribution compatibility
        compat_tags: list[str] | None = None,
        signature_sha256: str | None = None,
        signature_required: bool = False,
        gpg_key: str | None = None,
        gpg_keyring: str | None = None,
        exclude_patterns: list[str] = [],
        **kwargs):
    """
    Convenience macro for CMake packages with USE flag support.
    Uses the cmake eclass for standardized build phases.

    Args:
        name: Package name
        version: Package version
        src_uri: Source download URL
        sha256: Source checksum
        cmake_args: Base CMake arguments
        pre_configure: Pre-configure script
        deps: Base dependencies (always applied)
        maintainers: Package maintainers
        iuse: List of USE flags this package supports
        use_defaults: Default enabled USE flags
        use_options: Dict mapping USE flag to CMake option(s)
                     Example: {"ssl": "ENABLE_SSL", "tests": "BUILD_TESTING"}
        use_deps: Dict mapping USE flag to conditional dependencies
        global_use: Global USE flag configuration
        package_overrides: Package-specific USE overrides
        signature_sha256: SHA256 of GPG signature file (use update_checksums.py to populate)
        gpg_key: Optional GPG key ID or fingerprint to import and verify against
        gpg_keyring: Optional path to GPG keyring file with trusted keys
        exclude_patterns: List of patterns to exclude from source extraction (passed to tar --exclude)

    Example:
        cmake_package(
            name = "libfoo",
            version = "1.2.3",
            src_uri = "https://example.com/libfoo-1.2.3.tar.gz",
            sha256 = "...",
            iuse = ["ssl", "tests", "doc"],
            use_defaults = ["ssl"],
            use_options = {
                "ssl": "ENABLE_SSL",
                "tests": "BUILD_TESTING",
                "doc": "BUILD_DOCUMENTATION",
            },
            use_deps = {
                "ssl": ["//packages/linux/dev-libs/openssl"],
            },
        )
    """
    # Apply platform-specific constraints (Linux packages only build on Linux, etc.)
    kwargs = _apply_platform_constraints(kwargs)

    # Handle source - either use provided source or create one from src_uri
    if source:
        src_target = source
    else:
        if not src_uri or not sha256:
            fail("Either 'source' or both 'src_uri' and 'sha256' must be provided")
        src_name = name + "-src"
        download_source(
            name = src_name,
            src_uri = src_uri,
            sha256 = sha256,
            signature_sha256 = signature_sha256,
            signature_required = signature_required,
            gpg_key = gpg_key,
            gpg_keyring = gpg_keyring,
            exclude_patterns = exclude_patterns,
        )
        src_target = ":" + src_name

    # Calculate effective USE flags if USE flags are specified
    effective_use = []
    resolved_deps = list(deps)
    resolved_cmake_args = list(cmake_args)

    if iuse:
        effective_use = get_effective_use(
            name,
            iuse,
            use_defaults,
            global_use,
            package_overrides,
        )

        # Resolve conditional dependencies
        resolved_deps.extend(use_dep(use_deps, effective_use))

        # Generate CMake options based on USE flags
        if use_options:
            cmake_opts = use_cmake_options(use_options, effective_use)
            resolved_cmake_args.extend(cmake_opts)

        # Process use_cmake (raw cmake args like use_configure)
        if use_cmake:
            for flag, cmake_arg in use_cmake.items():
                should_add = False
                if flag.startswith("-"):
                    # Negative flag (e.g., "-lite")
                    flag_name = flag[1:]
                    if flag_name not in effective_use:
                        should_add = True
                else:
                    # Positive flag (e.g., "lite")
                    if flag in effective_use:
                        should_add = True

                if should_add:
                    # cmake_arg can be a string or list of strings
                    if type(cmake_arg) == type([]):
                        resolved_cmake_args.extend(cmake_arg)
                    else:
                        resolved_cmake_args.append(cmake_arg)

    # Use eclass inheritance for cmake
    eclass_config = inherit(["cmake"])

    # Handle cmake_args by setting environment variable
    env = kwargs.pop("env", {})
    if resolved_cmake_args:
        env["CMAKE_EXTRA_ARGS"] = " ".join(resolved_cmake_args)

    # Merge eclass bdepend with any existing bdepend
    bdepend = list(kwargs.pop("bdepend", []))
    for dep in eclass_config["bdepend"]:
        if dep not in bdepend:
            bdepend.append(dep)

    # Merge eclass exec_bdepend (host-platform build tools) with any existing exec_bdepend
    exec_bdepend = list(kwargs.pop("exec_bdepend", []))
    for dep in eclass_config.get("exec_bdepend", []):
        if dep not in exec_bdepend:
            exec_bdepend.append(dep)

    # Add bootstrap toolchain by default to ensure linking against BuckOS glibc
    # get_toolchain_dep() returns None when use_host_toolchain is enabled
    use_bootstrap = kwargs.pop("use_bootstrap", True)
    if use_bootstrap:
        toolchain_dep = get_toolchain_dep()
        if toolchain_dep:
            bdepend.append(toolchain_dep)

    # Allow overriding eclass phases via kwargs
    custom_src_prepare = kwargs.pop("src_prepare", None)
    custom_src_configure = kwargs.pop("src_configure", None)
    custom_src_compile = kwargs.pop("src_compile", None)
    custom_src_install = kwargs.pop("src_install", None)

    # Combine with eclass phases
    src_prepare = custom_src_prepare if custom_src_prepare else eclass_config.get("src_prepare", "")

    # Export patch files and create references
    patch_refs = []
    for i, patch in enumerate(patches):
        if patch.startswith(":") or patch.startswith("//"):
            # Already a target reference
            patch_refs.append(patch)
        else:
            # Create an export_file target for this patch
            patch_target_name = "{}-patch-{}".format(name, i)
            native.export_file(
                name = patch_target_name,
                src = patch,
                visibility = [],  # Private to this package
            )
            patch_refs.append(":" + patch_target_name)

    # Filter kwargs to only include parameters that ebuild_package_rule accepts
    src_install = custom_src_install if custom_src_install else eclass_config["src_install"]
    filtered_kwargs, src_install = filter_ebuild_kwargs(kwargs, src_install)

    ebuild_package_rule(
        name = name,
        source = src_target,
        version = version,
        package_type = "cmake",
        pre_configure = pre_configure,
        src_prepare = src_prepare,
        patches = patch_refs,  # Buck2 target references
        src_configure = custom_src_configure if custom_src_configure else eclass_config["src_configure"],
        src_compile = custom_src_compile if custom_src_compile else eclass_config["src_compile"],
        src_install = src_install,
        rdepend = resolved_deps,
        bdepend = bdepend,
        exec_bdepend = exec_bdepend,
        env = env,
        maintainers = maintainers,
        use_flags = effective_use,
        use_bootstrap = use_bootstrap,
        **filtered_kwargs
    )

def meson_package(
        name: str,
        version: str,
        src_uri: str | None = None,
        sha256: str | None = None,
        source: str | None = None,
        meson_args: list[str] = [],
        deps: list[str] = [],
        maintainers: list[str] = [],
        patches: list[str] = [],
        # USE flag support
        iuse: list[str] = [],
        use_defaults: list[str] = [],
        use_options: dict = {},
        use_meson: dict = {},  # Raw meson args like use_configure: {"ssl": "-Dssl=enabled", "-ssl": "-Dssl=disabled"}
        use_configure: dict = {},  # Alias for use_meson (for consistency with autotools_package)
        use_deps: dict = {},
        global_use: dict | None = None,
        package_overrides: dict | None = None,
        # Distribution compatibility
        compat_tags: list[str] | None = None,
        signature_sha256: str | None = None,
        signature_required: bool = False,
        gpg_key: str | None = None,
        gpg_keyring: str | None = None,
        exclude_patterns: list[str] = [],
        **kwargs):
    """
    Convenience macro for Meson packages with USE flag support.
    Uses the meson eclass for standardized build phases.

    Args:
        name: Package name
        version: Package version
        src_uri: Source download URL
        sha256: Source checksum
        meson_args: Base Meson arguments
        deps: Base dependencies (always applied)
        maintainers: Package maintainers
        iuse: List of USE flags this package supports
        use_defaults: Default enabled USE flags
        use_options: Dict mapping USE flag to Meson option(s)
                     Example: {"ssl": "ssl", "tests": "tests"}
        use_meson: Dict mapping USE flag to raw meson arguments
                   Example: {"ssl": "-Dssl=enabled", "-ssl": "-Dssl=disabled"}
        use_configure: Alias for use_meson (for consistency with autotools_package)
        use_deps: Dict mapping USE flag to conditional dependencies
        global_use: Global USE flag configuration
        package_overrides: Package-specific USE overrides
        signature_sha256: SHA256 of GPG signature file (use update_checksums.py to populate)
        gpg_key: Optional GPG key ID or fingerprint to import and verify against
        gpg_keyring: Optional path to GPG keyring file with trusted keys
        exclude_patterns: List of patterns to exclude from source extraction (passed to tar --exclude)

    Example:
        meson_package(
            name = "libbar",
            version = "2.3.4",
            src_uri = "https://example.com/libbar-2.3.4.tar.xz",
            sha256 = "...",
            iuse = ["ssl", "tests", "doc"],
            use_defaults = ["ssl"],
            use_options = {
                "ssl": "ssl",
                "tests": "tests",
                "doc": "docs",
            },
            # Or use raw meson args:
            use_meson = {
                "xwayland": "-Dxwayland=enabled",
                "-xwayland": "-Dxwayland=disabled",
            },
            use_deps = {
                "ssl": ["//packages/linux/dev-libs/openssl"],
            },
        )
    """
    # Apply platform-specific constraints (Linux packages only build on Linux, etc.)
    kwargs = _apply_platform_constraints(kwargs)

    # Handle source - either use provided source or create one from src_uri
    if source:
        src_target = source
    else:
        if not src_uri or not sha256:
            fail("Either 'source' or both 'src_uri' and 'sha256' must be provided")
        src_name = name + "-src"
        download_source(
            name = src_name,
            src_uri = src_uri,
            sha256 = sha256,
            signature_sha256 = signature_sha256,
            signature_required = signature_required,
            gpg_key = gpg_key,
            gpg_keyring = gpg_keyring,
            exclude_patterns = exclude_patterns,
        )
        src_target = ":" + src_name

    # Calculate effective USE flags if USE flags are specified
    effective_use = []
    resolved_deps = list(deps)
    resolved_meson_args = list(meson_args)

    if iuse:
        effective_use = get_effective_use(
            name,
            iuse,
            use_defaults,
            global_use,
            package_overrides,
        )

        # Resolve conditional dependencies
        resolved_deps.extend(use_dep(use_deps, effective_use))

        # Generate Meson options based on USE flags
        if use_options:
            meson_opts = use_meson_options(use_options, effective_use)
            resolved_meson_args.extend(meson_opts)

        # Process use_meson (raw meson args like use_configure)
        # Merge use_configure into use_meson for consistency
        combined_use_meson = dict(use_meson)
        combined_use_meson.update(use_configure)
        if combined_use_meson:
            meson_args_from_use = use_configure_args(combined_use_meson, effective_use)
            resolved_meson_args.extend(meson_args_from_use)

    # Use eclass inheritance for meson
    eclass_config = inherit(["meson"])

    # Handle meson_args by setting environment variable
    env = kwargs.pop("env", {})
    if resolved_meson_args:
        env["MESON_EXTRA_ARGS"] = " ".join(resolved_meson_args)

    # Merge eclass bdepend with any existing bdepend
    bdepend = list(kwargs.pop("bdepend", []))
    for dep in eclass_config["bdepend"]:
        if dep not in bdepend:
            bdepend.append(dep)

    # Merge eclass exec_bdepend (host-platform build tools) with any existing exec_bdepend
    exec_bdepend = list(kwargs.pop("exec_bdepend", []))
    for dep in eclass_config.get("exec_bdepend", []):
        if dep not in exec_bdepend:
            exec_bdepend.append(dep)

    # Add bootstrap toolchain by default to ensure linking against BuckOS glibc
    # get_toolchain_dep() returns None when use_host_toolchain is enabled
    use_bootstrap = kwargs.pop("use_bootstrap", True)
    if use_bootstrap:
        toolchain_dep = get_toolchain_dep()
        if toolchain_dep:
            bdepend.append(toolchain_dep)

    # Allow overriding eclass phases via kwargs
    custom_src_prepare = kwargs.pop("src_prepare", None)
    custom_src_configure = kwargs.pop("src_configure", None)
    custom_src_compile = kwargs.pop("src_compile", None)
    custom_src_install = kwargs.pop("src_install", None)

    # Combine with eclass phases
    src_prepare = custom_src_prepare if custom_src_prepare else eclass_config.get("src_prepare", "")

    # Export patch files and create references
    patch_refs = []
    for i, patch in enumerate(patches):
        if patch.startswith(":") or patch.startswith("//"):
            # Already a target reference
            patch_refs.append(patch)
        else:
            # Create an export_file target for this patch
            patch_target_name = "{}-patch-{}".format(name, i)
            native.export_file(
                name = patch_target_name,
                src = patch,
                visibility = [],  # Private to this package
            )
            patch_refs.append(":" + patch_target_name)

    # Filter kwargs to only include parameters that ebuild_package_rule accepts
    src_install = custom_src_install if custom_src_install else eclass_config["src_install"]
    filtered_kwargs, src_install = filter_ebuild_kwargs(kwargs, src_install)

    ebuild_package_rule(
        name = name,
        source = src_target,
        version = version,
        package_type = "meson",
        patches = patch_refs,
        src_prepare = src_prepare,
        src_configure = custom_src_configure if custom_src_configure else eclass_config["src_configure"],
        src_compile = custom_src_compile if custom_src_compile else eclass_config["src_compile"],
        src_install = src_install,
        rdepend = resolved_deps,
        bdepend = bdepend,
        exec_bdepend = exec_bdepend,
        env = env,
        maintainers = maintainers,
        use_flags = effective_use,
        use_bootstrap = use_bootstrap,
        **filtered_kwargs
    )

def autotools_package(
        name: str,
        version: str,
        src_uri: str | None = None,
        sha256: str | None = None,
        source: str | None = None,
        configure_args: list[str] = [],
        make_args: list[str] = [],
        deps: list[str] = [],
        maintainers: list[str] = [],
        patches: list[str] = [],
        # USE flag support
        iuse: list[str] = [],
        use_defaults: list[str] = [],
        use_configure: dict = {},
        use_deps: dict = {},
        global_use: dict | None = None,
        package_overrides: dict | None = None,
        # Distribution compatibility
        compat_tags: list[str] | None = None,
        signature_sha256: str | None = None,
        signature_required: bool = False,
        gpg_key: str | None = None,
        gpg_keyring: str | None = None,
        exclude_patterns: list[str] = [],
        **kwargs):
    """
    Convenience macro for autotools packages with USE flag support.
    Uses the autotools eclass for standardized build phases.

    This replaces both configure_make_package() and use_package() with a
    unified interface consistent with all other language package types.

    Args:
        name: Package name
        version: Package version
        src_uri: Source download URL (required if source not provided)
        sha256: Source checksum (required if source not provided)
        source: Pre-defined source target (alternative to src_uri/sha256)
        configure_args: Base configure arguments
        make_args: Make arguments
        deps: Base dependencies (always applied)
        maintainers: Package maintainers
        iuse: List of USE flags this package supports
        use_defaults: Default enabled USE flags
        use_configure: Dict mapping USE flag to configure argument(s)
                       Example: {"ssl": "--with-ssl", "-ssl": "--without-ssl"}
        use_deps: Dict mapping USE flag to conditional dependencies
        global_use: Global USE flag configuration
        package_overrides: Package-specific USE overrides
        compat_tags: Distribution compatibility tags (e.g., ["buckos-native", "fedora"])
                    Defaults to ["buckos-native"] if not specified
        signature_sha256: SHA256 of GPG signature file (use update_checksums.py to populate)
        gpg_key: Optional GPG key ID or fingerprint to import and verify against
        gpg_keyring: Optional path to GPG keyring file with trusted keys
        exclude_patterns: List of patterns to exclude from source extraction (passed to tar --exclude)

    Example:
        autotools_package(
            name = "curl",
            version = "8.5.0",
            src_uri = "https://curl.se/download/curl-8.5.0.tar.xz",
            sha256 = "...",
            iuse = ["ssl", "http2", "ipv6"],
            use_defaults = ["ssl", "ipv6"],
            use_configure = {
                "ssl": "--with-ssl",
                "-ssl": "--without-ssl",
                "http2": "--with-nghttp2",
                "ipv6": "--enable-ipv6",
                "-ipv6": "--disable-ipv6",
            },
            use_deps = {
                "ssl": ["//packages/linux/dev-libs/openssl"],
                "http2": ["//packages/linux/system/libs/network/nghttp2"],
            },
        )
    """
    # Apply platform-specific constraints (Linux packages only build on Linux, etc.)
    kwargs = _apply_platform_constraints(kwargs)

    # Handle distribution compatibility tags
    if compat_tags == None:
        compat_tags = [DISTRO_BUCKOS]  # Default to BuckOS-native only

    # Validate compat tags
    warnings = validate_compat_tags(compat_tags)
    for warning in warnings:
        print("Warning in {}: {}".format(name, warning))

    # Store compat tags in metadata for later use
    # Buck2 metadata keys must contain exactly one dot (e.g., "custom.key")
    if "metadata" not in kwargs:
        kwargs["metadata"] = {}
    kwargs["metadata"]["custom.compat_tags"] = compat_tags

    # Handle source - either use provided source or create one from src_uri
    if source:
        src_target = source
    else:
        if not src_uri or not sha256:
            fail("Either 'source' or both 'src_uri' and 'sha256' must be provided")
        src_name = name + "-src"
        download_source(
            name = src_name,
            src_uri = src_uri,
            sha256 = sha256,
            signature_sha256 = signature_sha256,
            signature_required = signature_required,
            gpg_key = gpg_key,
            gpg_keyring = gpg_keyring,
            exclude_patterns = exclude_patterns,
        )
        src_target = ":" + src_name

    # Calculate effective USE flags if USE flags are specified
    effective_use = []
    resolved_deps = list(deps)
    resolved_configure_args = list(configure_args)

    if iuse:
        effective_use = get_effective_use(
            name,
            iuse,
            use_defaults,
            global_use,
            package_overrides,
        )

        # Resolve conditional dependencies
        resolved_deps.extend(use_dep(use_deps, effective_use))

        # Generate configure arguments based on USE flags
        if use_configure:
            config_args = use_configure_args(use_configure, effective_use)
            resolved_configure_args.extend(config_args)

    # Use eclass inheritance for autotools
    eclass_config = inherit(["autotools"])

    # Handle configure and make args by setting environment variables
    env = kwargs.pop("env", {})
    if resolved_configure_args:
        env["EXTRA_ECONF"] = " ".join(resolved_configure_args)
    if make_args:
        env["EXTRA_EMAKE"] = " ".join(make_args)

    # Merge eclass bdepend with any existing bdepend
    bdepend = list(kwargs.pop("bdepend", []))

    # Merge eclass exec_bdepend (host-platform build tools) with any existing exec_bdepend
    exec_bdepend = list(kwargs.pop("exec_bdepend", []))
    for dep in eclass_config.get("exec_bdepend", []):
        if dep not in exec_bdepend:
            exec_bdepend.append(dep)

    # Check if host toolchain is enabled
    use_host_toolchain = _should_use_host_toolchain()

    for dep in eclass_config["bdepend"]:
        # NOTE: We no longer skip autoconf/automake/libtool with host toolchain
        # because the network-isolated build environment needs them in PATH.
        # The host tools aren't accessible during network isolation.
        if dep not in bdepend:
            bdepend.append(dep)

    # Add bootstrap toolchain by default to ensure linking against BuckOS glibc
    # Skip if this package is part of the bootstrap toolchain itself or if using host toolchain
    use_bootstrap = kwargs.pop("use_bootstrap", True)
    if use_bootstrap and not use_host_toolchain:
        # Use select to pick the right toolchain based on target architecture
        if BOOTSTRAP_TOOLCHAIN not in bdepend and BOOTSTRAP_TOOLCHAIN_AARCH64 not in bdepend:
            bdepend.append(select({
                "//platforms:is_aarch64": BOOTSTRAP_TOOLCHAIN_AARCH64,
                "DEFAULT": BOOTSTRAP_TOOLCHAIN,
            }))

    # Get pre_configure and post_install if provided
    pre_configure = kwargs.pop("pre_configure", "")
    post_install = kwargs.pop("post_install", "")

    # Allow overriding eclass phases for non-autotools packages
    custom_src_prepare = kwargs.pop("src_prepare", None)
    custom_src_configure = kwargs.pop("src_configure", None)
    custom_src_compile = kwargs.pop("src_compile", None)
    custom_src_install = kwargs.pop("src_install", None)

    # Combine with eclass phases
    src_prepare = custom_src_prepare if custom_src_prepare else eclass_config.get("src_prepare", "")


    if pre_configure:
        src_prepare += "\n" + pre_configure

    # Use custom phases if provided, otherwise use eclass defaults
    # Note: use "!= None" to allow empty string "" to skip the phase
    src_configure = custom_src_configure if custom_src_configure != None else eclass_config["src_configure"]
    src_compile = custom_src_compile if custom_src_compile != None else eclass_config["src_compile"]

    # For src_install, always append post_install if provided (whether using custom or eclass)
    src_install = custom_src_install if custom_src_install != None else eclass_config["src_install"]
    if post_install:
        src_install += "\n" + post_install

    # Export patch files and create references
    patch_refs = []
    for i, patch in enumerate(patches):
        if patch.startswith(":") or patch.startswith("//"):
            # Already a target reference
            patch_refs.append(patch)
        else:
            # Create an export_file target for this patch
            patch_target_name = "{}-patch-{}".format(name, i)
            native.export_file(
                name = patch_target_name,
                src = patch,
                visibility = [],  # Private to this package
            )
            patch_refs.append(":" + patch_target_name)

    # Filter kwargs to only include parameters that ebuild_package_rule accepts
    filtered_kwargs, src_install = filter_ebuild_kwargs(kwargs, src_install)

    ebuild_package_rule(
        name = name,
        source = src_target,
        version = version,
        package_type = "autotools",
        patches = patch_refs,  # Buck2 target references
        src_prepare = src_prepare,
        src_configure = src_configure,
        src_compile = src_compile,
        src_install = src_install,
        rdepend = resolved_deps,
        bdepend = bdepend,
        exec_bdepend = exec_bdepend,
        env = env,
        maintainers = maintainers,
        use_flags = effective_use,
        use_bootstrap = use_bootstrap,
        **filtered_kwargs
    )

def make_package(
        name: str,
        version: str,
        src_uri: str | None = None,
        sha256: str | None = None,
        source: str | None = None,
        make_args: list[str] = [],
        make_install_args: list[str] = [],
        deps: list[str] = [],
        maintainers: list[str] = [],
        patches: list[str] = [],
        # USE flag support
        iuse: list[str] = [],
        use_defaults: list[str] = [],
        use_make: dict = {},
        use_deps: dict = {},
        global_use: dict | None = None,
        package_overrides: dict | None = None,
        # Distribution compatibility
        compat_tags: list[str] | None = None,
        signature_sha256: str | None = None,
        signature_required: bool = False,
        gpg_key: str | None = None,
        gpg_keyring: str | None = None,
        exclude_patterns: list[str] = [],
        # Custom configure system support (for packages using config.in + configure.sh)
        config_in_options: dict | None = None,
        config_in_script: str = "./configure.sh config.in",
        # Custom phase overrides
        src_prepare: str = "",
        src_configure: str = ":",
        src_compile: str | None = None,
        src_install: str | None = None,
        **kwargs):
    """
    Convenience macro for make-based packages with USE flag support.
    Similar to autotools_package but for projects that only use make (no configure).

    Args:
        name: Package name
        version: Package version
        src_uri: Source download URL (required if source not provided)
        sha256: Source checksum (required if source not provided)
        source: Pre-defined source target (alternative to src_uri/sha256)
        make_args: Make arguments for compilation
        make_install_args: Make arguments for installation
        deps: Base dependencies (always applied)
        maintainers: Package maintainers
        patches: List of patch files to apply
        iuse: List of USE flags this package supports
        use_defaults: Default enabled USE flags
        use_make: Dict mapping USE flag to make arguments
                  Example: {"debug": "DEBUG=1", "-debug": "DEBUG=0"}
        use_deps: Dict mapping USE flag to conditional dependencies
        global_use: Global USE flag configuration
        package_overrides: Package-specific USE overrides
        compat_tags: Distribution compatibility tags
        config_in_options: Dict mapping config.in option names to values (y/n).
                          For packages using config.in + configure.sh style configuration.
                          Example: {"HAVE_HWTR": "n", "HAVE_AFINET6": "y"}
        config_in_script: Command to run configure.sh (default: "./configure.sh config.in")
        src_prepare: Custom src_prepare phase
        src_configure: Custom src_configure phase (default: ":" to skip)
        src_compile: Custom src_compile phase (default: "make")
        src_install: Custom src_install phase (default: "make install")

    Example with config_in_options (for packages like net-tools):
        make_package(
            name = "net-tools",
            version = "2.10",
            src_uri = "...",
            sha256 = "...",
            config_in_options = {
                "HAVE_HWTR": "n",      # Disable Token Ring (removed in kernel 3.5)
                "HAVE_HWSTRIP": "n",   # Disable STRIP (removed in kernel 3.6)
                "HAVE_AFBLUETOOTH": "n",  # Disable Bluetooth
                "HAVE_AFINET6": "y",   # Enable IPv6
            },
        )
    """
    # Apply platform-specific constraints
    kwargs = _apply_platform_constraints(kwargs)

    # Handle distribution compatibility tags
    if compat_tags == None:
        compat_tags = [DISTRO_BUCKOS]

    # Validate compat tags
    warnings = validate_compat_tags(compat_tags)
    for warning in warnings:
        print("Warning in {}: {}".format(name, warning))

    # Store compat tags in metadata
    if "metadata" not in kwargs:
        kwargs["metadata"] = {}
    kwargs["metadata"]["custom.compat_tags"] = compat_tags

    # Handle source
    if source:
        src_target = source
    else:
        if not src_uri or not sha256:
            fail("Either 'source' or both 'src_uri' and 'sha256' must be provided")
        src_name = name + "-src"
        download_source(
            name = src_name,
            src_uri = src_uri,
            sha256 = sha256,
            signature_sha256 = signature_sha256,
            signature_required = signature_required,
            gpg_key = gpg_key,
            gpg_keyring = gpg_keyring,
            exclude_patterns = exclude_patterns,
        )
        src_target = ":" + src_name

    # Calculate effective USE flags
    effective_use = []
    resolved_deps = list(deps)
    resolved_make_args = list(make_args)

    if iuse:
        effective_use = get_effective_use(
            name,
            iuse,
            use_defaults,
            global_use,
            package_overrides,
        )

        # Resolve conditional dependencies
        resolved_deps.extend(use_dep(use_deps, effective_use))

        # Generate make arguments based on USE flags
        if use_make:
            for flag, args in use_make.items():
                if flag.startswith("-"):
                    # Negative flag: add args if flag is NOT enabled
                    if flag[1:] not in effective_use:
                        if isinstance(args, list):
                            resolved_make_args.extend(args)
                        else:
                            resolved_make_args.append(args)
                else:
                    # Positive flag: add args if flag IS enabled
                    if flag in effective_use:
                        if isinstance(args, list):
                            resolved_make_args.extend(args)
                        else:
                            resolved_make_args.append(args)

    # Set up environment
    env = kwargs.pop("env", {})
    if resolved_make_args:
        env["EXTRA_EMAKE"] = " ".join(resolved_make_args)
    if make_install_args:
        env["MAKE_INSTALL_ARGS"] = " ".join(make_install_args)

    # Handle bdepend
    bdepend = list(kwargs.pop("bdepend", []))

    # Add bootstrap toolchain by default
    # Skip if using host toolchain
    use_bootstrap = kwargs.pop("use_bootstrap", True)
    use_host_toolchain = _should_use_host_toolchain()
    if use_bootstrap and not use_host_toolchain:
        # Use select to pick the right toolchain based on target architecture
        if BOOTSTRAP_TOOLCHAIN not in bdepend and BOOTSTRAP_TOOLCHAIN_AARCH64 not in bdepend:
            bdepend.append(select({
                "//platforms:is_aarch64": BOOTSTRAP_TOOLCHAIN_AARCH64,
                "DEFAULT": BOOTSTRAP_TOOLCHAIN,
            }))

    # Default src_compile if not provided
    if src_compile == None:
        src_compile = 'make -j${MAKEOPTS:-$(nproc)} $EXTRA_EMAKE'

    # Default src_install if not provided
    if src_install == None:
        src_install = 'make DESTDIR="$DESTDIR" $MAKE_INSTALL_ARGS install'

    # Handle config.in style configuration (for packages like net-tools)
    if config_in_options:
        # Generate sed commands to modify config.in options
        config_commands = ["# Modify config.in options (Gentoo-style set_opt)"]
        for opt_name, opt_value in config_in_options.items():
            # Use sed to change the option value in config.in
            # Pattern matches: bool 'description' OPTION_NAME y/n
            config_commands.append(
                'sed -i -e "/^bool.* {} /s:[yn]$:{}:" config.in'.format(opt_name, opt_value)
            )
        # Run configure.sh with the modified config.in
        config_commands.append('yes "" | {}'.format(config_in_script))

        # If src_configure was just ":", replace it entirely
        # Otherwise prepend to existing src_configure
        if src_configure == ":":
            src_configure = "\n".join(config_commands)
        else:
            src_configure = "\n".join(config_commands) + "\n" + src_configure

    # Export patch files
    patch_refs = []
    for i, patch in enumerate(patches):
        if patch.startswith(":") or patch.startswith("//"):
            patch_refs.append(patch)
        else:
            patch_target_name = "{}-patch-{}".format(name, i)
            native.export_file(
                name = patch_target_name,
                src = patch,
                visibility = [],
            )
            patch_refs.append(":" + patch_target_name)

    # Filter kwargs to only include parameters that ebuild_package_rule accepts
    filtered_kwargs, src_install = filter_ebuild_kwargs(kwargs, src_install)

    ebuild_package_rule(
        name = name,
        source = src_target,
        version = version,
        package_type = "make",
        patches = patch_refs,
        src_prepare = src_prepare,
        src_configure = src_configure,
        src_compile = src_compile,
        src_install = src_install,
        rdepend = resolved_deps,
        bdepend = bdepend,
        env = env,
        maintainers = maintainers,
        use_flags = effective_use,
        use_bootstrap = use_bootstrap,
        **filtered_kwargs
    )

# -----------------------------------------------------------------------------
# Rust Crate Support (pre-downloaded Rust crates for offline builds)
# -----------------------------------------------------------------------------

def _rust_crate_install_impl(ctx: AnalysisContext) -> list[Provider]:
    """Install Rust crate source into vendor directory structure."""
    out_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)
    src_dir = ctx.attrs.source[DefaultInfo].default_outputs[0]

    script_content = """#!/bin/bash
set -e
SRC_DIR="$1"
OUT_DIR="$2"
CRATE_NAME="$3"
VERSION="$4"

VENDOR_PATH="$OUT_DIR/vendor/$CRATE_NAME-$VERSION"
mkdir -p "$VENDOR_PATH"

cd "$SRC_DIR"

# Handle crates.io downloads (comes as download file) or extracted directories
if [ -f "download" ]; then
    tar -xzf download -C "$VENDOR_PATH" --strip-components=1 2>/dev/null || cp -r . "$VENDOR_PATH/"
else
    EXTRACTED=$(ls -d */ 2>/dev/null | head -1)
    if [ -n "$EXTRACTED" ]; then
        cp -r "$EXTRACTED"/* "$VENDOR_PATH/" 2>/dev/null || cp -r . "$VENDOR_PATH/"
    else
        cp -r . "$VENDOR_PATH/"
    fi
fi

# Create .cargo-checksum.json (required by cargo for vendored crates)
echo '{"files":{}}' > "$VENDOR_PATH/.cargo-checksum.json"
"""

    script = ctx.actions.write("install-rust-crate.sh", script_content, is_executable = True)
    ctx.actions.run(
        cmd_args(["bash", script, src_dir, out_dir.as_output(), ctx.attrs.crate_name, ctx.attrs.version]),
        category = "rust_crate",
        identifier = ctx.attrs.name,
    )

    return [
        DefaultInfo(default_output = out_dir),
        RustCrateInfo(
            crate_name = ctx.attrs.crate_name,
            version = ctx.attrs.version,
            crate_dir = out_dir,
            features = ctx.attrs.features,
        ),
    ]

_rust_crate_install = rule(
    impl = _rust_crate_install_impl,
    attrs = {
        "source": attrs.dep(),
        "crate_name": attrs.string(),
        "version": attrs.string(),
        "deps": attrs.list(attrs.dep(), default = []),
        "features": attrs.list(attrs.string(), default = []),
    },
)

def rust_crate(
        name: str,
        version: str,
        src_uri: str,
        crate_name: str | None = None,
        sha256: str = "TODO",
        deps: list[str] = [],
        features: list[str] = [],
        visibility: list[str] = ["PUBLIC"]):
    """
    Define a Rust crate for pre-downloading.

    This creates a vendorable Rust crate that can be combined with other
    rust_crate targets using rust_vendor() for offline builds.

    Args:
        name: Package name
        version: Crate version
        src_uri: Source download URL (e.g., from crates.io)
        crate_name: Crate name if different from package name
        sha256: Source checksum
        deps: Other rust_crate dependencies
        features: Cargo features to enable
        visibility: Buck2 visibility

    Example:
        rust_crate(
            name = "serde",
            version = "1.0.203",
            src_uri = "https://crates.io/api/v1/crates/serde/1.0.203/download",
            sha256 = "abc123...",
            features = ["derive"],
        )
    """
    actual_crate_name = crate_name if crate_name else name

    src_name = name + "-src"
    download_source(
        name = src_name,
        src_uri = src_uri,
        sha256 = sha256,
    )

    _rust_crate_install(
        name = name,
        source = ":" + src_name,
        crate_name = actual_crate_name,
        version = version,
        deps = deps,
        features = features,
        visibility = visibility,
    )

def _rust_vendor_impl(ctx: AnalysisContext) -> list[Provider]:
    """Combine multiple rust_crate dependencies into a vendor directory with cargo config."""
    out_dir = ctx.actions.declare_output("vendor", dir = True)

    # Collect crate directories from dependencies
    crate_dirs = []
    for dep in ctx.attrs.deps:
        if RustCrateInfo in dep:
            crate_dirs.append(dep[RustCrateInfo].crate_dir)
        elif DefaultInfo in dep:
            crate_dirs.append(dep[DefaultInfo].default_outputs[0])

    script_content = """#!/bin/bash
set -e
OUT_DIR="$1"
shift

mkdir -p "$OUT_DIR/vendor" "$OUT_DIR/.cargo"

for dir in "$@"; do
    if [ -d "$dir/vendor" ]; then
        cp -r "$dir/vendor/"* "$OUT_DIR/vendor/" 2>/dev/null || true
    fi
done

# Create .cargo/config.toml for offline builds
cat > "$OUT_DIR/.cargo/config.toml" << 'EOF'
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor"

[net]
offline = true
EOF
"""

    script = ctx.actions.write("merge-rust-vendor.sh", script_content, is_executable = True)
    cmd = cmd_args(["bash", script, out_dir.as_output()])
    for cdir in crate_dirs:
        cmd.add(cdir)

    ctx.actions.run(cmd, category = "rust_vendor", identifier = ctx.attrs.name)

    return [DefaultInfo(default_output = out_dir)]

_rust_vendor = rule(
    impl = _rust_vendor_impl,
    attrs = {
        "deps": attrs.list(attrs.dep()),
    },
)

def rust_vendor(
        name: str,
        deps: list[str],
        visibility: list[str] = ["PUBLIC"]):
    """
    Combine multiple rust_crate dependencies into a vendor directory.

    This creates a merged vendor/ directory with .cargo/config.toml
    for offline builds with cargo_package via vendor_deps parameter.

    Args:
        name: Target name
        deps: List of rust_crate targets to include
        visibility: Buck2 visibility

    Example:
        rust_vendor(
            name = "ripgrep-deps",
            deps = [
                "//packages/linux/dev-libs/rust/serde:serde",
                "//packages/linux/dev-libs/rust/regex:regex",
            ],
        )
    """
    _rust_vendor(
        name = name,
        deps = deps,
        visibility = visibility,
    )

# -----------------------------------------------------------------------------
# Cargo Lock Dependencies (Gentoo-style Cargo.lock parsing)
# -----------------------------------------------------------------------------

def _cargo_lock_download_impl(ctx: AnalysisContext) -> list[Provider]:
    """Download Rust crates from crates.io and create vendor directory structure."""
    out_dir = ctx.actions.declare_output("vendor", dir = True)

    # Build the download script with all crates
    crates_json = json.encode(ctx.attrs.crates)

    script_content = """#!/bin/bash
set -e
OUT_DIR="$1"
CRATES_JSON="$2"

mkdir -p "$OUT_DIR/vendor" "$OUT_DIR/.cargo"

# Read proxy and concurrency settings from environment
HTTP_PROXY="${BUCKOS_DOWNLOAD_PROXY:-${HTTP_PROXY:-${http_proxy:-}}}"
MAX_CONCURRENT="${BUCKOS_MAX_CONCURRENT_DOWNLOADS:-4}"
RATE_LIMIT="${BUCKOS_DOWNLOAD_RATE_LIMIT:-5.0}"

# Parse JSON and download each crate with proxy and rate limiting support
echo "$CRATES_JSON" | python3 -c '
import json
import sys
import os
import time
import hashlib
import tarfile
import tempfile
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed
import threading

crates = json.load(sys.stdin)
out_dir = sys.argv[1]
http_proxy = os.environ.get("HTTP_PROXY", "") or os.environ.get("http_proxy", "")
max_concurrent = int(os.environ.get("BUCKOS_MAX_CONCURRENT_DOWNLOADS", "4"))
rate_limit = float(os.environ.get("BUCKOS_DOWNLOAD_RATE_LIMIT", "5.0"))

# Simple rate limiter
class RateLimiter:
    def __init__(self, rate):
        self.rate = rate
        self.lock = threading.Lock()
        self.last_time = 0

    def acquire(self):
        with self.lock:
            now = time.time()
            wait_time = max(0, (1.0 / self.rate) - (now - self.last_time))
            if wait_time > 0:
                time.sleep(wait_time)
            self.last_time = time.time()

rate_limiter = RateLimiter(rate_limit) if rate_limit > 0 else None

# Configure proxy if set
if http_proxy:
    proxy_handler = urllib.request.ProxyHandler({"http": http_proxy, "https": http_proxy})
    opener = urllib.request.build_opener(proxy_handler)
    urllib.request.install_opener(opener)
    print(f"Using proxy: {http_proxy}")

vendor_dir = os.path.join(out_dir, "vendor")

def download_crate(crate):
    name = crate["name"]
    version = crate["version"]
    checksum = crate.get("checksum", "")

    crate_dir = os.path.join(vendor_dir, f"{name}-{version}")
    if os.path.exists(crate_dir):
        return name  # Already downloaded

    # Download from crates.io
    url = f"https://crates.io/api/v1/crates/{name}/{version}/download"

    if rate_limiter:
        rate_limiter.acquire()

    try:
        print(f"Downloading {name}-{version}")
        with tempfile.NamedTemporaryFile(suffix=".crate", delete=False) as tmp:
            urllib.request.urlretrieve(url, tmp.name)

            # Extract crate
            os.makedirs(crate_dir, exist_ok=True)
            with tarfile.open(tmp.name, "r:gz") as tar:
                # Crates extract to {name}-{version}/ directory
                for member in tar.getmembers():
                    # Strip the first directory component
                    parts = member.name.split("/", 1)
                    if len(parts) > 1:
                        member.name = parts[1]
                        tar.extract(member, crate_dir)

            os.unlink(tmp.name)

        # Create .cargo-checksum.json (required by cargo)
        checksum_data = {"files": {}}
        if checksum:
            checksum_data["package"] = checksum

        checksum_file = os.path.join(crate_dir, ".cargo-checksum.json")
        with open(checksum_file, "w") as f:
            json.dump(checksum_data, f)

        return name

    except urllib.error.HTTPError as e:
        print(f"Warning: Failed to download {name}-{version}: {e}")
        return None
    except Exception as e:
        print(f"Warning: Failed to download {name}-{version}: {e}")
        return None

# Download crates with concurrency limit
print(f"Downloading {len(crates)} Rust crates (max concurrent: {max_concurrent}, rate limit: {rate_limit}/s)")
with ThreadPoolExecutor(max_workers=max_concurrent) as executor:
    futures = {executor.submit(download_crate, crate): crate for crate in crates}
    for future in as_completed(futures):
        try:
            result = future.result()
        except Exception as e:
            print(f"Error downloading crate: {e}")

print("Rust crate vendor directory created successfully")
' "$OUT_DIR"

# Create .cargo/config.toml for offline builds
cat > "$OUT_DIR/.cargo/config.toml" << 'EOF'
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor"

[net]
offline = true
EOF
"""

    script = ctx.actions.write("download-cargo-lock.sh", script_content, is_executable = True)
    ctx.actions.run(
        cmd_args(["bash", script, out_dir.as_output(), crates_json]),
        category = "cargo_lock_download",
        identifier = ctx.attrs.name,
        local_only = True,  # Network access needed
        env = _get_download_env(),
    )

    return [DefaultInfo(default_output = out_dir)]

_cargo_lock_download = rule(
    impl = _cargo_lock_download_impl,
    attrs = {
        "crates": attrs.list(attrs.dict(key = attrs.string(), value = attrs.string())),
    },
)

def cargo_lock_deps(
        name: str,
        cargo_lock: list[str],
        visibility: list[str] = ["PUBLIC"]):
    """
    Create Rust vendor directory from Cargo.lock entries (Gentoo CRATES style).

    Parses Cargo.lock entries and downloads all crates from crates.io,
    creating a vendor directory structure for offline builds.

    Args:
        name: Target name
        cargo_lock: List of crate entries in format "name version checksum"
                    (checksum is optional)
        visibility: Buck2 visibility

    Example:
        cargo_lock_deps(
            name = "ripgrep-deps",
            cargo_lock = [
                "aho-corasick 1.1.2 b2969dcb958b36655471fc61f7e416fa76033bdd4bfed0678d8fee1e2d07a1f0",
                "memchr 2.7.1 523dc4f511e55ab87b694dc30d0f820d60906ef06413f93d4d7a1385599cc149",
                "regex 1.10.3 b62dbe01f0b06f9d8dc7d49e05a0785f153b00b2c227856282f671e0318c9b15",
                # ... all entries from Cargo.lock
            ],
        )

    Usage in cargo_package:
        cargo_package(
            name = "ripgrep",
            ...
            cargo_lock_deps = ":ripgrep-deps",
        )

    To generate the list from Cargo.lock:
        grep -E "^(name|version|checksum)" Cargo.lock | \\
          paste - - - | awk '{print $3, $6, $9}'
    """
    # Parse cargo.lock entries into crate list
    crates = []
    seen = {}

    for entry in cargo_lock:
        parts = entry.split()
        if len(parts) < 2:
            continue

        crate_name = parts[0]
        version = parts[1]
        checksum = parts[2] if len(parts) > 2 else ""

        # Deduplicate
        key = crate_name + "@" + version
        if key in seen:
            continue
        seen[key] = True

        crates.append({"name": crate_name, "version": version, "checksum": checksum})

    _cargo_lock_download(
        name = name,
        crates = crates,
        visibility = visibility,
    )

def cargo_package(
        name: str,
        version: str,
        src_uri: str,
        sha256: str,
        bins: list[str] = [],
        cargo_args: list[str] = [],
        deps: list[str] = [],
        vendor_deps: str | None = None,
        cargo_lock_deps: str | None = None,
        vendor_tarball_uri: str | None = None,
        vendor_tarball_sha256: str | None = None,
        maintainers: list[str] = [],
        patches: list[str] = [],
        # USE flag support
        iuse: list[str] = [],
        use_defaults: list[str] = [],
        use_features: dict = {},
        use_deps: dict = {},
        global_use: dict | None = None,
        package_overrides: dict | None = None,
        signature_sha256: str | None = None,
        gpg_key: str | None = None,
        gpg_keyring: str | None = None,
        signature_required: bool = False,
        exclude_patterns: list[str] = [],
        **kwargs):
    """
    Convenience macro for Rust/Cargo packages with USE flag support.
    Uses the cargo eclass for standardized build phases.

    Args:
        name: Package name
        version: Package version
        src_uri: Source download URL
        sha256: Source checksum
        bins: Binary names to install
        cargo_args: Base Cargo arguments
        deps: Base dependencies (always applied)
        vendor_deps: Optional rust_vendor target for pre-downloaded vendor/ directory
        cargo_lock_deps: Optional cargo_lock_deps target for Cargo.lock-based vendor (Gentoo-style)
        vendor_tarball_uri: URL to pre-made vendor tarball with all cargo dependencies
                           (use ./tools/cargo-vendor to generate, or use project-provided tarball)
        vendor_tarball_sha256: SHA256 checksum of vendor tarball
        maintainers: Package maintainers
        iuse: List of USE flags this package supports
        use_defaults: Default enabled USE flags
        use_features: Dict mapping USE flag to Cargo feature(s)
                      Example: {"ssl": "tls", "compression": ["zstd", "brotli"]}
        use_deps: Dict mapping USE flag to conditional dependencies
        global_use: Global USE flag configuration
        package_overrides: Package-specific USE overrides
        signature_sha256: SHA256 of GPG signature file (use update_checksums.py to populate)
        gpg_key: Optional GPG key ID or fingerprint to import and verify against
        gpg_keyring: Optional path to GPG keyring file with trusted keys
        exclude_patterns: List of patterns to exclude from source extraction (passed to tar --exclude)

    Example:
        cargo_package(
            name = "ripgrep",
            version = "14.0.0",
            src_uri = "https://github.com/BurntSushi/ripgrep/archive/14.0.0.tar.gz",
            sha256 = "...",
            iuse = ["pcre2", "simd"],
            use_defaults = ["simd"],
            use_features = {
                "pcre2": "pcre2",
                "simd": "simd-accel",
            },
            use_deps = {
                "pcre2": ["//packages/linux/dev-libs/pcre2"],
            },
            cargo_lock_deps = ":ripgrep-deps",  # Gentoo-style Cargo.lock deps
        )
    """
    # Apply platform-specific constraints (Linux packages only build on Linux, etc.)
    kwargs = _apply_platform_constraints(kwargs)

    src_name = name + "-src"

    download_source(
        name = src_name,
        src_uri = src_uri,
        sha256 = sha256,
        signature_sha256 = signature_sha256,
        signature_required = signature_required,
        gpg_key = gpg_key,
        gpg_keyring = gpg_keyring,
        exclude_patterns = exclude_patterns,
    )

    # Download vendor tarball if provided (for offline cargo builds with git deps)
    vendor_tarball_target = None
    if vendor_tarball_uri and vendor_tarball_sha256:
        vendor_tarball_name = name + "-vendor"
        download_source(
            name = vendor_tarball_name,
            src_uri = vendor_tarball_uri,
            sha256 = vendor_tarball_sha256,
            signature_required = False,
            # Vendor tarballs have vendor/ and .cargo/ at root level, no wrapper directory
            strip_components = 0,
        )
        vendor_tarball_target = ":" + vendor_tarball_name

    # Calculate effective USE flags if USE flags are specified
    effective_use = []
    resolved_deps = list(deps)
    resolved_cargo_args = list(cargo_args)

    if iuse:
        effective_use = get_effective_use(
            name,
            iuse,
            use_defaults,
            global_use,
            package_overrides,
        )

        # Resolve conditional dependencies
        resolved_deps.extend(use_dep(use_deps, effective_use))

        # Generate Cargo arguments with features
        if use_features:
            resolved_cargo_args = use_cargo_args(use_features, effective_use, cargo_args)

    # Use eclass inheritance for cargo
    eclass_config = inherit(["cargo"])

    # Handle cargo_args by setting environment variable
    env = kwargs.pop("env", {})
    if resolved_cargo_args:
        env["CARGO_BUILD_FLAGS"] = " ".join(resolved_cargo_args)

    # Merge eclass bdepend with any existing bdepend
    bdepend = list(kwargs.pop("bdepend", []))
    for dep in eclass_config["bdepend"]:
        if dep not in bdepend:
            bdepend.append(dep)

    # Add bootstrap toolchain by default to ensure linking against BuckOS glibc
    # get_toolchain_dep() returns None when use_host_toolchain is enabled
    use_bootstrap = kwargs.pop("use_bootstrap", True)
    rust_typed_toolchain = None
    if use_bootstrap:
        toolchain_dep = get_toolchain_dep()
        if toolchain_dep:
            bdepend.append(toolchain_dep)

        # Use typed Rust toolchain provider for Cargo packages
        rust_typed_toolchain = get_rust_typed_toolchain_dep()

    # Handle vendor_deps, cargo_lock_deps, and vendor_tarball for offline builds
    if vendor_deps:
        bdepend.append(vendor_deps)
    if cargo_lock_deps:
        bdepend.append(cargo_lock_deps)
    if vendor_tarball_target:
        bdepend.append(vendor_tarball_target)

    # Filter out rdepend from kwargs since we pass it explicitly as deps
    kwargs.pop("rdepend", None)

    # Allow overriding eclass phases via kwargs
    custom_src_prepare = kwargs.pop("src_prepare", None)

    # Combine with eclass phases
    vendor_src_prepare = ""
    if vendor_deps or cargo_lock_deps:
        vendor_src_prepare = """
# Copy vendored Rust crates for offline build
for vendor_src in $BDEPEND_DIRS; do
    if [ -d "$vendor_src/vendor" ]; then
        cp -r "$vendor_src/vendor" . 2>/dev/null || true
        echo "Copied vendored Rust crates from $vendor_src"
    fi
    if [ -d "$vendor_src/.cargo" ]; then
        mkdir -p .cargo
        cp -r "$vendor_src/.cargo/"* .cargo/ 2>/dev/null || true
        echo "Copied Cargo config from $vendor_src"
    fi
done
"""

    # Handle vendor tarball extraction (pre-made vendor directory with all deps including git)
    if vendor_tarball_target:
        vendor_src_prepare += """
# Copy pre-extracted vendor directory for offline cargo build
for vendor_src in $BDEPEND_DIRS; do
    # Look for vendor/ directory (extracted from vendor tarball)
    if [ -d "$vendor_src/vendor" ]; then
        echo "Found vendored crates in $vendor_src/vendor"
        cp -r "$vendor_src/vendor" . 2>/dev/null || true
    fi
    # Look for .cargo/config.toml
    if [ -f "$vendor_src/.cargo/config.toml" ]; then
        echo "Found cargo vendor config in $vendor_src/.cargo"
        mkdir -p .cargo
        cp "$vendor_src/.cargo/config.toml" .cargo/ 2>/dev/null || true
    elif [ -f "$vendor_src/config.toml" ]; then
        echo "Found cargo vendor config in $vendor_src"
        mkdir -p .cargo
        cp "$vendor_src/config.toml" .cargo/ 2>/dev/null || true
    fi
done
if [ -d vendor ]; then
    echo "Vendor directory ready for offline build"
fi
"""

    base_src_prepare = custom_src_prepare if custom_src_prepare else eclass_config.get("src_prepare", "")
    src_prepare = vendor_src_prepare + base_src_prepare

    # Use custom install if bins specified, otherwise use eclass default
    src_install = cargo_src_install(bins) if bins else eclass_config["src_install"]

    # Filter kwargs to only include parameters that ebuild_package_rule accepts
    filtered_kwargs, src_install = filter_ebuild_kwargs(kwargs, src_install)

    ebuild_package_rule(
        name = name,
        source = ":" + src_name,
        version = version,
        package_type = "cargo",
        src_prepare = src_prepare,
        src_configure = eclass_config["src_configure"],
        src_compile = eclass_config["src_compile"],
        src_install = src_install,
        rdepend = resolved_deps,
        bdepend = bdepend,
        env = env,
        maintainers = maintainers,
        use_flags = effective_use,
        use_bootstrap = use_bootstrap,
        _rust_toolchain = rust_typed_toolchain,
        **filtered_kwargs
    )

# -----------------------------------------------------------------------------
# Cargo Workspace Package Support
# -----------------------------------------------------------------------------

def cargo_workspace_package(
        name: str,
        workspace_source: str,
        member: str,
        version: str = "0.1.0",
        bins: list[str] = [],
        vendor_tarball_uri: str | None = None,
        vendor_tarball_sha256: str | None = None,
        cargo_args: list[str] = [],
        deps: list[str] = [],
        description: str = "",
        homepage: str = "",
        license: str = "",
        desktop_entry: dict | None = None,
        extra_install: str = "",
        allow_network: bool = True,
        **kwargs):
    """
    Build a member of a Cargo workspace.

    This is for projects where multiple crates share a single Cargo.toml workspace.
    The vendor tarball covers all workspace members, so it only needs to be
    downloaded once.

    Args:
        name: Package name (target name)
        workspace_source: Buck target for the workspace source tarball
        member: Name of the workspace member to build (the -p argument to cargo)
        version: Package version
        bins: List of binary names to install from target/release/
        vendor_tarball_uri: URL to vendor tarball with all Cargo dependencies
        vendor_tarball_sha256: SHA256 of vendor tarball
        cargo_args: Additional cargo build arguments
        deps: Runtime dependencies
        description: Package description
        homepage: Project homepage URL
        license: License identifier
        desktop_entry: Optional dict with desktop entry fields:
                      {name, comment, icon, exec, terminal, categories, keywords}
        extra_install: Additional shell commands for src_install phase
        allow_network: If True, allow network access for cargo to download deps

    Example:
        # First, download the workspace source
        download_source(
            name = "myworkspace-src",
            src_uri = "https://github.com/org/myworkspace/archive/main.tar.gz",
            sha256 = "...",
        )

        # Build the "cli" member of the workspace (with network for deps)
        cargo_workspace_package(
            name = "myworkspace-cli",
            workspace_source = ":myworkspace-src",
            member = "cli",
            bins = ["mycli"],
            allow_network = True,  # Allow cargo to download dependencies
        )
    """
    # Apply platform-specific constraints
    kwargs = _apply_platform_constraints(kwargs)

    # Download vendor tarball if provided
    vendor_tarball_target = None
    if vendor_tarball_uri and vendor_tarball_sha256:
        vendor_tarball_name = name + "-vendor"
        download_source(
            name = vendor_tarball_name,
            src_uri = vendor_tarball_uri,
            sha256 = vendor_tarball_sha256,
            signature_required = False,
            strip_components = 0,
        )
        vendor_tarball_target = ":" + vendor_tarball_name

    # Build bdepend list
    bdepend = list(kwargs.pop("bdepend", []))
    if vendor_tarball_target:
        bdepend.append(vendor_tarball_target)

    # Add bootstrap toolchain
    toolchain_dep = get_toolchain_dep()
    if toolchain_dep:
        bdepend.append(toolchain_dep)

    rust_typed_toolchain = get_rust_typed_toolchain_dep()

    # Build cargo args string
    cargo_args_str = " ".join(cargo_args) if cargo_args else ""

    # Generate src_prepare phase
    # Note: ebuild.sh handles cargo vendoring before phases run
    src_prepare = '''
# Workspace source is in ../source/
cd ../source || exit 1
echo "Workspace ready, will build member: {member}"
'''.format(member = member)

    # Generate src_configure phase
    src_configure = '''
cd ../source
'''

    # Generate src_compile phase - build using vendored deps (ebuild.sh sets up vendor/)
    # Fix for systems with /lib64 instead of /lib:
    # rust-lld and linker scripts reference /lib which may not exist or have 32-bit libs
    src_compile = '''
cd ../source

# Fix library paths for systems using /lib64 instead of /lib
# The rust toolchain's linker scripts reference /lib paths which may be 32-bit or missing
if [ -f /lib64/ld-linux-x86-64.so.2 ] && [ ! -e /lib/ld-linux-x86-64.so.2 ]; then
    echo "Configuring library paths for /lib64 system"
    # Set library search path to prefer /lib64
    export LIBRARY_PATH="/lib64:/usr/lib64:${{LIBRARY_PATH:-}}"
    # Tell linker to use correct paths
    export RUSTFLAGS="${{RUSTFLAGS:-}} -C link-arg=-L/lib64 -C link-arg=-L/usr/lib64"
    export RUSTFLAGS="${{RUSTFLAGS}} -C link-arg=-Wl,-rpath-link,/lib64 -C link-arg=-Wl,-rpath-link,/usr/lib64"
    export RUSTFLAGS="${{RUSTFLAGS}} -C link-arg=-Wl,--dynamic-linker=/lib64/ld-linux-x86-64.so.2"
fi

echo "Building workspace member: {member}"
echo "RUSTFLAGS=${{RUSTFLAGS:-}}"
cargo build --release -p {member} {cargo_args}

echo "Build complete"
ls -lh target/release/ | head -20
'''.format(member = member, cargo_args = cargo_args_str)

    # Generate src_install phase
    install_bins = ""
    if bins:
        for bin_name in bins:
            install_bins += '''
install -D -m 755 target/release/{bin} "$DESTDIR/usr/bin/{bin}"
echo "Installed {bin}"
'''.format(bin = bin_name)
    else:
        # Default: install binary matching member name
        install_bins = '''
if [ -f "target/release/{member}" ]; then
    install -D -m 755 target/release/{member} "$DESTDIR/usr/bin/{member}"
    echo "Installed {member}"
fi
'''.format(member = member)

    # Generate desktop entry if provided
    desktop_install = ""
    if desktop_entry:
        desktop_name = desktop_entry.get("name", name)
        desktop_comment = desktop_entry.get("comment", description)
        desktop_icon = desktop_entry.get("icon", "application-x-executable")
        desktop_exec = desktop_entry.get("exec", bins[0] if bins else member)
        desktop_terminal = "true" if desktop_entry.get("terminal", False) else "false"
        desktop_categories = desktop_entry.get("categories", "Utility;")
        desktop_keywords = desktop_entry.get("keywords", "")

        desktop_install = '''
mkdir -p "$DESTDIR/usr/share/applications"
cat > "$DESTDIR/usr/share/applications/{name}.desktop" << 'DESKTOP_EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name={desktop_name}
Comment={desktop_comment}
Icon={desktop_icon}
Exec={desktop_exec}
Terminal={desktop_terminal}
Categories={desktop_categories}
Keywords={desktop_keywords}
DESKTOP_EOF
chmod 644 "$DESTDIR/usr/share/applications/{name}.desktop"
echo "Installed desktop entry"
'''.format(
            name = name,
            desktop_name = desktop_name,
            desktop_comment = desktop_comment,
            desktop_icon = desktop_icon,
            desktop_exec = desktop_exec,
            desktop_terminal = desktop_terminal,
            desktop_categories = desktop_categories,
            desktop_keywords = desktop_keywords,
        )

    src_install = '''
cd ../source
{install_bins}
{desktop_install}
{extra_install}
'''.format(
        install_bins = install_bins,
        desktop_install = desktop_install,
        extra_install = extra_install,
    )

    # Filter kwargs for ebuild_package_rule
    filtered_kwargs, src_install = filter_ebuild_kwargs(kwargs, src_install)

    # Note: ebuild.sh handles cargo vendoring with network access before
    # entering the network-isolated build environment automatically

    ebuild_package_rule(
        name = name,
        source = workspace_source,
        version = version,
        package_type = "cargo",
        description = description,
        homepage = homepage,
        license = license,
        src_prepare = src_prepare,
        src_configure = src_configure,
        src_compile = src_compile,
        src_install = src_install,
        rdepend = deps,
        bdepend = bdepend,
        _rust_toolchain = rust_typed_toolchain,
        **filtered_kwargs
    )

# -----------------------------------------------------------------------------
# Go Library Support (pre-downloaded Go modules for offline builds)
# -----------------------------------------------------------------------------

def _go_library_install_impl(ctx: AnalysisContext) -> list[Provider]:
    """Install Go module source into vendor directory structure."""
    out_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)
    src_dir = ctx.attrs.source[DefaultInfo].default_outputs[0]

    script_content = """#!/bin/bash
set -e
SRC_DIR="$1"
OUT_DIR="$2"
MODULE_PATH="$3"

mkdir -p "$OUT_DIR/vendor/$MODULE_PATH"
cd "$SRC_DIR"

# Find extracted directory
EXTRACTED=$(ls -d */ 2>/dev/null | head -1)
if [ -n "$EXTRACTED" ]; then
    cd "$EXTRACTED"
fi

# Copy Go source files preserving directory structure
find . \\( -name "*.go" -o -name "go.mod" -o -name "go.sum" -o -name "LICENSE*" -o -name "*.s" -o -name "*.c" -o -name "*.h" \\) -type f | while read f; do
    dir=$(dirname "$f")
    mkdir -p "$OUT_DIR/vendor/$MODULE_PATH/$dir"
    cp "$f" "$OUT_DIR/vendor/$MODULE_PATH/$f"
done
"""

    script = ctx.actions.write("install-go-lib.sh", script_content, is_executable = True)
    ctx.actions.run(
        cmd_args(["bash", script, src_dir, out_dir.as_output(), ctx.attrs.module_path]),
        category = "go_library",
        identifier = ctx.attrs.name,
    )

    return [
        DefaultInfo(default_output = out_dir),
        GoLibraryInfo(
            module_path = ctx.attrs.module_path,
            version = ctx.attrs.version,
            vendor_dir = out_dir,
        ),
    ]

_go_library_install = rule(
    impl = _go_library_install_impl,
    attrs = {
        "source": attrs.dep(),
        "module_path": attrs.string(),
        "version": attrs.string(),
        "deps": attrs.list(attrs.dep(), default = []),
    },
)

def go_library(
        name: str,
        version: str,
        module_path: str,
        src_uri: str,
        sha256: str = "TODO",
        deps: list[str] = [],
        visibility: list[str] = ["PUBLIC"]):
    """
    Define a Go library module for pre-downloading.

    This creates a vendorable Go module that can be combined with other
    go_library targets using go_vendor() for offline builds.

    Args:
        name: Package name
        version: Module version
        module_path: Go module path (e.g., "github.com/spf13/cobra")
        src_uri: Source download URL
        sha256: Source checksum
        deps: Other go_library dependencies
        visibility: Buck2 visibility

    Example:
        go_library(
            name = "cobra",
            version = "1.8.0",
            module_path = "github.com/spf13/cobra",
            src_uri = "https://github.com/spf13/cobra/archive/refs/tags/v1.8.0.tar.gz",
            sha256 = "abc123...",
        )
    """
    src_name = name + "-src"
    download_source(
        name = src_name,
        src_uri = src_uri,
        sha256 = sha256,
    )

    _go_library_install(
        name = name,
        source = ":" + src_name,
        module_path = module_path,
        version = version,
        deps = deps,
        visibility = visibility,
    )

def _go_vendor_impl(ctx: AnalysisContext) -> list[Provider]:
    """Combine multiple go_library dependencies into a vendor directory."""
    out_dir = ctx.actions.declare_output("vendor", dir = True)

    # Collect vendor directories from dependencies
    vendor_dirs = []
    for dep in ctx.attrs.deps:
        if GoLibraryInfo in dep:
            vendor_dirs.append(dep[GoLibraryInfo].vendor_dir)
        elif DefaultInfo in dep:
            vendor_dirs.append(dep[DefaultInfo].default_outputs[0])

    script_content = """#!/bin/bash
set -e
OUT_DIR="$1"
shift

mkdir -p "$OUT_DIR/vendor"
for dir in "$@"; do
    if [ -d "$dir/vendor" ]; then
        cp -r "$dir/vendor/"* "$OUT_DIR/vendor/" 2>/dev/null || true
    fi
done
"""

    script = ctx.actions.write("merge-go-vendor.sh", script_content, is_executable = True)
    cmd = cmd_args(["bash", script, out_dir.as_output()])
    for vdir in vendor_dirs:
        cmd.add(vdir)

    ctx.actions.run(cmd, category = "go_vendor", identifier = ctx.attrs.name)

    return [DefaultInfo(default_output = out_dir)]

_go_vendor = rule(
    impl = _go_vendor_impl,
    attrs = {
        "deps": attrs.list(attrs.dep()),
    },
)

def go_vendor(
        name: str,
        deps: list[str],
        visibility: list[str] = ["PUBLIC"]):
    """
    Combine multiple go_library dependencies into a vendor directory.

    This creates a merged vendor/ directory that can be used with go_package
    via the vendor_deps parameter for offline builds.

    Args:
        name: Target name
        deps: List of go_library targets to include
        visibility: Buck2 visibility

    Example:
        go_vendor(
            name = "trivy-deps",
            deps = [
                "//packages/linux/dev-libs/go/cobra:cobra",
                "//packages/linux/dev-libs/go/zap:zap",
            ],
        )
    """
    _go_vendor(
        name = name,
        deps = deps,
        visibility = visibility,
    )

# -----------------------------------------------------------------------------
# Go Sum Dependencies (Gentoo-style go.sum parsing)
# -----------------------------------------------------------------------------

def _escape_module_path(path: str) -> str:
    """Escape module path for proxy.golang.org URL (uppercase -> !lowercase)."""
    result = ""
    for c in path.elems():
        if c.isupper():
            result += "!" + c.lower()
        else:
            result += c
    return result

def _go_sum_download_impl(ctx: AnalysisContext) -> list[Provider]:
    """Download Go modules from proxy.golang.org and create GOMODCACHE structure."""
    out_dir = ctx.actions.declare_output("gomodcache", dir = True)

    # Build the download script with all modules
    modules_json = json.encode(ctx.attrs.modules)

    script_content = """#!/bin/bash
set -e
OUT_DIR="$1"
MODULES_JSON="$2"

mkdir -p "$OUT_DIR"

# Read proxy and concurrency settings from environment
HTTP_PROXY="${BUCKOS_DOWNLOAD_PROXY:-${HTTP_PROXY:-${http_proxy:-}}}"
MAX_CONCURRENT="${BUCKOS_MAX_CONCURRENT_DOWNLOADS:-4}"
RATE_LIMIT="${BUCKOS_DOWNLOAD_RATE_LIMIT:-5.0}"

# Parse JSON and download each module with proxy and rate limiting support
echo "$MODULES_JSON" | python3 -c '
import json
import sys
import os
import time
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed
import threading

modules = json.load(sys.stdin)
out_dir = sys.argv[1]
http_proxy = os.environ.get("HTTP_PROXY", "") or os.environ.get("http_proxy", "")
max_concurrent = int(os.environ.get("BUCKOS_MAX_CONCURRENT_DOWNLOADS", "4"))
rate_limit = float(os.environ.get("BUCKOS_DOWNLOAD_RATE_LIMIT", "5.0"))

# Simple rate limiter
class RateLimiter:
    def __init__(self, rate):
        self.rate = rate
        self.lock = threading.Lock()
        self.last_time = 0

    def acquire(self):
        with self.lock:
            now = time.time()
            wait_time = max(0, (1.0 / self.rate) - (now - self.last_time))
            if wait_time > 0:
                time.sleep(wait_time)
            self.last_time = time.time()

rate_limiter = RateLimiter(rate_limit) if rate_limit > 0 else None

# Configure proxy if set
if http_proxy:
    proxy_handler = urllib.request.ProxyHandler({"http": http_proxy, "https": http_proxy})
    opener = urllib.request.build_opener(proxy_handler)
    urllib.request.install_opener(opener)
    print(f"Using proxy: {http_proxy}")

def escape_path(path):
    return "".join("!" + c.lower() if c.isupper() else c for c in path)

def download_module(mod):
    module_path = mod["path"]
    version = mod["version"]
    escaped_path = escape_path(module_path)

    # Create cache directory structure
    cache_dir = os.path.join(out_dir, "cache", "download", module_path, "@v")
    os.makedirs(cache_dir, exist_ok=True)

    files_to_download = [
        (f"https://proxy.golang.org/{escaped_path}/@v/{version}.mod", f"{version}.mod"),
        (f"https://proxy.golang.org/{escaped_path}/@v/{version}.zip", f"{version}.zip"),
        (f"https://proxy.golang.org/{escaped_path}/@v/{version}.info", f"{version}.info"),
    ]

    for url, filename in files_to_download:
        dest = os.path.join(cache_dir, filename)
        if not os.path.exists(dest):
            if rate_limiter:
                rate_limiter.acquire()
            try:
                print(f"Downloading {url}")
                urllib.request.urlretrieve(url, dest)
            except urllib.error.HTTPError as e:
                if e.code == 404 and filename.endswith(".info"):
                    continue  # .info files are optional
                print(f"Warning: Failed to download {url}: {e}")
                continue
            except Exception as e:
                print(f"Warning: Failed to download {url}: {e}")
                continue

    # Write list file
    list_file = os.path.join(cache_dir, "list")
    with open(list_file, "a") as f:
        f.write(version + "\\n")

    return module_path

# Download modules with concurrency limit
print(f"Downloading {len(modules)} Go modules (max concurrent: {max_concurrent}, rate limit: {rate_limit}/s)")
with ThreadPoolExecutor(max_workers=max_concurrent) as executor:
    futures = {executor.submit(download_module, mod): mod for mod in modules}
    for future in as_completed(futures):
        try:
            result = future.result()
        except Exception as e:
            print(f"Error downloading module: {e}")

print("Go module cache created successfully")
' "$OUT_DIR"

# Ensure all downloaded files are writable so Buck can clean the cache later
chmod -R u+w "$OUT_DIR" 2>/dev/null || true
"""

    script = ctx.actions.write("download-go-sum.sh", script_content, is_executable = True)
    ctx.actions.run(
        cmd_args(["bash", script, out_dir.as_output(), modules_json]),
        category = "go_sum_download",
        identifier = ctx.attrs.name,
        local_only = True,  # Network access needed
        env = _get_download_env(),
    )

    return [DefaultInfo(default_output = out_dir)]

_go_sum_download = rule(
    impl = _go_sum_download_impl,
    attrs = {
        "modules": attrs.list(attrs.dict(key = attrs.string(), value = attrs.string())),
    },
)

def go_sum_deps(
        name: str,
        go_sum: list[str],
        visibility: list[str] = ["PUBLIC"]):
    """
    Create Go module cache from go.sum entries (Gentoo EGO_SUM style).

    Parses go.sum entries and downloads all modules from proxy.golang.org,
    creating a GOMODCACHE structure for offline builds.

    Args:
        name: Target name
        go_sum: List of go.sum entries, each in format "module/path version hash"
                (hash is optional, only module and version are used)
        visibility: Buck2 visibility

    Example:
        go_sum_deps(
            name = "trivy-deps",
            go_sum = [
                "github.com/BurntSushi/toml v0.3.1 h1:abc...",
                "github.com/spf13/cobra v1.8.0 h1:xyz...",
                "github.com/spf13/cobra v1.8.0/go.mod h1:...",
                # ... all entries from go.sum
            ],
        )

    Usage in go_package:
        go_package(
            name = "trivy",
            ...
            go_mod_deps = ":trivy-deps",
        )
    """
    # Parse go.sum entries into module list
    modules = []
    seen = {}

    for entry in go_sum:
        parts = entry.split()
        if len(parts) < 2:
            continue

        module_path = parts[0]
        version = parts[1]

        # Skip go.mod entries (they share version with main module)
        if module_path.endswith("/go.mod"):
            continue

        # Deduplicate
        key = module_path + "@" + version
        if key in seen:
            continue
        seen[key] = True

        modules.append({"path": module_path, "version": version})

    _go_sum_download(
        name = name,
        modules = modules,
        visibility = visibility,
    )

def go_package(
        name: str,
        version: str,
        src_uri: str,
        sha256: str,
        bins: list[str] = [],
        packages: list[str] = ["."],
        deps: list[str] = [],
        vendor_deps: str | None = None,
        go_mod_deps: str | None = None,
        maintainers: list[str] = [],
        patches: list[str] = [],
        # USE flag support
        iuse: list[str] = [],
        use_defaults: list[str] = [],
        use_tags: dict = {},
        use_deps: dict = {},
        global_use: dict | None = None,
        package_overrides: dict | None = None,
        signature_sha256: str | None = None,
        gpg_key: str | None = None,
        gpg_keyring: str | None = None,
        signature_required: bool = False,
        exclude_patterns: list[str] = [],
        **kwargs):
    """
    Convenience macro for Go packages with USE flag support.
    Uses the go-module eclass for standardized build phases.

    Args:
        name: Package name
        version: Package version
        src_uri: Source download URL
        sha256: Source checksum
        bins: Binary names to install
        packages: Go packages to build
        deps: Base dependencies (always applied)
        vendor_deps: Optional go_vendor target for pre-downloaded vendor/ directory
        go_mod_deps: Optional go_sum_deps target for GOMODCACHE (Gentoo-style)
        maintainers: Package maintainers
        iuse: List of USE flags this package supports
        use_defaults: Default enabled USE flags
        use_tags: Dict mapping USE flag to Go build tag(s)
                  Example: {"sqlite": "sqlite", "postgres": "postgres"}
        use_deps: Dict mapping USE flag to conditional dependencies
        global_use: Global USE flag configuration
        package_overrides: Package-specific USE overrides
        signature_sha256: SHA256 of GPG signature file (use update_checksums.py to populate)
        gpg_key: Optional GPG key ID or fingerprint to import and verify against
        gpg_keyring: Optional path to GPG keyring file with trusted keys
        exclude_patterns: List of patterns to exclude from source extraction (passed to tar --exclude)

    Example:
        go_package(
            name = "go-sqlite3",
            version = "1.14.18",
            src_uri = "https://github.com/mattn/go-sqlite3/archive/v1.14.18.tar.gz",
            sha256 = "...",
            iuse = ["icu", "json1", "fts5"],
            use_defaults = ["json1"],
            use_tags = {
                "icu": "icu",
                "json1": "json1",
                "fts5": "fts5",
            },
            use_deps = {
                "icu": ["//packages/linux/dev-libs/icu"],
            },
        )
    """
    # Apply platform-specific constraints (Linux packages only build on Linux, etc.)
    kwargs = _apply_platform_constraints(kwargs)

    src_name = name + "-src"

    download_source(
        name = src_name,
        src_uri = src_uri,
        sha256 = sha256,
        signature_sha256 = signature_sha256,
        signature_required = signature_required,
        gpg_key = gpg_key,
        gpg_keyring = gpg_keyring,
        exclude_patterns = exclude_patterns,
    )

    # Calculate effective USE flags if USE flags are specified
    effective_use = []
    resolved_deps = list(deps)
    resolved_go_build_args = kwargs.pop("go_build_args", [])

    if iuse:
        effective_use = get_effective_use(
            name,
            iuse,
            use_defaults,
            global_use,
            package_overrides,
        )

        # Resolve conditional dependencies
        resolved_deps.extend(use_dep(use_deps, effective_use))

        # Generate Go build arguments with tags
        if use_tags:
            resolved_go_build_args = use_go_build_args(use_tags, effective_use, resolved_go_build_args)

    # Use eclass inheritance for go-module
    eclass_config = inherit(["go-module"])

    # Handle packages by setting environment variable
    env = kwargs.pop("env", {})
    if packages != ["."]:
        env["GO_PACKAGES"] = " ".join(packages)

    # Handle go_build_args
    if resolved_go_build_args:
        env["GO_BUILD_FLAGS"] = " ".join(resolved_go_build_args)

    # Merge eclass bdepend with any existing bdepend
    bdepend = list(kwargs.pop("bdepend", []))
    for dep in eclass_config["bdepend"]:
        if dep not in bdepend:
            bdepend.append(dep)

    # Add bootstrap toolchain by default to ensure linking against BuckOS glibc
    # get_toolchain_dep() returns None when use_host_toolchain is enabled
    use_bootstrap = kwargs.pop("use_bootstrap", True)
    go_typed_toolchain = None
    if use_bootstrap:
        toolchain_dep = get_toolchain_dep()
        if toolchain_dep:
            bdepend.append(toolchain_dep)

        # Use typed Go toolchain provider for Go packages
        go_typed_toolchain = get_go_typed_toolchain_dep()

    # Handle vendor_deps for offline builds (vendor/ directory approach)
    if vendor_deps:
        bdepend.append(vendor_deps)

    # Handle go_mod_deps for offline builds (GOMODCACHE approach - Gentoo style)
    if go_mod_deps:
        bdepend.append(go_mod_deps)

    # Allow overriding eclass phases via kwargs
    custom_src_prepare = kwargs.pop("src_prepare", None)
    custom_src_compile = kwargs.pop("src_compile", None)
    custom_src_install = kwargs.pop("src_install", None)

    # Combine with eclass phases
    vendor_src_prepare = ""
    if vendor_deps:
        vendor_src_prepare = """
# Copy vendored Go dependencies for offline build
for vendor_src in $BDEPEND_DIRS; do
    if [ -d "$vendor_src/vendor" ]; then
        cp -r "$vendor_src/vendor" . 2>/dev/null || true
        echo "Copied vendored Go dependencies from $vendor_src"
    fi
done
"""

    gomodcache_src_prepare = ""
    if go_mod_deps:
        gomodcache_src_prepare = """
# Set up GOMODCACHE from pre-downloaded modules (Gentoo-style)
for mod_cache in $BDEPEND_DIRS; do
    if [ -d "$mod_cache/cache/download" ]; then
        export GOMODCACHE="$mod_cache"
        export GOPROXY="off"
        echo "Using pre-downloaded Go modules from $mod_cache"
        break
    fi
done
"""

    base_src_prepare = custom_src_prepare if custom_src_prepare else eclass_config.get("src_prepare", "")
    src_prepare = vendor_src_prepare + gomodcache_src_prepare + base_src_prepare


    # Use custom install if provided, or generate based on bins
    if custom_src_install:
        src_install = custom_src_install
    elif bins:
        src_install = go_src_install(bins)
    else:
        # For library-only packages, install source for use by dependent packages
        src_install = '''
# Install Go library source for dependent packages
mkdir -p "$DESTDIR/usr/share/go/src"
# Copy Go source files (excluding tests and vendor)
find . -name "*.go" ! -name "*_test.go" ! -path "./vendor/*" -exec install -Dm644 {} "$DESTDIR/usr/share/go/src/{}" \;
# Copy go.mod and go.sum if present
[ -f go.mod ] && install -Dm644 go.mod "$DESTDIR/usr/share/go/src/go.mod"
[ -f go.sum ] && install -Dm644 go.sum "$DESTDIR/usr/share/go/src/go.sum"
echo "Go library source installed to /usr/share/go/src"
'''

    # Use custom compile if provided, otherwise use eclass default or library build
    if custom_src_compile:
        src_compile = custom_src_compile
    elif bins:
        src_compile = eclass_config["src_compile"]
    else:
        src_compile = '''
# Library-only package: verify compilation without producing executables
go build -v -p ${MAKEOPTS:-$(nproc)} ${GO_BUILD_FLAGS:-} ./...
echo "Go library compiled successfully (no binaries to install)"
'''

    # Filter kwargs to only include parameters that ebuild_package_rule accepts
    filtered_kwargs, src_install = filter_ebuild_kwargs(kwargs, src_install)

    ebuild_package_rule(
        name = name,
        source = ":" + src_name,
        version = version,
        package_type = "go",
        src_prepare = src_prepare,
        src_configure = eclass_config["src_configure"],
        src_compile = src_compile,
        src_install = src_install,
        rdepend = resolved_deps,
        bdepend = bdepend,
        env = env,
        maintainers = maintainers,
        use_flags = effective_use,
        use_bootstrap = use_bootstrap,
        _go_toolchain = go_typed_toolchain,
        **filtered_kwargs
    )

# -----------------------------------------------------------------------------
# Perl Package Support
# -----------------------------------------------------------------------------

def perl_package(
        name: str,
        version: str,
        src_uri: str,
        sha256: str,
        deps: list[str] = [],
        perl_deps: list[str] = [],
        maintainers: list[str] = [],
        signature_sha256: str | None = None,
        gpg_key: str | None = None,
        gpg_keyring: str | None = None,
        signature_required: bool = False,
        **kwargs):
    """
    Convenience macro for Perl/CPAN module packages.
    Uses the perl eclass for standardized build phases.

    Args:
        name: Package name
        version: Package version
        src_uri: Source download URL
        sha256: Source checksum
        deps: Runtime dependencies
        perl_deps: Perl module dependencies (targets that provide Perl modules)
        maintainers: Package maintainers
        signature_sha256: SHA256 of GPG signature file
        gpg_key: Optional GPG key ID
        gpg_keyring: Optional path to GPG keyring file

    Example:
        perl_package(
            name = "XML-Parser",
            version = "2.46",
            src_uri = "https://cpan.metacpan.org/authors/id/T/TO/TODDR/XML-Parser-2.46.tar.gz",
            sha256 = "...",
            deps = ["//packages/linux/dev-libs/expat:expat"],
        )
    """
    # Apply platform-specific constraints
    kwargs = _apply_platform_constraints(kwargs)

    src_name = name + "-src"

    download_source(
        name = src_name,
        src_uri = src_uri,
        sha256 = sha256,
        signature_sha256 = signature_sha256,
        signature_required = signature_required,
        gpg_key = gpg_key,
        gpg_keyring = gpg_keyring,
    )

    # Use eclass inheritance for perl
    eclass_config = inherit(["perl"])

    # Merge dependencies
    resolved_deps = list(deps)
    for dep in eclass_config.get("rdepend", []):
        if dep not in resolved_deps:
            resolved_deps.append(dep)

    # Add perl module dependencies
    bdepend = list(kwargs.pop("bdepend", []))
    for dep in eclass_config.get("bdepend", []):
        if dep not in bdepend:
            bdepend.append(dep)
    for dep in perl_deps:
        if dep not in bdepend:
            bdepend.append(dep)

    # Add bootstrap toolchain
    use_bootstrap = kwargs.pop("use_bootstrap", True)
    if use_bootstrap:
        toolchain_dep = get_toolchain_dep()
        if toolchain_dep:
            bdepend.append(toolchain_dep)

    # Allow overriding eclass phases
    src_configure = kwargs.pop("src_configure", eclass_config["src_configure"])
    src_compile = kwargs.pop("src_compile", eclass_config["src_compile"])
    src_install = kwargs.pop("src_install", eclass_config["src_install"])

    # Filter kwargs
    filtered_kwargs, src_install = filter_ebuild_kwargs(kwargs, src_install)

    ebuild_package_rule(
        name = name,
        source = ":" + src_name,
        version = version,
        package_type = "perl",
        src_configure = src_configure,
        src_compile = src_compile,
        src_install = src_install,
        rdepend = resolved_deps,
        bdepend = bdepend,
        maintainers = maintainers,
        use_bootstrap = use_bootstrap,
        **filtered_kwargs
    )

# -----------------------------------------------------------------------------
# Ruby Package Support
# -----------------------------------------------------------------------------

def ruby_package(
        name: str,
        version: str,
        src_uri: str,
        sha256: str,
        deps: list[str] = [],
        gem_deps: list[str] = [],
        maintainers: list[str] = [],
        signature_sha256: str | None = None,
        gpg_key: str | None = None,
        gpg_keyring: str | None = None,
        signature_required: bool = False,
        **kwargs):
    """
    Convenience macro for Ruby gem packages.
    Uses the ruby eclass for standardized build phases.

    Args:
        name: Package name
        version: Package version
        src_uri: Source download URL
        sha256: Source checksum
        deps: Runtime dependencies
        gem_deps: Ruby gem dependencies (targets that provide gems)
        maintainers: Package maintainers
        signature_sha256: SHA256 of GPG signature file
        gpg_key: Optional GPG key ID
        gpg_keyring: Optional path to GPG keyring file

    Example:
        ruby_package(
            name = "asciidoctor",
            version = "2.0.18",
            src_uri = "https://github.com/asciidoctor/asciidoctor/archive/v2.0.18.tar.gz",
            sha256 = "...",
            deps = ["//packages/linux/lang/ruby:ruby"],
        )
    """
    # Apply platform-specific constraints
    kwargs = _apply_platform_constraints(kwargs)

    src_name = name + "-src"

    download_source(
        name = src_name,
        src_uri = src_uri,
        sha256 = sha256,
        signature_sha256 = signature_sha256,
        signature_required = signature_required,
        gpg_key = gpg_key,
        gpg_keyring = gpg_keyring,
    )

    # Use eclass inheritance for ruby
    eclass_config = inherit(["ruby"])

    # Merge dependencies
    resolved_deps = list(deps)
    for dep in eclass_config.get("rdepend", []):
        if dep not in resolved_deps:
            resolved_deps.append(dep)

    # Add gem dependencies
    bdepend = list(kwargs.pop("bdepend", []))
    for dep in gem_deps:
        if dep not in bdepend:
            bdepend.append(dep)

    # Add bootstrap toolchain
    use_bootstrap = kwargs.pop("use_bootstrap", True)
    if use_bootstrap:
        toolchain_dep = get_toolchain_dep()
        if toolchain_dep:
            bdepend.append(toolchain_dep)

    # Allow overriding eclass phases
    src_configure = kwargs.pop("src_configure", eclass_config["src_configure"])
    src_compile = kwargs.pop("src_compile", eclass_config["src_compile"])
    src_install = kwargs.pop("src_install", eclass_config["src_install"])

    # Filter kwargs
    filtered_kwargs, src_install = filter_ebuild_kwargs(kwargs, src_install)

    ebuild_package_rule(
        name = name,
        source = ":" + src_name,
        version = version,
        package_type = "ruby",
        src_configure = src_configure,
        src_compile = src_compile,
        src_install = src_install,
        rdepend = resolved_deps,
        bdepend = bdepend,
        maintainers = maintainers,
        use_bootstrap = use_bootstrap,
        **filtered_kwargs
    )

# -----------------------------------------------------------------------------
# Font Package Support
# -----------------------------------------------------------------------------

def font_package(
        name: str,
        version: str,
        src_uri: str | None = None,
        sha256: str | None = None,
        source: str | None = None,
        font_types: list[str] = ["ttf", "otf"],
        font_suffix: dict = {},
        deps: list[str] = [],
        maintainers: list[str] = [],
        signature_sha256: str | None = None,
        gpg_key: str | None = None,
        gpg_keyring: str | None = None,
        signature_required: bool = False,
        exclude_patterns: list[str] = [],
        strip_components: int = 1,
        **kwargs):
    """
    Convenience macro for font packages.
    Uses the font eclass for standardized installation.

    Fonts are installed to:
    - TTF fonts -> /usr/share/fonts/TTF
    - OTF fonts -> /usr/share/fonts/OTF
    - PCF fonts -> /usr/share/fonts/misc
    - BDF fonts -> /usr/share/fonts/misc
    - Type1 fonts -> /usr/share/fonts/Type1

    Args:
        name: Package name
        version: Package version
        src_uri: Source download URL (required if source not provided)
        sha256: Source checksum (required if source not provided)
        source: Pre-defined source target (alternative to src_uri/sha256)
        font_types: List of font types to install (default: ["ttf", "otf"])
                   Supported types: ttf, otf, pcf, bdf, type1
        font_suffix: Dict mapping font type to custom suffix patterns
                    Example: {"ttf": "*.ttf *.TTF", "otf": "*.otf"}
        deps: Runtime dependencies
        maintainers: Package maintainers
        signature_sha256: SHA256 of GPG signature file
        gpg_key: Optional GPG key ID
        gpg_keyring: Optional path to GPG keyring file
        exclude_patterns: Patterns to exclude from extraction
        strip_components: Number of leading path components to strip (default: 1)

    Example:
        font_package(
            name = "noto-fonts",
            version = "2023.05",
            src_uri = "https://github.com/notofonts/noto-fonts/archive/v2023.05.tar.gz",
            sha256 = "...",
            font_types = ["ttf", "otf"],
            deps = ["//packages/linux/system/libs/font/fontconfig:fontconfig"],
        )

        # With custom suffix patterns:
        font_package(
            name = "custom-fonts",
            version = "1.0",
            src_uri = "...",
            sha256 = "...",
            font_types = ["ttf"],
            font_suffix = {"ttf": "*.ttf *.TTF *.ttc"},
        )
    """
    # Apply platform-specific constraints
    kwargs = _apply_platform_constraints(kwargs)

    # Handle source
    if source:
        src_target = source
    else:
        if not src_uri or not sha256:
            fail("Either 'source' or both 'src_uri' and 'sha256' must be provided")
        src_name = name + "-src"
        download_source(
            name = src_name,
            src_uri = src_uri,
            sha256 = sha256,
            signature_sha256 = signature_sha256,
            signature_required = signature_required,
            gpg_key = gpg_key,
            gpg_keyring = gpg_keyring,
            exclude_patterns = exclude_patterns,
            strip_components = strip_components,
        )
        src_target = ":" + src_name

    # Use eclass inheritance for font
    eclass_config = inherit(["font"])

    # Set up environment with font types
    env = kwargs.pop("env", {})
    env["FONT_TYPES"] = " ".join(font_types)
    env["PN"] = name  # Package name for license directory

    # Set custom suffix patterns if provided
    for font_type, suffix in font_suffix.items():
        env_key = "FONT_SUFFIX_{}".format(font_type.upper())
        env[env_key] = suffix

    # Merge dependencies
    resolved_deps = list(deps)
    for dep in eclass_config.get("rdepend", []):
        if dep not in resolved_deps:
            resolved_deps.append(dep)

    # Handle bdepend
    bdepend = list(kwargs.pop("bdepend", []))

    # Font packages don't typically need bootstrap toolchain since they don't compile
    use_bootstrap = kwargs.pop("use_bootstrap", False)
    if use_bootstrap:
        toolchain_dep = get_toolchain_dep()
        if toolchain_dep:
            bdepend.append(toolchain_dep)

    # Get phases from eclass (allow overriding)
    src_configure = kwargs.pop("src_configure", eclass_config["src_configure"])
    src_compile = kwargs.pop("src_compile", eclass_config["src_compile"])
    src_install = kwargs.pop("src_install", eclass_config["src_install"])

    # Get post_install from eclass for fc-cache
    post_install = eclass_config.get("post_install", "")

    # Filter kwargs and handle post_install
    filtered_kwargs, src_install = filter_ebuild_kwargs(kwargs, src_install)

    # Append eclass post_install to src_install
    if post_install:
        src_install = src_install + "\n" + post_install

    ebuild_package_rule(
        name = name,
        source = src_target,
        version = version,
        package_type = "font",
        src_configure = src_configure,
        src_compile = src_compile,
        src_install = src_install,
        rdepend = resolved_deps,
        bdepend = bdepend,
        env = env,
        maintainers = maintainers,
        use_bootstrap = use_bootstrap,
        **filtered_kwargs
    )

# -----------------------------------------------------------------------------
# NPM/Node.js Package Support
# -----------------------------------------------------------------------------

def npm_package(
        name: str,
        version: str,
        src_uri: str,
        sha256: str,
        bins: list[str] = [],
        deps: list[str] = [],
        vendored_deps: str | None = None,
        maintainers: list[str] = [],
        patches: list[str] = [],
        npm_install_args: list[str] = [],
        npm_build_args: list[str] = [],
        production: bool = True,
        signature_sha256: str | None = None,
        gpg_key: str | None = None,
        gpg_keyring: str | None = None,
        signature_required: bool = False,
        exclude_patterns: list[str] = [],
        **kwargs):
    """
    Convenience macro for npm/Node.js packages.
    Uses the npm eclass for standardized build phases.

    Args:
        name: Package name
        version: Package version
        src_uri: Source download URL
        sha256: Source checksum
        bins: Binary names to install (auto-detected from package.json if not specified)
        deps: Runtime dependencies
        vendored_deps: Optional target providing pre-downloaded node_modules for offline builds
        maintainers: Package maintainers
        patches: List of patch files to apply
        npm_install_args: Additional arguments for npm install
        npm_build_args: Additional arguments for npm run build
        production: Whether to install production dependencies only (default: True)
        signature_sha256: SHA256 of GPG signature file (use update_checksums.py to populate)
        gpg_key: Optional GPG key ID or fingerprint to import and verify against
        gpg_keyring: Optional path to GPG keyring file with trusted keys
        exclude_patterns: List of patterns to exclude from source extraction

    Example:
        npm_package(
            name = "typescript",
            version = "5.3.3",
            src_uri = "https://github.com/microsoft/TypeScript/archive/v5.3.3.tar.gz",
            sha256 = "...",
            bins = ["tsc", "tsserver"],
        )

        # Offline build with vendored dependencies
        npm_package(
            name = "eslint",
            version = "8.56.0",
            src_uri = "https://github.com/eslint/eslint/archive/v8.56.0.tar.gz",
            sha256 = "...",
            vendored_deps = ":eslint-node-modules",  # target that provides node_modules
        )
    """
    # Apply platform-specific constraints (Linux packages only build on Linux, etc.)
    kwargs = _apply_platform_constraints(kwargs)

    src_name = name + "-src"

    download_source(
        name = src_name,
        src_uri = src_uri,
        sha256 = sha256,
        signature_sha256 = signature_sha256,
        signature_required = signature_required,
        gpg_key = gpg_key,
        gpg_keyring = gpg_keyring,
        exclude_patterns = exclude_patterns,
    )

    # Use eclass inheritance for npm
    eclass_config = inherit(["npm"])

    # Setup environment variables
    env = kwargs.pop("env", {})
    env["NPM_PACKAGE_NAME"] = name
    env["NPM_PRODUCTION"] = "true" if production else "false"

    if npm_install_args:
        env["NPM_INSTALL_ARGS"] = " ".join(npm_install_args)
    if npm_build_args:
        env["NPM_BUILD_ARGS"] = " ".join(npm_build_args)

    # Merge eclass bdepend with any existing bdepend
    bdepend = list(kwargs.pop("bdepend", []))
    for dep in eclass_config["bdepend"]:
        if dep not in bdepend:
            bdepend.append(dep)

    # Merge eclass rdepend with any existing rdepend
    resolved_deps = list(deps)
    for dep in eclass_config.get("rdepend", []):
        if dep not in resolved_deps:
            resolved_deps.append(dep)

    # Add bootstrap toolchain by default to ensure linking against BuckOS glibc
    use_bootstrap = kwargs.pop("use_bootstrap", True)
    if use_bootstrap:
        toolchain_dep = get_toolchain_dep()
        if toolchain_dep:
            bdepend.append(toolchain_dep)

    # Handle vendored_deps for offline builds
    if vendored_deps:
        bdepend.append(vendored_deps)
        env["NPM_OFFLINE"] = "true"

    # Allow overriding eclass phases via kwargs
    custom_src_prepare = kwargs.pop("src_prepare", None)
    custom_src_configure = kwargs.pop("src_configure", None)
    custom_src_compile = kwargs.pop("src_compile", None)
    custom_src_install = kwargs.pop("src_install", None)

    # Combine with eclass phases
    vendor_src_prepare = ""
    if vendored_deps:
        vendor_src_prepare = """
# Copy vendored node_modules for offline build
for vendor_src in $BDEPEND_DIRS; do
    if [ -d "$vendor_src/node_modules" ]; then
        cp -r "$vendor_src/node_modules" . 2>/dev/null || true
        echo "Copied vendored node_modules from $vendor_src"
    fi
done
"""

    base_src_prepare = custom_src_prepare if custom_src_prepare else eclass_config.get("src_prepare", "")
    src_prepare = vendor_src_prepare + base_src_prepare

    # Use custom phases if provided, otherwise use eclass defaults
    src_configure = custom_src_configure if custom_src_configure else eclass_config["src_configure"]
    src_compile = custom_src_compile if custom_src_compile else eclass_config["src_compile"]
    src_install = custom_src_install if custom_src_install else eclass_config["src_install"]

    # Filter kwargs to only include parameters that ebuild_package_rule accepts
    filtered_kwargs, src_install = filter_ebuild_kwargs(kwargs, src_install)

    ebuild_package_rule(
        name = name,
        source = ":" + src_name,
        version = version,
        package_type = "npm",
        src_prepare = src_prepare,
        src_configure = src_configure,
        src_compile = src_compile,
        src_install = src_install,
        rdepend = resolved_deps,
        bdepend = bdepend,
        env = env,
        maintainers = maintainers,
        use_bootstrap = use_bootstrap,
        **filtered_kwargs
    )

# -----------------------------------------------------------------------------
# Python Library Support (pre-downloaded PyPI packages for offline builds)
# -----------------------------------------------------------------------------

def _python_library_install_impl(ctx: AnalysisContext) -> list[Provider]:
    """Install Python package source into site-packages structure."""
    out_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)
    src_dir = ctx.attrs.source[DefaultInfo].default_outputs[0]

    script_content = """#!/bin/bash
set -e
SRC_DIR="$1"
OUT_DIR="$2"
PKG_NAME="$3"
VERSION="$4"

SITE_PACKAGES="$OUT_DIR/lib/python3/site-packages"
mkdir -p "$SITE_PACKAGES"

cd "$SRC_DIR"

# Find extracted directory
EXTRACTED=$(ls -d */ 2>/dev/null | head -1)
[ -n "$EXTRACTED" ] && cd "$EXTRACTED"

# Copy Python source to site-packages
if [ -d "src/$PKG_NAME" ]; then
    cp -r "src/$PKG_NAME" "$SITE_PACKAGES/"
elif [ -d "$PKG_NAME" ]; then
    cp -r "$PKG_NAME" "$SITE_PACKAGES/"
elif [ -d "$(echo $PKG_NAME | tr '-' '_')" ]; then
    cp -r "$(echo $PKG_NAME | tr '-' '_')" "$SITE_PACKAGES/"
else
    # Single module package - copy all .py files
    find . -maxdepth 1 -name "*.py" -exec cp {} "$SITE_PACKAGES/" \\;
fi

# Copy metadata if present
[ -f setup.py ] && cp setup.py "$OUT_DIR/"
[ -f pyproject.toml ] && cp pyproject.toml "$OUT_DIR/"
"""

    script = ctx.actions.write("install-python-lib.sh", script_content, is_executable = True)
    ctx.actions.run(
        cmd_args(["bash", script, src_dir, out_dir.as_output(), ctx.attrs.package_name, ctx.attrs.version]),
        category = "python_library",
        identifier = ctx.attrs.name,
    )

    return [
        DefaultInfo(default_output = out_dir),
        PythonLibraryInfo(
            package_name = ctx.attrs.package_name,
            version = ctx.attrs.version,
            site_packages = out_dir,
        ),
    ]

_python_library_install = rule(
    impl = _python_library_install_impl,
    attrs = {
        "source": attrs.dep(),
        "package_name": attrs.string(),
        "version": attrs.string(),
        "deps": attrs.list(attrs.dep(), default = []),
        "extras": attrs.list(attrs.string(), default = []),
    },
)

def python_library(
        name: str,
        version: str,
        src_uri: str,
        pypi_name: str | None = None,
        sha256: str = "TODO",
        deps: list[str] = [],
        extras: list[str] = [],
        visibility: list[str] = ["PUBLIC"]):
    """
    Define a Python package from PyPI for pre-downloading.

    This creates a vendorable Python package that can be combined with other
    python_library targets using python_vendor() for offline builds.

    Args:
        name: Package name
        version: Package version
        src_uri: Source download URL (e.g., from PyPI)
        pypi_name: PyPI name if different from package name
        sha256: Source checksum
        deps: Other python_library dependencies
        extras: Optional extras to include
        visibility: Buck2 visibility

    Example:
        python_library(
            name = "requests",
            version = "2.31.0",
            src_uri = "https://files.pythonhosted.org/packages/source/r/requests/requests-2.31.0.tar.gz",
            sha256 = "abc123...",
            deps = [":urllib3", ":certifi"],
        )
    """
    actual_name = pypi_name if pypi_name else name

    src_name = name + "-src"
    download_source(
        name = src_name,
        src_uri = src_uri,
        sha256 = sha256,
    )

    _python_library_install(
        name = name,
        source = ":" + src_name,
        package_name = actual_name,
        version = version,
        deps = deps,
        extras = extras,
        visibility = visibility,
    )

def _python_vendor_impl(ctx: AnalysisContext) -> list[Provider]:
    """Combine multiple python_library dependencies into a site-packages directory."""
    out_dir = ctx.actions.declare_output("vendor", dir = True)

    # Collect library directories from dependencies
    lib_dirs = []
    for dep in ctx.attrs.deps:
        if PythonLibraryInfo in dep:
            lib_dirs.append(dep[PythonLibraryInfo].site_packages)
        elif DefaultInfo in dep:
            lib_dirs.append(dep[DefaultInfo].default_outputs[0])

    script_content = """#!/bin/bash
set -e
OUT_DIR="$1"
shift

SITE_PACKAGES="$OUT_DIR/lib/python3/site-packages"
mkdir -p "$SITE_PACKAGES"

for dir in "$@"; do
    if [ -d "$dir/lib/python3/site-packages" ]; then
        cp -r "$dir/lib/python3/site-packages/"* "$SITE_PACKAGES/" 2>/dev/null || true
    fi
done
"""

    script = ctx.actions.write("merge-python-vendor.sh", script_content, is_executable = True)
    cmd = cmd_args(["bash", script, out_dir.as_output()])
    for ldir in lib_dirs:
        cmd.add(ldir)

    ctx.actions.run(cmd, category = "python_vendor", identifier = ctx.attrs.name)

    return [DefaultInfo(default_output = out_dir)]

_python_vendor = rule(
    impl = _python_vendor_impl,
    attrs = {
        "deps": attrs.list(attrs.dep()),
    },
)

def python_vendor(
        name: str,
        deps: list[str],
        visibility: list[str] = ["PUBLIC"]):
    """
    Combine multiple python_library dependencies into a site-packages directory.

    This creates a merged vendor directory with all Python packages
    for offline builds with python_package via vendor_deps parameter.

    Args:
        name: Target name
        deps: List of python_library targets to include
        visibility: Buck2 visibility

    Example:
        python_vendor(
            name = "app-deps",
            deps = [
                "//packages/linux/dev-libs/python/requests:requests",
                "//packages/linux/dev-libs/python/click:click",
            ],
        )
    """
    _python_vendor(
        name = name,
        deps = deps,
        visibility = visibility,
    )

# -----------------------------------------------------------------------------
# PyPI Dependencies (Gentoo-style requirements.txt parsing)
# -----------------------------------------------------------------------------

def _pypi_deps_download_impl(ctx: AnalysisContext) -> list[Provider]:
    """Download Python packages from PyPI and create site-packages structure."""
    out_dir = ctx.actions.declare_output("vendor", dir = True)

    # Build the download script with all packages
    packages_json = json.encode(ctx.attrs.packages)

    script_content = """#!/bin/bash
set -e
OUT_DIR="$1"
PACKAGES_JSON="$2"

SITE_PACKAGES="$OUT_DIR/lib/python3/site-packages"
mkdir -p "$SITE_PACKAGES"

# Read proxy and concurrency settings from environment
HTTP_PROXY="${BUCKOS_DOWNLOAD_PROXY:-${HTTP_PROXY:-${http_proxy:-}}}"
MAX_CONCURRENT="${BUCKOS_MAX_CONCURRENT_DOWNLOADS:-4}"
RATE_LIMIT="${BUCKOS_DOWNLOAD_RATE_LIMIT:-5.0}"

# Parse JSON and download each package with proxy and rate limiting support
echo "$PACKAGES_JSON" | python3 -c '
import json
import sys
import os
import time
import tarfile
import zipfile
import tempfile
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed
import threading

packages = json.load(sys.stdin)
out_dir = sys.argv[1]
http_proxy = os.environ.get("HTTP_PROXY", "") or os.environ.get("http_proxy", "")
max_concurrent = int(os.environ.get("BUCKOS_MAX_CONCURRENT_DOWNLOADS", "4"))
rate_limit = float(os.environ.get("BUCKOS_DOWNLOAD_RATE_LIMIT", "5.0"))

# Simple rate limiter
class RateLimiter:
    def __init__(self, rate):
        self.rate = rate
        self.lock = threading.Lock()
        self.last_time = 0

    def acquire(self):
        with self.lock:
            now = time.time()
            wait_time = max(0, (1.0 / self.rate) - (now - self.last_time))
            if wait_time > 0:
                time.sleep(wait_time)
            self.last_time = time.time()

rate_limiter = RateLimiter(rate_limit) if rate_limit > 0 else None

# Configure proxy if set
if http_proxy:
    proxy_handler = urllib.request.ProxyHandler({"http": http_proxy, "https": http_proxy})
    opener = urllib.request.build_opener(proxy_handler)
    urllib.request.install_opener(opener)
    print(f"Using proxy: {http_proxy}")

site_packages = os.path.join(out_dir, "lib/python3/site-packages")
os.makedirs(site_packages, exist_ok=True)

def download_package(pkg):
    name = pkg["name"]
    version = pkg["version"]

    # PyPI sdist URL pattern
    first_char = name[0].lower()
    url = f"https://files.pythonhosted.org/packages/source/{first_char}/{name}/{name}-{version}.tar.gz"

    if rate_limiter:
        rate_limiter.acquire()

    try:
        print(f"Downloading {name}-{version}")
        with tempfile.NamedTemporaryFile(suffix=".tar.gz", delete=False) as tmp:
            try:
                urllib.request.urlretrieve(url, tmp.name)
            except urllib.error.HTTPError:
                # Try with underscores instead of hyphens
                alt_name = name.replace("-", "_")
                url = f"https://files.pythonhosted.org/packages/source/{first_char}/{name}/{alt_name}-{version}.tar.gz"
                try:
                    urllib.request.urlretrieve(url, tmp.name)
                except:
                    # Try wheel format
                    url = f"https://files.pythonhosted.org/packages/py3/{first_char}/{name}/{name.replace(\"-\", \"_\")}-{version}-py3-none-any.whl"
                    urllib.request.urlretrieve(url, tmp.name)

            # Extract package
            if tmp.name.endswith(".whl") or zipfile.is_zipfile(tmp.name):
                with zipfile.ZipFile(tmp.name, "r") as z:
                    z.extractall(site_packages)
            else:
                with tarfile.open(tmp.name, "r:gz") as tar:
                    # Find the package directory inside the archive
                    members = tar.getnames()
                    pkg_dir = None
                    for m in members:
                        parts = m.split("/")
                        if len(parts) > 1:
                            subdir = parts[1]
                            if subdir == name or subdir == name.replace("-", "_") or subdir == "src":
                                pkg_dir = parts[0]
                                break

                    # Extract to temp and copy
                    with tempfile.TemporaryDirectory() as tmpdir:
                        tar.extractall(tmpdir)
                        extracted = os.listdir(tmpdir)[0]
                        src_path = os.path.join(tmpdir, extracted)

                        # Find package code
                        pkg_code = None
                        for p in [name, name.replace("-", "_"), "src/" + name, "src/" + name.replace("-", "_")]:
                            if os.path.isdir(os.path.join(src_path, p)):
                                pkg_code = os.path.join(src_path, p)
                                break

                        if pkg_code:
                            import shutil
                            dest = os.path.join(site_packages, os.path.basename(pkg_code))
                            if os.path.exists(dest):
                                shutil.rmtree(dest)
                            shutil.copytree(pkg_code, dest)
                        else:
                            # Copy .py files directly
                            for f in os.listdir(src_path):
                                if f.endswith(".py"):
                                    import shutil
                                    shutil.copy(os.path.join(src_path, f), site_packages)

            os.unlink(tmp.name)
        return name

    except urllib.error.HTTPError as e:
        print(f"Warning: Failed to download {name}-{version}: {e}")
        return None
    except Exception as e:
        print(f"Warning: Failed to download {name}-{version}: {e}")
        return None

# Download packages with concurrency limit
print(f"Downloading {len(packages)} Python packages (max concurrent: {max_concurrent}, rate limit: {rate_limit}/s)")
with ThreadPoolExecutor(max_workers=max_concurrent) as executor:
    futures = {executor.submit(download_package, pkg): pkg for pkg in packages}
    for future in as_completed(futures):
        try:
            result = future.result()
        except Exception as e:
            print(f"Error downloading package: {e}")

print("Python vendor directory created successfully")
' "$OUT_DIR"
"""

    script = ctx.actions.write("download-pypi-deps.sh", script_content, is_executable = True)
    ctx.actions.run(
        cmd_args(["bash", script, out_dir.as_output(), packages_json]),
        category = "pypi_deps_download",
        identifier = ctx.attrs.name,
        local_only = True,  # Network access needed
        env = _get_download_env(),
    )

    return [DefaultInfo(default_output = out_dir)]

_pypi_deps_download = rule(
    impl = _pypi_deps_download_impl,
    attrs = {
        "packages": attrs.list(attrs.dict(key = attrs.string(), value = attrs.string())),
    },
)

def pypi_deps(
        name: str,
        requirements: list[str],
        visibility: list[str] = ["PUBLIC"]):
    """
    Create Python vendor directory from requirements.txt entries.

    Parses requirements.txt entries and downloads all packages from PyPI,
    creating a site-packages structure for offline builds.

    Args:
        name: Target name
        requirements: List of requirement entries in format "package==version"
        visibility: Buck2 visibility

    Example:
        pypi_deps(
            name = "app-deps",
            requirements = [
                "requests==2.31.0",
                "click==8.1.7",
                "pyyaml==6.0.1",
            ],
        )

    Usage in python_package:
        python_package(
            name = "myapp",
            ...
            pypi_deps = ":app-deps",
        )
    """
    # Parse requirements entries into package list
    packages = []
    seen = {}

    for entry in requirements:
        # Handle various requirement formats: name==version, name>=version, name
        entry = entry.strip()
        if not entry or entry.startswith("#"):
            continue

        # Extract name and version
        pkg_name = None
        version = None
        for sep in ["==", ">=", "<=", ">", "<", "~="]:
            if sep in entry:
                parts = entry.split(sep, 1)
                pkg_name = parts[0].strip()
                version = parts[1].strip().split(",")[0].strip()  # Take first version constraint
                break

        # No version specified, skip
        if pkg_name == None or version == None:
            continue

        # Deduplicate
        key = pkg_name.lower()
        if key in seen:
            continue
        seen[key] = True

        packages.append({"name": pkg_name, "version": version})

    _pypi_deps_download(
        name = name,
        packages = packages,
        visibility = visibility,
    )

def python_package(
        name: str,
        version: str,
        src_uri: str,
        sha256: str,
        python: str = "python3",
        deps: list[str] = [],
        vendor_deps: str | None = None,
        pypi_deps: str | None = None,
        maintainers: list[str] = [],
        patches: list[str] = [],
        visibility: list[str] = ["PUBLIC"],
        # USE flag support
        iuse: list[str] = [],
        use_defaults: list[str] = [],
        use_extras: dict = {},
        use_deps: dict = {},
        global_use: dict | None = None,
        package_overrides: dict | None = None,
        signature_sha256: str | None = None,
        gpg_key: str | None = None,
        gpg_keyring: str | None = None,
        signature_required: bool = False,
        exclude_patterns: list[str] = [],
        **kwargs):
    """
    Convenience macro for Python packages with USE flag support.
    Uses the python-single-r1 eclass for standardized build phases.

    Args:
        name: Package name
        version: Package version
        src_uri: Source download URL
        sha256: Source checksum
        python: Python interpreter (default: python3)
        deps: Base dependencies (always applied)
        vendor_deps: Optional python_vendor target for pre-downloaded packages
        pypi_deps: Optional pypi_deps target for requirements.txt-based vendor
        maintainers: Package maintainers
        iuse: List of USE flags this package supports
        use_defaults: Default enabled USE flags
        use_extras: Dict mapping USE flag to Python extras
                    Example: {"ssl": "ssl", "http2": "http2"}
        use_deps: Dict mapping USE flag to conditional dependencies
        global_use: Global USE flag configuration
        package_overrides: Package-specific USE overrides
        signature_sha256: SHA256 of GPG signature file (use update_checksums.py to populate)
        gpg_key: Optional GPG key ID or fingerprint to import and verify against
        gpg_keyring: Optional path to GPG keyring file with trusted keys
        exclude_patterns: List of patterns to exclude from source extraction (passed to tar --exclude)

    Example:
        python_package(
            name = "requests",
            version = "2.31.0",
            src_uri = "https://github.com/psf/requests/archive/v2.31.0.tar.gz",
            sha256 = "...",
            iuse = ["socks", "security"],
            use_defaults = ["security"],
            use_extras = {
                "socks": "socks",
                "security": "security",
            },
            use_deps = {
                "socks": ["//packages/linux/lang/python/pysocks"],
            },
            pypi_deps = ":requests-deps",  # Pre-downloaded dependencies
        )
    """
    src_name = name + "-src"

    download_source(
        name = src_name,
        src_uri = src_uri,
        sha256 = sha256,
        signature_sha256 = signature_sha256,
        signature_required = signature_required,
        gpg_key = gpg_key,
        gpg_keyring = gpg_keyring,
        exclude_patterns = exclude_patterns,
    )

    # Calculate effective USE flags if USE flags are specified
    effective_use = []
    resolved_deps = list(deps)
    extras = []

    if iuse:
        effective_use = get_effective_use(
            name,
            iuse,
            use_defaults,
            global_use,
            package_overrides,
        )

        # Resolve conditional dependencies
        resolved_deps.extend(use_dep(use_deps, effective_use))

        # Collect Python extras based on USE flags
        enabled_set = {f: True for f in effective_use}
        for flag, extra_name in use_extras.items():
            if flag in enabled_set:
                if isinstance(extra_name, list):
                    extras.extend(extra_name)
                else:
                    extras.append(extra_name)

    # Use eclass inheritance for python-single-r1
    eclass_config = inherit(["python-single-r1"])

    # Handle python version by setting environment variable
    env = kwargs.pop("env", {})
    if python != "python3":
        env["PYTHON"] = python

    # Set extras if any are enabled
    if extras:
        env["PYTHON_EXTRAS"] = ",".join(extras)

    # Merge eclass bdepend with any existing bdepend
    bdepend = list(kwargs.pop("bdepend", []))
    for dep in eclass_config["bdepend"]:
        if dep not in bdepend:
            bdepend.append(dep)

    # Add bootstrap toolchain by default
    # get_toolchain_dep() returns None when use_host_toolchain is enabled
    use_bootstrap = kwargs.pop("use_bootstrap", True)
    if use_bootstrap:
        toolchain_dep = get_toolchain_dep()
        if toolchain_dep:
            bdepend.append(toolchain_dep)

    # Handle vendor_deps and pypi_deps for offline builds
    if vendor_deps:
        bdepend.append(vendor_deps)
    if pypi_deps:
        bdepend.append(pypi_deps)

    # Merge eclass rdepend with resolved dependencies
    rdepend = resolved_deps
    for dep in eclass_config.get("rdepend", []):
        if dep not in rdepend:
            rdepend.append(dep)

    # Filter kwargs to only include parameters that ebuild_package_rule accepts
    # Also pop src_prepare before filtering so we can use custom_src_prepare
    custom_src_prepare = kwargs.pop("src_prepare", None)
    filtered_kwargs, _ = filter_ebuild_kwargs(kwargs)

    # Setup vendor src_prepare for offline builds
    vendor_src_prepare = ""
    if vendor_deps or pypi_deps:
        vendor_src_prepare = """
# Copy vendored Python packages for offline build
for vendor_src in $BDEPEND_DIRS; do
    if [ -d "$vendor_src/lib/python3/site-packages" ]; then
        export PYTHONPATH="$vendor_src/lib/python3/site-packages:${PYTHONPATH:-}"
        echo "Added Python vendor path from $vendor_src"
    fi
done
export PIP_NO_INDEX=1
export PIP_FIND_LINKS=""
"""

    # Combine with eclass phases
    base_src_prepare = custom_src_prepare if custom_src_prepare else eclass_config.get("src_prepare", "")
    src_prepare = vendor_src_prepare + base_src_prepare


    ebuild_package_rule(
        name = name,
        source = ":" + src_name,
        version = version,
        package_type = "python",
        src_prepare = src_prepare,
        src_configure = eclass_config["src_configure"],
        src_compile = eclass_config["src_compile"],
        src_install = eclass_config["src_install"],
        rdepend = rdepend,
        bdepend = bdepend,
        env = env,
        maintainers = maintainers,
        use_flags = effective_use,
        use_bootstrap = use_bootstrap,
        visibility = visibility,
        **filtered_kwargs
    )

# -----------------------------------------------------------------------------
# Ruby Gem Support (pre-downloaded gems for offline builds)
# -----------------------------------------------------------------------------

def _ruby_gem_install_impl(ctx: AnalysisContext) -> list[Provider]:
    """Install Ruby gem source into vendor/bundle structure."""
    out_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)
    src_dir = ctx.attrs.source[DefaultInfo].default_outputs[0]

    script_content = """#!/bin/bash
set -e
SRC_DIR="$1"
OUT_DIR="$2"
GEM_NAME="$3"
VERSION="$4"

GEM_DIR="$OUT_DIR/vendor/bundle/ruby/gems/$GEM_NAME-$VERSION"
mkdir -p "$GEM_DIR"

cd "$SRC_DIR"

# .gem files are tar archives containing data.tar.gz
if [ -f "download" ]; then
    # Handle crates.io-style download
    cd "$(dirname "$SRC_DIR")"
    if tar -tf "$SRC_DIR/download" data.tar.gz >/dev/null 2>&1; then
        tar -xf "$SRC_DIR/download" -O data.tar.gz | tar -xz -C "$GEM_DIR"
    else
        tar -xzf "$SRC_DIR/download" -C "$GEM_DIR" --strip-components=1 2>/dev/null || cp -r "$SRC_DIR/"* "$GEM_DIR/"
    fi
else
    # Look for extracted directory
    EXTRACTED=$(ls -d */ 2>/dev/null | head -1)
    if [ -n "$EXTRACTED" ]; then
        cp -r "$EXTRACTED"/* "$GEM_DIR/" 2>/dev/null || cp -r . "$GEM_DIR/"
    else
        cp -r . "$GEM_DIR/"
    fi
fi
"""

    script = ctx.actions.write("install-ruby-gem.sh", script_content, is_executable = True)
    ctx.actions.run(
        cmd_args(["bash", script, src_dir, out_dir.as_output(), ctx.attrs.gem_name, ctx.attrs.version]),
        category = "ruby_gem",
        identifier = ctx.attrs.name,
    )

    return [
        DefaultInfo(default_output = out_dir),
        RubyGemInfo(
            gem_name = ctx.attrs.gem_name,
            version = ctx.attrs.version,
            gem_dir = out_dir,
        ),
    ]

_ruby_gem_install = rule(
    impl = _ruby_gem_install_impl,
    attrs = {
        "source": attrs.dep(),
        "gem_name": attrs.string(),
        "version": attrs.string(),
        "deps": attrs.list(attrs.dep(), default = []),
    },
)

def ruby_gem(
        name: str,
        version: str,
        src_uri: str,
        gem_name: str | None = None,
        sha256: str = "TODO",
        deps: list[str] = [],
        visibility: list[str] = ["PUBLIC"]):
    """
    Define a Ruby gem for pre-downloading.

    Args:
        name: Package name
        version: Gem version
        src_uri: Source download URL (e.g., from rubygems.org)
        gem_name: Gem name if different from package name
        sha256: Source checksum
        deps: Other ruby_gem dependencies
        visibility: Buck2 visibility

    Example:
        ruby_gem(
            name = "nokogiri",
            version = "1.16.0",
            src_uri = "https://rubygems.org/downloads/nokogiri-1.16.0.gem",
            sha256 = "abc123...",
        )
    """
    actual_name = gem_name if gem_name else name

    src_name = name + "-src"
    download_source(
        name = src_name,
        src_uri = src_uri,
        sha256 = sha256,
    )

    _ruby_gem_install(
        name = name,
        source = ":" + src_name,
        gem_name = actual_name,
        version = version,
        deps = deps,
        visibility = visibility,
    )

def _ruby_vendor_impl(ctx: AnalysisContext) -> list[Provider]:
    """Combine multiple ruby_gem dependencies into a vendor/bundle directory."""
    out_dir = ctx.actions.declare_output("vendor", dir = True)

    # Collect gem directories from dependencies
    gem_dirs = []
    for dep in ctx.attrs.deps:
        if RubyGemInfo in dep:
            gem_dirs.append(dep[RubyGemInfo].gem_dir)
        elif DefaultInfo in dep:
            gem_dirs.append(dep[DefaultInfo].default_outputs[0])

    script_content = """#!/bin/bash
set -e
OUT_DIR="$1"
shift

mkdir -p "$OUT_DIR/vendor/bundle/ruby/gems"

for dir in "$@"; do
    if [ -d "$dir/vendor/bundle/ruby/gems" ]; then
        cp -r "$dir/vendor/bundle/ruby/gems/"* "$OUT_DIR/vendor/bundle/ruby/gems/" 2>/dev/null || true
    fi
done
"""

    script = ctx.actions.write("merge-ruby-vendor.sh", script_content, is_executable = True)
    cmd = cmd_args(["bash", script, out_dir.as_output()])
    for gdir in gem_dirs:
        cmd.add(gdir)

    ctx.actions.run(cmd, category = "ruby_vendor", identifier = ctx.attrs.name)

    return [DefaultInfo(default_output = out_dir)]

_ruby_vendor = rule(
    impl = _ruby_vendor_impl,
    attrs = {
        "deps": attrs.list(attrs.dep()),
    },
)

def ruby_vendor(
        name: str,
        deps: list[str],
        visibility: list[str] = ["PUBLIC"]):
    """
    Combine multiple ruby_gem dependencies into a vendor/bundle directory.

    Args:
        name: Target name
        deps: List of ruby_gem targets to include
        visibility: Buck2 visibility

    Example:
        ruby_vendor(
            name = "app-deps",
            deps = [
                "//packages/linux/dev-libs/ruby/nokogiri:nokogiri",
                "//packages/linux/dev-libs/ruby/rack:rack",
            ],
        )
    """
    _ruby_vendor(
        name = name,
        deps = deps,
        visibility = visibility,
    )

# -----------------------------------------------------------------------------
# Gemfile Dependencies (Bundler-style gem downloads)
# -----------------------------------------------------------------------------

def _gemfile_deps_download_impl(ctx: AnalysisContext) -> list[Provider]:
    """Download Ruby gems from rubygems.org and create vendor/bundle structure."""
    out_dir = ctx.actions.declare_output("vendor", dir = True)

    gems_json = json.encode(ctx.attrs.gems)

    script_content = """#!/bin/bash
set -e
OUT_DIR="$1"
GEMS_JSON="$2"

mkdir -p "$OUT_DIR/vendor/bundle/ruby/gems"

HTTP_PROXY="${BUCKOS_DOWNLOAD_PROXY:-${HTTP_PROXY:-${http_proxy:-}}}"
MAX_CONCURRENT="${BUCKOS_MAX_CONCURRENT_DOWNLOADS:-4}"
RATE_LIMIT="${BUCKOS_DOWNLOAD_RATE_LIMIT:-5.0}"

echo "$GEMS_JSON" | python3 -c '
import json
import sys
import os
import time
import tarfile
import tempfile
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed
import threading

gems = json.load(sys.stdin)
out_dir = sys.argv[1]
http_proxy = os.environ.get("HTTP_PROXY", "") or os.environ.get("http_proxy", "")
max_concurrent = int(os.environ.get("BUCKOS_MAX_CONCURRENT_DOWNLOADS", "4"))
rate_limit = float(os.environ.get("BUCKOS_DOWNLOAD_RATE_LIMIT", "5.0"))

class RateLimiter:
    def __init__(self, rate):
        self.rate = rate
        self.lock = threading.Lock()
        self.last_time = 0

    def acquire(self):
        with self.lock:
            now = time.time()
            wait_time = max(0, (1.0 / self.rate) - (now - self.last_time))
            if wait_time > 0:
                time.sleep(wait_time)
            self.last_time = time.time()

rate_limiter = RateLimiter(rate_limit) if rate_limit > 0 else None

if http_proxy:
    proxy_handler = urllib.request.ProxyHandler({"http": http_proxy, "https": http_proxy})
    opener = urllib.request.build_opener(proxy_handler)
    urllib.request.install_opener(opener)
    print(f"Using proxy: {http_proxy}")

gems_dir = os.path.join(out_dir, "vendor/bundle/ruby/gems")
os.makedirs(gems_dir, exist_ok=True)

def download_gem(gem):
    name = gem["name"]
    version = gem["version"]

    gem_dir = os.path.join(gems_dir, f"{name}-{version}")
    if os.path.exists(gem_dir):
        return name

    url = f"https://rubygems.org/downloads/{name}-{version}.gem"

    if rate_limiter:
        rate_limiter.acquire()

    try:
        print(f"Downloading {name}-{version}")
        with tempfile.NamedTemporaryFile(suffix=".gem", delete=False) as tmp:
            urllib.request.urlretrieve(url, tmp.name)

            # .gem is a tar containing data.tar.gz and metadata.gz
            os.makedirs(gem_dir, exist_ok=True)
            with tarfile.open(tmp.name, "r") as outer:
                for member in outer.getmembers():
                    if member.name == "data.tar.gz":
                        data_file = outer.extractfile(member)
                        with tarfile.open(fileobj=data_file, mode="r:gz") as inner:
                            inner.extractall(gem_dir)
                        break

            os.unlink(tmp.name)
        return name

    except Exception as e:
        print(f"Warning: Failed to download {name}-{version}: {e}")
        return None

print(f"Downloading {len(gems)} Ruby gems (max concurrent: {max_concurrent})")
with ThreadPoolExecutor(max_workers=max_concurrent) as executor:
    futures = {executor.submit(download_gem, gem): gem for gem in gems}
    for future in as_completed(futures):
        try:
            future.result()
        except Exception as e:
            print(f"Error: {e}")

print("Ruby vendor directory created successfully")
' "$OUT_DIR"
"""

    script = ctx.actions.write("download-gemfile-deps.sh", script_content, is_executable = True)
    ctx.actions.run(
        cmd_args(["bash", script, out_dir.as_output(), gems_json]),
        category = "gemfile_deps_download",
        identifier = ctx.attrs.name,
        local_only = True,
        env = _get_download_env(),
    )

    return [DefaultInfo(default_output = out_dir)]

_gemfile_deps_download = rule(
    impl = _gemfile_deps_download_impl,
    attrs = {
        "gems": attrs.list(attrs.dict(key = attrs.string(), value = attrs.string())),
    },
)

def gemfile_deps(
        name: str,
        gems: list[str],
        visibility: list[str] = ["PUBLIC"]):
    """
    Create Ruby vendor directory from Gemfile.lock entries.

    Args:
        name: Target name
        gems: List of gem entries in format "name version"
        visibility: Buck2 visibility

    Example:
        gemfile_deps(
            name = "app-deps",
            gems = [
                "rack 3.0.8",
                "nokogiri 1.16.0",
                "puma 6.4.0",
            ],
        )
    """
    gem_list = []
    seen = {}

    for entry in gems:
        parts = entry.split()
        if len(parts) < 2:
            continue

        gem_name = parts[0]
        version = parts[1]

        key = gem_name.lower()
        if key in seen:
            continue
        seen[key] = True

        gem_list.append({"name": gem_name, "version": version})

    _gemfile_deps_download(
        name = name,
        gems = gem_list,
        visibility = visibility,
    )

# -----------------------------------------------------------------------------
# Perl Module Support (pre-downloaded CPAN modules for offline builds)
# -----------------------------------------------------------------------------

def _perl_module_install_impl(ctx: AnalysisContext) -> list[Provider]:
    """Install Perl module source into lib/perl5 structure."""
    out_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)
    src_dir = ctx.attrs.source[DefaultInfo].default_outputs[0]

    script_content = """#!/bin/bash
set -e
SRC_DIR="$1"
OUT_DIR="$2"
MODULE_NAME="$3"

PERL_LIB="$OUT_DIR/lib/perl5"
mkdir -p "$PERL_LIB"

cd "$SRC_DIR"

EXTRACTED=$(ls -d */ 2>/dev/null | head -1)
[ -n "$EXTRACTED" ] && cd "$EXTRACTED"

# Copy lib directory if present
if [ -d "lib" ]; then
    cp -r lib/* "$PERL_LIB/"
elif [ -d "blib/lib" ]; then
    cp -r blib/lib/* "$PERL_LIB/"
else
    # Copy .pm files maintaining directory structure
    find . -name "*.pm" -exec cp --parents {} "$PERL_LIB/" \\;
fi
"""

    script = ctx.actions.write("install-perl-module.sh", script_content, is_executable = True)
    ctx.actions.run(
        cmd_args(["bash", script, src_dir, out_dir.as_output(), ctx.attrs.module_name]),
        category = "perl_module",
        identifier = ctx.attrs.name,
    )

    return [
        DefaultInfo(default_output = out_dir),
        PerlModuleInfo(
            module_name = ctx.attrs.module_name,
            version = ctx.attrs.version,
            lib_dir = out_dir,
        ),
    ]

_perl_module_install = rule(
    impl = _perl_module_install_impl,
    attrs = {
        "source": attrs.dep(),
        "module_name": attrs.string(),
        "version": attrs.string(),
        "deps": attrs.list(attrs.dep(), default = []),
    },
)

def perl_module(
        name: str,
        version: str,
        src_uri: str,
        module_name: str | None = None,
        sha256: str = "TODO",
        deps: list[str] = [],
        visibility: list[str] = ["PUBLIC"]):
    """
    Define a Perl CPAN module for pre-downloading.

    Args:
        name: Package name
        version: Module version
        src_uri: Source download URL (e.g., from CPAN)
        module_name: CPAN module name (e.g., "JSON::XS")
        sha256: Source checksum
        deps: Other perl_module dependencies
        visibility: Buck2 visibility

    Example:
        perl_module(
            name = "json-xs",
            version = "4.03",
            src_uri = "https://cpan.metacpan.org/authors/id/M/ML/MLEHMANN/JSON-XS-4.03.tar.gz",
            module_name = "JSON::XS",
            sha256 = "abc123...",
        )
    """
    actual_name = module_name if module_name else name.replace("-", "::")

    src_name = name + "-src"
    download_source(
        name = src_name,
        src_uri = src_uri,
        sha256 = sha256,
    )

    _perl_module_install(
        name = name,
        source = ":" + src_name,
        module_name = actual_name,
        version = version,
        deps = deps,
        visibility = visibility,
    )

def _perl_vendor_impl(ctx: AnalysisContext) -> list[Provider]:
    """Combine multiple perl_module dependencies into a lib/perl5 directory."""
    out_dir = ctx.actions.declare_output("vendor", dir = True)

    lib_dirs = []
    for dep in ctx.attrs.deps:
        if PerlModuleInfo in dep:
            lib_dirs.append(dep[PerlModuleInfo].lib_dir)
        elif DefaultInfo in dep:
            lib_dirs.append(dep[DefaultInfo].default_outputs[0])

    script_content = """#!/bin/bash
set -e
OUT_DIR="$1"
shift

mkdir -p "$OUT_DIR/lib/perl5"

for dir in "$@"; do
    if [ -d "$dir/lib/perl5" ]; then
        cp -r "$dir/lib/perl5/"* "$OUT_DIR/lib/perl5/" 2>/dev/null || true
    fi
done
"""

    script = ctx.actions.write("merge-perl-vendor.sh", script_content, is_executable = True)
    cmd = cmd_args(["bash", script, out_dir.as_output()])
    for ldir in lib_dirs:
        cmd.add(ldir)

    ctx.actions.run(cmd, category = "perl_vendor", identifier = ctx.attrs.name)

    return [DefaultInfo(default_output = out_dir)]

_perl_vendor = rule(
    impl = _perl_vendor_impl,
    attrs = {
        "deps": attrs.list(attrs.dep()),
    },
)

def perl_vendor(
        name: str,
        deps: list[str],
        visibility: list[str] = ["PUBLIC"]):
    """
    Combine multiple perl_module dependencies into a lib/perl5 directory.

    Args:
        name: Target name
        deps: List of perl_module targets to include
        visibility: Buck2 visibility
    """
    _perl_vendor(
        name = name,
        deps = deps,
        visibility = visibility,
    )

# -----------------------------------------------------------------------------
# NPM Package Support (pre-downloaded npm packages for offline builds)
# -----------------------------------------------------------------------------

def _npm_package_install_impl(ctx: AnalysisContext) -> list[Provider]:
    """Install NPM package source into node_modules structure."""
    out_dir = ctx.actions.declare_output(ctx.attrs.name, dir = True)
    src_dir = ctx.attrs.source[DefaultInfo].default_outputs[0]

    script_content = """#!/bin/bash
set -e
SRC_DIR="$1"
OUT_DIR="$2"
PKG_NAME="$3"

# Handle scoped packages (@org/name)
if [[ "$PKG_NAME" == @* ]]; then
    SCOPE=$(echo "$PKG_NAME" | cut -d'/' -f1)
    NAME=$(echo "$PKG_NAME" | cut -d'/' -f2)
    NODE_MODULES="$OUT_DIR/node_modules/$SCOPE/$NAME"
else
    NODE_MODULES="$OUT_DIR/node_modules/$PKG_NAME"
fi
mkdir -p "$NODE_MODULES"

cd "$SRC_DIR"

# NPM tarballs extract to "package/" directory
if [ -d "package" ]; then
    cp -r package/* "$NODE_MODULES/"
else
    EXTRACTED=$(ls -d */ 2>/dev/null | head -1)
    if [ -n "$EXTRACTED" ]; then
        cp -r "$EXTRACTED"/* "$NODE_MODULES/" 2>/dev/null || cp -r . "$NODE_MODULES/"
    else
        cp -r . "$NODE_MODULES/"
    fi
fi
"""

    script = ctx.actions.write("install-npm-package.sh", script_content, is_executable = True)
    ctx.actions.run(
        cmd_args(["bash", script, src_dir, out_dir.as_output(), ctx.attrs.package_name]),
        category = "npm_package",
        identifier = ctx.attrs.name,
    )

    return [
        DefaultInfo(default_output = out_dir),
        NpmPackageInfo(
            package_name = ctx.attrs.package_name,
            version = ctx.attrs.version,
            node_modules = out_dir,
        ),
    ]

_npm_package_install = rule(
    impl = _npm_package_install_impl,
    attrs = {
        "source": attrs.dep(),
        "package_name": attrs.string(),
        "version": attrs.string(),
        "deps": attrs.list(attrs.dep(), default = []),
    },
)

def npm_library(
        name: str,
        version: str,
        src_uri: str,
        npm_name: str | None = None,
        sha256: str = "TODO",
        deps: list[str] = [],
        visibility: list[str] = ["PUBLIC"]):
    """
    Define an NPM library for pre-downloading (offline builds).

    This is used to pre-download npm packages from the registry for offline
    builds. The downloaded packages can be combined using npm_vendor() to
    create a node_modules directory for use with npm_package().

    Args:
        name: Package name
        version: Package version
        src_uri: Source download URL (e.g., from npm registry)
        npm_name: NPM name if different (can be scoped like @org/name)
        sha256: Source checksum
        deps: Other npm_library dependencies
        visibility: Buck2 visibility

    Example:
        npm_library(
            name = "lodash",
            version = "4.17.21",
            src_uri = "https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz",
            sha256 = "abc123...",
        )

        npm_library(
            name = "babel-core",
            version = "7.24.0",
            npm_name = "@babel/core",
            src_uri = "https://registry.npmjs.org/@babel/core/-/core-7.24.0.tgz",
            sha256 = "abc123...",
        )
    """
    actual_name = npm_name if npm_name else name

    src_name = name + "-src"
    download_source(
        name = src_name,
        src_uri = src_uri,
        sha256 = sha256,
    )

    _npm_package_install(
        name = name,
        source = ":" + src_name,
        package_name = actual_name,
        version = version,
        deps = deps,
        visibility = visibility,
    )

def _npm_vendor_impl(ctx: AnalysisContext) -> list[Provider]:
    """Combine multiple npm_package dependencies into a node_modules directory."""
    out_dir = ctx.actions.declare_output("vendor", dir = True)

    pkg_dirs = []
    for dep in ctx.attrs.deps:
        if NpmPackageInfo in dep:
            pkg_dirs.append(dep[NpmPackageInfo].node_modules)
        elif DefaultInfo in dep:
            pkg_dirs.append(dep[DefaultInfo].default_outputs[0])

    script_content = """#!/bin/bash
set -e
OUT_DIR="$1"
shift

mkdir -p "$OUT_DIR/node_modules"

for dir in "$@"; do
    if [ -d "$dir/node_modules" ]; then
        cp -r "$dir/node_modules/"* "$OUT_DIR/node_modules/" 2>/dev/null || true
    fi
done
"""

    script = ctx.actions.write("merge-npm-vendor.sh", script_content, is_executable = True)
    cmd = cmd_args(["bash", script, out_dir.as_output()])
    for pdir in pkg_dirs:
        cmd.add(pdir)

    ctx.actions.run(cmd, category = "npm_vendor", identifier = ctx.attrs.name)

    return [DefaultInfo(default_output = out_dir)]

_npm_vendor = rule(
    impl = _npm_vendor_impl,
    attrs = {
        "deps": attrs.list(attrs.dep()),
    },
)

def npm_vendor(
        name: str,
        deps: list[str],
        visibility: list[str] = ["PUBLIC"]):
    """
    Combine multiple npm_package dependencies into a node_modules directory.

    Args:
        name: Target name
        deps: List of npm_package targets to include
        visibility: Buck2 visibility
    """
    _npm_vendor(
        name = name,
        deps = deps,
        visibility = visibility,
    )

# -----------------------------------------------------------------------------
# package-lock.json Dependencies (NPM lockfile parsing)
# -----------------------------------------------------------------------------

def _npm_lock_deps_download_impl(ctx: AnalysisContext) -> list[Provider]:
    """Download NPM packages from registry and create node_modules structure."""
    out_dir = ctx.actions.declare_output("vendor", dir = True)

    packages_json = json.encode(ctx.attrs.packages)

    script_content = """#!/bin/bash
set -e
OUT_DIR="$1"
PACKAGES_JSON="$2"

mkdir -p "$OUT_DIR/node_modules"

HTTP_PROXY="${BUCKOS_DOWNLOAD_PROXY:-${HTTP_PROXY:-${http_proxy:-}}}"
MAX_CONCURRENT="${BUCKOS_MAX_CONCURRENT_DOWNLOADS:-4}"
RATE_LIMIT="${BUCKOS_DOWNLOAD_RATE_LIMIT:-5.0}"

echo "$PACKAGES_JSON" | python3 -c '
import json
import sys
import os
import time
import tarfile
import tempfile
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed
import threading

packages = json.load(sys.stdin)
out_dir = sys.argv[1]
http_proxy = os.environ.get("HTTP_PROXY", "") or os.environ.get("http_proxy", "")
max_concurrent = int(os.environ.get("BUCKOS_MAX_CONCURRENT_DOWNLOADS", "4"))
rate_limit = float(os.environ.get("BUCKOS_DOWNLOAD_RATE_LIMIT", "5.0"))

class RateLimiter:
    def __init__(self, rate):
        self.rate = rate
        self.lock = threading.Lock()
        self.last_time = 0

    def acquire(self):
        with self.lock:
            now = time.time()
            wait_time = max(0, (1.0 / self.rate) - (now - self.last_time))
            if wait_time > 0:
                time.sleep(wait_time)
            self.last_time = time.time()

rate_limiter = RateLimiter(rate_limit) if rate_limit > 0 else None

if http_proxy:
    proxy_handler = urllib.request.ProxyHandler({"http": http_proxy, "https": http_proxy})
    opener = urllib.request.build_opener(proxy_handler)
    urllib.request.install_opener(opener)
    print(f"Using proxy: {http_proxy}")

node_modules = os.path.join(out_dir, "node_modules")
os.makedirs(node_modules, exist_ok=True)

def download_package(pkg):
    name = pkg["name"]
    version = pkg["version"]

    # Handle scoped packages
    if name.startswith("@"):
        scope, pkg_name = name.split("/", 1)
        pkg_dir = os.path.join(node_modules, scope, pkg_name)
        encoded_name = name.replace("/", "%2f")
        url = f"https://registry.npmjs.org/{encoded_name}/-/{pkg_name}-{version}.tgz"
    else:
        pkg_dir = os.path.join(node_modules, name)
        url = f"https://registry.npmjs.org/{name}/-/{name}-{version}.tgz"

    if os.path.exists(pkg_dir):
        return name

    if rate_limiter:
        rate_limiter.acquire()

    try:
        print(f"Downloading {name}@{version}")
        with tempfile.NamedTemporaryFile(suffix=".tgz", delete=False) as tmp:
            urllib.request.urlretrieve(url, tmp.name)

            os.makedirs(pkg_dir, exist_ok=True)
            with tarfile.open(tmp.name, "r:gz") as tar:
                for member in tar.getmembers():
                    # Strip "package/" prefix
                    if member.name.startswith("package/"):
                        member.name = member.name[8:]
                        if member.name:
                            tar.extract(member, pkg_dir)

            os.unlink(tmp.name)
        return name

    except Exception as e:
        print(f"Warning: Failed to download {name}@{version}: {e}")
        return None

print(f"Downloading {len(packages)} NPM packages (max concurrent: {max_concurrent})")
with ThreadPoolExecutor(max_workers=max_concurrent) as executor:
    futures = {executor.submit(download_package, pkg): pkg for pkg in packages}
    for future in as_completed(futures):
        try:
            future.result()
        except Exception as e:
            print(f"Error: {e}")

print("NPM vendor directory created successfully")
' "$OUT_DIR"
"""

    script = ctx.actions.write("download-npm-lock-deps.sh", script_content, is_executable = True)
    ctx.actions.run(
        cmd_args(["bash", script, out_dir.as_output(), packages_json]),
        category = "npm_lock_deps_download",
        identifier = ctx.attrs.name,
        local_only = True,
        env = _get_download_env(),
    )

    return [DefaultInfo(default_output = out_dir)]

_npm_lock_deps_download = rule(
    impl = _npm_lock_deps_download_impl,
    attrs = {
        "packages": attrs.list(attrs.dict(key = attrs.string(), value = attrs.string())),
    },
)

def npm_lock_deps(
        name: str,
        packages: list[str],
        visibility: list[str] = ["PUBLIC"]):
    """
    Create NPM vendor directory from package-lock.json entries.

    Args:
        name: Target name
        packages: List of package entries in format "name version"
                  (scoped packages like "@babel/core" are supported)
        visibility: Buck2 visibility

    Example:
        npm_lock_deps(
            name = "app-deps",
            packages = [
                "lodash 4.17.21",
                "@babel/core 7.24.0",
                "react 18.2.0",
            ],
        )
    """
    pkg_list = []
    seen = {}

    for entry in packages:
        # Handle both "name version" and "name@version" formats
        if "@" in entry and not entry.startswith("@"):
            parts = entry.rsplit("@", 1)
        else:
            parts = entry.rsplit(" ", 1)

        if len(parts) < 2:
            continue

        pkg_name = parts[0].strip()
        version = parts[1].strip()

        key = pkg_name.lower()
        if key in seen:
            continue
        seen[key] = True

        pkg_list.append({"name": pkg_name, "version": version})

    _npm_lock_deps_download(
        name = name,
        packages = pkg_list,
        visibility = visibility,
    )

# -----------------------------------------------------------------------------
# Binary Package Helper Functions
# -----------------------------------------------------------------------------

def binary_install_bins(bins: list[str], src_dir: str = "$SRCS") -> str:
    """
    Helper to install binary executables from source directory to /usr/bin.

    Usage in install_script:
        install_script = binary_install_bins(["myapp", "mytool"])
    """
    cmds = ['mkdir -p "$OUT/usr/bin"']
    for b in bins:
        cmds.append('install -m 0755 "{}/{}" "$OUT/usr/bin/"'.format(src_dir, b))
    return "\n".join(cmds)

def binary_install_libs(libs: list[str], src_dir: str = "$SRCS") -> str:
    """
    Helper to install shared libraries from source directory to /usr/lib64.

    Usage in install_script:
        install_script = binary_install_libs(["libfoo.so", "libbar.so.1"])
    """
    cmds = ['mkdir -p "$OUT/usr/lib64"']
    for lib in libs:
        cmds.append('install -m 0755 "{}/{}" "$OUT/usr/lib64/"'.format(src_dir, lib))
    return "\n".join(cmds)

def binary_extract_tarball(tarball: str, dest: str = "/usr", strip: int = 1) -> str:
    """
    Helper to extract a tarball to a destination directory.

    Usage in install_script:
        install_script = binary_extract_tarball("app-1.0.tar.gz", "/opt/app", strip=1)
    """
    return '''
mkdir -p "$OUT{dest}"
tar -xf "$SRCS/{tarball}" -C "$OUT{dest}" --strip-components={strip}
'''.format(tarball = tarball, dest = dest, strip = strip)

def binary_copy_tree(src_subdir: str = "", dest: str = "/usr") -> str:
    """
    Helper to copy a directory tree from source to destination.

    Usage in install_script:
        install_script = binary_copy_tree("bin", "/usr/bin")
    """
    src = "$SRCS" if not src_subdir else "$SRCS/{}".format(src_subdir)
    return '''
mkdir -p "$OUT{dest}"
cp -r {src}/* "$OUT{dest}/" 2>/dev/null || true
'''.format(src = src, dest = dest)

def binary_create_wrapper(name: str, target: str, env_vars: dict[str, str] = {}) -> str:
    """
    Helper to create a wrapper script for a binary with environment setup.

    Usage in install_script:
        install_script = binary_create_wrapper("java", "/usr/lib/jvm/bin/java", {"JAVA_HOME": "/usr/lib/jvm"})
    """
    env_exports = "\n".join(['export {}="{}"'.format(k, v) for k, v in env_vars.items()])
    return '''
mkdir -p "$OUT/usr/bin"
cat > "$OUT/usr/bin/{name}" << 'WRAPPER_EOF'
#!/bin/bash
{env}
exec "{target}" "$@"
WRAPPER_EOF
chmod 0755 "$OUT/usr/bin/{name}"
'''.format(name = name, target = target, env = env_exports)

def binary_install_manpages(manpages: list[str], src_dir: str = "$SRCS") -> str:
    """
    Helper to install man pages from a binary package.

    Usage in install_script:
        install_script = binary_install_manpages(["app.1", "app.conf.5"])
    """
    cmds = []
    for man in manpages:
        # Extract section from filename (e.g., "app.1" -> section 1)
        cmds.append('''
_manfile="{src_dir}/{man}"
_section="${{_manfile##*.}}"
mkdir -p "$OUT/usr/share/man/man$_section"
install -m 0644 "$_manfile" "$OUT/usr/share/man/man$_section/"
'''.format(src_dir = src_dir, man = man))
    return "\n".join(cmds)

def binary_make_symlinks(symlinks: dict[str, str]) -> str:
    """
    Helper to create symbolic links.

    Usage in install_script:
        install_script = binary_make_symlinks({"/usr/bin/vi": "/usr/bin/vim"})
    """
    cmds = []
    for link, target in symlinks.items():
        cmds.append('mkdir -p "$OUT/$(dirname "{}")"'.format(link))
        cmds.append('ln -sf "{}" "$OUT/{}"'.format(target, link))
    return "\n".join(cmds)

def bootstrap_compiler_install(
        bootstrap_tarball: str,
        source_dir: str,
        build_cmd: str,
        install_prefix: str = "/usr",
        bins: list[str] = []) -> str:
    """
    Helper for bootstrap-style compiler installations (Go, GHC, Rust, etc.).

    Usage in install_script:
        install_script = bootstrap_compiler_install(
            bootstrap_tarball = "go1.21.6.linux-amd64.tar.gz",
            source_dir = "go",
            build_cmd = "cd src && ./make.bash",
            install_prefix = "/usr/local/go",
            bins = ["go", "gofmt"]
        )
    """
    bin_symlinks = "\n".join([
        'ln -sf "{}/bin/{}" "$OUT/usr/bin/{}"'.format(install_prefix, b, b)
        for b in bins
    ]) if bins else ""

    return '''
# Setup bootstrap
mkdir -p $WORK/bootstrap
tar -xf "$SRCS/{bootstrap_tarball}" -C $WORK/bootstrap --strip-components=1
export PATH="$WORK/bootstrap/bin:$PATH"

# Build from source
cd "$SRCS/{source_dir}"
{build_cmd}

# Install
mkdir -p "$OUT{install_prefix}"
cp -r "$SRCS/{source_dir}"/* "$OUT{install_prefix}/"

# Create bin symlinks
mkdir -p "$OUT/usr/bin"
{bin_symlinks}
'''.format(
        bootstrap_tarball = bootstrap_tarball,
        source_dir = source_dir,
        build_cmd = build_cmd,
        install_prefix = install_prefix,
        bin_symlinks = bin_symlinks,
    )

# -----------------------------------------------------------------------------
# Binary Package Convenience Macros
# -----------------------------------------------------------------------------

def simple_binary_package(
        name: str,
        version: str,
        src_uri: str,
        sha256: str,
        bins: list[str] = [],
        libs: list[str] = [],
        extract_to: str = "/usr",
        symlinks: dict[str, str] = {},
        deps: list[str] = [],
        maintainers: list[str] = [],
        patches: list[str] = [],
        exclude_patterns: list[str] = [],
        **kwargs):
    """
    Convenience macro for simple precompiled binary packages.

    This is the easiest way to package a precompiled binary - just specify
    the binaries and libraries to install.

    Example:
        simple_binary_package(
            name = "ripgrep",
            version = "14.1.0",
            src_uri = "https://github.com/BurntSushi/ripgrep/releases/download/14.1.0/ripgrep-14.1.0-x86_64-unknown-linux-musl.tar.gz",
            sha256 = "...",
            bins = ["rg"],
        )
    """
    src_name = name + "-src"

    download_source(
        name = src_name,
        src_uri = src_uri,
        sha256 = sha256,
        exclude_patterns = exclude_patterns,
    )

    # Build install script
    install_cmds = []
    if bins:
        install_cmds.append(binary_install_bins(bins))
    if libs:
        install_cmds.append(binary_install_libs(libs))
    if symlinks:
        install_cmds.append(binary_make_symlinks(symlinks))
    if not bins and not libs:
        install_cmds.append(binary_copy_tree("", extract_to))

    binary_package(
        name = name,
        srcs = [":" + src_name],
        version = version,
        install_script = "\n".join(install_cmds),
        deps = deps,
        maintainers = maintainers,
        **kwargs
    )

def bootstrap_package(
        name: str,
        version: str,
        src_uri: str,
        sha256: str,
        bootstrap_uri: str,
        bootstrap_sha256: str,
        build_cmd: str,
        install_prefix: str = "/usr",
        bins: list[str] = [],
        deps: list[str] = [],
        maintainers: list[str] = [],
        patches: list[str] = [],
        exclude_patterns: list[str] = [],
        bootstrap_exclude_patterns: list[str] = [],
        **kwargs):
    """
    Convenience macro for bootstrap-compiled packages (compilers that need
    a previous version to build).

    Example:
        bootstrap_package(
            name = "go",
            version = "1.22.0",
            src_uri = "https://go.dev/dl/go1.22.0.src.tar.gz",
            sha256 = "...",
            bootstrap_uri = "https://go.dev/dl/go1.21.6.linux-amd64.tar.gz",
            bootstrap_sha256 = "...",
            build_cmd = "cd src && ./make.bash",
            install_prefix = "/usr/local/go",
            bins = ["go", "gofmt"],
        )
    """
    src_name = name + "-src"
    bootstrap_name = name + "-bootstrap-src"

    download_source(
        name = src_name,
        src_uri = src_uri,
        sha256 = sha256,
        exclude_patterns = exclude_patterns,
    )

    download_source(
        name = bootstrap_name,
        src_uri = bootstrap_uri,
        sha256 = bootstrap_sha256,
        exclude_patterns = bootstrap_exclude_patterns,
    )

    # Derive bootstrap tarball name from URI
    bootstrap_tarball = bootstrap_uri.split("/")[-1]

    binary_package(
        name = name,
        srcs = [":" + src_name, ":" + bootstrap_name],
        version = version,
        install_script = bootstrap_compiler_install(
            bootstrap_tarball = bootstrap_tarball,
            source_dir = name,
            build_cmd = build_cmd,
            install_prefix = install_prefix,
            bins = bins,
        ),
        deps = deps,
        maintainers = maintainers,
        **kwargs
    )

# -----------------------------------------------------------------------------
# Maven/SBT Dependencies (like Go modules and Rust crates)
# -----------------------------------------------------------------------------

MavenArtifactInfo = provider(fields = ["group_id", "artifact_id", "version", "jar_path"])

def _maven_artifact_download_impl(ctx: AnalysisContext) -> list[Provider]:
    """Download a single Maven artifact from Maven Central."""
    out_jar = ctx.actions.declare_output(ctx.attrs.artifact_id + "-" + ctx.attrs.version + ".jar")

    group_path = ctx.attrs.group_id.replace(".", "/")
    url = "https://repo1.maven.org/maven2/{}/{}/{}/{}-{}.jar".format(
        group_path,
        ctx.attrs.artifact_id,
        ctx.attrs.version,
        ctx.attrs.artifact_id,
        ctx.attrs.version,
    )

    script_content = """#!/bin/bash
set -e
URL="$1"
OUT="$2"
SHA256="$3"

PROXY_ARGS=""
if [ -n "${{http_proxy:-}}" ]; then
    PROXY_ARGS="--proxy $http_proxy"
elif [ -n "${{https_proxy:-}}" ]; then
    PROXY_ARGS="--proxy $https_proxy"
fi

curl -fsSL $PROXY_ARGS -o "$OUT" "$URL"

if [ -n "$SHA256" ] && [ "$SHA256" != "TODO" ]; then
    ACTUAL=$(sha256sum "$OUT" | cut -d' ' -f1)
    if [ "$ACTUAL" != "$SHA256" ]; then
        echo "SHA256 mismatch for $URL"
        echo "  Expected: $SHA256"
        echo "  Actual:   $ACTUAL"
        exit 1
    fi
fi
"""
    script = ctx.actions.write("download-maven.sh", script_content, is_executable = True)
    ctx.actions.run(
        cmd_args(["bash", script, url, out_jar.as_output(), ctx.attrs.sha256]),
        category = "maven_download",
        identifier = "{}:{}:{}".format(ctx.attrs.group_id, ctx.attrs.artifact_id, ctx.attrs.version),
    )

    return [
        DefaultInfo(default_output = out_jar),
        MavenArtifactInfo(
            group_id = ctx.attrs.group_id,
            artifact_id = ctx.attrs.artifact_id,
            version = ctx.attrs.version,
            jar_path = out_jar,
        ),
    ]

_maven_artifact_download = rule(
    impl = _maven_artifact_download_impl,
    attrs = {
        "group_id": attrs.string(),
        "artifact_id": attrs.string(),
        "version": attrs.string(),
        "sha256": attrs.string(default = "TODO"),
    },
)

def _maven_repo_impl(ctx: AnalysisContext) -> list[Provider]:
    """Combine multiple Maven artifacts into a local repository structure."""
    out_dir = ctx.actions.declare_output("maven-repo", dir = True)

    # Collect all artifacts from dependencies
    artifacts = []
    for dep in ctx.attrs.deps:
        info = dep.get(MavenArtifactInfo)
        if info:
            artifacts.append({
                "group_id": info.group_id,
                "artifact_id": info.artifact_id,
                "version": info.version,
                "jar": dep[DefaultInfo].default_outputs[0],
            })

    script_lines = ["#!/bin/bash", "set -e", 'OUT_DIR="$1"', "shift", "mkdir -p \"$OUT_DIR\""]

    for i, art in enumerate(artifacts):
        group_path = art["group_id"].replace(".", "/")
        dest_dir = "$OUT_DIR/{}/{}/{}".format(group_path, art["artifact_id"], art["version"])
        jar_name = "{}-{}.jar".format(art["artifact_id"], art["version"])
        script_lines.append('mkdir -p "{}"'.format(dest_dir))
        script_lines.append('cp "${}" "{}/{}"'.format(i + 1, dest_dir, jar_name))

    script_content = "\n".join(script_lines)
    script = ctx.actions.write("create-maven-repo.sh", script_content, is_executable = True)

    jar_args = [art["jar"] for art in artifacts]
    ctx.actions.run(
        cmd_args(["bash", script, out_dir.as_output()] + jar_args),
        category = "maven_repo",
        identifier = ctx.attrs.name,
    )

    return [DefaultInfo(default_output = out_dir)]

_maven_repo = rule(
    impl = _maven_repo_impl,
    attrs = {
        "deps": attrs.list(attrs.dep()),
    },
)

def maven_artifact(
        name: str,
        group_id: str,
        artifact_id: str,
        version: str,
        sha256: str = "TODO",
        visibility: list[str] = ["PUBLIC"]):
    """
    Download a single Maven artifact from Maven Central.

    Args:
        name: Target name
        group_id: Maven group ID (e.g., "org.scala-lang")
        artifact_id: Maven artifact ID (e.g., "scala-library")
        version: Artifact version
        sha256: JAR checksum
        visibility: Buck2 visibility

    Example:
        maven_artifact(
            name = "scala-library",
            group_id = "org.scala-lang",
            artifact_id = "scala-library",
            version = "2.12.18",
            sha256 = "abc123...",
        )
    """
    _maven_artifact_download(
        name = name,
        group_id = group_id,
        artifact_id = artifact_id,
        version = version,
        sha256 = sha256,
        visibility = visibility,
    )

def maven_deps(
        name: str,
        artifacts: list,
        visibility: list[str] = ["PUBLIC"]):
    """
    Download multiple Maven artifacts and create a local repository.

    Similar to go_sum_deps, this downloads all specified Maven artifacts
    and creates a repository structure for offline SBT/Maven builds.

    Args:
        name: Target name
        artifacts: List of tuples (group_id, artifact_id, version, sha256)
                   sha256 can be "TODO" for initial setup
        visibility: Buck2 visibility

    Example:
        maven_deps(
            name = "djinni-deps",
            artifacts = [
                ("org.scala-lang", "scala-library", "2.10.7", "abc..."),
                ("com.typesafe.sbt", "sbt-start-script", "0.10.0", "def..."),
            ],
        )
    """
    dep_targets = []
    for i, art in enumerate(artifacts):
        group_id, artifact_id, version = art[0], art[1], art[2]
        sha256 = art[3] if len(art) > 3 else "TODO"
        artifact_name = "{}-{}".format(name, i)

        maven_artifact(
            name = artifact_name,
            group_id = group_id,
            artifact_id = artifact_id,
            version = version,
            sha256 = sha256,
            visibility = [":" + name],
        )
        dep_targets.append(":" + artifact_name)

    _maven_repo(
        name = name,
        deps = dep_targets,
        visibility = visibility,
    )

# -----------------------------------------------------------------------------
# Java Package Support
# -----------------------------------------------------------------------------

def java_package(
        name: str,
        version: str,
        src_uri: str | None = None,
        sha256: str | None = None,
        source: str | None = None,
        java_src_dir: str = "src",
        jar_name: str | None = None,
        javac_opts: list[str] = [],
        java_source: str = "11",
        java_target: str = "11",
        deps: list[str] = [],
        maintainers: list[str] = [],
        patches: list[str] = [],
        # USE flag support
        iuse: list[str] = [],
        use_defaults: list[str] = [],
        use_deps: dict = {},
        global_use: dict | None = None,
        package_overrides: dict | None = None,
        signature_sha256: str | None = None,
        gpg_key: str | None = None,
        gpg_keyring: str | None = None,
        signature_required: bool = False,
        exclude_patterns: list[str] = [],
        **kwargs):
    """
    Convenience macro for Java packages built with javac.
    Uses the java eclass for standardized build phases.

    Args:
        name: Package name
        version: Package version
        src_uri: Source download URL
        sha256: Source checksum
        source: Pre-defined source target (alternative to src_uri/sha256)
        java_src_dir: Source directory (default: "src")
        jar_name: Output JAR name (default: package name)
        javac_opts: Additional javac options
        java_source: Java source version (default: "11")
        java_target: Java target version (default: "11")
        deps: Base dependencies (always applied)
        maintainers: Package maintainers
        iuse: List of USE flags this package supports
        use_defaults: Default enabled USE flags
        use_deps: Dict mapping USE flag to conditional dependencies
        global_use: Global USE flag configuration
        package_overrides: Package-specific USE overrides

    Example:
        java_package(
            name = "my-java-lib",
            version = "1.0.0",
            src_uri = "https://example.com/my-java-lib-1.0.0.tar.gz",
            sha256 = "...",
            java_src_dir = "src/main/java",
            jar_name = "mylib",
        )
    """
    # Apply platform-specific constraints
    kwargs = _apply_platform_constraints(kwargs)

    # Handle source - either use provided source or create one from src_uri
    if source:
        src_target = source
    else:
        if not src_uri or not sha256:
            fail("Either 'source' or both 'src_uri' and 'sha256' must be provided")
        src_name = name + "-src"
        download_source(
            name = src_name,
            src_uri = src_uri,
            sha256 = sha256,
            signature_sha256 = signature_sha256,
            signature_required = signature_required,
            gpg_key = gpg_key,
            gpg_keyring = gpg_keyring,
            exclude_patterns = exclude_patterns,
        )
        src_target = ":" + src_name

    # Calculate effective USE flags if USE flags are specified
    effective_use = []
    resolved_deps = list(deps)

    if iuse:
        effective_use = get_effective_use(
            name,
            iuse,
            use_defaults,
            global_use,
            package_overrides,
        )

        # Resolve conditional dependencies
        resolved_deps.extend(use_dep(use_deps, effective_use))

    # Use eclass inheritance for java
    eclass_config = inherit(["java"])

    # Set environment variables for Java compilation
    env = kwargs.pop("env", {})
    env["JAVA_SRC_DIR"] = java_src_dir
    env["JAVA_SOURCE"] = java_source
    env["JAVA_TARGET"] = java_target
    env["PN"] = name
    if jar_name:
        env["JAR_NAME"] = jar_name
    if javac_opts:
        env["JAVAC_OPTS"] = " ".join(javac_opts)

    # Merge eclass bdepend with any existing bdepend
    bdepend = list(kwargs.pop("bdepend", []))
    for dep in eclass_config["bdepend"]:
        if dep not in bdepend:
            bdepend.append(dep)

    # Add bootstrap toolchain by default
    use_bootstrap = kwargs.pop("use_bootstrap", True)
    if use_bootstrap:
        toolchain_dep = get_toolchain_dep()
        if toolchain_dep and toolchain_dep not in bdepend:
            bdepend.append(toolchain_dep)

    # Allow overriding eclass phases via kwargs
    custom_src_compile = kwargs.pop("src_compile", None)
    custom_src_install = kwargs.pop("src_install", None)

    # Export patch files and create references
    patch_refs = []
    for i, patch in enumerate(patches):
        if patch.startswith(":") or patch.startswith("//"):
            patch_refs.append(patch)
        else:
            patch_target_name = "{}-patch-{}".format(name, i)
            native.export_file(
                name = patch_target_name,
                src = patch,
                visibility = [],
            )
            patch_refs.append(":" + patch_target_name)

    # Filter kwargs
    src_install = custom_src_install if custom_src_install else eclass_config["src_install"]
    filtered_kwargs, src_install = filter_ebuild_kwargs(kwargs, src_install)

    ebuild_package_rule(
        name = name,
        source = src_target,
        version = version,
        package_type = "java",
        patches = patch_refs,
        src_compile = custom_src_compile if custom_src_compile else eclass_config["src_compile"],
        src_install = src_install,
        rdepend = resolved_deps,
        bdepend = bdepend,
        env = env,
        maintainers = maintainers,
        use_flags = effective_use,
        use_bootstrap = use_bootstrap,
        **filtered_kwargs
    )

# -----------------------------------------------------------------------------
# Maven Package Support
# -----------------------------------------------------------------------------

def maven_package(
        name: str,
        version: str,
        src_uri: str | None = None,
        sha256: str | None = None,
        source: str | None = None,
        maven_args: list[str] = [],
        maven_deps_target: str | None = None,
        deps: list[str] = [],
        maintainers: list[str] = [],
        patches: list[str] = [],
        # USE flag support
        iuse: list[str] = [],
        use_defaults: list[str] = [],
        use_maven: dict = {},
        use_deps: dict = {},
        global_use: dict | None = None,
        package_overrides: dict | None = None,
        signature_sha256: str | None = None,
        gpg_key: str | None = None,
        gpg_keyring: str | None = None,
        signature_required: bool = False,
        exclude_patterns: list[str] = [],
        **kwargs):
    """
    Convenience macro for Maven-based Java packages.
    Uses the maven eclass for standardized build phases.

    Args:
        name: Package name
        version: Package version
        src_uri: Source download URL
        sha256: Source checksum
        source: Pre-defined source target (alternative to src_uri/sha256)
        maven_args: Additional Maven arguments
        maven_deps_target: Optional maven_deps target for offline builds
        deps: Base dependencies (always applied)
        maintainers: Package maintainers
        iuse: List of USE flags this package supports
        use_defaults: Default enabled USE flags
        use_maven: Dict mapping USE flag to Maven arguments
        use_deps: Dict mapping USE flag to conditional dependencies
        global_use: Global USE flag configuration
        package_overrides: Package-specific USE overrides

    Example:
        maven_package(
            name = "my-maven-project",
            version = "1.0.0",
            src_uri = "https://example.com/my-maven-1.0.0.tar.gz",
            sha256 = "...",
            maven_args = ["-Dmaven.test.skip=true"],
            maven_deps_target = ":my-maven-deps",
        )
    """
    # Apply platform-specific constraints
    kwargs = _apply_platform_constraints(kwargs)

    # Handle source - either use provided source or create one from src_uri
    if source:
        src_target = source
    else:
        if not src_uri or not sha256:
            fail("Either 'source' or both 'src_uri' and 'sha256' must be provided")
        src_name = name + "-src"
        download_source(
            name = src_name,
            src_uri = src_uri,
            sha256 = sha256,
            signature_sha256 = signature_sha256,
            signature_required = signature_required,
            gpg_key = gpg_key,
            gpg_keyring = gpg_keyring,
            exclude_patterns = exclude_patterns,
        )
        src_target = ":" + src_name

    # Calculate effective USE flags if USE flags are specified
    effective_use = []
    resolved_deps = list(deps)
    resolved_maven_args = list(maven_args)

    if iuse:
        effective_use = get_effective_use(
            name,
            iuse,
            use_defaults,
            global_use,
            package_overrides,
        )

        # Resolve conditional dependencies
        resolved_deps.extend(use_dep(use_deps, effective_use))

        # Process use_maven (maven args based on USE flags)
        if use_maven:
            for flag, maven_arg in use_maven.items():
                should_add = False
                if flag.startswith("-"):
                    flag_name = flag[1:]
                    if flag_name not in effective_use:
                        should_add = True
                else:
                    if flag in effective_use:
                        should_add = True

                if should_add:
                    if type(maven_arg) == type([]):
                        resolved_maven_args.extend(maven_arg)
                    else:
                        resolved_maven_args.append(maven_arg)

    # Use eclass inheritance for maven
    eclass_config = inherit(["maven"])

    # Set environment variables for Maven
    env = kwargs.pop("env", {})
    env["PN"] = name
    if resolved_maven_args:
        env["MVN_EXTRA_ARGS"] = " ".join(resolved_maven_args)

    # Merge eclass bdepend with any existing bdepend
    bdepend = list(kwargs.pop("bdepend", []))
    for dep in eclass_config["bdepend"]:
        if dep not in bdepend:
            bdepend.append(dep)

    # Add maven_deps_target if provided for offline builds
    if maven_deps_target:
        bdepend.append(maven_deps_target)

    # Add bootstrap toolchain by default
    use_bootstrap = kwargs.pop("use_bootstrap", True)
    if use_bootstrap:
        toolchain_dep = get_toolchain_dep()
        if toolchain_dep and toolchain_dep not in bdepend:
            bdepend.append(toolchain_dep)

    # Set up src_prepare to handle maven_deps_target
    maven_src_prepare = ""
    if maven_deps_target:
        maven_src_prepare = """
# Set up offline Maven repository from pre-downloaded dependencies
for maven_cache in $BDEPEND_DIRS; do
    if [ -d "$maven_cache/maven-repo" ]; then
        export MAVEN_REPO="$maven_cache/maven-repo"
        echo "Using pre-downloaded Maven repository: $MAVEN_REPO"
        break
    fi
done
"""

    # Allow overriding eclass phases via kwargs
    custom_src_prepare = kwargs.pop("src_prepare", None)
    custom_src_configure = kwargs.pop("src_configure", None)
    custom_src_compile = kwargs.pop("src_compile", None)
    custom_src_install = kwargs.pop("src_install", None)

    # Combine prepare phases
    base_src_prepare = custom_src_prepare if custom_src_prepare else ""
    src_prepare = maven_src_prepare + base_src_prepare

    # Export patch files and create references
    patch_refs = []
    for i, patch in enumerate(patches):
        if patch.startswith(":") or patch.startswith("//"):
            patch_refs.append(patch)
        else:
            patch_target_name = "{}-patch-{}".format(name, i)
            native.export_file(
                name = patch_target_name,
                src = patch,
                visibility = [],
            )
            patch_refs.append(":" + patch_target_name)

    # Filter kwargs
    src_install = custom_src_install if custom_src_install else eclass_config["src_install"]
    filtered_kwargs, src_install = filter_ebuild_kwargs(kwargs, src_install)

    ebuild_package_rule(
        name = name,
        source = src_target,
        version = version,
        package_type = "maven",
        patches = patch_refs,
        src_prepare = src_prepare,
        src_configure = custom_src_configure if custom_src_configure else eclass_config["src_configure"],
        src_compile = custom_src_compile if custom_src_compile else eclass_config["src_compile"],
        src_install = src_install,
        rdepend = resolved_deps,
        bdepend = bdepend,
        env = env,
        maintainers = maintainers,
        use_flags = effective_use,
        use_bootstrap = use_bootstrap,
        **filtered_kwargs
    )

def sbt_package(
        name: str,
        version: str,
        src_uri: str,
        sha256: str,
        maven_deps_target: str | None = None,
        build_cmd: str = "sbt compile stage",
        install_script: str | None = None,
        deps: list[str] = [],
        visibility: list[str] = ["PUBLIC"],
        **kwargs):
    """
    Build an SBT project with offline Maven dependencies.

    Similar to go_package, this builds SBT projects using pre-downloaded
    Maven dependencies for reproducible, offline builds.

    Args:
        name: Package name
        version: Package version
        src_uri: Source download URL
        sha256: Source checksum
        maven_deps_target: Optional maven_deps target for offline builds
        build_cmd: SBT build command (default: "sbt compile stage")
        install_script: Custom install script (after build)
        deps: Build dependencies
        visibility: Buck2 visibility

    Example:
        sbt_package(
            name = "djinni",
            version = "1.0",
            src_uri = "https://github.com/dropbox/djinni/archive/abc123.tar.gz",
            sha256 = "...",
            maven_deps_target = ":djinni-deps",
            install_script = '''
                mkdir -p "$OUT/usr/bin"
                cp target/universal/stage/bin/* "$OUT/usr/bin/"
            ''',
        )
    """
    src_name = name + "-src"

    download_source(
        name = src_name,
        src_uri = src_uri,
        sha256 = sha256,
    )

    srcs = [":" + src_name]
    if maven_deps_target:
        srcs.append(maven_deps_target)
        deps = deps + [maven_deps_target]

    offline_setup = ""
    if maven_deps_target:
        offline_setup = '''
# Set up offline Maven/Ivy repositories
MAVEN_REPO=$(find "$SRCS" -type d -name "maven-repo" | head -1)
if [ -n "$MAVEN_REPO" ]; then
    export SBT_OPTS="$SBT_OPTS -Dsbt.repository.config=$MAVEN_REPO/repositories"
    export COURSIER_CACHE="$MAVEN_REPO"
    mkdir -p ~/.sbt/1.0
    cat > ~/.sbt/1.0/repositories << EOF
[repositories]
  local
  local-maven: file://$MAVEN_REPO
EOF
    echo "Using offline Maven repository: $MAVEN_REPO"
fi
'''

    default_install = '''
mkdir -p "$OUT/usr/lib/{name}"
if [ -d target/universal/stage ]; then
    cp -r target/universal/stage/* "$OUT/usr/lib/{name}/"
fi
mkdir -p "$OUT/usr/bin"
for bin in "$OUT/usr/lib/{name}/bin/"*; do
    [ -f "$bin" ] && ln -sf "/usr/lib/{name}/bin/$(basename $bin)" "$OUT/usr/bin/"
done
'''.format(name = name)

    full_install_script = '''
cd "$SRCS"

# Find extracted directory
EXTRACTED=$(ls -d */ 2>/dev/null | head -1)
[ -n "$EXTRACTED" ] && cd "$EXTRACTED"

{offline_setup}

# Build
{build_cmd}

# Install
{install_script}
'''.format(
        offline_setup = offline_setup,
        build_cmd = build_cmd,
        install_script = install_script if install_script else default_install,
    )

    binary_package(
        name = name,
        srcs = srcs,
        version = version,
        install_script = full_install_script,
        deps = deps,
        visibility = visibility,
        **kwargs
    )


def qt6_package(
        name: str,
        version: str,
        src_uri: str | None = None,
        sha256: str | None = None,
        source: str | None = None,
        cmake_args: list[str] = [],
        qmake_args: list[str] = [],
        pre_configure: str = "",
        deps: list[str] = [],
        maintainers: list[str] = [],
        patches: list[str] = [],
        # USE flag support
        iuse: list[str] = [],
        use_defaults: list[str] = [],
        use_options: dict = {},
        use_cmake: dict = {},
        use_deps: dict = {},
        global_use: dict | None = None,
        package_overrides: dict | None = None,
        # Distribution compatibility
        compat_tags: list[str] | None = None,
        signature_sha256: str | None = None,
        signature_required: bool = False,
        gpg_key: str | None = None,
        gpg_keyring: str | None = None,
        exclude_patterns: list[str] = [],
        **kwargs):
    """
    Convenience macro for Qt6 packages with USE flag support.
    Uses the qt6 eclass for standardized build phases.

    Supports both qmake6 (.pro files) and cmake (CMakeLists.txt) build systems.

    Args:
        name: Package name
        version: Package version
        src_uri: Source download URL
        sha256: Source checksum
        cmake_args: Base CMake arguments (for cmake-based Qt6 projects)
        qmake_args: Base QMake arguments (for qmake6-based Qt6 projects)
        pre_configure: Pre-configure script
        deps: Base dependencies (always applied)
        maintainers: Package maintainers
        iuse: List of USE flags this package supports
        use_defaults: Default enabled USE flags
        use_options: Dict mapping USE flag to CMake option(s)
                     Example: {"ssl": "ENABLE_SSL", "tests": "BUILD_TESTING"}
        use_cmake: Dict mapping USE flag to raw cmake arguments
        use_deps: Dict mapping USE flag to conditional dependencies
        global_use: Global USE flag configuration
        package_overrides: Package-specific USE overrides
        signature_sha256: SHA256 of GPG signature file (use update_checksums.py to populate)
        gpg_key: Optional GPG key ID or fingerprint to import and verify against
        gpg_keyring: Optional path to GPG keyring file with trusted keys
        exclude_patterns: List of patterns to exclude from source extraction (passed to tar --exclude)

    Example:
        qt6_package(
            name = "my-qt6-app",
            version = "1.2.3",
            src_uri = "https://example.com/my-qt6-app-1.2.3.tar.gz",
            sha256 = "...",
            cmake_args = ["-DBUILD_SHARED_LIBS=ON"],
            iuse = ["tests", "doc"],
            use_defaults = [],
            use_options = {
                "tests": "BUILD_TESTING",
                "doc": "BUILD_DOCUMENTATION",
            },
            deps = ["//packages/dev-qt/qt6-widgets:qt6-widgets"],
        )
    """
    # Apply platform-specific constraints (Linux packages only build on Linux, etc.)
    kwargs = _apply_platform_constraints(kwargs)

    # Handle source - either use provided source or create one from src_uri
    if source:
        src_target = source
    else:
        if not src_uri or not sha256:
            fail("Either 'source' or both 'src_uri' and 'sha256' must be provided")
        src_name = name + "-src"
        download_source(
            name = src_name,
            src_uri = src_uri,
            sha256 = sha256,
            signature_sha256 = signature_sha256,
            signature_required = signature_required,
            gpg_key = gpg_key,
            gpg_keyring = gpg_keyring,
            exclude_patterns = exclude_patterns,
        )
        src_target = ":" + src_name

    # Calculate effective USE flags if USE flags are specified
    effective_use = []
    resolved_deps = list(deps)
    resolved_cmake_args = list(cmake_args)

    if iuse:
        effective_use = get_effective_use(
            name,
            iuse,
            use_defaults,
            global_use,
            package_overrides,
        )

        # Resolve conditional dependencies
        resolved_deps.extend(use_dep(use_deps, effective_use))

        # Generate CMake options based on USE flags
        if use_options:
            cmake_opts = use_cmake_options(use_options, effective_use)
            resolved_cmake_args.extend(cmake_opts)

        # Process use_cmake (raw cmake args)
        if use_cmake:
            for flag, cmake_arg in use_cmake.items():
                should_add = False
                if flag.startswith("-"):
                    # Negative flag (e.g., "-lite")
                    flag_name = flag[1:]
                    if flag_name not in effective_use:
                        should_add = True
                else:
                    # Positive flag (e.g., "lite")
                    if flag in effective_use:
                        should_add = True

                if should_add:
                    # cmake_arg can be a string or list of strings
                    if type(cmake_arg) == type([]):
                        resolved_cmake_args.extend(cmake_arg)
                    else:
                        resolved_cmake_args.append(cmake_arg)

    # Use eclass inheritance for qt6
    eclass_config = inherit(["qt6"])

    # Handle cmake_args and qmake_args by setting environment variables
    env = kwargs.pop("env", {})
    if resolved_cmake_args:
        env["CMAKE_EXTRA_ARGS"] = " ".join(resolved_cmake_args)
    if qmake_args:
        env["QMAKE_ARGS"] = " ".join(qmake_args)

    # Merge eclass bdepend with any existing bdepend
    bdepend = list(kwargs.pop("bdepend", []))
    for dep in eclass_config["bdepend"]:
        if dep not in bdepend:
            bdepend.append(dep)

    # Add bootstrap toolchain by default to ensure linking against BuckOS glibc
    # get_toolchain_dep() returns None when use_host_toolchain is enabled
    use_bootstrap = kwargs.pop("use_bootstrap", True)
    if use_bootstrap:
        toolchain_dep = get_toolchain_dep()
        if toolchain_dep:
            bdepend.append(toolchain_dep)

    # Allow overriding eclass phases via kwargs
    custom_src_prepare = kwargs.pop("src_prepare", None)
    custom_src_configure = kwargs.pop("src_configure", None)
    custom_src_compile = kwargs.pop("src_compile", None)
    custom_src_install = kwargs.pop("src_install", None)

    # Combine with eclass phases
    src_prepare = custom_src_prepare if custom_src_prepare else eclass_config.get("src_prepare", "")

    # Export patch files and create references
    patch_refs = []
    for i, patch in enumerate(patches):
        if patch.startswith(":") or patch.startswith("//"):
            # Already a target reference
            patch_refs.append(patch)
        else:
            # Create an export_file target for this patch
            patch_target_name = "{}-patch-{}".format(name, i)
            native.export_file(
                name = patch_target_name,
                src = patch,
                visibility = [],  # Private to this package
            )
            patch_refs.append(":" + patch_target_name)

    # Filter kwargs to only include parameters that ebuild_package_rule accepts
    src_install = custom_src_install if custom_src_install else eclass_config["src_install"]
    filtered_kwargs, src_install = filter_ebuild_kwargs(kwargs, src_install)

    ebuild_package_rule(
        name = name,
        source = src_target,
        version = version,
        package_type = "qt6",
        pre_configure = pre_configure,
        src_prepare = src_prepare,
        patches = patch_refs,  # Buck2 target references
        src_configure = custom_src_configure if custom_src_configure else eclass_config["src_configure"],
        src_compile = custom_src_compile if custom_src_compile else eclass_config["src_compile"],
        src_install = src_install,
        rdepend = resolved_deps,
        bdepend = bdepend,
        env = env,
        maintainers = maintainers,
        use_flags = effective_use,
        use_bootstrap = use_bootstrap,
        **filtered_kwargs
    )

# -----------------------------------------------------------------------------
# Account User/Group Package Wrappers
# -----------------------------------------------------------------------------

def acct_user_package(
        name: str,
        uid: int = -1,
        shell: str = "/sbin/nologin",
        home: str = "/dev/null",
        groups: list[str] = [],
        primary_group: str | None = None,
        description: str = "",
        deps: list[str] = [],
        visibility: list[str] = ["PUBLIC"],
        **kwargs):
    """
    Convenience macro for creating system user account packages.

    Creates a package that provisions a system user using the acct-user eclass.
    This is useful for services like nginx, postgres, etc. that need dedicated
    system users.

    Args:
        name: Username to create (also the package name)
        uid: Numeric UID (-1 for auto-assign in range 100-999)
        shell: Login shell (default: /sbin/nologin)
        home: Home directory (default: /dev/null)
        groups: List of supplementary groups
        primary_group: Primary group (default: same as username)
        description: Package description
        deps: Dependencies (e.g., acct-group packages for groups)
        visibility: Buck2 visibility

    Example:
        acct_user_package(
            name = "nginx",
            uid = 101,
            home = "/var/lib/nginx",
            groups = ["nginx"],
            deps = ["//packages/acct-group/nginx:nginx"],
        )
    """
    eclass_config = inherit(["acct-user"])

    # Build environment with user configuration
    env = {
        "ACCT_USER_NAME": name,
        "ACCT_USER_ID": str(uid),
        "ACCT_USER_SHELL": shell,
        "ACCT_USER_HOME": home,
        "ACCT_USER_GROUPS": ",".join(groups) if groups else "",
        "ACCT_USER_PRIMARY_GROUP": primary_group if primary_group else name,
    }

    # Create a minimal source (placeholder file so ebuild doesn't error on empty dir)
    # The package just runs the eclass src_install which creates account files
    src_name = name + "-acct-src"
    native.genrule(
        name = src_name,
        out = ".",
        cmd = "mkdir -p $OUT && echo '# acct-user package: {}' > $OUT/README".format(name),
    )

    # Get post_install script if available
    post_install = eclass_config.get("post_install", "")
    src_install = eclass_config["src_install"]
    if post_install:
        src_install = src_install + "\n" + post_install

    ebuild_package_rule(
        name = name,
        source = ":" + src_name,
        version = "0",  # Account packages don't have versions
        package_type = "acct-user",
        src_compile = "# No compilation needed for account packages",
        src_install = src_install,
        rdepend = deps,
        env = env,
        description = description if description else "System user account: " + name,
        visibility = visibility,
        **kwargs
    )

def acct_group_package(
        name: str,
        gid: int = -1,
        description: str = "",
        visibility: list[str] = ["PUBLIC"],
        **kwargs):
    """
    Convenience macro for creating system group account packages.

    Creates a package that provisions a system group using the acct-group eclass.
    This is useful for services that need dedicated system groups.

    Args:
        name: Group name to create (also the package name)
        gid: Numeric GID (-1 for auto-assign in range 100-999)
        description: Package description
        visibility: Buck2 visibility

    Example:
        acct_group_package(
            name = "nginx",
            gid = 101,
        )
    """
    eclass_config = inherit(["acct-group"])

    # Build environment with group configuration
    env = {
        "ACCT_GROUP_NAME": name,
        "ACCT_GROUP_ID": str(gid),
    }

    # Create a minimal source (placeholder file so ebuild doesn't error on empty dir)
    src_name = name + "-acct-src"
    native.genrule(
        name = src_name,
        out = ".",
        cmd = "mkdir -p $OUT && echo '# acct-group package: {}' > $OUT/README".format(name),
    )

    # Get post_install script if available
    post_install = eclass_config.get("post_install", "")
    src_install = eclass_config["src_install"]
    if post_install:
        src_install = src_install + "\n" + post_install

    ebuild_package_rule(
        name = name,
        source = ":" + src_name,
        version = "0",  # Account packages don't have versions
        package_type = "acct-group",
        src_compile = "# No compilation needed for account packages",
        src_install = src_install,
        env = env,
        description = description if description else "System group account: " + name,
        visibility = visibility,
        **kwargs
    )
