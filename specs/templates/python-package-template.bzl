"""
Template for python_package (pip install or setup.py install into the prefix).

Real-world example: packages/linux/ai/audio-ml/audio-diffusion-pytorch/BUCK
                                                                       (minimal pip)
                    packages/linux/dev-libs/python/grako/BUCK
                                                       (setup.py + pre_configure_cmds)
Wrapper definition: defs/packages/python.bzl
Underlying rule:    defs/rules/python.bzl
Common kwargs:      defs/package.bzl (see the package() docstring)

Default behaviour: pip install .  Set use_setup_py = True to fall back to
`python setup.py install`.
"""

load("//defs/packages:python.bzl", "python_package")

python_package(
    name = "PACKAGE_NAME",
    version = "VERSION",
    url = "https://files.pythonhosted.org/packages/.../PACKAGE_NAME-VERSION.tar.gz",
    sha256 = "REPLACE_WITH_SHA256",

    # ── SBOM metadata ────────────────────────────────────────────────
    description = "One-line description",
    homepage = "https://pypi.org/project/PACKAGE_NAME/",
    license = "MIT",

    # ── Install backend ──────────────────────────────────────────────
    # use_setup_py = True,    # legacy setup.py instead of pip
    # pip_args = ["--no-deps", "--no-build-isolation"],

    # ── USE flags ────────────────────────────────────────────────────
    # Python "extras" are conventionally surfaced via pip_args (e.g.
    # ".[ssl]").  Use use_configure here to splice such args in:
    use_configure = {
        # "ssl": ("--config-settings=extras=ssl", ""),
    },
    use_deps = {
        # "ssl": "//packages/linux/dev-libs/python/cryptography:cryptography",
    },

    # ── Patches ──────────────────────────────────────────────────────
    # patches = glob(["patches/*.patch"]),

    # ── Dependencies ─────────────────────────────────────────────────
    deps = [
        # The Python interpreter itself is implicit, but downstream
        # consumers usually want it listed:
        # "//packages/linux/lang/python:python",
        # Other Python packages:
        # "//packages/linux/dev-libs/python/setuptools:setuptools",
        # "//packages/linux/dev-libs/python/wheel:wheel",
        # Native libs for C extensions:
        # "//packages/linux/system/libs/utility/libffi:libffi",
    ],

    # ── Pre-install fixups (e.g. Python 3.10 collections.abc) ────────
    # pre_configure_cmds = ["""
    #     python3 -c '
    # import pathlib
    # for p in pathlib.Path(".").rglob("*.py"):
    #     t = p.read_text()
    #     t = t.replace("from collections import Mapping",
    #                   "from collections.abc import Mapping")
    #     p.write_text(t)'
    # """],
)
