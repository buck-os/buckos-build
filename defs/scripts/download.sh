#!/bin/bash
# Download and extract source archives
# Arguments:
#   $1  - Output directory
#   $2  - Source URL
#   $3  - Expected SHA256 checksums (space-separated)
#   $4  - Signature URI (optional)
#   $5  - GPG key (optional)
#   $6  - GPG keyring (optional)
#   $7  - Signature required (1 or empty)
#   $8  - Exclude args for tar (e.g., --exclude='pattern')
#   $9  - Strip components (default: 1)
#   $10 - Do extract (1 or 0)

set -e

# === GUARD RAILS: Validate inputs ===
if [[ -z "$1" ]]; then
    echo "ERROR: Output directory not specified" >&2
    exit 1
fi
if [[ -z "$2" ]]; then
    echo "ERROR: Source URL not specified" >&2
    exit 1
fi
if [[ -z "$3" ]]; then
    echo "ERROR: Expected checksum not specified" >&2
    exit 1
fi

mkdir -p "$1"
cd "$1"

# Proxy can be passed as argument $11, or via environment variables
PROXY="${11:-}"

# Also check environment variables if no proxy arg provided
if [ -z "$PROXY" ]; then
    PROXY="${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}}"
fi

# Build curl proxy args if proxy is set
CURL_PROXY_ARGS=""
if [ -n "$PROXY" ]; then
    CURL_PROXY_ARGS="--proxy $PROXY"
fi

# Concurrent download limiting using flock-based semaphore
# Reads BUCKOS_MAX_CONCURRENT_DOWNLOADS from environment (default: 4)
MAX_CONCURRENT_DOWNLOADS="${BUCKOS_MAX_CONCURRENT_DOWNLOADS:-4}"
LOCK_DIR="${BUCKOS_DOWNLOAD_LOCK_DIR:-/tmp/buckos-download-locks}"

# Function to acquire a download slot using flock
acquire_download_slot() {
    if ! command -v flock &> /dev/null; then
        # flock not available, skip limiting
        return 0
    fi

    mkdir -p "$LOCK_DIR"

    # Try to acquire any available slot from the pool
    for i in $(seq 0 $((MAX_CONCURRENT_DOWNLOADS - 1))); do
        LOCK_FILE="$LOCK_DIR/download-slot-$i.lock"
        exec {LOCK_FD}>>"$LOCK_FILE"
        if flock -n "$LOCK_FD" 2>/dev/null; then
            # Successfully acquired lock, store FD for later release
            export BUCKOS_DOWNLOAD_LOCK_FD="$LOCK_FD"
            export BUCKOS_DOWNLOAD_LOCK_FILE="$LOCK_FILE"
            return 0
        fi
        exec {LOCK_FD}>&-
    done

    # All slots busy, wait for any slot to become available
    for i in $(seq 0 $((MAX_CONCURRENT_DOWNLOADS - 1))); do
        LOCK_FILE="$LOCK_DIR/download-slot-$i.lock"
        exec {LOCK_FD}>>"$LOCK_FILE"
        if flock "$LOCK_FD" 2>/dev/null; then
            export BUCKOS_DOWNLOAD_LOCK_FD="$LOCK_FD"
            export BUCKOS_DOWNLOAD_LOCK_FILE="$LOCK_FILE"
            return 0
        fi
        exec {LOCK_FD}>&-
    done

    # Fallback: proceed without lock
    return 0
}

# Function to release download slot
release_download_slot() {
    if [ -n "${BUCKOS_DOWNLOAD_LOCK_FD:-}" ]; then
        flock -u "$BUCKOS_DOWNLOAD_LOCK_FD" 2>/dev/null || true
        exec {BUCKOS_DOWNLOAD_LOCK_FD}>&- 2>/dev/null || true
    fi
}

# Set up trap to release lock on exit
trap release_download_slot EXIT

