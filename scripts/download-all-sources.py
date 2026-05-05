#!/usr/bin/env python3
"""
Download all source files from Buck2 targets to a local directory.

This script:
1. Queries all Buck2 targets to find download sources
2. Downloads files with SHA256 verification
3. Implements rate limiting to respect upstream servers
4. Supports concurrent downloads with progress tracking
5. Creates a mirror-ready directory structure

Usage:
    ./scripts/download-all-sources.py --output-dir /path/to/downloads
    ./scripts/download-all-sources.py --output-dir /path/to/downloads --workers 4 --rate-limit 10
    ./scripts/download-all-sources.py --output-dir /path/to/downloads --targets //packages/linux/core/...
"""

import argparse
import configparser
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from threading import Lock, Semaphore
from typing import Dict, List, Optional, Set, Tuple
from urllib.parse import urlparse


def read_buckconfig_download_settings() -> Dict:
    """Read download settings from .buckconfig.

    Returns:
        Dict with 'max_concurrent', 'rate_limit', and 'timeout' settings
    """
    defaults = {
        'max_concurrent': 4,
        'rate_limit': 5.0,
        'timeout': 30,
    }

    # Look for .buckconfig in current directory and parent directories
    search_paths = [
        Path.cwd() / '.buckconfig',
        Path(__file__).parent.parent / '.buckconfig',
    ]

    for buckconfig_path in search_paths:
        if buckconfig_path.exists():
            try:
                config = configparser.ConfigParser()
                config.read(buckconfig_path)

                if config.has_section('download'):
                    return {
                        'max_concurrent': config.getint('download', 'max_concurrent', fallback=defaults['max_concurrent']),
                        'rate_limit': config.getfloat('download', 'rate_limit', fallback=defaults['rate_limit']),
                        'timeout': config.getint('download', 'timeout', fallback=defaults['timeout']),
                    }
            except (configparser.Error, ValueError) as e:
                print(f"Warning: Failed to parse {buckconfig_path}: {e}", file=sys.stderr)

    return defaults


class RateLimiter:
    """Token bucket rate limiter for controlling download rate."""

    def __init__(self, rate_per_second: float):
        """
        Args:
            rate_per_second: Maximum requests per second
        """
        self.rate = rate_per_second
        self.tokens = rate_per_second
        self.last_update = time.time()
        self.lock = Lock()

    def acquire(self):
        """Wait until a token is available."""
        while True:
            with self.lock:
                now = time.time()
                elapsed = now - self.last_update
                self.last_update = now

                # Add tokens based on elapsed time
                self.tokens = min(self.rate, self.tokens + elapsed * self.rate)

                if self.tokens >= 1.0:
                    self.tokens -= 1.0
                    return

            # Wait a bit before trying again
            time.sleep(0.1)


class DownloadStats:
    """Track download statistics."""

    def __init__(self):
        self.lock = Lock()
        self.total = 0
        self.downloaded = 0
        self.cached = 0
        self.failed = 0
        self.bytes_downloaded = 0

    def increment_downloaded(self, size: int):
        with self.lock:
            self.downloaded += 1
            self.bytes_downloaded += size

    def increment_cached(self):
        with self.lock:
            self.cached += 1

    def increment_failed(self):
        with self.lock:
            self.failed += 1

    def set_total(self, total: int):
        with self.lock:
            self.total = total

    def get_summary(self) -> str:
        with self.lock:
            mb_downloaded = self.bytes_downloaded / (1024 * 1024)
            return (
                f"Downloaded: {self.downloaded}/{self.total}, "
                f"Cached: {self.cached}, "
                f"Failed: {self.failed}, "
                f"Size: {mb_downloaded:.2f} MB"
            )


def run_buck_query(query: str) -> List[str]:
    """Run a Buck2 query and return results as list of lines.

    Args:
        query: Buck2 query string

    Returns:
        List of matching targets
    """
    try:
        result = subprocess.run(
            ["buck2", "query", query],
            capture_output=True,
            text=True,
            check=True,
        )
        return [line.strip() for line in result.stdout.strip().split("\n") if line.strip()]
    except subprocess.CalledProcessError as e:
        print(f"Error running buck2 query: {e}", file=sys.stderr)
        print(f"stderr: {e.stderr}", file=sys.stderr)
        return []


