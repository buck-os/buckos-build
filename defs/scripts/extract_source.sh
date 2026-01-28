#!/bin/bash
# extract_source.sh - Extract archives and verify GPG signatures
# This script handles extraction and GPG verification for archives downloaded via http_file
#
# Arguments:
#   $1  - Output directory
#   $2  - Archive file path (from http_file)
#   $3  - Signature file path (from http_file, or empty)
#   $4  - GPG key ID (optional)
#   $5  - GPG keyring path (optional)
#   $6  - Exclude args for tar (e.g., --exclude='pattern')
#   $7  - Strip components (default: 1)
#   $8  - Do extract (1 or 0)

set -e

OUT_DIR="$1"
ARCHIVE="$2"
SIGNATURE="$3"
GPG_KEY="$4"
GPG_KEYRING="$5"
EXCLUDE_ARGS="$6"
STRIP_COMPONENTS="${7:-1}"
DO_EXTRACT="${8:-1}"

# === GUARD RAILS: Validate inputs early ===
if [[ -z "$OUT_DIR" ]]; then
    echo "ERROR: Output directory not specified" >&2
    exit 1
fi

if [[ -z "$ARCHIVE" ]]; then
    echo "ERROR: Archive path not specified" >&2
    exit 1
fi

# Convert to absolute paths before changing directories
if [[ "$ARCHIVE" != /* ]]; then
    ARCHIVE="$(pwd)/$ARCHIVE"
fi
if [[ -n "$SIGNATURE" && "$SIGNATURE" != /* ]]; then
    SIGNATURE="$(pwd)/$SIGNATURE"
fi

# === GUARD RAIL: Check archive exists before proceeding ===
if [[ ! -f "$ARCHIVE" ]]; then
    echo "ERROR: Archive file does not exist: $ARCHIVE" >&2
    echo "  This usually means the download failed or the path is incorrect." >&2
    echo "  Check that the download_source URL and sha256 are correct." >&2
    exit 1
fi

# === GUARD RAIL: Check archive is not empty ===
if [[ ! -s "$ARCHIVE" ]]; then
    echo "ERROR: Archive file is empty: $ARCHIVE" >&2
    echo "  The download may have failed silently." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

# Copy archive to working directory with original filename
FILENAME=$(basename "$ARCHIVE")
if ! cp "$ARCHIVE" "$FILENAME"; then
    echo "ERROR: Failed to copy archive to working directory" >&2
    echo "  Source: $ARCHIVE" >&2
    echo "  Dest: $(pwd)/$FILENAME" >&2
    exit 1
fi

# Disable glob expansion for exclude patterns (they contain * that shouldn't be expanded by bash)
set -f

# Verify GPG signature if provided
if [ -n "$SIGNATURE" ] && [ -f "$SIGNATURE" ]; then
    echo "Verifying GPG signature..."

    # Check if the signature file is valid OpenPGP data
    if ! gpg --batch --list-packets "$SIGNATURE" >/dev/null 2>&1; then
        echo "Warning: Signature file is not valid GPG data, skipping verification"
    else
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
        GPG_OUTPUT=$(gpg $GPG_OPTS --verify "$SIGNATURE" "$FILENAME" 2>&1)
        GPG_EXIT=$?

        if [ $GPG_EXIT -eq 0 ]; then
            echo "GPG signature verification PASSED"
        else
            echo "GPG signature verification FAILED" >&2
            echo "  File:      $FILENAME" >&2
            echo "  Signature: $SIGNATURE" >&2
            if [ -n "$GPG_KEY" ]; then
                echo "  Expected Key: $GPG_KEY" >&2
            fi
            echo "" >&2
            echo "GPG output:" >&2
            echo "$GPG_OUTPUT" >&2
            exit 1
        fi
    fi
fi

# Check if extraction is disabled
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
elif [[ "$FILETYPE" == *"Zstandard compressed"* ]]; then
    echo "Detected: Zstandard compressed tarball (strip-components=$STRIP_COMPONENTS)"
    tar --zstd -xf "$FILENAME" --strip-components=$STRIP_COMPONENTS $EXCLUDE_ARGS
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
    # Handle single top-level directory
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
    # Try unzip if filename ends in .zip (some zips report as "data")
    if [[ "$FILENAME" == *.zip ]]; then
        echo "Attempting unzip based on .zip extension..."
        if unzip -q "$FILENAME" 2>/dev/null; then
            echo "Successfully extracted with unzip"
            # Handle single top-level directory
            if [ $(ls -1 | wc -l) -eq 1 ] && [ -d "$(ls -1)" ]; then
                mv "$(ls -1)"/* . && rmdir "$(ls -1)"
            fi
            rm "$FILENAME"
        else
            echo "Error: Could not extract zip archive" >&2
            echo "File type: $FILETYPE" >&2
            exit 1
        fi
    else
        echo "Attempting tar with auto-compression detection..."
        if tar xaf "$FILENAME" --strip-components=$STRIP_COMPONENTS $EXCLUDE_ARGS 2>/dev/null; then
            echo "Successfully extracted with tar auto-detect"
            rm "$FILENAME"
        else
            echo "Error: Could not extract archive" >&2
            echo "File type: $FILETYPE" >&2
            exit 1
        fi
    fi
fi

# Re-enable glob expansion
set +f

# Fix permissions on extracted files
# Archives from different sources may have restrictive permissions that
# cause build failures. Ensure all files are readable and writable.
chmod -R u+rwX . 2>/dev/null || true

# Fix filenames with escape sequences (e.g., \x2d -> -)
# Buck2 cannot handle files with escape sequences in their names
# These are literal backslash-x sequences in the filenames, not actual escape chars
# First try find with -name pattern, then try grep-based approach as fallback
RENAMED_COUNT=0

# Method 1: Find files with \x in name using -name (may not work on all systems)
find . -name '*\x*' 2>/dev/null | while read -r file; do
    # Decode \x2d (hyphen), \x40 (@), etc. to their actual characters
    newname=$(echo "$file" | sed 's/\\x2d/-/g; s/\\x40/@/g; s/\\x2e/./g')
    if [ "$file" != "$newname" ]; then
        mkdir -p "$(dirname "$newname")"
        mv "$file" "$newname" 2>/dev/null && echo "Renamed: $file -> $newname" && RENAMED_COUNT=$((RENAMED_COUNT+1))
    fi
done

# Method 2: Use find with -print0 and grep to catch files the -name pattern missed
find . -print0 2>/dev/null | tr '\0' '\n' | grep '\\x' | while read -r file; do
    if [ -e "$file" ]; then
        # Decode \x2d (hyphen), \x40 (@), etc. to their actual characters
        newname=$(echo "$file" | sed 's/\\x2d/-/g; s/\\x40/@/g; s/\\x2e/./g')
        if [ "$file" != "$newname" ]; then
            mkdir -p "$(dirname "$newname")"
            mv "$file" "$newname" 2>/dev/null && echo "Renamed: $file -> $newname"
        fi
    fi
done

# Method 3: Brute force - list all files and check each one
# This handles cases where the filesystem represents the backslash differently
for file in $(find . -type f -o -type d 2>/dev/null); do
    case "$file" in
        *x2d*|*x40*|*x2e*)
            # Check if it's a literal \x sequence (4-char sequence with backslash)
            if echo "$file" | grep -q '\\x[0-9a-fA-F][0-9a-fA-F]'; then
                newname=$(echo "$file" | sed 's/\\x2d/-/g; s/\\x40/@/g; s/\\x2e/./g')
                if [ "$file" != "$newname" ] && [ -e "$file" ]; then
                    mkdir -p "$(dirname "$newname")"
                    mv "$file" "$newname" 2>/dev/null && echo "Renamed: $file -> $newname"
                fi
            fi
            ;;
    esac
done

echo "Extraction complete: $(find . -type f | wc -l) files"
