#!/bin/bash
# provenance-stamp.sh - Embed build provenance into ELF binaries
# Sourced by the ebuild wrapper after src_install when BUCKOS_PROVENANCE_ENABLED=true.
#
# Writes:
#   $DESTDIR/.buckos-provenance.jsonl  — aggregate NDJSON (own + deps)
#   .note.package ELF section           — this package's record only

set -e

# ── 1. Build own provenance record ──────────────────────────────────────────

_prov_escape() {
    # Minimal JSON string escaping: backslash, double-quote, control chars
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g'
}

_prov_name="$(_prov_escape "$PN")"
_prov_version="$(_prov_escape "$PV")"
_prov_type="$(_prov_escape "${BUCKOS_PKG_TYPE:-}")"
_prov_target="$(_prov_escape "${BUCKOS_PKG_TARGET:-}")"
_prov_url="$(_prov_escape "${BUCKOS_PKG_SOURCE_URL:-}")"
_prov_sha="$(_prov_escape "${BUCKOS_PKG_SOURCE_SHA256:-}")"
_prov_graph_hash="$(_prov_escape "${BUCKOS_PKG_GRAPH_HASH:-}")"

_own_record="{\"name\":\"${_prov_name}\",\"version\":\"${_prov_version}\",\"type\":\"${_prov_type}\",\"target\":\"${_prov_target}\",\"sourceUrl\":\"${_prov_url}\",\"sourceSha256\":\"${_prov_sha}\",\"graphHash\":\"${_prov_graph_hash}\""

# ── 2. Append SLSA volatile fields if enabled ───────────────────────────────

if [ "${BUCKOS_SLSA_ENABLED:-false}" = "true" ]; then
    _build_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _build_host="$(hostname -f 2>/dev/null || hostname)"
    _own_record="${_own_record},\"buildTime\":\"$(_prov_escape "$_build_time")\",\"buildHost\":\"$(_prov_escape "$_build_host")\""
fi

# Close the record (without BOS_PROV) so we can hash it
_own_record_pre="${_own_record}}"

# ── 2b. Compute BOS_PROV — sha256 of sorted metadata JSON ──────────────────
# Hash the record with keys sorted, excluding BOS_PROV itself.

if command -v python3 >/dev/null 2>&1; then
    _bos_prov="$(printf '%s' "$_own_record_pre" | python3 -c "
import json, sys, hashlib
rec = json.loads(sys.stdin.read())
canonical = json.dumps(rec, sort_keys=True, separators=(',', ':'))
print(hashlib.sha256(canonical.encode()).hexdigest())
")"
elif command -v sha256sum >/dev/null 2>&1; then
    # Fallback: hash the raw record (not sorted, but deterministic since we control field order)
    _bos_prov="$(printf '%s' "$_own_record_pre" | sha256sum | awk '{print $1}')"
else
    _bos_prov=""
fi

_own_record="${_own_record},\"BOS_PROV\":\"${_bos_prov}\"}"

# ── 3. Scan dependency JSONL files ──────────────────────────────────────────

declare -A _seen_pkgs
_seen_pkgs["${_prov_name}|${_prov_version}"]=1
_aggregate=""

if [ -n "${_EBUILD_DEP_DIRS:-}" ]; then
    for _dep_dir in $_EBUILD_DEP_DIRS; do
        _jsonl="$_dep_dir/.buckos-provenance.jsonl"
        [ -f "$_jsonl" ] || continue
        while IFS= read -r _line; do
            [ -z "$_line" ] && continue
            # Extract name and version for dedup (tolerate optional whitespace)
            _dep_name="$(printf '%s' "$_line" | sed -n 's/.*"name" *: *"\([^"]*\)".*/\1/p')"
            _dep_ver="$(printf '%s' "$_line" | sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p')"
            _key="${_dep_name}|${_dep_ver}"
            if [ -z "${_seen_pkgs[$_key]+x}" ]; then
                _seen_pkgs["$_key"]=1
                _aggregate="${_aggregate}${_line}
"
            fi
        done < "$_jsonl"
    done
fi

# ── 4. Write aggregate NDJSON ────────────────────────────────────────────────

mkdir -p "$DESTDIR"
{
    printf '%s\n' "$_own_record"
    [ -n "$_aggregate" ] && printf '%s' "$_aggregate"
} > "$DESTDIR/.buckos-provenance.jsonl"

# ── 5. Stamp ELF binaries with .note.package ────────────────────────────────

_objcopy="${OBJCOPY:-objcopy}"
if ! command -v "$_objcopy" >/dev/null 2>&1; then
    echo "provenance-stamp: objcopy not found, skipping ELF stamping"
    return 0 2>/dev/null || exit 0
fi

_stamp_tmp="$T/.buckos-note-package.json"
printf '%s\n' "$_own_record" > "$_stamp_tmp"

# Find ELF executables and shared objects in DESTDIR
_stamp_elf() {
    local _elf="$1"
    # Verify it's actually an ELF file
    local _magic
    _magic="$(head -c 4 "$_elf" 2>/dev/null)" || return
    case "$_magic" in
        $'\x7fELF') ;;
        *) return ;;
    esac
    "$_objcopy" --add-section .note.package="$_stamp_tmp" \
                --set-section-flags .note.package=noload,readonly \
                "$_elf" 2>/dev/null || {
        echo "provenance-stamp: warning: failed to stamp $_elf"
    }
}

_fd_bin=""
command -v fd >/dev/null 2>&1 && _fd_bin=fd
[ -z "$_fd_bin" ] && command -v fdfind >/dev/null 2>&1 && _fd_bin=fdfind

if [ -n "$_fd_bin" ]; then
    # .so files (exact extension)
    while IFS= read -r _elf; do
        [ -n "$_elf" ] && _stamp_elf "$_elf"
    done < <("$_fd_bin" --type f --no-ignore --hidden -e so '' "$DESTDIR" 2>/dev/null)
    # .so.N versioned shared libs (regex)
    while IFS= read -r _elf; do
        [ -n "$_elf" ] && _stamp_elf "$_elf"
    done < <("$_fd_bin" --type f --no-ignore --hidden '\.so\.' "$DESTDIR" 2>/dev/null)
    # executable files (--type x implies --type f)
    while IFS= read -r _elf; do
        [ -n "$_elf" ] && _stamp_elf "$_elf"
    done < <("$_fd_bin" --type x --no-ignore --hidden '' "$DESTDIR" 2>/dev/null)
else
    while IFS= read -r -d '' _elf; do
        _stamp_elf "$_elf"
    done < <(find "$DESTDIR" -type f \( -executable -o -name '*.so' -o -name '*.so.*' \) -print0 2>/dev/null)
fi

echo "provenance-stamp: stamped ELF binaries in $DESTDIR"
