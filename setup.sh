#!/usr/bin/env bash
set -euo pipefail

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_YES=false
DISTRO=""
PACKAGES=()

detect_distro() {
    if [ ! -f /etc/os-release ]; then
        echo "Error: /etc/os-release not found. Cannot detect distribution." >&2
        exit 1
    fi

    # shellcheck source=/dev/null
    . /etc/os-release

    case "${ID:-}" in
        arch|archarm)
            DISTRO="arch" ;;
        debian|ubuntu|linuxmint|pop)
            DISTRO="debian" ;;
        fedora|rhel|centos|rocky|alma)
            DISTRO="fedora" ;;
        gentoo)
            DISTRO="gentoo" ;;
        *)
            # Check ID_LIKE for derivatives
            case "${ID_LIKE:-}" in
                *arch*)   DISTRO="arch" ;;
                *debian*) DISTRO="debian" ;;
                *fedora*|*rhel*) DISTRO="fedora" ;;
                *gentoo*) DISTRO="gentoo" ;;
                *)
                    echo "Error: Unsupported distribution: ${ID:-unknown} (ID_LIKE=${ID_LIKE:-})" >&2
                    echo "Supported: Arch, Debian/Ubuntu, Fedora/RHEL, Gentoo" >&2
                    exit 1
                    ;;
            esac
            ;;
    esac
}

define_packages() {
    case "$DISTRO" in
        arch)
            PACKAGES=(
                base-devel cmake meson ninja python perl m4 autoconf automake
                libtool pkg-config curl tar xz bzip2 gzip lzip zstd file patch
                unzip gawk sed grep diffutils findutils coreutils bash gettext
                texinfo bison flex gperf help2man linux-api-headers git gnupg
                fd ripgrep
            )
            # zlib-ng-compat (e.g. CachyOS) is a drop-in replacement for zlib
            if pacman -Qi zlib-ng-compat &>/dev/null; then
                PACKAGES+=(zlib-ng-compat)
            else
                PACKAGES+=(zlib)
            fi
            # rustup provides cargo/rustc and conflicts with the rust package
            if pacman -Qi rustup &>/dev/null; then
                PACKAGES+=(rustup)
            else
                PACKAGES+=(rust)
            fi
            ;;
        debian)
            PACKAGES=(
                build-essential binutils cmake meson ninja-build python3 perl
                m4 autoconf automake libtool pkg-config curl tar xz-utils
                bzip2 gzip lzip zstd file patch unzip util-linux gawk sed grep
                diffutils findutils coreutils bash gettext texinfo bison flex
                gperf help2man zlib1g-dev linux-libc-dev git gnupg
                cargo fd-find ripgrep
                ima-evm-utils
            )
            ;;
        fedora)
            PACKAGES=(
                gcc gcc-c++ make binutils cmake meson ninja-build python3 perl
                m4 autoconf automake libtool pkgconf curl tar xz bzip2 gzip
                lzip zstd file patch unzip util-linux-core gawk sed grep
                diffutils findutils coreutils bash gettext texinfo bison flex
                gperf help2man zlib-devel kernel-headers glibc-static git gnupg2
                cargo fd-find ripgrep
                ima-evm-utils
            )
            ;;
        gentoo)
            PACKAGES=(
                sys-devel/gcc sys-devel/binutils dev-build/cmake dev-build/meson
                dev-build/ninja dev-lang/python dev-lang/perl sys-devel/m4
                dev-build/autoconf dev-build/automake dev-build/libtool
                virtual/pkgconfig net-misc/curl app-arch/tar app-arch/xz-utils
                app-arch/bzip2 app-arch/gzip app-arch/lzip app-arch/zstd
                sys-apps/file sys-devel/patch app-arch/unzip sys-apps/gawk
                sys-apps/sed sys-apps/grep sys-apps/diffutils sys-apps/findutils
                sys-apps/coreutils app-shells/bash sys-devel/gettext
                sys-apps/texinfo sys-devel/bison sys-devel/flex dev-util/gperf
                sys-apps/help2man sys-libs/zlib sys-kernel/linux-headers
                dev-vcs/git app-crypt/gnupg dev-lang/rust
                sys-apps/fd sys-apps/ripgrep
                app-crypt/ima-evm-utils
            )
            ;;
    esac
}

