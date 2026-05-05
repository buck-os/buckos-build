"""Host tool package lists for seed bootstrap.

BASE_TOOL_PACKAGES: simple POSIX tools with no deep dep chains.

EXTENDED_TOOL_PACKAGES: build system tools and compilers needed for
building packages.  Only includes tools actually used at build time —
NOT test tools (qemu), image tools (grub, mtools), or signing tools.

Both are built via host_tools_transition → bootstrap-toolchain (stage 2
cross-compiler + host PATH fallback).  The transition breaks the
direct seed dependency, but cycles still exist through exec_deps:
glibc → linux-headers → kernel-config → flex (exec) → tar (exec)
→ seed-exec-toolchain → host-tools.  Packages already in the
sysroot (glibc, linux-headers) must NOT be included here.

HOST_TOOL_PACKAGES = BASE + EXTENDED, used by the host_tools_aggregator
for the complete seed archive.
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
    "//packages/linux/core/file:file",
    "//packages/linux/core/util-linux:util-linux",

    # Core libraries
    "//packages/linux/core/zlib:zlib",

    # Native C/C++ compiler
    "//packages/linux/lang/gcc:gcc-native",

    # NOTE: glibc, linux-headers, and libxcrypt are NOT included here.
    # They're already in the sysroot (tools/<triple>/sys-root/) and
    # host-tools binaries find them via RPATH symlinks created at
    # unpack time.

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
    "//packages/linux/dev-tools/dev-utils/gperf:gperf",

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

    # Compiler cache
    "//packages/linux/dev-tools/dev-utils/ccache:ccache",

    # Languages
    "//packages/linux/lang/rust:rust",
    "//packages/linux/lang/go:go",

    # Kernel module tools
    "//packages/linux/system/libs/kmod:kmod",

    # ELF / DWARF
    "//packages/linux/dev-tools/dev-utils/dwarves:dwarves",

    # Crypto / TLS (needed by many packages at configure time)
    "//packages/linux/system/libs/crypto/openssl:openssl",
]

HOST_TOOL_PACKAGES = BASE_TOOL_PACKAGES + EXTENDED_TOOL_PACKAGES
