"""
Template for cmake_package (cmake -S . -B build && ninja && ninja install).

Real-world example: packages/linux/desktop/kde/ecm/BUCK  (small)
                    packages/linux/dev-libs/spirv/BUCK    (with cmake_dep_defines)
Wrapper definition: defs/packages/cmake.bzl
Underlying rule:    defs/rules/cmake.bzl
Common kwargs:      defs/package.bzl (see the package() docstring)
"""

load("//defs/packages:cmake.bzl", "cmake_package")

cmake_package(
    name = "PACKAGE_NAME",
    version = "VERSION",
    url = "https://example.org/PACKAGE_NAME-VERSION.tar.gz",
    sha256 = "REPLACE_WITH_SHA256",

    # ── SBOM metadata ────────────────────────────────────────────────
    description = "One-line description",
    homepage = "https://example.org/",
    license = "Apache-2.0",
    # cpe = "cpe:2.3:a:vendor:PACKAGE_NAME:VERSION:*:*:*:*:*:*:*",

    # ── CMake configuration ──────────────────────────────────────────
    # CMAKE_INSTALL_PREFIX=/usr and CMAKE_BUILD_TYPE=Release are set
    # automatically.  Add anything else here:
    configure_args = [
        # "-DCMAKE_INSTALL_PREFIX=/usr",
        # "-DBUILD_SHARED_LIBS=ON",
        # "-DBUILD_TESTING=OFF",
    ],

    # Convenient dict form for -D defines (merged into configure_args):
    # cmake_defines = {
    #     "BUILD_TESTING": "OFF",
    #     "INSTALL_DOCS": "OFF",
    # },

    # Defines whose VALUES are buck targets (path substituted at build):
    # cmake_dep_defines = {
    #     "SPIRV-Headers_SOURCE_DIR": ":spirv-headers",
    # },

    # Other rule-specific knobs (see defs/packages/cmake.bzl):
    # source_subdir = "subprojects/foo",  # CMake project inside a subdir
    # make_args = ["-v"],

    # ── USE flags ────────────────────────────────────────────────────
    use_configure = {
        # "flag": ("-DWITH_FLAG=ON", "-DWITH_FLAG=OFF"),
        # "ssl": ("-DWITH_SSL=ON", "-DWITH_SSL=OFF"),
    },
    use_deps = {
        # "ssl": "//packages/linux/system/libs/crypto/openssl:openssl",
    },

    # ── Patches ──────────────────────────────────────────────────────
    # patches = glob(["patches/*.patch"]),

    # ── Dependencies ─────────────────────────────────────────────────
    deps = [
        # "//packages/linux/core/zlib:zlib",
    ],
    # host_deps = [],  # auto-injected: cmake, ninja, pkg-config, etc.

    # ── Transforms / labels (optional) ───────────────────────────────
    # transforms = ["strip", "stamp"],
    # labels = ["buckos:hw:vulkan"],
)
