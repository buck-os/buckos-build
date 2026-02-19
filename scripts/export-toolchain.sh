#!/usr/bin/env bash
#
# Export the built bootstrap toolchain as a compressed tarball for re-import.
#
# Usage:
#   ./scripts/export-toolchain.sh                        # build + export to default location
#   ./scripts/export-toolchain.sh --output /path/to/dir  # custom output directory
#
# The exported tarball can be re-imported by setting in .buckconfig:
#   [buckos]
#   prebuilt_toolchain_path = /path/to/bootstrap-toolchain-<arch>.tar.zst

set -euo pipefail

ARCH="$(uname -m)"
DEFAULT_OUTPUT_DIR="$HOME/.cache/buckos/toolchains"
OUTPUT_DIR=""
TARGET="toolchains//bootstrap:bootstrap-toolchain"

usage() {
    echo "Usage: $0 [--output DIR] [--arch ARCH] [--target TARGET]"
    echo ""
    echo "Options:"
    echo "  --output DIR     Output directory (default: $DEFAULT_OUTPUT_DIR)"
    echo "  --arch ARCH      Architecture label (default: $ARCH)"
    echo "  --target TARGET  Buck2 target (default: $TARGET)"
    echo "  --help           Show this help"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --arch)
            ARCH="$2"
            shift 2
            ;;
        --target)
            TARGET="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            ;;
    esac
done

OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
TARBALL_NAME="bootstrap-toolchain-${ARCH}.tar.zst"
TARBALL_PATH="${OUTPUT_DIR}/${TARBALL_NAME}"

echo "==> Discovering bootstrap targets..."
mapfile -t ALL_TARGETS < <(buck2 targets toolchains//bootstrap:)

# Filter out broken targets
TARGETS=()
for t in "${ALL_TARGETS[@]}"; do
    case "$t" in
        *verify-*) ;;
        *) TARGETS+=("$t") ;;
    esac
done

echo "==> Building ${#TARGETS[@]} bootstrap targets (skipped verify targets)..."
buck2 build "${TARGETS[@]}"

echo "==> Collecting build outputs..."
mapfile -t BUILD_OUTPUTS < <(buck2 targets --show-output toolchains//bootstrap: 2>/dev/null | awk '{print $2}')

# Collect all outputs into a staging directory
STAGING_DIR="$(mktemp -d)"
trap "rm -rf '$STAGING_DIR'" EXIT

count=0
for output in "${BUILD_OUTPUTS[@]}"; do
    if [[ -n "$output" && -d "$output" ]]; then
        target_name="$(basename "$output")"
        cp -a "$output" "$STAGING_DIR/$target_name"
        count=$((count + 1))
    fi
done

echo "  Collected $count target outputs"

mkdir -p "$OUTPUT_DIR"

echo "==> Creating tarball: $TARBALL_PATH"
tar --zstd -cf "$TARBALL_PATH" -C "$STAGING_DIR" .

TARBALL_SIZE="$(du -h "$TARBALL_PATH" | cut -f1)"
echo ""
echo "==> Export complete!"
echo "  Tarball: $TARBALL_PATH ($TARBALL_SIZE)"
echo ""
echo "To use the pre-built toolchain, add to .buckconfig:"
echo ""
echo "  [buckos]"
echo "  prebuilt_toolchain_path = $TARBALL_PATH"
