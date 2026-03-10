"""Shared list of host tool packages for seed bootstrap.

Used by both the host_tools_aggregator (merged FHS tree for hermetic PATH)
and toolchain_export (per-package archives in the seed).
"""

HOST_TOOL_PACKAGES = [
    # Shell
    "//packages/linux/core/bash:bash",

    # Core utilities
    "//packages/linux/system/apps/coreutils:coreutils",
    "//packages/linux/system/apps/findutils:findutils",
    "//packages/linux/system/apps/rsync:rsync",
    "//packages/linux/system/apps/tar:tar",
    "//packages/linux/system/apps/which:which",
    "//packages/linux/editors/diffutils:diffutils",
    "//packages/linux/editors/sed:sed",
    "//packages/linux/editors/grep:grep",
    "//packages/linux/editors/gawk:gawk",
    "//packages/linux/editors/patch:patch",
    "//packages/linux/core/file:file",
    "//packages/linux/core/util-linux:util-linux",

    # Compression
    "//packages/linux/system/libs/compression/gzip:gzip",
    "//packages/linux/system/libs/compression/xz:xz",
    "//packages/linux/system/libs/compression/bzip2:bzip2",
    "//packages/linux/system/libs/compression/zstd:zstd",

    # Core libraries (needed by HOSTCC tools: kernel libbpf, resolve_btfids)
    "//packages/linux/core/zlib:zlib",

    # Binary utilities (strip, objcopy, ar, as, ld, etc.)
    "//packages/linux/dev-tools/build-systems/binutils:binutils",

    # Native C/C++ compiler (needed by Kconfig, kernel builds, etc.)
    "//packages/linux/lang/gcc:gcc-native",

    # C library + kernel headers -- gcc-native needs glibc CRT files
    # (Scrt1.o, crti.o, crtn.o), headers (sys/types.h, stdio.h), and
    # shared libs to compile and link host programs.
    "//packages/linux/core/glibc:glibc",
    "//packages/linux/system/libs/crypto/libxcrypt:libxcrypt",

    # GCC dependencies (libs must be in merged tree for gcc to find them)
    "//packages/linux/system/libs/utility/gmp:gmp",
    "//packages/linux/system/libs/utility/mpfr:mpfr",
    "//packages/linux/system/libs/utility/mpc:mpc",

    # Build systems
    "//packages/linux/dev-tools/build-systems/make:make",
    "//packages/linux/dev-tools/build-systems/m4:m4",
    "//packages/linux/dev-tools/build-systems/autoconf:autoconf",
    "//packages/linux/dev-tools/build-systems/automake:automake",
    "//packages/linux/dev-tools/build-systems/libtool:libtool",
    "//packages/linux/dev-tools/build-systems/pkg-config:pkg-config",

    # Editors
    "//packages/linux/editors/ed:ed",

    # Dev utilities
    "//packages/linux/dev-tools/dev-utils/bc:bc",
    "//packages/linux/dev-tools/dev-utils/bison:bison",
    "//packages/linux/dev-tools/dev-utils/flex:flex",

    # ELF tools
    "//packages/linux/system/libs/elfutils:elfutils",
    "//packages/linux/dev-tools/dev-utils/patchelf:patchelf",

    # Internationalization
    "//packages/linux/dev-libs/misc/gettext:gettext",

    # Languages
    "//packages/linux/lang/perl:perl",
    "//packages/linux/lang/python:python",

    # Documentation tools (needed by bison, automake, etc.)
    "//packages/linux/dev-tools/documentation/help2man:help2man",

    # LLVM/Clang (Rust uses clang as linker)
    "//packages/linux/core/llvm:llvm-native",

    # Linker
    "//packages/linux/lang/linkers:mold",

    # Build systems
    "//packages/linux/dev-tools/build-systems/cmake:cmake",
    "//packages/linux/dev-tools/build-systems/ninja:ninja",
    "//packages/linux/dev-tools/build-systems/meson:meson",

    # Languages
    "//packages/linux/lang/rust:rust",
    "//packages/linux/lang/go:go",

    # Kernel module tools
    "//packages/linux/system/libs/kmod:kmod",

    # ELF / DWARF
    "//packages/linux/dev-tools/dev-utils/dwarves:dwarves",

    # ISO image tools (xorriso, grub-mkimage, mksquashfs, mtools)
    "//packages/linux/dev-libs/iso/libisoburn:libisoburn",
    "//packages/linux/system/apps/mtools:mtools",

    # Image / filesystem tools
    "//packages/linux/system/filesystem/native/squashfs-tools:squashfs-tools",
    "//packages/linux/system/filesystem/native/e2fsprogs:e2fsprogs",
    "//packages/linux/system/filesystem/native/dosfstools:dosfstools",
    "//packages/linux/system/filesystem/native/btrfs-progs:btrfs-progs",
    "//packages/linux/system/filesystem/native/xfsprogs:xfsprogs",
    "//packages/linux/system/filesystem/management/gptfdisk:gptfdisk",
    "//packages/linux/system/libs/cpio:cpio",
    "//packages/linux/boot/grub:grub",
    "//packages/linux/emulation/hypervisors/qemu:qemu",

    # Crypto / TLS
    "//packages/linux/system/libs/crypto/openssl:openssl",

    # Security / signing
    "//packages/linux/system/security/ima-evm-utils:ima-evm-utils",
]
