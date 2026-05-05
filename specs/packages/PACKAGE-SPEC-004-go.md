---
id: "PACKAGE-SPEC-004"
title: "Go Packages"
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
  - "go"
  - "golang"
  - "language-packages"

related:
  - "PACKAGE-SPEC-001"
  - "PACKAGE-SPEC-003"
  - "PACKAGE-SPEC-005"

implementation:
  status: "complete"
  completeness: 85

compatibility:
  buck2_version: ">=2024.11.01"
  buckos_version: ">=1.0.0"
  breaking_changes: false
---

# Go Package Specification

## Abstract

This specification defines how to create BuckOS packages for Go projects using Go modules.

## Package Type

**`package(build_rule = "go")`** - Builds Go projects with `go build`

## Quick Start

### Basic Go Package

```python
load("//defs:package.bzl", "package")

package(
    build_rule = "go",
    name = "hugo",
    version = "0.121.0",
    url = "https://github.com/gohugoio/hugo/archive/v0.121.0.tar.gz",
    sha256 = "abc123...",
    packages = ["."],
    maintainers = ["go@buckos.org"],
)
```

### Multi-Binary Package

```python
package(
    build_rule = "go",
    name = "k8s-tools",
    version = "1.28.0",
    url = "https://github.com/kubernetes/kubernetes/archive/v1.28.0.tar.gz",
    sha256 = "xyz789...",
    packages = [
        "./cmd/kubectl",
        "./cmd/kubelet",
        "./cmd/kube-proxy",
    ],
)
```

### With USE Flags and Build Tags

```python
package(
    build_rule = "go",
    name = "tool",
    version = "1.0.0",
    url = "...",
    sha256 = "...",
    iuse = ["netgo", "sqlite"],
    use_tags = {
        "netgo": "netgo",
        "sqlite": "sqlite",
    },
    go_build_args = ["-ldflags", "-w -s -X main.version=1.0.0"],
)
```

## Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Package name |
| `version` | string | Package version |
| `url` | string | Source tarball URL |
| `sha256` | string | SHA-256 checksum |

## Go-Specific Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `bins` | list[string] | [] | Binary names to install |
| `packages` | list[string] | ["."] | Go packages to build |
| `go_build_args` | list[string] | [] | Additional go build arguments (ldflags, etc.) |
| `use_tags` | dict | {} | Map USE flags to Go build tags |
| `use_deps` | dict | {} | Conditional dependencies based on USE flags |

## Build Process

### 1. Module Download

```bash
go mod download
go mod vendor  # For reproducibility
```

### 2. Build

```bash
go build \
    -tags="$BUILD_TAGS" \
    -ldflags="$LDFLAGS" \
    -o $OUT/bin/ \
    <go_packages>
```

### 3. Installation

Binaries installed to `/usr/bin/`

## Build Tags

Build tags are controlled via USE flags:

```python
iuse = ["netgo", "sqlite", "postgres"]
use_tags = {
    "netgo": "netgo",
    "sqlite": "sqlite",
    "postgres": "postgres",
}
use_deps = {
    "sqlite": "//packages/linux/dev-db:sqlite",
    "postgres": "//packages/linux/dev-db:postgresql",
}
```

## Build Arguments

Linker flags and other build args via `go_build_args`:

```python
go_build_args = [
    "-ldflags",
    "-w -s -X main.version={version}".format(version = version),
]
```

The eclass sets these via `GO_BUILD_FLAGS` environment variable.

## CGO Support

### Disable CGO (Pure Go)

```python
env = {
    "CGO_ENABLED": "0",
}
```

### Enable CGO with Dependencies

```python
env = {
    "CGO_ENABLED": "1",
}
deps = [
    "//packages/linux/dev-libs:libfoo",
]
```

## Cross-Compilation

```python
package(
    build_rule = "go",
    name = "app",
    env = {
        "GOOS": "linux",
        "GOARCH": "arm64",
        "CGO_ENABLED": "0",
    },
)
```

## Example Packages

- Simple CLI: `//packages/linux/dev-vcs:gh`
- Complex: `//packages/linux/sys-cluster:kubernetes`
- Tools: `//packages/linux/dev-util:golangci-lint`

## References

- Go Modules: https://go.dev/ref/mod
- Go Build: https://pkg.go.dev/cmd/go#hdr-Compile_packages_and_dependencies
- PACKAGE-SPEC-001: Base package specification