def get_target_attributes(target: str) -> Optional[Dict]:
    """Get attributes of a Buck2 target.

    Args:
        target: Buck2 target path

    Returns:
        Dict of target attributes or None if not found
    """
    try:
        result = subprocess.run(
            ["buck2", "query", f"labels(src_uri, {target})", "--output-attribute", "src_uri"],
            capture_output=True,
            text=True,
            check=True,
        )

        # Try to extract src_uri from output
        output = result.stdout.strip()
        if not output:
            return None

        # Also get sha256
        result_sha = subprocess.run(
            ["buck2", "query", f"labels(sha256, {target})", "--output-attribute", "sha256"],
            capture_output=True,
            text=True,
            check=True,
        )

        return {
            "src_uri": output,
            "sha256": result_sha.stdout.strip() if result_sha.stdout.strip() else None,
        }

    except subprocess.CalledProcessError:
        return None


def parse_buck_targets(targets_pattern: str = "//...") -> List[Tuple[str, str, str]]:
    """Parse Buck targets to extract download URLs and checksums.

    Args:
        targets_pattern: Buck query pattern for targets to process

    Returns:
        List of (target_name, url, sha256) tuples
    """
    print(f"Querying Buck targets matching: {targets_pattern}")

    # Find all targets with src_uri attribute (these are download_source targets)
    query = f'kind("http_file", {targets_pattern})'
    targets = run_buck_query(query)

    print(f"Found {len(targets)} http_file targets")

    downloads = []
    for target in targets:
        attrs = get_target_attributes(target)
        if attrs and attrs.get("src_uri"):
            url = attrs["src_uri"]
            sha256 = attrs.get("sha256", "")
            downloads.append((target, url, sha256))

    return downloads


def extract_downloads_from_starlark() -> List[Tuple[str, str, str]]:
    """
    Alternative method: Parse BUCK files directly to extract download information.
    This is more reliable than Buck queries for getting metadata.
    """
    print("Scanning BUCK files for download_source and http_file calls...")

    downloads = []
    buck_files = []
    unstable_count = 0

    # Find all BUCK files
    for root, dirs, files in os.walk("packages"):
        # Skip hidden directories
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for file in files:
            if file == "BUCK":
                buck_files.append(os.path.join(root, file))

    print(f"Found {len(buck_files)} BUCK files")

    # Pattern to extract src_uri and sha256 from BUCK files
    import re

    for buck_file in buck_files:
        try:
            with open(buck_file, "r") as f:
                content = f.read()

            # Remove comments to avoid matching commented-out URLs
            content = re.sub(r'#[^\n]*', '', content)

            # Extract package path as fallback
            package_path = buck_file.replace("packages/", "").replace("/BUCK", "")

            # Split into individual rules to extract names
            rules = re.split(r'\n(?=\w+_package\(|download_source\(|http_file\()', content)

            for rule in rules:
                # Extract name field if present
                name_match = re.search(r'name\s*=\s*"([^"]+)"', rule)
                package_name = name_match.group(1) if name_match else package_path

                # Clean up package name - remove -src suffix and lowercase
                package_name = package_name.replace("-src", "").lower()

                # Find download_source and http_file calls
                # Pattern: src_uri = "URL", sha256 = "HASH"
                pattern = r'src_uri\s*=\s*"([^"]+)"[^}]*?sha256\s*=\s*"([^"]+)"'
                matches = re.findall(pattern, rule, re.DOTALL)

                for url, sha256 in matches:
                    # Skip empty or placeholder URLs
                    if url and not url.startswith("...") and sha256 and sha256 != "0" * 64:
                        # Mark unstable GitHub archive URLs (checksums will be skipped)
                        if "/archive/" in url and "/refs/heads/" in url:
                            print(f"Warning: Unstable URL (will skip verification): {url}", file=sys.stderr)
                            unstable_count += 1
                            # Add with empty checksum to skip verification
                            downloads.append((package_name, url, ""))
                        else:
                            downloads.append((package_name, url, sha256))

        except Exception as e:
            print(f"Warning: Failed to parse {buck_file}: {e}", file=sys.stderr)

    if unstable_count > 0:
        print(f"\nFound {unstable_count} unstable URLs (branch archives)")
        print("Note: Checksum verification will be skipped for these files")
        print("Recommend using tagged releases instead (e.g., /archive/refs/tags/v1.0.0.tar.gz)")

    return downloads


