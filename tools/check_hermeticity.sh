#!/bin/bash
# Check buckos-built ELF files for host contamination.
#
# Modes:
#   check_hermeticity.sh interp <dir> [<dir>...]
#     Check interpreters — find binaries with host (non-sysroot) interpreter
#
#   check_hermeticity.sh glibc <dir> [<dir>...]
#     Check glibc version requirements — find .so/.bin files that need
#     newer glibc than the host provides
#
#   check_hermeticity.sh all <dir> [<dir>...]
#     Run both checks

set -euo pipefail

HOST_GLIBC_VER=""
get_host_glibc() {
    if [ -z "$HOST_GLIBC_VER" ]; then
        HOST_GLIBC_VER=$(ldd --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+$' || echo "2.17")
    fi
    echo "$HOST_GLIBC_VER"
}

# Compare version strings: returns 0 if $1 > $2
ver_gt() {
    local a_major a_minor b_major b_minor
    a_major=$(echo "$1" | cut -d. -f1)
    a_minor=$(echo "$1" | cut -d. -f2)
    b_major=$(echo "$2" | cut -d. -f1)
    b_minor=$(echo "$2" | cut -d. -f2)
    [ "$a_major" -gt "$b_major" ] && return 0
    [ "$a_major" -eq "$b_major" ] && [ "$a_minor" -gt "$b_minor" ] && return 0
    return 1
}

LEAKS=0
CHECKED=0

check_interp() {
    local f="$1"
    file -b "$f" 2>/dev/null | grep -q "ELF" || return 0
    CHECKED=$((CHECKED + 1))
    local interp
    interp=$(readelf -l "$f" 2>/dev/null | sed -n 's/.*\[Requesting program interpreter: \(.*\)\]/\1/p' || true)
    [ -z "$interp" ] && return 0
    if echo "$interp" | grep -q "sys-root"; then
        return 0  # sysroot interpreter — good
    fi
    if [ "$interp" = "/lib64/ld-linux-x86-64.so.2" ] || [ "$interp" = "/lib/ld-linux-x86-64.so.2" ]; then
        LEAKS=$((LEAKS + 1))
        echo "HOST_INTERP: $f"
        echo "  interpreter: $interp"
    fi
}

check_glibc_ver() {
    local f="$1"
    file -b "$f" 2>/dev/null | grep -q "ELF" || return 0
    CHECKED=$((CHECKED + 1))
    local host_ver
    host_ver=$(get_host_glibc)
    # Find highest GLIBC_X.Y version required
    local versions
    versions=$(readelf -V "$f" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -t_ -k2 -V | uniq || true)
    [ -z "$versions" ] && return 0
    local max_ver=""
    for v in $versions; do
        local ver=${v#GLIBC_}
        if [ -z "$max_ver" ] || ver_gt "$ver" "$max_ver"; then
            max_ver="$ver"
        fi
    done
    [ -z "$max_ver" ] && return 0
    if ver_gt "$max_ver" "$host_ver"; then
        LEAKS=$((LEAKS + 1))
        echo "GLIBC_LEAK: $f"
        echo "  requires: GLIBC_$max_ver (host has: $host_ver)"
        # Show which symbols need the newer version
        readelf -V "$f" 2>/dev/null | grep -E "GLIBC_($max_ver)" | head -3 || true
    fi
}

MODE="${1:-all}"
shift || { echo "Usage: $0 {interp|glibc|all} <dir> [<dir>...]"; exit 1; }

if [ $# -eq 0 ]; then
    echo "Usage: $0 {interp|glibc|all} <dir> [<dir>...]"
    exit 1
fi

echo "Host glibc: $(get_host_glibc)"
echo "Mode: $MODE"
echo ""

for dir in "$@"; do
    [ -d "$dir" ] || { echo "skip: $dir (not found)"; continue; }
    while IFS= read -r -d '' f; do
        case "$MODE" in
            interp) check_interp "$f" ;;
            glibc)  check_glibc_ver "$f" ;;
            all)    check_interp "$f"; check_glibc_ver "$f" ;;
        esac
    done < <(find "$dir" -type f -print0 2>/dev/null)
done

echo ""
echo "Checked: $CHECKED ELF files"
echo "Leaks:   $LEAKS"
[ "$LEAKS" -eq 0 ] && exit 0 || exit 1
