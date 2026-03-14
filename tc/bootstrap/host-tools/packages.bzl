"""Host tool package lists for seed bootstrap.

BASE_TOOL_PACKAGES: simple POSIX tools with no deep dep chains.
Built via host_tools_transition (buckos compiler + host PATH fallback).
These become the seed toolchains' hermetic PATH — no host fallback
needed for any package that uses the seed toolchain.

EXTENDED_TOOL_PACKAGES: complex packages with deep dep chains (glibc,
gcc, llvm, rust, kernel tools, etc.).  Built normally with the seed
toolchain.  Included in the full seed export but NOT in the base
host_tools (to avoid cycles).

HOST_TOOL_PACKAGES = BASE + EXTENDED, used by toolchain_export for
the complete seed archive.
"""

BASE_TOOL_PACKAGES = [
    # Shell
    "//packages/linux/core/bash:bash",

    # Core POSIX utilities
    "//packages/linux/system/apps/coreutils:coreutils",
    "//packages/linux/system/apps/findutils:findutils",
    "//packages/linux/system/apps/tar:tar",
    "//packages/linux/editors/diffutils:diffutils",
    "//packages/linux/editors/sed:sed",
    "//packages/linux/editors/grep:grep",
    "//packages/linux/editors/gawk:gawk",
    "//packages/linux/editors/patch:patch",
    "//packages/linux/editors/ed:ed",

    # Compression
    "//packages/linux/system/libs/compression/gzip:gzip",
    "//packages/linux/system/libs/compression/xz:xz",
    "//packages/linux/system/libs/compression/bzip2:bzip2",
    "//packages/linux/system/libs/compression/lzip:lzip",

    # Binary utilities (ar, ranlib, strip, objcopy — called by Makefiles)
    "//packages/linux/dev-tools/build-systems/binutils:binutils",

    # Build systems (simple autotools packages)
    "//packages/linux/dev-tools/build-systems/make:make",
    "//packages/linux/dev-tools/build-systems/m4:m4",
    "//packages/linux/dev-tools/build-systems/pkg-config:pkg-config",
]

EXTENDED_TOOL_PACKAGES = [
    # Core utilities with deeper deps
    "//packages/linux/system/apps/rsync:rsync",
    "//packages/linux/core/file:file",
    "//packages/linux/core/util-linux:util-linux",

    # Core libraries
    "//packages/linux/core/zlib:zlib",

    # Binary utilities (already in BASE)

    # Native C/C++ compiler
    "//packages/linux/lang/gcc:gcc-native",

    # Kernel UAPI headers
    "//tc/bootstrap/stage2:linux-headers",

    # C library + kernel headers
    "//packages/linux/core/glibc:glibc",
    "//packages/linux/system/libs/crypto/libxcrypt:libxcrypt",

    # GCC dependencies
    "//packages/linux/system/libs/utility/gmp:gmp",
    "//packages/linux/system/libs/utility/mpfr:mpfr",
    "//packages/linux/system/libs/utility/mpc:mpc",

    # Build systems (need perl or complex deps)
    "//packages/linux/dev-tools/build-systems/autoconf:autoconf",
    "//packages/linux/dev-tools/build-systems/automake:automake",
    "//packages/linux/dev-tools/build-systems/libtool:libtool",

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

    # Documentation tools
    "//packages/linux/dev-tools/documentation/help2man:help2man",

    # LLVM/Clang
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

    # ISO image tools
    "//packages/linux/dev-libs/iso/libisofs:libisofs",
    "//packages/linux/dev-libs/iso/libburn:libburn",
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

HOST_TOOL_PACKAGES = BASE_TOOL_PACKAGES + EXTENDED_TOOL_PACKAGES
