---
id: "PACKAGE-SPEC-005"
title: "Python Packages"
status: "approved"
version: "1.0.0"
created: "2025-12-27"
updated: "2025-12-27"

authors:
  - name: "BuckOS Team"
    email: "team@buckos.org"

maintainers:
  - "team@buckos.org"

category: "packages"
tags:
  - "package-creation"
  - "python"
  - "pip"
  - "setuptools"
  - "language-packages"

related:
  - "PACKAGE-SPEC-001"
  - "PACKAGE-SPEC-003"
  - "PACKAGE-SPEC-004"

implementation:
  status: "complete"
  completeness: 80

compatibility:
  buck2_version: ">=2024.11.01"
  buckos_version: ">=1.0.0"
  breaking_changes: false
---

# Python Package Specification

## Abstract

This specification defines how to create BuckOS packages for Python projects.

## Package Type

**`package(build_rule = "python")`** - Builds Python packages with pip/setuptools

## Quick Start

### Basic Python Package

```python
load("//defs:package.bzl", "package")

package(
    build_rule = "python",
    name = "requests",
    version = "2.31.0",
    url = "https://pypi.io/packages/source/r/requests/requests-2.31.0.tar.gz",
    sha256 = "942c5a758f98d5505896ef02fb6d8fe39530e8c2fcf1df7f8a5fdcfa42a9b12e",
    deps = [
        "//packages/linux/dev-python:urllib3",
        "//packages/linux/dev-python:certifi",
    ],
    maintainers = ["python@buckos.org"],
)
```

### With USE Flags for Extras

```python
package(
    build_rule = "python",
    name = "requests",
    version = "2.31.0",
    url = "https://pypi.io/packages/source/r/requests/requests-2.31.0.tar.gz",
    sha256 = "...",
    iuse = ["socks", "security"],
    use_defaults = ["security"],
    use_extras = {
        "socks": "socks",
        "security": "security",
    },
    use_deps = {
        "socks": "//packages/linux/dev-python:pysocks",
    },
)
```

## Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Package name (PyPI name) |
| `version` | string | Package version |
| `url` | string | Source tarball URL |
| `sha256` | string | SHA-256 checksum |

## Python-Specific Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `python` | string | "python3" | Python interpreter to use |
| `use_extras` | dict | {} | Map USE flags to Python extras |
| `use_deps` | dict | {} | Conditional dependencies based on USE flags |
| `patches` | list[string] | [] | Patch files to apply |

## Python Extras

Python extras are optional dependencies defined in `setup.py` or `pyproject.toml`. They map to USE flags:

```python
iuse = ["ssl", "http2"]
use_extras = {
    "ssl": "ssl",
    "http2": "http2",
}
use_deps = {
    "ssl": "//packages/linux/dev-python:pyopenssl",
    "http2": "//packages/linux/dev-python:h2",
}
```

The eclass will install with: `pip install package[ssl,http2]` when USE flags are enabled.

## Build Process

### 1. Install Build Dependencies

```bash
pip install --prefix=$OUT <python_setup_requires>
```

### 2. Build Package

```bash
python setup.py build
```

or with pyproject.toml:

```bash
python -m build --wheel
```

### 3. Install

```bash
python setup.py install --prefix=/usr --root=$OUT
```

or:

```bash
pip install --prefix=/usr --root=$OUT dist/*.whl
```

## Dependencies

### Runtime Dependencies

Use standard `deps` field for Python package dependencies:

```python
deps = [
    "//packages/linux/dev-python:numpy",
    "//packages/linux/dev-python:scipy",
]
```

### Build Dependencies

For packages with C extensions, add system libraries:

```python
deps = [
    "//packages/linux/dev-libs:libfoo",
]
```

The Python eclass automatically provides Python, pip, and setuptools.

## C Extensions

Packages with C code need system library dependencies:

```python
package(
    build_rule = "python",
    name = "pillow",
    version = "10.1.0",
    url = "https://pypi.io/packages/source/p/pillow/pillow-10.1.0.tar.gz",
    sha256 = "...",
    deps = [
        "//packages/linux/media-libs:libjpeg-turbo",
        "//packages/linux/media-libs:libpng",
        "//packages/linux/sys-libs:zlib",
    ],
)
```

## Python Interpreter

Specify Python version:

```python
package(
    build_rule = "python",
    name = "legacy-pkg",
    python = "python2.7",  # Default is "python3"
    # ...
)
```

The eclass sets the `PYTHON` environment variable for the build.

## Example Packages

- Pure Python: `//packages/linux/dev-python:requests`
- C Extension: `//packages/linux/dev-python:numpy`
- CLI Tool: `//packages/linux/dev-python:black`

## References

- Python Packaging: https://packaging.python.org/
- PyPI: https://pypi.org/
- PEP 517/518: Build system interface
- PACKAGE-SPEC-001: Base package specification
