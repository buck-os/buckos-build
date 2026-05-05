load("//defs:package.bzl", "package")

# Pre-generate en_US.UTF-8 locale for the live system
# KDE and GUI applications require UTF-8 locale
package(
    name = "glibc-locale",
    build_rule = "binary",
    source = "//packages/linux/core:glibc-src",
    version = "2.41",
    description = "Pre-generated en_US.UTF-8 locale data",
    install_script = """
# Create locale directory
mkdir -p "$OUT/usr/lib/locale"

# Generate en_US.UTF-8 locale
localedef -i en_US -f UTF-8 "$OUT/usr/lib/locale/en_US.UTF-8" --no-archive

echo "Generated en_US.UTF-8 locale"
""",
    deps = ["//packages/linux/core:glibc"],
    visibility = ["PUBLIC"],
)