# Acquire download slot (blocks if all slots are in use)
acquire_download_slot

# Download with original filename
URL="$2"
FILENAME="${URL##*/}"

echo "Downloading: $URL"
if ! curl -fL --connect-timeout 30 --max-time 600 $CURL_PROXY_ARGS -o "$FILENAME" "$URL"; then
    echo "ERROR: Download failed for URL: $URL" >&2
    echo "  curl exit code: $?" >&2
    echo "  Check that the URL is correct and accessible." >&2
    rm -f "$FILENAME"  # Clean up partial download
    exit 1
fi

# === GUARD RAIL: Verify download produced a file ===
if [[ ! -f "$FILENAME" ]]; then
    echo "ERROR: Download completed but file not found: $FILENAME" >&2
    exit 1
fi
if [[ ! -s "$FILENAME" ]]; then
    echo "ERROR: Downloaded file is empty: $FILENAME" >&2
    echo "  URL: $URL" >&2
    rm -f "$FILENAME"
    exit 1
fi

echo "Downloaded: $FILENAME ($(stat -c%s "$FILENAME" 2>/dev/null || stat -f%z "$FILENAME") bytes)"

# Strip components setting (passed as $9)
STRIP_COMPONENTS="${9:-1}"

# Verify checksum
EXPECTED_CHECKSUMS="$3"
if [ -z "$EXPECTED_CHECKSUMS" ]; then
    echo "ERROR: No checksum provided" >&2
    exit 1
fi

# Compute actual checksum
ACTUAL_CHECKSUM=$(sha256sum "$FILENAME" | awk '{print $1}')

# Compare against list of valid checksums (space-separated)
CHECKSUM_MATCHED=false
for EXPECTED in $EXPECTED_CHECKSUMS; do
    if [ "$EXPECTED" = "$ACTUAL_CHECKSUM" ]; then
        CHECKSUM_MATCHED=true
        echo "Checksum verification passed: $ACTUAL_CHECKSUM"
        break
    fi
done

if [ "$CHECKSUM_MATCHED" = false ]; then
    echo "Checksum verification FAILED" >&2
    echo "  Expected: $EXPECTED_CHECKSUMS" >&2
    echo "  Actual:   $ACTUAL_CHECKSUM" >&2
    echo "  File:     $FILENAME" >&2
    exit 1
fi

# Verify GPG signature if provided
SIGNATURE_URI="$4"
GPG_KEY="$5"
GPG_KEYRING="$6"
SIG_REQUIRED="$7"
EXCLUDE_ARGS="$8"

