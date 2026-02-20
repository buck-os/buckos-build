#!/bin/bash
# verify_bootstrap.sh — verify bootstrap-produced binaries are correct
#
# Checks:
#   1. ELF architecture is x86-64
#   2. Glibc symbol version requirements <= target version (2.42)
#   3. No host-specific paths in RPATH/RUNPATH or binary strings
#   4. NEEDED libraries are expected (libc.so.6, libm.so.6, etc.)
#   5. No unexpected host library references
#
# Usage:
#   tools/verify_bootstrap.sh <directory>
#   tools/verify_bootstrap.sh <file.so>
#   tools/verify_bootstrap.sh --compare <dir1> <dir2>

set -euo pipefail

GLIBC_TARGET_VERSION="2.42"
TARGET_TRIPLE="x86_64-buckos-linux-gnu"
ERRORS=0
WARNINGS=0
CHECKED=0

# Allowed NEEDED libraries (base system)
ALLOWED_NEEDED=(
    "libc.so.6"
    "libm.so.6"
    "libdl.so.2"
    "libpthread.so.0"
    "librt.so.1"
    "libz.so.1"
    "libgcc_s.so.1"
    "libstdc++.so.6"
    "ld-linux-x86-64.so.2"
    "linux-vdso.so.1"
)

# Host paths that must not appear
HOST_PATH_PATTERNS=(
    "/home/"
    "/usr/local/"
    "/opt/"
    "/nix/"
    "buck-out/"
    "/tmp/buck"
)

error() {
    echo "  ERROR: $*" >&2
    ERRORS=$((ERRORS + 1))
}

warn() {
    echo "  WARN:  $*" >&2
    WARNINGS=$((WARNINGS + 1))
}

info() {
    echo "  OK:    $*"
}

