#!/bin/bash
# pkg-config wrapper that rewrites paths from .pc files to actual dependency locations
#
# Problem: .pc files contain prefix=/usr, so pkg-config --cflags returns -I/usr/include
# which finds host headers instead of our dependency headers in buck-out.
#
# Solution: Find which dependency provided the .pc file and rewrite /usr paths to
# point to that dependency's actual location.

REAL_PKGCONFIG=""
# Find the real pkg-config (skip ourselves)
for p in $(type -ap pkg-config); do
    if [ "$p" != "$0" ] && [ "$p" != "$T/bin/pkg-config" ]; then
        REAL_PKGCONFIG="$p"
        break
    fi
done

if [ -z "$REAL_PKGCONFIG" ]; then
    # Check TOOLCHAIN_PATH if set (bootstrap toolchain)
    if [ -n "$TOOLCHAIN_PATH" ]; then
        for dir in ${TOOLCHAIN_PATH//:/ }; do
            if [ -x "$dir/pkg-config" ]; then
                REAL_PKGCONFIG="$dir/pkg-config"
                break
            fi
        done
    fi
fi

if [ -z "$REAL_PKGCONFIG" ]; then
    # Fallback: try common locations
    for p in /usr/bin/pkg-config /bin/pkg-config; do
        if [ -x "$p" ]; then
            REAL_PKGCONFIG="$p"
            break
        fi
    done
fi

if [ -z "$REAL_PKGCONFIG" ]; then
    echo "pkg-config wrapper: cannot find real pkg-config" >&2
    exit 1
fi

# Get the output from real pkg-config
OUTPUT=$("$REAL_PKGCONFIG" "$@")
RC=$?

if [ $RC -ne 0 ]; then
    exit $RC
fi

# If no output or not a flag query, pass through unchanged
if [ -z "$OUTPUT" ]; then
    exit 0
fi

# For --cflags, --libs, --cflags-only-I, --libs-only-L queries, rewrite paths
case "$*" in
    *--cflags*|*--libs*|*--variable*)
        # Determine which package we're querying
        PKG_NAME=""
        for arg in "$@"; do
            case "$arg" in
                --*) ;;
                *) PKG_NAME="$arg"; break ;;
            esac
        done

        if [ -n "$PKG_NAME" ] && [ -n "$PKG_CONFIG_LIBDIR" ]; then
            # Find which pkgconfig directory has this package's .pc file
            IFS=':' read -ra PC_DIRS <<< "$PKG_CONFIG_LIBDIR"
            for pc_dir in "${PC_DIRS[@]}"; do
                if [ -f "$pc_dir/$PKG_NAME.pc" ]; then
                    # Extract the dependency root from the pkgconfig path
                    # e.g., /path/to/buck-out/.../pkg/usr/lib64/pkgconfig -> /path/to/buck-out/.../pkg
                    DEP_ROOT="${pc_dir%/usr/lib64/pkgconfig}"
                    DEP_ROOT="${DEP_ROOT%/usr/lib/pkgconfig}"
                    DEP_ROOT="${DEP_ROOT%/usr/share/pkgconfig}"
                    DEP_ROOT="${DEP_ROOT%/lib64/pkgconfig}"
                    DEP_ROOT="${DEP_ROOT%/lib/pkgconfig}"

                    if [ "$DEP_ROOT" != "$pc_dir" ]; then
                        # Rewrite /usr paths to point to dependency root
                        # -I/usr/include -> -I$DEP_ROOT/usr/include
                        # -L/usr/lib64 -> -L$DEP_ROOT/usr/lib64
                        # /usr/share/... -> $DEP_ROOT/usr/share/... (for pkgdatadir etc)
                        # Also handle //usr/... (double slash from pc_sysrootdir="/" + /usr)
                        OUTPUT=$(echo "$OUTPUT" | sed -e "s|-I/usr/include|-I$DEP_ROOT/usr/include|g" \
                                                      -e "s|-L/usr/lib64|-L$DEP_ROOT/usr/lib64|g" \
                                                      -e "s|-L/usr/lib|-L$DEP_ROOT/usr/lib|g" \
                                                      -e "s| /usr/include| $DEP_ROOT/usr/include|g" \
                                                      -e "s| /usr/lib| $DEP_ROOT/usr/lib|g" \
                                                      -e "s| /usr/share| $DEP_ROOT/usr/share|g" \
                                                      -e "s|^//usr/share|$DEP_ROOT/usr/share|g" \
                                                      -e "s|^//usr/include|$DEP_ROOT/usr/include|g" \
                                                      -e "s|^//usr/lib|$DEP_ROOT/usr/lib|g" \
                                                      -e "s|^/usr/share|$DEP_ROOT/usr/share|g" \
                                                      -e "s|^/usr/include|$DEP_ROOT/usr/include|g" \
                                                      -e "s|^/usr/lib|$DEP_ROOT/usr/lib|g")
                    fi
                    break
                fi
            done
        fi

        # Fix include paths that reference transitive dependency subdirectories
        # e.g., pango's .pc references -I.../pango/usr/include/harfbuzz but harfbuzz
        # is in a separate package. Search all deps for missing subdirectories.
        if [ -n "$DEP_BASE_DIRS" ]; then
            NEW_OUTPUT=""
            for token in $OUTPUT; do
                case "$token" in
                    -I*)
                        inc_path="${token#-I}"
                        if [ ! -d "$inc_path" ]; then
                            # Extract the subdirectory name (e.g., harfbuzz, freetype2)
                            subdir=$(basename "$inc_path")
                            found=false
                            IFS=':' read -ra ALL_DEPS <<< "$DEP_BASE_DIRS"
                            for dep in "${ALL_DEPS[@]}"; do
                                if [ -d "$dep/usr/include/$subdir" ]; then
                                    token="-I$dep/usr/include/$subdir"
                                    found=true
                                    break
                                fi
                            done
                        fi
                        ;;
                esac
                NEW_OUTPUT="$NEW_OUTPUT $token"
            done
            OUTPUT="${NEW_OUTPUT# }"
        fi
        ;;
esac

echo "$OUTPUT"