def verify_sha256(file_path: Path, expected_sha256: str) -> bool:
    """Verify file SHA256 checksum.

    Args:
        file_path: Path to file
        expected_sha256: Expected SHA256 hash

    Returns:
        True if checksum matches
    """
    if not expected_sha256:
        return True  # No checksum to verify

    sha256 = hashlib.sha256()
    with open(file_path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            sha256.update(chunk)

    return sha256.hexdigest() == expected_sha256


def download_file(
    url: str,
    output_path: Path,
    sha256: Optional[str] = None,
    rate_limiter: Optional[RateLimiter] = None,
    stats: Optional[DownloadStats] = None,
    skip_verification: bool = False,
    timeout: int = 30,
) -> bool:
    """Download a file with checksum verification.

    Args:
        url: URL to download
        output_path: Destination path
        sha256: Expected SHA256 checksum
        rate_limiter: Rate limiter instance
        stats: Download statistics tracker
        skip_verification: Skip SHA256 verification
        timeout: Connection timeout in seconds

    Returns:
        True if download successful
    """
    # Check if file already exists and is valid
    if output_path.exists():
        if verify_sha256(output_path, sha256):
            if stats:
                stats.increment_cached()
            return True
        else:
            print(f"Checksum mismatch for cached {output_path}, re-downloading...")
            output_path.unlink()

    # Apply rate limiting
    if rate_limiter:
        rate_limiter.acquire()

    # Create parent directory
    output_path.parent.mkdir(parents=True, exist_ok=True)

    # Download with retries
    max_retries = 3
    for attempt in range(max_retries):
        try:
            print(f"Downloading {url} -> {output_path} (attempt {attempt + 1}/{max_retries})")

            # Use urllib with timeout
            with urllib.request.urlopen(url, timeout=timeout) as response:
                total_size = int(response.headers.get("content-length", 0))

                # Download to temporary file
                temp_path = output_path.with_suffix(output_path.suffix + ".tmp")
                bytes_downloaded = 0

                with open(temp_path, "wb") as f:
                    while True:
                        chunk = response.read(8192)
                        if not chunk:
                            break
                        f.write(chunk)
                        bytes_downloaded += len(chunk)

                # Verify checksum (if not skipped)
                if sha256 and not skip_verification:
                    if not verify_sha256(temp_path, sha256):
                        temp_path.unlink()
                        raise ValueError(f"SHA256 mismatch for {url}")
                elif sha256 and skip_verification:
                    print(f"  Skipping checksum verification (--skip-verification)")

                # Move to final location
                temp_path.rename(output_path)

                if stats:
                    stats.increment_downloaded(bytes_downloaded)

                print(f"✓ Downloaded {output_path.name} ({bytes_downloaded / 1024 / 1024:.2f} MB)")
                return True

        except (urllib.error.URLError, ValueError, OSError) as e:
            print(f"✗ Download failed (attempt {attempt + 1}/{max_retries}): {e}")
            if attempt < max_retries - 1:
                time.sleep(2 ** attempt)  # Exponential backoff
            else:
                if stats:
                    stats.increment_failed()
                return False

    return False


def create_mirror_structure(
    downloads: List[Tuple[str, str, str]], output_dir: Path, workers: int, rate_limit: float, skip_verification: bool = False, timeout: int = 30
) -> None:
    """Download all files to a mirror directory structure.

    Args:
        downloads: List of (target, url, sha256) tuples
        output_dir: Output directory
        workers: Number of concurrent workers
        rate_limit: Requests per second limit
        skip_verification: Skip SHA256 verification
        timeout: Connection timeout in seconds
    """
    output_dir.mkdir(parents=True, exist_ok=True)

    # Initialize rate limiter and stats
    rate_limiter = RateLimiter(rate_limit)
    stats = DownloadStats()
    stats.set_total(len(downloads))

    # Create manifest file
    manifest_path = output_dir / "MANIFEST.json"
    manifest = []

    # Download files concurrently
    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {}

        for target, url, sha256 in downloads:
            # Create filename from URL
            parsed = urlparse(url)
            original_filename = os.path.basename(parsed.path)

            # Create new filename with package name prefix
            # target is the package name (already lowercase from earlier processing)
            # Avoid duplicates if filename already starts with package name
            if original_filename.lower().startswith(target.lower() + "-"):
                filename = original_filename
            else:
                filename = f"{target}-{original_filename}"

            # Create subdirectory based on first letter of package name
            if target:
                first_letter = target[0].lower()
                subdir = output_dir / first_letter
            else:
                subdir = output_dir / "other"

            output_path = subdir / filename

            # Submit download task
            future = executor.submit(
                download_file, url, output_path, sha256, rate_limiter, stats, skip_verification, timeout
            )
            futures[future] = (target, url, sha256, output_path)

        # Process completed downloads
        for future in as_completed(futures):
            target, url, sha256, output_path = futures[future]
            success = future.result()

            manifest.append(
                {
                    "target": target,
                    "url": url,
                    "sha256": sha256,
                    "path": str(output_path.relative_to(output_dir)),
                    "success": success,
                }
            )

            # Print progress
            print(f"Progress: {stats.get_summary()}")

    # Write manifest
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)

    print(f"\n✓ Download complete!")
    print(f"  {stats.get_summary()}")
    print(f"  Manifest: {manifest_path}")


