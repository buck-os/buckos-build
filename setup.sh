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
        *)
            # Check ID_LIKE for derivatives
            case "${ID_LIKE:-}" in
                *arch*)   DISTRO="arch" ;;
                *debian*) DISTRO="debian" ;;
                *fedora*|*rhel*) DISTRO="fedora" ;;
                *)
                    echo "Error: Unsupported distribution: ${ID:-unknown} (ID_LIKE=${ID_LIKE:-})" >&2
                    echo "Supported: Arch, Debian/Ubuntu, Fedora/RHEL" >&2
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
                texinfo bison flex gperf zlib linux-api-headers git gnupg
                rust fd ripgrep
                ima-evm-utils
            )
            ;;
        debian)
            PACKAGES=(
                build-essential binutils cmake meson ninja-build python3 perl
                m4 autoconf automake libtool pkg-config curl tar xz-utils
                bzip2 gzip lzip zstd file patch unzip util-linux gawk sed grep
                diffutils findutils coreutils bash gettext texinfo bison flex
                gperf zlib1g-dev libelf-dev linux-libc-dev git gnupg
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
                gperf zlib-devel elfutils-libelf-devel kernel-headers glibc-static git gnupg2
                cargo fd-find ripgrep
                ima-evm-utils
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
    echo "Config:     .buckconfig.local [buckos] use_host_toolchain = true"
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

configure_buckconfig() {
    echo "--- Configuring .buckconfig.local ---"
    local config_file="$SCRIPT_DIR/.buckconfig.local"

    if [ -f "$config_file" ] && grep -q '^\[buckos\]' "$config_file"; then
        # Update existing [buckos] section
        sed -i '/^\[buckos\]/,/^\[/{s/^use_host_toolchain.*/use_host_toolchain = true/}' "$config_file"
        # Add if key wasn't present in section
        if ! grep -q 'use_host_toolchain' "$config_file"; then
            sed -i '/^\[buckos\]/a use_host_toolchain = true' "$config_file"
        fi
    else
        # Append new section
        {
            [ -s "$config_file" ] && echo ""
            echo "[buckos]"
            echo "use_host_toolchain = true"
        } >> "$config_file"
    fi

    echo "Wrote: $config_file"
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
    configure_buckconfig
    verify
}

main "$@"
