#!/usr/bin/env bash
# Generate the offline cargo registry archive for the buckos Rust workspace.
#
# BuckOS's cli/installer build with raw `cargo build`, which needs crates from
# crates.io.  For builds that can't reach the network (network isolation /
# remote execution), this produces a self-contained cargo registry snapshot
# (registry/cache + registry/index for exactly the crates in the workspace's
# Cargo.lock) that can be published to the buck mirror and consumed offline
# via `buckos.cargo_registry_sha256` (see packages/linux/apps/buckos-tools/BUCK).
#
# Run this on a host WITH crates.io access — it populates the cargo cache via
# `cargo fetch`, then snapshots only the crates the Linux build needs.
#
# Usage:
#   scripts/gen-cargo-registry.sh [WORKSPACE_DIR] [OUTPUT.tar.zst]
#
#   WORKSPACE_DIR  directory containing the workspace Cargo.toml/Cargo.lock
#                  (default: a checkout of the buckos sources release tag).
#   OUTPUT         output archive path
#                  (default: ./buckos-cargo-registry-<version>.tar.zst).
#
# Honors $CARGO_HOME (default: ~/.cargo) and $TARGET (default the host's
# x86_64-unknown-linux-gnu).  After it runs:
#   1. publish OUTPUT to the mirror at the printed content-addressed path
#      (download.bzl scheme: tree/<c>/<name>-<version>-<sha256[:12]>.tar.zst);
#   2. set  buckos.cargo_registry_sha256 = <printed sha256>  in your buckconfig.

set -euo pipefail

# Must match the buckos-tools version in packages/linux/apps/buckos-tools/BUCK.
VERSION=0.0.4
TARGET=${TARGET:-x86_64-unknown-linux-gnu}
CARGO_HOME=${CARGO_HOME:-$HOME/.cargo}

WORKSPACE=${1:-}
OUT=${2:-"$PWD/buckos-cargo-registry-${VERSION}.tar.zst"}

if [ -z "$WORKSPACE" ] || [ ! -f "$WORKSPACE/Cargo.lock" ]; then
    echo "error: pass a WORKSPACE_DIR containing the workspace Cargo.lock" >&2
    echo "       (the buckos Rust workspace root, with cli/ + installer/ members)" >&2
    exit 1
fi
LOCK="$WORKSPACE/Cargo.lock"

command -v cargo >/dev/null || { echo "error: cargo not found in PATH" >&2; exit 1; }

# 1. Ensure the host cargo cache has every crate the Linux build needs.
#    Restrict to the Linux target so platform-only crates that the Linux build
#    never compiles (e.g. *_macos / *_windows) aren't required.
echo ">> cargo fetch --locked --target $TARGET (populating $CARGO_HOME) ..."
( cd "$WORKSPACE" && CARGO_HOME="$CARGO_HOME" cargo fetch --locked --target "$TARGET" )

REG_SRC="$CARGO_HOME/registry"
CACHE_SRC=$(ls -d "$REG_SRC"/cache/* 2>/dev/null | head -1)
INDEX_SRC=$(ls -d "$REG_SRC"/index/* 2>/dev/null | head -1)
if [ ! -d "${CACHE_SRC:-}" ] || [ ! -d "${INDEX_SRC:-}" ]; then
    echo "error: no registry cache/index under $REG_SRC" >&2
    exit 1
fi
REG_ID=$(basename "$CACHE_SRC")

# 2. Stage registry/{cache,index}: only the .crate files for the lock's
#    (name, version) pairs, plus the whole (metadata-only) index.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/registry/cache/$REG_ID" "$STAGE/registry/index"
cp -a "$INDEX_SRC" "$STAGE/registry/index/"

python3 - "$LOCK" "$CACHE_SRC" "$STAGE/registry/cache/$REG_ID" <<'PY'
import sys, os, re, shutil
lock, cache, dst = sys.argv[1:4]
pkgs = re.findall(r'name = "([^"]+)"\nversion = "([^"]+)"', open(lock).read())
have = set(os.listdir(cache))
copied = skipped = 0
for name, ver in pkgs:
    f = f"{name}-{ver}.crate"
    if f in have:
        shutil.copy2(os.path.join(cache, f), os.path.join(dst, f))
        copied += 1
    else:
        skipped += 1  # workspace path-member or non-Linux-target crate
print(f"   staged {copied} .crate files "
      f"({skipped} lock entries skipped: workspace members + non-Linux targets)")
PY

# 3. Archive deterministically + checksum.
echo ">> creating $OUT ..."
tar --zstd --sort=name --mtime='1970-01-01 00:00:00' \
    --owner=0 --group=0 --numeric-owner \
    -C "$STAGE" -cf "$OUT" registry

SHA=$(sha256sum "$OUT" | awk '{print $1}')
DL="buckos-cargo-registry-${VERSION}-${SHA:0:12}.tar.zst"

echo
echo "registry archive: $OUT"
echo "sha256:           $SHA"
echo
echo "Next steps:"
echo "  1. publish to the mirror at:   tree/${DL:0:1}/${DL}"
echo "  2. set in your buckconfig:     buckos.cargo_registry_sha256 = $SHA"
