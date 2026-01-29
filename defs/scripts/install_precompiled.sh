#!/bin/bash
# install_precompiled.sh - External precompiled package installation script
# This script is SOURCED by the wrapper, not executed directly.
# Changes to this script invalidate packages that use precompiled_package.
#
# Environment variables (set by wrapper):
#   _PRECOMPILED_DESTDIR - destination directory
#   _PRECOMPILED_SRCDIR - source directory with precompiled files
#   _PRECOMPILED_EXTRACT_TO - path prefix for extraction (e.g., /usr)
#   SYMLINKS_SCRIPT - symlink commands to execute

set -e

# Prevent cd from outputting paths when CDPATH is set
unset CDPATH

# Directory setup from wrapper environment
mkdir -p "$_PRECOMPILED_DESTDIR"
export OUT="$(cd "$_PRECOMPILED_DESTDIR" && pwd)"
export SRC="$(cd "$_PRECOMPILED_SRCDIR" && pwd)"

# Create target directory
mkdir -p "$OUT$_PRECOMPILED_EXTRACT_TO"

# Copy precompiled files
cp -r "$SRC"/* "$OUT$_PRECOMPILED_EXTRACT_TO/" 2>/dev/null || true

# Create symlinks (from SYMLINKS_SCRIPT environment variable)
if [ -n "$SYMLINKS_SCRIPT" ]; then
    eval "$SYMLINKS_SCRIPT"
fi

# Verification
FILE_COUNT=$(find "$OUT" -type f 2>/dev/null | wc -l)
if [ "$FILE_COUNT" -eq 0 ]; then
    echo "Warning: No files installed to $OUT" >&2
fi

echo "Precompiled package installed: $FILE_COUNT files"
