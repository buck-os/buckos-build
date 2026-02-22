#!/bin/bash
# Ebuild-style shell helper functions for binary_package install scripts.
#
# Source this file in install scripts to get Gentoo-like helper functions.
# Expects $OUT to be set to the install prefix directory.
#
# Usage in install_script:
#   DESTDIR="$OUT" dobin foo
#   insinto /etc/myapp
#   doins config.conf

# Default DESTDIR to OUT if not set
: "${DESTDIR:=$OUT}"

# Default library directory
: "${LIBDIR:=usr/lib64}"

# ── Logging ──────────────────────────────────────────────────────────

einfo()  { echo -e "\033[32m * \033[0m$*"; }
ewarn()  { echo -e "\033[33m * \033[0mWARNING: $*"; }
eerror() { echo -e "\033[31m * \033[0mERROR: $*"; }
ebegin() { echo -e "\033[32m * \033[0m$*..."; }

eend() {
    local rv="${1:-$?}"
    if [ "$rv" -eq 0 ]; then
        echo -e "\033[32m [ ok ]\033[0m"
    else
        echo -e "\033[31m [ !! ]\033[0m"
    fi
    return "$rv"
}

die() { eerror "$@"; exit 1; }

# ── Directory context ────────────────────────────────────────────────

into()    { export INSDESTTREE="$1"; }
insinto() { export INSDESTTREE="$1"; }
exeinto() { export EXEDESTTREE="$1"; }
docinto() { export DOCDESTTREE="$1"; }

# ── File installation ────────────────────────────────────────────────

dobin() {
    mkdir -p "$DESTDIR/usr/bin"
    for f in "$@"; do
        install -m 0755 "$f" "$DESTDIR/usr/bin/"
    done
}

dosbin() {
    mkdir -p "$DESTDIR/usr/sbin"
    for f in "$@"; do
        install -m 0755 "$f" "$DESTDIR/usr/sbin/"
    done
}

newbin() {
    mkdir -p "$DESTDIR/usr/bin"
    install -m 0755 "$1" "$DESTDIR/usr/bin/$2"
}

newsbin() {
    mkdir -p "$DESTDIR/usr/sbin"
    install -m 0755 "$1" "$DESTDIR/usr/sbin/$2"
}

dolib_so() {
    mkdir -p "$DESTDIR/${LIBDIR:-usr/lib64}"
    for f in "$@"; do
        install -m 0755 "$f" "$DESTDIR/${LIBDIR:-usr/lib64}/"
    done
}

dolib_a() {
    mkdir -p "$DESTDIR/${LIBDIR:-usr/lib64}"
    for f in "$@"; do
        install -m 0644 "$f" "$DESTDIR/${LIBDIR:-usr/lib64}/"
    done
}

newlib_so() {
    mkdir -p "$DESTDIR/${LIBDIR:-usr/lib64}"
    install -m 0755 "$1" "$DESTDIR/${LIBDIR:-usr/lib64}/$2"
}

newlib_a() {
    mkdir -p "$DESTDIR/${LIBDIR:-usr/lib64}"
    install -m 0644 "$1" "$DESTDIR/${LIBDIR:-usr/lib64}/$2"
}

doins() {
    mkdir -p "$DESTDIR/${INSDESTTREE:-usr/share}"
    for f in "$@"; do
        if [ -d "$f" ]; then
            cp -a "$f" "$DESTDIR/${INSDESTTREE:-usr/share}/"
        else
            install -m 0644 "$f" "$DESTDIR/${INSDESTTREE:-usr/share}/"
        fi
    done
}

newins() {
    mkdir -p "$DESTDIR/${INSDESTTREE:-usr/share}"
    install -m 0644 "$1" "$DESTDIR/${INSDESTTREE:-usr/share}/$2"
}

doexe() {
    mkdir -p "$DESTDIR/${EXEDESTTREE:-usr/bin}"
    for f in "$@"; do
        install -m 0755 "$f" "$DESTDIR/${EXEDESTTREE:-usr/bin}/"
    done
}

newexe() {
    mkdir -p "$DESTDIR/${EXEDESTTREE:-usr/bin}"
    install -m 0755 "$1" "$DESTDIR/${EXEDESTTREE:-usr/bin}/$2"
}

doheader() {
    mkdir -p "$DESTDIR/usr/include"
    for f in "$@"; do
        install -m 0644 "$f" "$DESTDIR/usr/include/"
    done
}

