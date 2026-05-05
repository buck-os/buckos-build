

# Binary Package System

Precompiled binary packages for faster deployment and distribution.

## Overview

The binary package system allows you to:
1. **Build** Buck targets and package outputs
2. **Upload** packages to mirrors with automatic organization
3. **Download** and install precompiled binaries
4. **Verify** integrity with config and file hashes

## Package Naming Format

```
<package>-<version>-<config_hash>-bin.tar.gz
<package>-<version>-<config_hash>-bin.tar.gz.sha256
```

**Example:**
```
bash-5.3-a1b2c3d4-bin.tar.gz
bash-5.3-a1b2c3d4-bin.tar.gz.sha256
```

Where:
- **package**: Package name (e.g., `bash`, `vim`, `gcc`)
- **version**: Package version (e.g., `5.3`, `9.1.0`)
- **config_hash**: 8-char hash of build configuration (compiler, USE flags, platform, dependencies)
- **-bin**: Suffix to indicate binary package
- **.sha256**: Hash file containing SHA256 checksum and metadata

The config hash in the filename allows multiple builds with different configurations to coexist:
- `bash-5.3-a1b2c3d4-bin.tar.gz` - Built with SSL enabled
- `bash-5.3-e5f6g7h8-bin.tar.gz` - Built without SSL

The `.sha256` file format:
```
<tarball_sha256>  <filename>
# Config Hash: <8-char config hash>
# Content Hash: <8-char content hash>
# Package: <package name>
# Version: <version>
# Target: <buck target>
```

This format allows automatic verification using standard tools like `sha256sum -c`.

## Scripts

### 1. `package-binary.py` - Build and Package

Build Buck targets and create binary packages.

```bash
# Package a single target
./scripts/package-binary.py //packages/linux/core/bash:bash

# Package multiple targets
./scripts/package-binary.py \
    //packages/linux/core/bash:bash \
    //packages/linux/editors/vim:vim \
    //packages/linux/core/coreutils:coreutils

# Package and upload to mirror
./scripts/package-binary.py \
    //packages/linux/core/bash:bash \
    --upload \
    --mirror-url user@mirror.buckos.org:/var/www/buckos-mirror/binaries

# Custom output directory
./scripts/package-binary.py \
    //packages/linux/core/bash:bash \
    --output-dir /path/to/binaries
```

**Options:**
- `--output-dir, -o DIR` - Output directory (default: ./binaries)
- `--upload, -u` - Upload after packaging
- `--mirror-url, -m URL` - Mirror URL for upload

### 2. `upload-binaries.py` - Upload to Mirror

Upload binary packages to mirror server with automatic organization.

```bash
# Upload to remote mirror via SCP
./scripts/upload-binaries.py \
    --source ./binaries \
    --mirror user@mirror.buckos.org:/var/www/buckos-mirror/binaries

# Upload to local mirror
./scripts/upload-binaries.py \
    --source ./binaries \
    --mirror /var/www/buckos-mirror/binaries

# Use rsync (faster for updates)
./scripts/upload-binaries.py \
    --source ./binaries \
    --mirror user@mirror.buckos.org:/var/www/buckos-mirror/binaries \
    --use-rsync

# Generate index only (no upload)
./scripts/upload-binaries.py \
    --source ./binaries \
    --generate-index-only

# Dry run (see what would be uploaded)
./scripts/upload-binaries.py \
    --source ./binaries \
    --mirror user@mirror.buckos.org:/var/www/buckos-mirror/binaries \
    --dry-run
```

**Options:**
- `--source, -s DIR` - Source directory with packages (required)
- `--mirror, -m URL` - Mirror destination
- `--use-rsync, -r` - Use rsync instead of scp
- `--staging-dir DIR` - Staging directory (default: /tmp/buckos-binaries-staging)
- `--generate-index-only, -i` - Only generate index.json
- `--dry-run, -n` - Show what would be uploaded

**Mirror Organization:**

Packages are organized by package name's first letter:

```
binaries/
├── a/
│   ├── aspell-0.60.8.1-abc12345-bin.tar.gz
│   ├── aspell-0.60.8.1-abc12345-bin.tar.gz.sha256
│   ├── autoconf-2.71-def67890-bin.tar.gz
│   └── autoconf-2.71-def67890-bin.tar.gz.sha256
├── b/
│   ├── bash-5.3-a1b2c3d4-bin.tar.gz        # Built with config A
│   ├── bash-5.3-a1b2c3d4-bin.tar.gz.sha256
│   ├── bash-5.3-e5f6g7h8-bin.tar.gz        # Built with config B (different USE flags)
│   ├── bash-5.3-e5f6g7h8-bin.tar.gz.sha256
│   ├── bison-3.8.2-jkl13141-bin.tar.gz
│   └── bison-3.8.2-jkl13141-bin.tar.gz.sha256
├── v/
│   ├── vim-9.1.0-mno15161-bin.tar.gz
│   └── vim-9.1.0-mno15161-bin.tar.gz.sha256
└── index.json
```

### 3. `install-binary.py` - Download and Install

Download and install precompiled binaries from mirror.

```bash
# Install a package
./scripts/install-binary.py bash --version 5.3

# Install to custom prefix
./scripts/install-binary.py bash --version 5.3 --prefix /opt/buckos

# Specify config hash for exact match
./scripts/install-binary.py bash \
    --version 5.3 \
    --config-hash abc12345

# Download only (don't install)
./scripts/install-binary.py bash \
    --version 5.3 \
    --download-only

# List available versions
./scripts/install-binary.py bash --list
```