show_plan() {
    echo "BuckOS Host Toolchain Setup"
    echo "==========================="
    echo "Distro:     $DISTRO"
    echo "Packages:   ${#PACKAGES[@]} packages via ${PKG_CMD}"
    echo "Buck2:      ~/.local/bin/buck2"
    echo ""
}

install_packages() {
    echo "--- Installing system packages ---"
    case "$DISTRO" in
        arch)
            # Fresh Docker containers may lack initialized keyring
            if [ ! -d /etc/pacman.d/gnupg ] || [ ! -f /etc/pacman.d/gnupg/trustdb.gpg ]; then
                $SUDO pacman-key --init
                $SUDO pacman-key --populate
            fi
            $SUDO pacman -Syu --needed --noconfirm "${PACKAGES[@]}"
            ;;
        debian)
            $SUDO apt-get update -qq
            DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y "${PACKAGES[@]}"
            ;;
        fedora)
            $SUDO dnf install -y "${PACKAGES[@]}"
            ;;
        gentoo)
            $SUDO emerge --noreplace "${PACKAGES[@]}"
            ;;
    esac
    echo ""
}

install_uv() {
    if command -v uv &>/dev/null; then
        echo "--- uv already installed: $(command -v uv) ---"
        echo ""
        return
    fi

    echo "--- Installing uv ---"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    echo ""
}

install_buck2() {
    if command -v buck2 &>/dev/null; then
        echo "--- Buck2 already installed: $(command -v buck2) ---"
        echo ""
        return
    fi

    echo "--- Installing Buck2 ---"
    local arch
    case "$(uname -m)" in
        x86_64)  arch="x86_64" ;;
        aarch64) arch="aarch64" ;;
        *)
            echo "Error: Unsupported architecture: $(uname -m)" >&2
            exit 1
            ;;
    esac

    local buck2_dir="$HOME/.local/bin"
    mkdir -p "$buck2_dir"

    local url="https://github.com/facebook/buck2/releases/download/latest/buck2-${arch}-unknown-linux-gnu.zst"
    echo "Downloading from: $url"
    curl -sL "$url" | zstd -d -o "$buck2_dir/buck2"
    chmod +x "$buck2_dir/buck2"

    if [[ ":$PATH:" != *":$buck2_dir:"* ]]; then
        export PATH="$buck2_dir:$PATH"
        echo "Added $buck2_dir to PATH for this session."
        echo "To make it permanent, add to your shell profile:"
        echo "  export PATH=\"$buck2_dir:\$PATH\""
    fi
    echo ""
}

download_seed() {
    local seed_path="$SCRIPT_DIR/seed-toolchain.tar.zst"

    if [ -f "$seed_path" ]; then
        echo "--- Seed toolchain already downloaded ---"
        echo ""
        return
    fi

    echo "--- Downloading seed toolchain ---"
    local url="https://github.com/buck-os/buckos-build/releases/download/dev/seed-toolchain.tar.zst"
    if ! curl -fSL -o "$seed_path" "$url"; then
        echo "Warning: No seed available yet (dev prerelease may not exist)." >&2
        echo "You can build from source with: buck2 build //tc/bootstrap:seed-export" >&2
        rm -f "$seed_path"
        echo ""
        return 1
    fi
    echo "  Downloaded to $seed_path"
    echo ""
}

configure_buck2() {
    if [ -f "$SCRIPT_DIR/.buckconfig.local" ]; then
        echo "--- .buckconfig.local already exists, skipping ---"
        echo ""
        return
    fi

    echo "--- Generating .buckconfig.local ---"
    local tmpdir
    tmpdir=$(mktemp -d)
    buck2 init "$tmpdir" 2>/dev/null

    {
        if [ -f "$SCRIPT_DIR/seed-toolchain.tar.zst" ]; then
            echo "[buckos]"
            echo "  seed_path = seed-toolchain.tar.zst"
            echo ""
        fi
        echo "[cells]"
        grep 'none = none' "$tmpdir/.buckconfig"
        echo ""
        echo "[cell_aliases]"
        sed -n '/^\[cell_aliases\]/,/^$/p' "$tmpdir/.buckconfig" \
            | grep -v '^\[' | grep -v '^$' \
            | grep -v '^\s*config =' | grep -v '^\s*buck =' \
            | sed 's/= none$/= buckos/'
    } > "$SCRIPT_DIR/.buckconfig.local"

    rm -rf "$tmpdir"
    echo "  Created $SCRIPT_DIR/.buckconfig.local"
    echo ""
}