# Compare two glibc versions: returns 0 if $1 <= $2
version_le() {
    local v1="$1" v2="$2"
    # Strip GLIBC_ prefix
    v1="${v1#GLIBC_}"
    v2="${v2#GLIBC_}"

    # Compare as dotted version numbers
    local IFS='.'
    read -ra a <<< "$v1"
    read -ra b <<< "$v2"

    local max=${#a[@]}
    [[ ${#b[@]} -gt $max ]] && max=${#b[@]}

    for ((i = 0; i < max; i++)); do
        local ai=${a[i]:-0}
        local bi=${b[i]:-0}
        if ((ai < bi)); then return 0; fi
        if ((ai > bi)); then return 1; fi
    done
    return 0
}

check_elf() {
    local file="$1"
    CHECKED=$((CHECKED + 1))

    echo "Checking: $file"

    # 1. ELF architecture
    local file_type
    file_type=$(file -b "$file")
    if ! echo "$file_type" | grep -q "ELF 64-bit.*x86-64"; then
        error "$file: not ELF 64-bit x86-64 (got: $file_type)"
        return
    fi
    info "ELF 64-bit x86-64"

    # Skip further checks for static libraries and object files
    if echo "$file_type" | grep -q "relocatable"; then
        info "relocatable object — skipping dynamic checks"
        return
    fi

    # 2. RPATH/RUNPATH — no host paths
    local rpath
    rpath=$(readelf -d "$file" 2>/dev/null | grep -E 'RPATH|RUNPATH' || true)
    if [[ -n "$rpath" ]]; then
        for pattern in "${HOST_PATH_PATTERNS[@]}"; do
            if echo "$rpath" | grep -qF "$pattern"; then
                error "$file: host path in RPATH/RUNPATH: $rpath"
            fi
        done
        # Also check for absolute host library paths
        if echo "$rpath" | grep -qE '/usr/lib/(x86_64-linux-gnu|gcc)'; then
            error "$file: host distro library path in RPATH: $rpath"
        fi
    fi
    info "RPATH/RUNPATH clean"

    # 3. NEEDED libraries
    local needed
    needed=$(readelf -d "$file" 2>/dev/null | grep NEEDED | sed 's/.*\[//;s/\]//' || true)
    if [[ -n "$needed" ]]; then
        while IFS= read -r lib; do
            local found=0
            for allowed in "${ALLOWED_NEEDED[@]}"; do
                if [[ "$lib" == "$allowed" ]]; then
                    found=1
                    break
                fi
            done
            if [[ $found -eq 0 ]]; then
                warn "$file: unexpected NEEDED library: $lib"
            fi
        done <<< "$needed"
        info "NEEDED libraries verified"
    fi

    # 4. Glibc symbol version requirements
    local versions
    versions=$(readelf -V "$file" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' | sort -u || true)
    if [[ -n "$versions" ]]; then
        local max_ver=""
        while IFS= read -r ver; do
            ver_num="${ver#GLIBC_}"
            if ! version_le "$ver_num" "$GLIBC_TARGET_VERSION"; then
                error "$file: requires $ver > GLIBC_$GLIBC_TARGET_VERSION"
            fi
            if [[ -z "$max_ver" ]] || ! version_le "$ver_num" "${max_ver#GLIBC_}"; then
                max_ver="$ver"
            fi
        done <<< "$versions"
        if [[ -n "$max_ver" ]]; then
            info "max glibc requirement: $max_ver <= GLIBC_$GLIBC_TARGET_VERSION"
        fi
    fi

    # 5. Host paths in strings (best effort, skip very large files)
    local size
    size=$(stat -c%s "$file" 2>/dev/null || echo 0)
    if ((size < 50000000)); then
        for pattern in "${HOST_PATH_PATTERNS[@]}"; do
            if strings "$file" 2>/dev/null | grep -qF "$pattern"; then
                warn "$file: host path '$pattern' found in strings"
            fi
        done
    fi
}

# Find all ELF files in a directory
find_elfs() {
    local dir="$1"
    find "$dir" -type f \( -name '*.so' -o -name '*.so.*' -o -name '*.a' \
        -o -executable \) 2>/dev/null | while read -r f; do
        if file -b "$f" | grep -q "ELF"; then
            echo "$f"
        fi
    done
}

# Compare ABI compatibility between two directories
compare_abi() {
    local dir1="$1" dir2="$2"

    echo "=== ABI Comparison ==="
    echo "Dir 1: $dir1"
    echo "Dir 2: $dir2"
    echo

    # Find shared libraries common to both
    local libs1 libs2
    libs1=$(find "$dir1" -name '*.so*' -type f 2>/dev/null | xargs -I{} basename {} | sort -u)
    libs2=$(find "$dir2" -name '*.so*' -type f 2>/dev/null | xargs -I{} basename {} | sort -u)

    local common
    common=$(comm -12 <(echo "$libs1") <(echo "$libs2"))

    if [[ -z "$common" ]]; then
        echo "No common shared libraries found."
        return
    fi

    while IFS= read -r lib; do
        local f1 f2
        f1=$(find "$dir1" -name "$lib" -type f 2>/dev/null | head -1)
        f2=$(find "$dir2" -name "$lib" -type f 2>/dev/null | head -1)
        [[ -z "$f1" || -z "$f2" ]] && continue

        echo "Comparing: $lib"

        # Compare exported symbols
        local syms1 syms2
        syms1=$(nm -D "$f1" 2>/dev/null | grep ' T ' | awk '{print $3}' | sort)
        syms2=$(nm -D "$f2" 2>/dev/null | grep ' T ' | awk '{print $3}' | sort)

        local only1 only2
        only1=$(comm -23 <(echo "$syms1") <(echo "$syms2"))
        only2=$(comm -13 <(echo "$syms1") <(echo "$syms2"))

        if [[ -n "$only1" ]]; then
            warn "$lib: symbols in dir1 but not dir2: $(echo "$only1" | wc -l) symbols"
        fi
        if [[ -n "$only2" ]]; then
            warn "$lib: symbols in dir2 but not dir1: $(echo "$only2" | wc -l) symbols"
        fi

        # Compare ELF machine type
        local m1 m2
        m1=$(readelf -h "$f1" 2>/dev/null | grep Machine | awk '{print $2}')
        m2=$(readelf -h "$f2" 2>/dev/null | grep Machine | awk '{print $2}')
        if [[ "$m1" != "$m2" ]]; then
            error "$lib: machine type mismatch: $m1 vs $m2"
        else
            info "$lib: same machine type ($m1)"
        fi
    done <<< "$common"
}

# Main
case "${1:-}" in
    --compare)
        shift
        if [[ $# -lt 2 ]]; then
            echo "Usage: $0 --compare <dir1> <dir2>" >&2
            exit 1
        fi
        compare_abi "$1" "$2"
        ;;
    "")
        echo "Usage: $0 <directory|file> [--compare <dir1> <dir2>]" >&2
        exit 1
        ;;
    *)
        target="$1"
        if [[ -f "$target" ]]; then
            check_elf "$target"
        elif [[ -d "$target" ]]; then
            echo "=== Verifying ELF binaries in $target ==="
            echo
            while IFS= read -r f; do
                check_elf "$f"
                echo
            done < <(find_elfs "$target")
        else
            echo "error: $target is not a file or directory" >&2
            exit 1
        fi
        ;;
esac

echo
echo "=== Summary ==="
echo "Checked: $CHECKED files"
echo "Errors:  $ERRORS"
echo "Warnings: $WARNINGS"

if [[ $ERRORS -gt 0 ]]; then
    echo "FAIL"
    exit 1
fi

echo "PASS"
exit 0
