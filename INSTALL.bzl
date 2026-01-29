load("//defs:package_defs.bzl", "rootfs")

rootfs(
    name = "installer-rootfs",
    packages = [
        "//packages/linux/system/apps/coreutils:coreutils",
        "//packages/linux/core/util-linux:util-linux",
        "//packages/linux/core/procps-ng:procps-ng",
        "//packages/linux/system/apps/shadow:shadow",
        "//packages/linux/core/file:file",
        "//packages/linux/core/bash:bash",
        "//packages/linux/core/zlib:zlib",
        "//packages/linux/core/glibc:glibc",
        "//packages/linux/system/libs/crypto/openssl:openssl",
        "//packages/linux/network/curl:curl",
        "//packages/linux/network/iproute2:iproute2",
        "//packages/linux/network/openssh:openssh",
        "//packages/linux/editors/vim:vim",
    ],
    visibility = ["PUBLIC"],
)
