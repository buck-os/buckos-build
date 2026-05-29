---
id: "PACKAGE-SPEC-005"
title: "Python Packages"
status: "approved"
version: "2.0.0"
created: "2025-12-27"
updated: "2026-05-29"

authors:
  - name: "BuckOS Team"
    email: "team@buckos.org"

category: "packages"
tags:
  - "package-creation"
  - "python"
  - "pip"
  - "setuptools"
  - "language-packages"

related:
  - "SPEC-001"
  - "SPEC-002"
  - "SPEC-005"
  - "PACKAGE-SPEC-001"
  - "PACKAGE-SPEC-004"

implementation:
  status: "complete"
  completeness: 100

compatibility:
  buck2_version: ">=2024.11.01"
  buckos_version: ">=2026.02"
  breaking_changes: false

changelog:
  - version: "2.0.0"
    date: "2026-05-29"
    changes: "Rewrite against wrapper-based package() API."
  - version: "1.0.0"
    date: "2025-12-27"
    changes: "Initial spec — superseded."
---

# Python Package Specification

## Overview

`python_package` installs a Python distribution into the package prefix
via pip (or `setup.py install` when `use_setup_py = True`). One Buck2
action drives `python_helper.py`, which assembles `PYTHONPATH` from the
package's runtime deps and runs the install.

| Macro | Loaded from | Underlying rule |
|-------|-------------|-----------------|
| `python_package` | `//defs/packages:python.bzl` | `defs/rules/python.bzl::python_build` |

## Wrapper Signature

```python
python_package(name, version, url, sha256, **kwargs)
```

## Required Arguments

| Argument | Type | Description |
|----------|------|-------------|
| `name` | string | Target name (PyPI distribution name) |
| `version` | string | Distribution version |
| `url` | string | Source tarball / sdist URL |
| `sha256` | string | SHA-256 of the archive |

## Common Optional Arguments

All common kwargs from PACKAGE-SPEC-001 apply: `description`, `homepage`,
`license`, `deps`, `host_deps`, `runtime_deps`, `patches`, `env`,
`transforms`, `use_transforms`, `use_deps`, `local_only`, `filename`,
`strip_components`, `pre_configure_cmds`, etc.

`deps` are added to `PYTHONPATH` at install time and propagate via
tsets to consumers. Python packages typically need
`//packages/linux/lang/python:python` in `deps`.

## Python-Specific Arguments

Forwarded to `python_build` (see `defs/rules/python.bzl`):

| Argument | Type | Description |
|----------|------|-------------|
| `use_setup_py` | bool | If True, install via `python setup.py install` instead of pip |
| `pip_args` | list[string] | Extra args appended to the `pip install` invocation |

There is **no** `python` (interpreter selector) kwarg; the rule always
uses the buckos `python` toolchain. There is **no** `use_extras` kwarg —
extras-style optional functionality is expressed via `use_deps` listing
the implementation packages.

## Examples

### Pure-Python package

See `/home/hodgesd/buckos-build/packages/linux/ai/whisper/BUCK`:

```python
load("//defs/packages:python.bzl", "python_package")

python_package(
    name = "whisper",
    version = "20231117",
    url = "https://github.com/openai/whisper/archive/refs/tags/v20231117.tar.gz",
    sha256 = "b0f8b8d3b485fad2c423ba7f8b95eded067aad11ed3165828aad819d168cac06",
    deps = [
        "//packages/linux/dev-libs/python/numba:numba",
        "//packages/linux/ai/ml-frameworks/pytorch:pytorch",
        "//packages/linux/dev-libs/python/tqdm:tqdm",
        "//packages/linux/dev-libs/python/more-itertools:more-itertools",
        "//packages/linux/dev-libs/python/tiktoken:tiktoken",
    ],
)
```

### Legacy `setup.py` install with pre-build patch

See `/home/hodgesd/buckos-build/packages/linux/dev-libs/python/grako/BUCK`
for `use_setup_py = True` combined with a `pre_configure_cmds` snippet
that patches the source before install.

## USE Flag Integration

Standard model: dict keys of `use_deps`, `use_configure`, `use_transforms`
declare flags. Each gets a `buckos:iuse:FLAG` label and a `USE_FLAG=1|0`
env var. See SPEC-002.

To gate optional functionality (the rough equivalent of pip extras), use
`use_deps` listing the optional implementation package:

```python
python_package(
    name = "requests",
    version = "2.31.0",
    url  = "https://files.pythonhosted.org/packages/.../requests-2.31.0.tar.gz",
    sha256 = "...",
    deps = [
        "//packages/linux/dev-libs/python/urllib3:urllib3",
        "//packages/linux/dev-libs/python/certifi:certifi",
    ],
    use_deps = {
        "socks":  "//packages/linux/dev-libs/python/pysocks:pysocks",
        "crypto": "//packages/linux/dev-libs/python/pyopenssl:pyopenssl",
    },
)
```

## C Extensions

For packages with native C/C++ extensions, list the system libraries in
`deps`. Their sysroot include / lib paths propagate via tsets, and the
Python helper sets `CFLAGS` / `LDFLAGS` accordingly:

```python
python_package(
    name = "pillow",
    version = "10.1.0",
    url = "...",
    sha256 = "...",
    deps = [
        "//packages/linux/media-libs:libjpeg-turbo",
        "//packages/linux/media-libs:libpng",
        "//packages/linux/core/zlib:zlib",
    ],
)
```

## Patches

Same model as PACKAGE-SPEC-001; see SPEC-005 for the patch registry.

## Generated Targets

```
:{name}-archive   # source archive
:{name}-src       # extracted source
:{name}-build     # python install action
:{name}           # alias
```

## References

- `defs/packages/python.bzl` — wrapper
- `defs/rules/python.bzl` — rule
- `tools/python_helper.py` — build driver
- PACKAGE-SPEC-001 — common kwargs, USE-flag value forms
- SPEC-001 (Architecture), SPEC-002 (USE flags), SPEC-005 (Patches)
- Python Packaging: https://packaging.python.org/
