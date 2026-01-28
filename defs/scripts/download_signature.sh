#!/bin/bash
# download_signature.sh - Download GPG signature trying multiple extensions
# Tries .sig, .asc, .sign extensions and outputs the first successful one
#
# Arguments:
#   $1 - Output file path
#   $2 - Base URL (source archive URL, signature extension will be appended)
#   $3 - Expected SHA256 checksum of signature file

set -e

OUT_FILE="$1"
BASE_URL="$2"
EXPECTED_SHA256="$3"
PROXY="$4"

# === GUARD RAILS: Validate inputs ===
if [[ -z "$OUT_FILE" ]]; then
    echo "ERROR: Output file path not specified" >&2
    exit 1
fi
if [[ -z "$BASE_URL" ]]; then
    echo "ERROR: Base URL not specified" >&2
    exit 1
fi
if [[ -z "$EXPECTED_SHA256" ]]; then
    echo "ERROR: Expected SHA256 not specified" >&2
    exit 1
fi

# Build curl proxy args if proxy is set
CURL_PROXY_ARGS=""
if [ -n "$PROXY" ]; then
    CURL_PROXY_ARGS="--proxy $PROXY"
fi

# Extensions to try (in order of preference)
EXTENSIONS=(".sig" ".asc" ".sign")

for ext in "${EXTENSIONS[@]}"; do
    SIG_URL="${BASE_URL}${ext}"
    echo "Trying: $SIG_URL"

    # Try to download
    if curl $CURL_PROXY_ARGS -fsSL --retry 3 --retry-delay 2 -o "$OUT_FILE" "$SIG_URL" 2>/dev/null; then
        # Verify SHA256
        ACTUAL_SHA256=$(sha256sum "$OUT_FILE" | cut -d' ' -f1)

        if [ "$ACTUAL_SHA256" = "$EXPECTED_SHA256" ]; then
            echo "Success: Downloaded from $SIG_URL"
            echo "SHA256 verified: $ACTUAL_SHA256"
            exit 0
        else
            echo "SHA256 mismatch for $SIG_URL"
            echo "  Expected: $EXPECTED_SHA256"
            echo "  Actual:   $ACTUAL_SHA256"
            rm -f "$OUT_FILE"
        fi
    else
        echo "Failed to download: $SIG_URL"
    fi
done

echo "Error: Could not download signature from any extension (.sig, .asc, .sign)" >&2
echo "Base URL: $BASE_URL" >&2
exit 1