**Options:**
- `--version, -v VERSION` - Package version (required)
- `--config-hash, -c HASH` - Config hash (8 hex chars)
- `--file-hash, -f HASH` - File hash (8 hex chars)
- `--mirror-url, -m URL` - Mirror base URL (default: https://mirror.buckos.org)
- `--prefix, -p PATH` - Installation prefix (default: /usr)
- `--download-only, -d` - Download but don't install
- `--list, -l` - List available versions
- `--cache-dir DIR` - Download cache (default: ~/.cache/buckos-binaries)

## Workflows

### Workflow 1: Build and Distribute Binaries

```bash
# 1. Build and package targets
./scripts/package-binary.py \
    //packages/linux/core/bash:bash \
    //packages/linux/editors/vim:vim \
    --output-dir ./binaries

# 2. Upload to mirror
./scripts/upload-binaries.py \
    --source ./binaries \
    --mirror user@mirror.buckos.org:/var/www/buckos-mirror/binaries

# 3. Users can now install
./scripts/install-binary.py bash --version 5.3
```

### Workflow 2: CI/CD Build Pipeline

```bash
#!/bin/bash
# ci-build.sh - Build and publish binaries

TARGETS=(
    "//packages/linux/core/bash:bash"
    "//packages/linux/editors/vim:vim"
    "//packages/linux/core/coreutils:coreutils"
)

# Build and package
for target in "${TARGETS[@]}"; do
    ./scripts/package-binary.py "$target" --output-dir ./ci-binaries
done

# Upload to mirror
./scripts/upload-binaries.py \
    --source ./ci-binaries \
    --mirror user@mirror.buckos.org:/var/www/buckos-mirror/binaries \
    --use-rsync
```

### Workflow 3: Local Development with Binary Cache

```bash
# Build and cache locally
./scripts/package-binary.py \
    //packages/linux/core/bash:bash \
    --output-dir ~/.cache/buckos-build

# "Install" from local cache
./scripts/upload-binaries.py \
    --source ~/.cache/buckos-build \
    --mirror /usr/local/buckos-binaries
```

## Config Hash Details

The config hash ensures binaries are only reused when built with identical configuration:

**Included in hash:**
- Platform/architecture (`uname -m`)
- Compiler version (`gcc --version`)
- USE flags (from `.buckconfig` `[use]` section)
- Dependencies (hash of `buck2 query deps(target)`)

**Example:**
```
Config parts:
  platform: x86_64
  use: ["ssl", "ipv6", "systemd"]
  gcc: gcc (GCC) 14.2.0
  deps: a1b2c3d4

Hash: SHA256(all parts)[:8] = "e5f6g7h8"
```

This means two packages with different USE flags will have different config hashes, preventing incompatible binaries from being used.

## File Hash Details

The file hash is the first 8 characters of the SHA256 hash of the package contents. This ensures:
- **Integrity**: Detect corruption during download
- **Uniqueness**: Different builds produce different hashes
- **Reproducibility**: Same source + config = same hash

## Index Format

The `index.json` file generated by `upload-binaries.py`:

```json
{
  "total": 150,
  "packages": [
    {
      "name": "bash",
      "version": "5.3",
      "config_hash": "abc12345",
      "file_hash": "def67890",
      "filename": "bash-5.3-abc12345-def67890.tar.gz",
      "size": 1048576
    }
  ],
  "by_name": {
    "bash": [
      {
        "version": "5.3",
        "config_hash": "abc12345",
        "file_hash": "def67890",
        "filename": "bash-5.3-abc12345-def67890.tar.gz",
        "size": 1048576
      }
    ]
  }
}
```

## Configuration

Binary package settings can be configured in `.buckconfig`:

```ini
[buckos]
# Mirror URL for precompiled binary packages
binary_mirror = https://mirror.buckos.org

# Whether to prefer binary packages (for future integration)
prefer_binaries = true
```

This configuration is used by the binary package scripts and can be leveraged by future build system integrations or package managers.

## Best Practices

### 1. Version Compatibility

Always match versions exactly:
```bash
# Good
./scripts/install-binary.py bash --version 5.3

# Bad (might get wrong version)
./scripts/install-binary.py bash
```

### 2. Config Hash Matching

For production, specify config hash:
```bash
# Ensures exact build configuration
./scripts/install-binary.py bash \
    --version 5.3 \
    --config-hash abc12345
```

### 3. Upload Organization

Use rsync for efficiency:
```bash
# First upload: SCP is fine
./scripts/upload-binaries.py --source ./binaries --mirror user@host:/path

# Subsequent uploads: Use rsync
./scripts/upload-binaries.py --source ./binaries --mirror user@host:/path --use-rsync
```

### 4. Mirror Structure

Recommended mirror directory structure:
```
/var/www/buckos-mirror/
├── sources/           # Source tarballs (from download-all.sh)
│   ├── a/
│   ├── b/
│   └── ...
└── binaries/          # Precompiled binaries
    ├── a/
    ├── b/
    ├── ...
    └── index.json
```

## Troubleshooting

### Package Not Found

```bash
# List available packages
./scripts/install-binary.py bash --list

# Check mirror index
curl https://mirror.buckos.org/binaries/index.json | jq .by_name.bash
```

### Hash Mismatch

Config hash mismatch means different build configuration:
```bash
# Check what config hash you have
./scripts/package-binary.py //packages/linux/core/bash:bash --output-dir ./test

# Install with your config hash
./scripts/install-binary.py bash --version 5.3 --config-hash <your-hash>
```

### Upload Fails

```bash
# Test connection
ssh user@mirror.buckos.org

# Use dry-run to test
./scripts/upload-binaries.py --source ./binaries --mirror user@host:/path --dry-run

# Try local upload first
./scripts/upload-binaries.py --source ./binaries --mirror /tmp/test-mirror
```

## Complete Workflow Example

### Setting Up a Binary Package Mirror

```bash
# 1. Configure your mirror in .buckconfig
cat >> .buckconfig << EOF
[buckos]
binary_mirror = https://mirror.buckos.org
prefer_binaries = true
EOF

# 2. Build and package some targets
./scripts/package-binary.py \
    //packages/linux/core/bash:bash \
    //packages/linux/core/coreutils:coreutils \
    //packages/linux/editors/vim:vim \
    --output-dir ./binaries

# 3. Upload to mirror
./scripts/upload-binaries.py \
    --source ./binaries \
    --mirror user@mirror.buckos.org:/var/www/buckos-mirror/binaries \
    --use-rsync

# 4. Now builds will use binaries automatically
buck2 build //packages/linux/core:bash
# Output: "Binary available, downloading..."
```

### Using Binary Packages

Binary packages are managed separately from Buck builds using the provided scripts:

1. **Build & Package**: Use `package-binary.py` to create binaries from Buck targets
2. **Upload**: Use `upload-binaries.py` to publish to mirrors
3. **Install**: Use `install-binary.py` to download and install binaries directly

Future integration with the build system or package managers can leverage the config hash system to automatically select compatible binaries.

## Future Enhancements

Potential improvements:
1. **Signature verification** - GPG sign packages
2. **Compression options** - zstd, xz levels
3. **Delta updates** - Binary diffs for upgrades
4. **Multi-arch** - Same package for x86_64, aarch64, etc.
5. **CDN integration** - Multiple mirror support with fallback
6. **Build cache** - Share binaries across team members

## See Also

- `scripts/download-all-sources.py` - Download source packages
- `scripts/generate-download-script.py` - Generate mirror scripts
- `defs/package_defs.bzl` - Package definitions
- Buck2 documentation: https://buck2.build/