# Function to try signature verification
verify_signature() {
    local SIG_URL="$1"
    local SIG_FILENAME="${SIG_URL##*/}"

    # Try to download signature file
    if curl -L $CURL_PROXY_ARGS -f -o "$SIG_FILENAME" "$SIG_URL" 2>/dev/null; then
        echo "Found signature file: $SIG_URL"

        # Check if the downloaded file is actually a GPG signature
        FILETYPE=$(file -b "$SIG_FILENAME")
        if [[ "$FILETYPE" == *"HTML"* ]] || [[ "$FILETYPE" == *"ASCII text"* && ! "$FILETYPE" =~ "PGP" ]]; then
            if head -1 "$SIG_FILENAME" | grep -q -i '<!DOCTYPE\|<html\|<head'; then
                echo "Signature file is HTML (likely 404/redirect), skipping verification"
                rm "$SIG_FILENAME"
                return 1
            fi
        fi

        # Verify the signature is valid OpenPGP data
        if ! gpg --batch --list-packets "$SIG_FILENAME" >/dev/null 2>&1; then
            echo "Downloaded file is not a valid GPG signature, skipping verification"
            rm "$SIG_FILENAME"
            return 1
        fi

        # Setup GPG options
        GPG_OPTS="--batch --no-default-keyring"

        if [ -n "$GPG_KEYRING" ]; then
            echo "Using keyring: $GPG_KEYRING"
            GPG_OPTS="$GPG_OPTS --keyring $GPG_KEYRING"
        fi

        # Import key if specified
        if [ -n "$GPG_KEY" ]; then
            echo "Importing GPG key: $GPG_KEY"
            gpg $GPG_OPTS --keyserver hkps://keys.openpgp.org --recv-keys "$GPG_KEY" 2>&1 | grep -v "already in keyring" || true
        fi

        # Verify the signature
        echo "Verifying GPG signature..."
        GPG_OUTPUT=$(gpg $GPG_OPTS --verify "$SIG_FILENAME" "$FILENAME" 2>&1)
        GPG_EXIT=$?

        if [ $GPG_EXIT -eq 0 ]; then
            echo "Signature verification PASSED"
            rm "$SIG_FILENAME"
            return 0
        else
            echo "Signature verification FAILED" >&2
            echo "  File:         $FILENAME" >&2
            echo "  Signature:    $SIG_FILENAME" >&2
            echo "  Signature URL: $SIG_URL" >&2
            if [ -n "$GPG_KEY" ]; then
                echo "  Expected Key: $GPG_KEY" >&2
            fi
            echo "" >&2
            echo "GPG output:" >&2
            echo "$GPG_OUTPUT" >&2
            echo "" >&2
            echo "Fix options:" >&2
            echo "  1. Disable GPG verification: Set signature_required=False in BUCK file" >&2
            echo "  2. Import the correct key: gpg --recv-keys <KEY_ID>" >&2
            echo "  3. Check if signature URL is correct" >&2
            rm "$SIG_FILENAME"
            exit 1
        fi
    fi
    return 1
}

# Check for global USE flag override via environment variable
if [ -n "$BUCKOS_VERIFY_SIGNATURES" ]; then
    if [ "$BUCKOS_VERIFY_SIGNATURES" = "1" ] || [ "$BUCKOS_VERIFY_SIGNATURES" = "true" ]; then
        SIG_REQUIRED="1"
    elif [ "$BUCKOS_VERIFY_SIGNATURES" = "0" ] || [ "$BUCKOS_VERIFY_SIGNATURES" = "false" ]; then
        SIG_REQUIRED=""
        SIGNATURE_URI=""
    fi
fi

# Try signature verification
if [ -n "$SIGNATURE_URI" ]; then
    verify_signature "$SIGNATURE_URI" || exit 1
elif [ -n "$SIG_REQUIRED" ]; then
    echo "Auto-detecting signature file..."
    TRIED=0
    for ext in .asc .sig .sign; do
        if verify_signature "${URL}${ext}"; then
            TRIED=1
            break
        fi
    done
    if [ $TRIED -eq 0 ]; then
        echo "No signature file found (tried .asc, .sig, .sign extensions)"
    fi
fi

# Check if extraction is disabled (arg $10)
DO_EXTRACT="${10}"
if [ "$DO_EXTRACT" = "0" ]; then
    echo "Extraction disabled - keeping file as-is: $FILENAME"
    exit 0
fi

# Detect actual file type (not just extension)
FILETYPE=$(file -b "$FILENAME")

# Extract based on actual file type
if [[ "$FILETYPE" == *"gzip compressed"* ]]; then
    echo "Detected: gzip compressed tarball (strip-components=$STRIP_COMPONENTS)"
    tar xzf "$FILENAME" --strip-components=$STRIP_COMPONENTS $EXCLUDE_ARGS
    rm "$FILENAME"
elif [[ "$FILETYPE" == *"XZ compressed"* ]]; then
    echo "Detected: XZ compressed tarball (strip-components=$STRIP_COMPONENTS)"
    tar xJf "$FILENAME" --strip-components=$STRIP_COMPONENTS $EXCLUDE_ARGS
    rm "$FILENAME"
