"""
Template for meson_package (meson setup build && ninja -C build install).

Real-world example: packages/linux/dev-libs/parsers/inih/BUCK  (minimal)
                    packages/linux/dev-libs/glib/BUCK            (USE flags)
Wrapper definition: defs/packages/meson.bzl
Underlying rule:    defs/rules/meson.bzl
Common kwargs:      defs/package.bzl (see the package() docstring)
"""

load("//defs/packages:meson.bzl", "meson_package")

meson_package(
    name = "PACKAGE_NAME",
    version = "VERSION",
    url = "https://example.org/PACKAGE_NAME-VERSION.tar.xz",
    sha256 = "REPLACE_WITH_SHA256",

    # ── SBOM metadata ────────────────────────────────────────────────
    description = "One-line description",
    homepage = "https://example.org/",
    license = "LGPL-2.1+",

    # ── Meson configuration ──────────────────────────────────────────
    # --prefix=/usr and --buildtype=release are set automatically.
    # Pass -Doption=value entries through configure_args:
    configure_args = [
        # "--wrap-mode=nofallback",
        # "-Dtests=false",
        # "-Dgtk_doc=false",
    ],

    # Convenient dict form for -D options (merged into configure_args):
    # meson_defines = {
    #     "tests": "false",
    #     "docs": "disabled",
    # },

    # Other rule-specific knobs (see defs/packages/meson.bzl):
    # source_subdir = "subdir",
    # make_args = ["-v"],

    # ── USE flags ────────────────────────────────────────────────────
    # NOTE: Meson uses use_configure (not a separate use_options) — the
    # name "configure" is generic across build systems.
    use_configure = {
        # "flag": ("-Dflag=enabled", "-Dflag=disabled"),
        # "introspection": ("-Dintrospection=enabled", "-Dintrospection=disabled"),
        # "systemd": ("-Dsystemd=true", "-Dsystemd=false"),
    },
    use_deps = {
        # "systemd": "//packages/linux/system/init/systemd:systemd",
    },

    # ── Patches ──────────────────────────────────────────────────────
    # patches = glob(["patches/*.patch"]),

    # ── Dependencies ─────────────────────────────────────────────────
    deps = [
        # "//packages/linux/system/libs/utility/libffi:libffi",
        # "//packages/linux/core/zlib:zlib",
    ],
    # host_deps = [],  # auto-injected: meson, ninja, pkg-config, etc.

    # ── Transforms (optional) ────────────────────────────────────────
    # transforms = ["strip", "stamp"],
)
