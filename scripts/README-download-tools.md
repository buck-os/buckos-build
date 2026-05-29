# Source Download Tools

This directory contains tools for downloading all BuckOS source files, useful for creating mirrors or offline builds.

## Tools

### 1. `download-all-sources.py` - Python Downloader

Interactive Python script with concurrent downloads, progress tracking, and rate limiting.

**Features:**
- Concurrent downloads with configurable workers
- Rate limiting (requests per second)
- SHA256 verification
- Resume support (skips already-downloaded files)
- Progress tracking and statistics
- Creates JSON manifest

**Usage:**

```bash
# Basic usage
./scripts/download-all-sources.py --output-dir /path/to/downloads

# With custom settings
./scripts/download-all-sources.py \
    --output-dir /path/to/mirror \
    --workers 8 \
    --rate-limit 10 \
    --targets "//packages/linux/core/..."

# Help
./scripts/download-all-sources.py --help
```

**Options:**
- `--output-dir, -o DIR` - Output directory (default: ./downloads)
- `--workers, -w N` - Concurrent workers (default: 4)
- `--rate-limit, -r N` - Max requests/sec (default: 5.0)
- `--targets, -t PATTERN` - Buck target pattern (default: //packages/...)
- `--method, -m METHOD` - Extraction method: 'query' or 'parse' (default: parse)

**Methods:**
- `parse` - Fast, scans BUCK files directly (recommended)
- `query` - Uses `buck2 query` (slower but more accurate)

### 2. `generate-download-script.py` - Shell Script Generator

Generates a standalone bash script that can be run on any system.

**Features:**
- No dependencies (just bash, curl/wget, sha256sum)
- Perfect for running on remote mirrors
- Self-contained (all URLs and checksums embedded)
- Rate limiting and retry logic
- Creates download manifest

**Usage:**

```bash
# Generate script to stdout
./scripts/generate-download-script.py > download-all.sh

# Generate to file
./scripts/generate-download-script.py --output download-all.sh

# Use wget instead of curl
./scripts/generate-download-script.py --wget --output download-all.sh

# Custom settings
./scripts/generate-download-script.py \
    --output download-all.sh \
    --output-dir /var/www/mirror \
    --rate-limit 10

# Help
./scripts/generate-download-script.py --help
```

**Options:**
- `--output, -o FILE` - Output script file (default: stdout)
- `--output-dir, -d DIR` - Download directory in script (default: downloads)
- `--rate-limit, -r N` - Requests/sec (default: 5.0)
- `--wget` - Use wget instead of curl

**Running the generated script:**

```bash
# On your mirror server
bash download-all.sh

# Or make it executable
chmod +x download-all.sh
./download-all.sh
```

## Use Cases

### Creating a Local Mirror

```bash
# Generate download script
./scripts/generate-download-script.py --output-dir /var/www/buckos-mirror > mirror-sync.sh

# Run on mirror server
scp mirror-sync.sh mirror.example.com:/tmp/
ssh mirror.example.com 'bash /tmp/mirror-sync.sh'
```

### Offline Build Preparation

```bash
# Download all sources to portable drive
./scripts/download-all-sources.py --output-dir /mnt/usb/buckos-sources --workers 8

# Later, use as local mirror
buck2 build ... --config http.mirror_url=file:///mnt/usb/buckos-sources
```

### CI/CD Pre-caching

```bash
# In CI pipeline, download and cache sources
./scripts/download-all-sources.py \
    --output-dir /cache/buckos-sources \
    --workers 16 \
    --rate-limit 20
```

### Gentoo-style DISTDIR

```bash
# Download to DISTDIR-compatible structure
./scripts/download-all-sources.py --output-dir /var/cache/distfiles

# Files organized by first letter:
# /var/cache/distfiles/b/bash-5.3.tar.gz
# /var/cache/distfiles/c/curl-8.5.0.tar.xz
# /var/cache/distfiles/l/linux-6.6.tar.xz
```

## Output Structure

Both tools create a similar directory structure:

```
downloads/
├── a/
│   ├── acl-2.3.1.tar.gz
│   └── autoconf-2.71.tar.xz
├── b/
│   ├── bash-5.3.tar.gz
│   ├── binutils-2.41.tar.xz
│   └── bison-3.8.2.tar.xz
├── c/
│   ├── curl-8.5.0.tar.xz
│   └── coreutils-9.4.tar.xz
├── MANIFEST.json (Python script)
└── MANIFEST.txt (Shell script)
```

## Performance Tips

### Optimize Download Speed

```bash
# More workers for faster downloads
./scripts/download-all-sources.py --workers 16 --rate-limit 20

# But respect upstream servers - use rate limiting!
```

### Minimize Bandwidth

```bash
# Check what needs downloading first
./scripts/download-all-sources.py --output-dir /existing/cache --workers 1

# It will skip files that already exist with valid checksums
```

### Parallel Generation

```bash
# Download different package categories in parallel
./scripts/download-all-sources.py --targets "//packages/linux/core/..." &
./scripts/download-all-sources.py --targets "//packages/linux/desktop/..." &
wait
```

## Troubleshooting

### "No downloads found"

Ensure you're in the repository root:
```bash
cd /path/to/buckos-build
./scripts/download-all-sources.py
```

### Rate Limiting Issues

If you're getting rate limited by upstream:
```bash
# Reduce rate
./scripts/download-all-sources.py --rate-limit 2 --workers 2
```

### SHA256 Mismatches

If checksums don't match:
1. Check if BUCK files have correct checksums
2. Re-download (script will retry automatically)
3. Manually update the `sha256` field in the relevant BUCK file

### Missing Dependencies (Python script)

The Python script only requires Python 3.7+ standard library.
No external dependencies needed!

### Missing Dependencies (Shell script)

The generated shell script requires:
- bash
- curl (default) or wget (--wget flag)
- sha256sum or shasum
- bc (for rate limiting)

Install on Debian/Ubuntu:
```bash
sudo apt install curl bc coreutils
```

Install on RHEL/Fedora:
```bash
sudo dnf install curl bc coreutils
```

## Integration with Buck2

### Use Downloaded Sources

Configure Buck2 to use your local mirror:

```bash
# .buckconfig
[http]
mirror_url = file:///path/to/downloads
```

### Verify Downloads Match Buck Targets

```bash
# Compare manifest with Buck targets
buck2 query 'kind("http_file", //...)' | wc -l
jq length downloads/MANIFEST.json
```

## Advanced Usage

### Custom URL Filtering

Modify the Python scripts to filter URLs:

```python
# Only download from specific domains
if "kernel.org" in url or "gnu.org" in url:
    downloads.append((package, url, sha256))
```

### Bandwidth Monitoring

```bash
# Monitor download progress
watch -n 1 'du -sh downloads/ && find downloads/ -type f | wc -l'
```

### Create Torrent for Distribution

```bash
# After downloading
./scripts/download-all-sources.py --output-dir buckos-sources-$(date +%Y%m%d)
tar czf buckos-sources-$(date +%Y%m%d).tar.gz buckos-sources-*/
mktorrent -a tracker.example.com buckos-sources-*.tar.gz
```

## See Also

- `defs/package.bzl` - The `package()` macro (build-rule dispatch, source download, transforms)
- Buck2 documentation: https://buck2.build/