elif [[ "$FILETYPE" == *"bzip2 compressed"* ]]; then
    echo "Detected: bzip2 compressed tarball (strip-components=$STRIP_COMPONENTS)"
    tar xjf "$FILENAME" --strip-components=$STRIP_COMPONENTS $EXCLUDE_ARGS
    rm "$FILENAME"
elif [[ "$FILETYPE" == *"POSIX tar archive"* ]]; then
    echo "Detected: uncompressed tar archive (strip-components=$STRIP_COMPONENTS)"
    tar xf "$FILENAME" --strip-components=$STRIP_COMPONENTS $EXCLUDE_ARGS
    rm "$FILENAME"
elif [[ "$FILETYPE" == *"lzip compressed"* ]]; then
    echo "Detected: lzip compressed tarball (strip-components=$STRIP_COMPONENTS)"
    lzip -dc "$FILENAME" | tar xf - --strip-components=$STRIP_COMPONENTS $EXCLUDE_ARGS
    rm "$FILENAME"
elif [[ "$FILETYPE" == *"Zip archive"* ]]; then
    echo "Detected: Zip archive"
    unzip -q "$FILENAME"
    if [ $(ls -1 | wc -l) -eq 1 ] && [ -d "$(ls -1)" ]; then
        mv "$(ls -1)"/* . && rmdir "$(ls -1)"
    fi
    rm "$FILENAME"
elif [[ "$FILETYPE" == *"Debian binary package"* ]]; then
    echo "Detected: Debian binary package (.deb)"
    echo "Keeping file as-is for binary_package extraction"
elif [[ "$FILETYPE" == *"POSIX shell script"* ]] || [[ "$FILETYPE" == *"shell script"* ]] || [[ "$FILENAME" == *.run ]]; then
    echo "Detected: Self-extracting shell script (.run)"
    echo "Keeping file as-is for binary_package extraction"
elif [[ "$FILETYPE" == *"HTML"* ]]; then
    echo "Error: Downloaded file appears to be HTML, not an archive!" >&2
    echo "File type: $FILETYPE" >&2
    echo "This usually means the URL returned an error page instead of the file." >&2
    head -20 "$FILENAME" >&2
    exit 1
elif [[ "$FILETYPE" == *"ASCII text"* ]] || [[ "$FILETYPE" == *"C source"* ]] || [[ "$FILETYPE" == *"source"* ]] || [[ "$FILETYPE" == *"Unicode text"* ]]; then
    if [[ "$FILENAME" =~ \.(c|h|cpp|hpp|cc|cxx|py|sh|pl|rb|java|rs|go|js|ts|pem|crt|key)$ ]]; then
        echo "Detected: Single source file - $FILENAME"
        echo "Keeping file as-is (no extraction needed)"
    else
        echo "Error: Downloaded file appears to be ASCII text, not an archive!" >&2
        echo "File type: $FILETYPE" >&2
        echo "Filename: $FILENAME" >&2
        head -20 "$FILENAME" >&2
        exit 1
    fi
else
    echo "Unknown file type: $FILETYPE"
    if [[ "$FILENAME" == *.zip ]]; then
        echo "Attempting unzip based on filename extension..."
        if unzip -q "$FILENAME" 2>/dev/null; then
            if [ $(ls -1 | wc -l) -eq 1 ] && [ -d "$(ls -1)" ]; then
                mv "$(ls -1)"/* . && rmdir "$(ls -1)"
            fi
            echo "Successfully extracted with unzip"
            rm "$FILENAME"
        else
            echo "Error: Could not extract zip archive" >&2
            exit 1
        fi
    else
        echo "Attempting tar with auto-compression detection..."
        if tar xaf "$FILENAME" --strip-components=$STRIP_COMPONENTS 2>/dev/null; then
            echo "Successfully extracted with tar auto-detect"
            rm "$FILENAME"
        else
            echo "Error: Could not extract archive" >&2
            echo "File type: $FILETYPE" >&2
            exit 1
        fi
    fi
fi