configure_local_modifiers() {
    local modifiers_file="$SCRIPT_DIR/config/local_modifiers.bzl"
    local default_file="$SCRIPT_DIR/config/local_modifiers.bzl.default"

    if [ -f "$modifiers_file" ]; then
        echo "--- config/local_modifiers.bzl already exists, skipping ---"
        echo ""
        return
    fi

    echo "--- Creating config/local_modifiers.bzl from default ---"
    if [ -f "$default_file" ]; then
        cp "$default_file" "$modifiers_file"
    else
        cat > "$modifiers_file" << 'BZLEOF'
# Local Buck2 modifier configuration for BuckOS
# Edit via: buckos use [flags] or buckos use profile <profile>
LOCAL_MODIFIERS = [
]
BZLEOF
    fi
    echo "  Created $modifiers_file"
    echo "  Configure USE flags with: buckos use profile <desktop|server|minimal>"
    echo ""
}

verify() {
    echo "--- Verification ---"
    local failed=false

    for cmd in gcc g++ make cmake meson ninja ar ld nm curl tar zstd python3 perl cargo rg uv; do
        if command -v "$cmd" &>/dev/null; then
            printf "  %-12s %s\n" "$cmd" "$(command -v "$cmd")"
        else
            printf "  %-12s MISSING\n" "$cmd"
            failed=true
        fi
    done

    # fd-find: binary is "fd" on Arch/Fedora, "fdfind" on Debian/Ubuntu
    if command -v fd &>/dev/null; then
        printf "  %-12s %s\n" "fd" "$(command -v fd)"
    elif command -v fdfind &>/dev/null; then
        printf "  %-12s %s\n" "fd(find)" "$(command -v fdfind)"
    else
        printf "  %-12s MISSING\n" "fd"
        failed=true
    fi

    # Check buck2 separately (might need PATH update)
    local buck2_path
    buck2_path="$(command -v buck2 2>/dev/null || echo "$HOME/.local/bin/buck2")"
    if [ -x "$buck2_path" ]; then
        printf "  %-12s %s\n" "buck2" "$buck2_path"
    else
        printf "  %-12s MISSING\n" "buck2"
        failed=true
    fi

    echo ""

    if [ "$failed" = true ]; then
        echo "Warning: Some tools are missing. Build may not work correctly."
        return 1
    fi

    echo "All tools verified. Ready to build with: buck2 build //packages/..."

    # Remind Arch users about AUR packages
    if [ "$DISTRO" = "arch" ]; then
        echo ""
        echo "Note: ima-evm-utils is not in the Arch repos."
        echo "If IMA signing support is needed, install from AUR:"
        echo "  yay -S ima-evm-utils   (or your preferred AUR helper)"
    fi
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --yes|-y) AUTO_YES=true ;;
            *)
                echo "Usage: setup.sh [--yes]" >&2
                exit 1
                ;;
        esac
        shift
    done

    if [ ! -f "$SCRIPT_DIR/.buckroot" ]; then
        echo "Error: .buckroot not found. Run this script from the BuckOS repository root." >&2
        exit 1
    fi

    detect_distro
    define_packages

    case "$DISTRO" in
        arch)   PKG_CMD="pacman" ;;
        debian) PKG_CMD="apt" ;;
        fedora) PKG_CMD="dnf" ;;
        gentoo) PKG_CMD="emerge" ;;
    esac

    show_plan

    if [ "$AUTO_YES" != true ]; then
        read -rp "Proceed? [Y/n] " answer
        case "${answer:-Y}" in
            [Yy]*) ;;
            *)
                echo "Aborted."
                exit 0
                ;;
        esac
        echo ""
    fi

    install_packages
    install_uv
    install_buck2
    download_seed || true
    configure_buck2
    configure_local_modifiers
    verify
}

main "$@"