newheader() {
    mkdir -p "$DESTDIR/usr/include"
    install -m 0644 "$1" "$DESTDIR/usr/include/$2"
}

doconfd() {
    mkdir -p "$DESTDIR/etc/conf.d"
    for f in "$@"; do
        install -m 0644 "$f" "$DESTDIR/etc/conf.d/"
    done
}

doenvd() {
    mkdir -p "$DESTDIR/etc/env.d"
    for f in "$@"; do
        install -m 0644 "$f" "$DESTDIR/etc/env.d/"
    done
}

doinitd() {
    mkdir -p "$DESTDIR/etc/init.d"
    for f in "$@"; do
        install -m 0755 "$f" "$DESTDIR/etc/init.d/"
    done
}

dosym() {
    local target="$1" link="$2"
    mkdir -p "$DESTDIR/$(dirname "$link")"
    ln -sf "$target" "$DESTDIR/$link"
}

dosym_rel() {
    local target="$1" link="$2"
    mkdir -p "$DESTDIR/$(dirname "$link")"
    ln -srf "$DESTDIR/$target" "$DESTDIR/$link"
}

# ── Documentation ────────────────────────────────────────────────────

dodoc() {
    local docdir="$DESTDIR/usr/share/doc/${PN:-$PACKAGE_NAME}/${DOCDESTTREE:-}"
    mkdir -p "$docdir"
    for f in "$@"; do
        install -m 0644 "$f" "$docdir/"
    done
}

newdoc() {
    local docdir="$DESTDIR/usr/share/doc/${PN:-$PACKAGE_NAME}/${DOCDESTTREE:-}"
    mkdir -p "$docdir"
    install -m 0644 "$1" "$docdir/$2"
}

doman() {
    for f in "$@"; do
        local section="${f##*.}"
        mkdir -p "$DESTDIR/usr/share/man/man$section"
        install -m 0644 "$f" "$DESTDIR/usr/share/man/man$section/"
    done
}

newman() {
    local section="${2##*.}"
    mkdir -p "$DESTDIR/usr/share/man/man$section"
    install -m 0644 "$1" "$DESTDIR/usr/share/man/man$section/$2"
}

doinfo() {
    mkdir -p "$DESTDIR/usr/share/info"
    for f in "$@"; do
        install -m 0644 "$f" "$DESTDIR/usr/share/info/"
    done
}

# ── Directories and permissions ──────────────────────────────────────

dodir() {
    for d in "$@"; do
        mkdir -p "$DESTDIR/$d"
    done
}

keepdir() {
    for d in "$@"; do
        mkdir -p "$DESTDIR/$d"
        touch "$DESTDIR/$d/.keep"
    done
}

fowners() {
    local owner="$1"; shift
    for f in "$@"; do
        chown "$owner" "$DESTDIR/$f"
    done
}

fperms() {
    local mode="$1"; shift
    for f in "$@"; do
        chmod "$mode" "$DESTDIR/$f"
    done
}

# ── Systemd helpers ──────────────────────────────────────────────────

systemd_dounit() {
    mkdir -p "$DESTDIR/usr/lib/systemd/system"
    for f in "$@"; do
        install -m 0644 "$f" "$DESTDIR/usr/lib/systemd/system/"
    done
}

systemd_newunit() {
    mkdir -p "$DESTDIR/usr/lib/systemd/system"
    install -m 0644 "$1" "$DESTDIR/usr/lib/systemd/system/$2"
}

systemd_douserunit() {
    mkdir -p "$DESTDIR/usr/lib/systemd/user"
    for f in "$@"; do
        install -m 0644 "$f" "$DESTDIR/usr/lib/systemd/user/"
    done
}

systemd_enable_service() {
    local service="$1"
    local target="${2:-multi-user.target}"
    mkdir -p "$DESTDIR/usr/lib/systemd/system/${target}.wants"
    ln -sf "../$service" "$DESTDIR/usr/lib/systemd/system/${target}.wants/$service"
}

# ── OpenRC helpers ───────────────────────────────────────────────────

newinitd() {
    mkdir -p "$DESTDIR/etc/init.d"
    install -m 0755 "$1" "$DESTDIR/etc/init.d/$2"
}

newconfd() {
    mkdir -p "$DESTDIR/etc/conf.d"
    install -m 0644 "$1" "$DESTDIR/etc/conf.d/$2"
}
