#!/usr/bin/env python3
"""
Query whether a binary package is available on the mirror.

This script is called by Buck build rules to determine if a precompiled
binary exists before attempting to build from source.

Exit codes:
    0 - Binary available
    1 - Binary not available or error

Output (on success):
    JSON with package URL and metadata
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path
from typing import Dict, Optional


def calculate_config_hash(target: str) -> str:
    """Calculate a hash representing the build configuration.

    This must match the config hash calculation in package-binary.py.
    """
    config_parts = []

    # Get platform info
    platform = subprocess.run(
        ["uname", "-m"],
        capture_output=True,
        text=True,
        check=True
    ).stdout.strip()
    config_parts.append(f"platform:{platform}")

    # Get USE flags from .buckconfig [use] section
    try:
        import configparser
        bc = configparser.ConfigParser()
        bc.read(".buckconfig")
        if bc.has_section("use"):
            flags = [k for k, v in bc.items("use") if v.lower() in ("true", "1", "yes")]
            if flags:
                config_parts.append(f"use:{','.join(sorted(flags))}")
    except Exception:
        pass

    # Get compiler version
    try:
        gcc_version = subprocess.run(
            ["gcc", "--version"],
            capture_output=True,
            text=True,
            check=True
        ).stdout.split('\n')[0]
        config_parts.append(f"gcc:{gcc_version}")
    except:
        pass

    # Get target dependencies
    try:
        deps_result = subprocess.run(
            ["buck2", "query", f"deps({target})", "--output-attribute", "name"],
            capture_output=True,
            text=True,
            check=True
        )
        deps_hash = hashlib.sha256(deps_result.stdout.encode()).hexdigest()[:8]
        config_parts.append(f"deps:{deps_hash}")
    except:
        pass

    # Combine all config parts and hash
    config_string = "|".join(config_parts)
    config_hash = hashlib.sha256(config_string.encode()).hexdigest()[:8]

    return config_hash


def query_package_index(mirror_url: str, package_name: str, version: str, config_hash: str) -> Optional[Dict]:
    """Query the mirror index for a specific package.

    Args:
        mirror_url: Base mirror URL
        package_name: Package name
        version: Package version
        config_hash: Config hash to match

    Returns:
        Package info dict if found, None otherwise
    """
    index_url = f"{mirror_url}/binaries/index.json"

    try:
        with urllib.request.urlopen(index_url, timeout=5) as response:
            index = json.loads(response.read())

            # Look in by_name index
            packages = index.get("by_name", {}).get(package_name, [])

            # Find matching version and config hash
            for pkg in packages:
                if pkg.get("version") == version and pkg.get("config_hash") == config_hash:
                    return pkg

    except Exception as e:
        # Silently fail - we'll just build from source
        pass

    return None


def check_binary_exists(mirror_url: str, package_name: str, filename: str) -> bool:
    """Check if binary package file exists on mirror.

    Args:
        mirror_url: Base mirror URL
        package_name: Package name
        filename: Package filename

    Returns:
        True if file exists
    """
    first_letter = package_name[0].lower()
    package_url = f"{mirror_url}/binaries/{first_letter}/{filename}"

    try:
        request = urllib.request.Request(package_url, method='HEAD')
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status == 200
    except:
        return False


def main():
    parser = argparse.ArgumentParser(
        description="Query if binary package is available on mirror"
    )
    parser.add_argument(
        "--target",
        required=True,
        help="Buck target (e.g., //packages/linux/core/bash:bash)"
    )
    parser.add_argument(
        "--package-name",
        required=True,
        help="Package name (e.g., bash)"
    )
    parser.add_argument(
        "--version",
        required=True,
        help="Package version (e.g., 5.3)"
    )
    parser.add_argument(
        "--mirror-url",
        default=os.environ.get("BUCKOS_BINARY_MIRROR", "https://mirror.buckos.org"),
        help="Mirror base URL (default: $BUCKOS_BINARY_MIRROR or https://mirror.buckos.org)"
    )
    parser.add_argument(
        "--config-hash",
        help="Pre-calculated config hash (optional, will calculate if not provided)"
    )
    parser.add_argument(
        "--quiet",
        "-q",
        action="store_true",
        help="Suppress informational output"
    )

    args = parser.parse_args()

    # Calculate or use provided config hash
    if args.config_hash:
        config_hash = args.config_hash
    else:
        if not args.quiet:
            print(f"Calculating config hash for {args.target}...", file=sys.stderr)
        config_hash = calculate_config_hash(args.target)
        if not args.quiet:
            print(f"Config hash: {config_hash}", file=sys.stderr)

    # Query package index
    if not args.quiet:
        print(f"Querying mirror for {args.package_name} {args.version} ({config_hash})...", file=sys.stderr)

    pkg_info = query_package_index(args.mirror_url, args.package_name, args.version, config_hash)

    if not pkg_info:
        if not args.quiet:
            print(f"Binary not found in index", file=sys.stderr)
        sys.exit(1)

    # Verify file exists
    filename = pkg_info.get("filename")
    if not check_binary_exists(args.mirror_url, args.package_name, filename):
        if not args.quiet:
            print(f"Binary file not found on mirror", file=sys.stderr)
        sys.exit(1)

    # Success - output package info
    first_letter = args.package_name[0].lower()
    package_url = f"{args.mirror_url}/binaries/{first_letter}/{filename}"

    result = {
        "url": package_url,
        "filename": filename,
        "version": pkg_info.get("version"),
        "config_hash": pkg_info.get("config_hash"),
        "file_hash": pkg_info.get("file_hash"),
        "size": pkg_info.get("size"),
    }

    print(json.dumps(result, indent=2))

    if not args.quiet:
        print(f"✓ Binary available: {package_url}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
