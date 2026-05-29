"""
Template for autotools_package (./configure && make && make install).

This is the standard build flow for GNU-style packages.  Copy this file
into your new package directory as `BUCK`, replace the placeholders, and
delete the optional sections you don't need.

Real-world example: packages/linux/core/bash/BUCK
Wrapper definition: defs/packages/autotools.bzl
Underlying rule:    defs/rules/autotools.bzl
Common kwargs:      defs/package.bzl (see the package() docstring)
"""

load("//defs/packages:autotools.bzl", "autotools_package")

autotools_package(
    name = "PACKAGE_NAME",
    version = "VERSION",
    url = "https://example.org/PACKAGE_NAME-VERSION.tar.xz",
    sha256 = "REPLACE_WITH_SHA256",

    # ── SBOM metadata (recommended) ──────────────────────────────────
    description = "One-line description of the package",
    homepage = "https://example.org/",
    license = "GPL-3.0",  # SPDX identifier
    # cpe = "cpe:2.3:a:vendor:PACKAGE_NAME:VERSION:*:*:*:*:*:*:*",
    # libraries = ["foo"],  # shared libs installed (without "lib" prefix)

    # ── Static build configuration ──────────────────────────────────
    configure_args = [
        # "--disable-static",
        # "--without-bash-malloc",
    ],
    # extra_cflags = ["-O2"],
    # extra_ldflags = ["-Wl,--as-needed"],
    # make_args = ["V=1"],
    # install_targets = ["install", "install-info"],

    # ── USE flags ────────────────────────────────────────────────────
    # Flags are declared implicitly by mentioning them in use_*; there is
    # no separate `iuse` list.  See use/constraints/ for how to register
    # new flags.
    use_configure = {
        # "flag": ("--enable-flag", "--disable-flag"),
        # "ssl": ("--with-openssl", "--without-ssl"),
        # "ipv6": ("--enable-ipv6", "--disable-ipv6"),
    },
    use_deps = {
        # "flag": "//pkg:target"               # single dep
        # "flag": ["//pkg:a", "//pkg:b"]       # multiple deps
        # "flag": ("//pkg:on-dep", "//pkg:off-dep")  # switch deps
        # "ssl": "//packages/linux/system/libs/crypto/openssl:openssl",
    },

    # ── Patches ──────────────────────────────────────────────────────
    # patches = glob(["patches/*.patch"]),

    # ── Dependencies (always required) ───────────────────────────────
    deps = [
        # "//packages/linux/core/zlib:zlib",
    ],
    # host_deps = [
    #     "//packages/linux/dev-tools/build-systems/autoconf:autoconf",
    # ],

    # ── Post-install hooks ───────────────────────────────────────────
    # post_install_cmds = ["""
    #     ln -sf bash "$DESTDIR/usr/bin/sh"
    # """],

    # ── Output transforms ────────────────────────────────────────────
    # transforms = ["strip", "stamp"],
    # use_transforms = {"ima": "ima"},

    # ── Rule-specific knobs (see defs/packages/autotools.bzl) ────────
    # skip_configure = True,        # raw Makefile (or use make_package)
    # skip_host_arg = True,         # configure doesn't accept --host=
    # configure_script = "./bootstrap.sh",
    # configure_prefix_deps = ["//some:codegen-tool"],
    # build_subdir = "build",       # out-of-tree build dir
    # pre_build_cmds = ["./autogen.sh"],
    # install_args = ["install-strip"],
    # install_prefix_var = "prefix",  # for Makefiles using $(prefix) not $(DESTDIR)
)