def main():
    # Read config settings from .buckconfig
    config_settings = read_buckconfig_download_settings()

    parser = argparse.ArgumentParser(
        description="Download all source files from Buck2 targets",
        epilog="Settings can also be configured in .buckconfig under [download] section.",
    )
    parser.add_argument(
        "--output-dir",
        "-o",
        type=Path,
        default=Path("downloads"),
        help="Output directory for downloads (default: ./downloads)",
    )
    parser.add_argument(
        "--workers",
        "-w",
        type=int,
        default=None,
        help=f"Number of concurrent download workers (default: {config_settings['max_concurrent']} from .buckconfig)",
    )
    parser.add_argument(
        "--rate-limit",
        "-r",
        type=float,
        default=None,
        help=f"Maximum downloads per second (default: {config_settings['rate_limit']} from .buckconfig)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=None,
        help=f"Connection timeout in seconds (default: {config_settings['timeout']} from .buckconfig)",
    )
    parser.add_argument(
        "--targets",
        "-t",
        type=str,
        default="//packages/...",
        help="Buck target pattern to query (default: //packages/...)",
    )
    parser.add_argument(
        "--method",
        "-m",
        choices=["query", "parse"],
        default="parse",
        help="Method to extract downloads: 'query' uses buck2 query, 'parse' scans BUCK files (default: parse)",
    )
    parser.add_argument(
        "--skip-verification",
        action="store_true",
        help="Skip SHA256 checksum verification (allows unstable URLs)",
    )

    args = parser.parse_args()

    # Apply config defaults if CLI args not provided
    workers = args.workers if args.workers is not None else config_settings['max_concurrent']
    rate_limit = args.rate_limit if args.rate_limit is not None else config_settings['rate_limit']
    timeout = args.timeout if args.timeout is not None else config_settings['timeout']

    print("BuckOS Source Downloader")
    print("=" * 60)
    print(f"Output directory: {args.output_dir}")
    print(f"Workers: {workers}" + (" (from .buckconfig)" if args.workers is None else " (from CLI)"))
    print(f"Rate limit: {rate_limit} req/sec" + (" (from .buckconfig)" if args.rate_limit is None else " (from CLI)"))
    print(f"Timeout: {timeout}s" + (" (from .buckconfig)" if args.timeout is None else " (from CLI)"))
    print(f"Target pattern: {args.targets}")
    print(f"Method: {args.method}")
    print("=" * 60)

    # Extract download information
    if args.method == "query":
        downloads = parse_buck_targets(args.targets)
    else:
        downloads = extract_downloads_from_starlark()

    if not downloads:
        print("No downloads found!")
        return 1

    print(f"\nFound {len(downloads)} source files to download\n")

    # Show first few downloads
    print("Sample downloads:")
    for i, (target, url, sha256) in enumerate(downloads[:5]):
        print(f"  {i+1}. {url}")
        print(f"     SHA256: {sha256[:16]}...")
        print(f"     Target: {target}")
    if len(downloads) > 5:
        print(f"  ... and {len(downloads) - 5} more")
    print()

    # Confirm with user
    response = input("Proceed with download? [y/N] ")
    if response.lower() not in ["y", "yes"]:
        print("Cancelled.")
        return 0

    # Download all files
    create_mirror_structure(downloads, args.output_dir, workers, rate_limit, args.skip_verification, timeout)

    return 0


if __name__ == "__main__":
    sys.exit(main())
