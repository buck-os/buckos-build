#!/usr/bin/env python3
"""
Package Buck build outputs as precompiled binaries for distribution.

This script:
1. Builds a Buck target
2. Calculates config hash (compiler flags, dependencies, platform)
3. Calculates file hash (SHA256 of output)
4. Packages output as: package-version-confighash-filehash.tar.gz
5. Optionally uploads to mirror

Usage:
    # Package a single target
    ./scripts/package-binary.py //packages/linux/core/bash:bash

    # Package with upload
    ./scripts/package-binary.py //packages/linux/core/bash:bash --upload

    # Package multiple targets
    ./scripts/package-binary.py //packages/linux/core/bash:bash //packages/linux/editors/vim:vim

    # Specify output directory
    ./scripts/package-binary.py //packages/linux/core/bash:bash --output-dir /path/to/binaries
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tarfile
from pathlib import Path
from typing import Dict, List, Optional, Tuple


def run_command(cmd: List[str], capture: bool = True) -> subprocess.CompletedProcess:
    """Run a command and return the result."""
    if capture:
        return subprocess.run(cmd, capture_output=True, text=True, check=True)
    else:
        return subprocess.run(cmd, check=True)


def get_target_info(target: str, skip_build: bool = False) -> Dict:
    """Get information about a Buck target.

    Args:
        target: Buck target path (e.g., //packages/linux/core/bash:bash)
        skip_build: If True, use uquery instead of query to avoid analysis

    Returns:
        Dict with target metadata
    """
    print(f"Getting info for {target}...")

    if skip_build:
        # Use uquery to avoid configured target analysis
        query_cmd = "uquery"
    else:
        query_cmd = "query"

    try:
        # Query target attributes
        result = run_command([
            "buck2", query_cmd,
            f"{target}",
            "--output-attribute", "name",
            "--output-attribute", "version",
            "--json"
        ])

        # Buck2 may output logging lines before JSON, find the JSON part
        stdout = result.stdout
        json_start = stdout.find('{')
        if json_start != -1:
            stdout = stdout[json_start:]

        info = json.loads(stdout)
        # Extract from JSON structure - target may have "buckos//" prefix
        target_key = target
        if target not in info and f"buckos//{target.lstrip('//')}" in info:
            target_key = f"buckos//{target.lstrip('//')}"

        target_data = info.get(target_key, {})
        return {
            "target": target,
            "name": target_data.get("name", target.split(":")[-1]),
            "version": target_data.get("version", "unknown"),
        }
    except (json.JSONDecodeError, subprocess.CalledProcessError) as e:
        # Fallback parsing
        print(f"Warning: Failed to query target info: {e}")
        return {
            "target": target,
            "name": target.split(":")[-1],
            "version": "unknown",
        }


def calculate_config_hash(target: str, skip_build: bool = False) -> str:
    """Calculate a hash representing the build configuration.

    This includes:
    - Package compatibility (fedora/buckos)
    - Compiler flags (CFLAGS, CXXFLAGS, LDFLAGS)
    - USE flags
    - Platform/architecture
    - Dependencies and their versions

    Args:
        target: Buck target path
        skip_build: If True, skip Buck queries that might trigger builds

    Returns:
        Full SHA256 hex hash of config (64 characters)
    """
    print(f"Calculating config hash for {target}...")

    config_parts = []

    # Get package compatibility (fedora vs buckos)
    try:
        with open("config/package_config.bzl", "r") as f:
            package_config = f.read()
            import re
            compat_match = re.search(r'PACKAGE_COMPAT\s*=\s*["\'](\w+)["\']', package_config)
            if compat_match:
                config_parts.append(f"compat:{compat_match.group(1)}")
            else:
                config_parts.append("compat:buckos")  # default
    except FileNotFoundError:
        config_parts.append("compat:buckos")  # default

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

    # Get target-specific env variables and USE flags
    # Use uquery to avoid triggering builds
    try:
        env_result = run_command([
            "buck2", "uquery",
            f"{target}",
            "--output-attribute", "env",
            "--output-attribute", "use_flags",
            "--json"
        ])

        # Parse JSON to extract env and use_flags
        stdout = env_result.stdout
        json_start = stdout.find('{')
        if json_start != -1:
            stdout = stdout[json_start:]
            env_data = json.loads(stdout)

            # Find the target in the result
            target_key = target
            if target not in env_data and f"buckos//{target.lstrip('//')}" in env_data:
                target_key = f"buckos//{target.lstrip('//')}"

            # Get env attribute - include ALL env variables in sorted order
            env_attr = env_data.get(target_key, {}).get("env", {})
            if env_attr:
                # Sort keys for consistent hashing
                for key in sorted(env_attr.keys()):
                    value = env_attr[key]
                    # Include all env vars, even empty ones
                    config_parts.append(f"env.{key}:{value}")

            # Get use_flags attribute
            use_flags = env_data.get(target_key, {}).get("use_flags", [])
            if use_flags:
                config_parts.append(f"target_use:{','.join(sorted(use_flags))}")
    except Exception as e:
        # If query fails, try to continue without flags
        print(f"Warning: Failed to query target env/use_flags: {e}")

    # Get target dependencies (skip if skip_build to avoid triggering Buck)
    if not skip_build:
        try:
            deps_result = run_command([
                "buck2", "query",
                f"deps({target})",
                "--output-attribute", "name"
            ])
            # Hash the dependency list
            deps_hash = hashlib.sha256(deps_result.stdout.encode()).hexdigest()[:8]
            config_parts.append(f"deps:{deps_hash}")
        except:
            pass

    # Combine all config parts and hash
    config_string = "|".join(config_parts)
    config_hash = hashlib.sha256(config_string.encode()).hexdigest()[:16]

    return config_hash


def find_built_package(target: str) -> Optional[Path]:
    """Find already-built package in buck-out without triggering a build.

    Args:
        target: Buck target path (e.g., //packages/linux/core/bash:bash or //toolchains/bootstrap:cross-gcc-pass1)

    Returns:
        Path to built output if found, None otherwise
    """
    # Extract package path from target
    # e.g., //packages/linux/core/bash:bash -> packages/linux/core/bash
    # e.g., //toolchains/bootstrap:cross-gcc-pass1 -> toolchains/bootstrap
    target_path = target.replace("//", "/").lstrip("/").split(":")[0]
    package_name = target.split(":")[-1]

    # All targets live under the buckos cell
    buck_out = Path("buck-out/v2/gen/buckos")

    if not buck_out.exists():
        return None

    # For toolchains targets, search in toolchains/bootstrap directly
    if target_path.startswith("toolchains/"):
        # Pattern: buck-out/v2/gen/buckos/HASH/toolchains/bootstrap/__PACKAGE__/PACKAGE/
        subpath = target_path

        for hash_dir in buck_out.iterdir():
            if not hash_dir.is_dir():
                continue

            pkg_dir = hash_dir / subpath / f"__{package_name}__" / package_name
            if pkg_dir.exists() and pkg_dir.is_dir():
                if (pkg_dir / "usr").exists() or len(list(pkg_dir.iterdir())) > 0:
                    print(f"Found built package at: {pkg_dir}")
                    return pkg_dir
    else:
        # Find all hash directories for regular packages
        for hash_dir in buck_out.iterdir():
            if not hash_dir.is_dir():
                continue

            # Check for package directory
            pkg_dir = hash_dir / target_path / f"__{package_name}__" / package_name
            if pkg_dir.exists() and pkg_dir.is_dir():
                # Verify it has actual content (usr/ directory)
                if (pkg_dir / "usr").exists():
                    print(f"Found built package at: {pkg_dir}")
                    return pkg_dir

    return None


def build_target(target: str) -> Path:
    """Build a Buck target and return path to output.

    Args:
        target: Buck target path

    Returns:
        Path to built output
    """
    print(f"Building {target}...")

    # Build the target
    run_command(["buck2", "build", target], capture=False)

    # Get output path
    result = run_command([
        "buck2", "build", target,
        "--show-output"
    ])

    # Parse output path from "target_name output_path"
    output_line = result.stdout.strip().split('\n')[-1]
    output_path = output_line.split()[-1]

    return Path(output_path)


def calculate_file_hash(path: Path) -> str:
    """Calculate SHA256 hash of a file or directory.

    Args:
        path: Path to file or directory

    Returns:
        16-character hex hash
    """
    print(f"Calculating file hash for {path}...")

    sha256 = hashlib.sha256()

    if path.is_dir():
        # Hash all files in directory
        for root, dirs, files in sorted(os.walk(path)):
            # Sort for reproducibility
            dirs.sort()
            for file in sorted(files):
                file_path = Path(root) / file
                if file_path.is_file():
                    with open(file_path, "rb") as f:
                        for chunk in iter(lambda: f.read(8192), b""):
                            sha256.update(chunk)
    else:
        # Hash single file
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(8192), b""):
                sha256.update(chunk)

    return sha256.hexdigest()[:16]


def create_package(
    target: str,
    output_path: Path,
    package_name: str,
    version: str,
    config_hash: str,
    file_hash: str,
    output_dir: Path
) -> Path:
    """Create a tarball package of the build output with hash file.

    Args:
        target: Buck target
        output_path: Path to built output
        package_name: Package name
        version: Package version
        config_hash: Config hash
        file_hash: File hash (of contents before tarring)
        output_dir: Directory to save package

    Returns:
        Path to created package
    """
    # Create package filename with config hash
    package_filename = f"{package_name}-{version}-{config_hash}-bin.tar.gz"
    package_path = output_dir / package_filename

    print(f"Creating package: {package_filename}")

    # Create tarball
    output_dir.mkdir(parents=True, exist_ok=True)

    with tarfile.open(package_path, "w:gz") as tar:
        # Add the built output
        if output_path.is_dir():
            tar.add(output_path, arcname=package_name)
        else:
            tar.add(output_path, arcname=os.path.basename(output_path))

        # Add metadata file
        metadata = {
            "target": target,
            "name": package_name,
            "version": version,
            "config_hash": config_hash,
            "content_hash": file_hash,
        }

        import tempfile
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            json.dump(metadata, f, indent=2)
            metadata_path = f.name

        tar.add(metadata_path, arcname="METADATA.json")
        os.unlink(metadata_path)

    # Calculate SHA256 of the tarball
    sha256 = hashlib.sha256()
    with open(package_path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            sha256.update(chunk)
    tarball_hash = sha256.hexdigest()

    # Create hash file with metadata
    hash_filename = f"{package_filename}.sha256"
    hash_path = output_dir / hash_filename

    with open(hash_path, "w") as f:
        f.write(f"{tarball_hash}  {package_filename}\n")
        f.write(f"# Config Hash: {config_hash}\n")
        f.write(f"# Content Hash: {file_hash}\n")
        f.write(f"# Package: {package_name}\n")
        f.write(f"# Version: {version}\n")
        f.write(f"# Target: {target}\n")

    print(f"✓ Created: {package_path}")
    print(f"  Size: {package_path.stat().st_size / 1024 / 1024:.2f} MB")
    print(f"✓ Created: {hash_path}")
    print(f"  Tarball SHA256: {tarball_hash[:16]}...")
    print(f"  Config Hash: {config_hash}")
    print(f"  Content Hash: {file_hash}")

    return package_path


def upload_package(package_path: Path, mirror_url: str):
    """Upload package to mirror server.

    Args:
        package_path: Path to package file
        mirror_url: Mirror URL (e.g., https://mirror.buckos.org/binaries/)
    """
    print(f"Uploading {package_path.name} to {mirror_url}...")

    # Use scp or rsync depending on URL format
    if mirror_url.startswith("ssh://") or ":" in mirror_url and not mirror_url.startswith("http"):
        # SSH/SCP upload
        run_command(["scp", str(package_path), mirror_url], capture=False)
    elif mirror_url.startswith("/"):
        # Local path
        import shutil
        dest = Path(mirror_url) / package_path.name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(package_path, dest)
        print(f"✓ Copied to {dest}")
    else:
        print(f"Error: Unsupported mirror URL format: {mirror_url}")
        print("Use: ssh://user@host/path, user@host:/path, or /local/path")
        return

    print(f"✓ Uploaded: {package_path.name}")


def package_target(
    target: str,
    output_dir: Path,
    upload: bool = False,
    mirror_url: Optional[str] = None,
    skip_build: bool = False
) -> Optional[Path]:
    """Package a single Buck target.

    Args:
        target: Buck target path
        output_dir: Output directory for packages
        upload: Whether to upload to mirror
        mirror_url: Mirror URL for upload
        skip_build: If True, package already-built target without building

    Returns:
        Path to created package, or None if skipped
    """
    # Get target info
    info = get_target_info(target, skip_build=skip_build)
    package_name = info["name"]
    version = info["version"]

    # Calculate config hash
    config_hash = calculate_config_hash(target, skip_build=skip_build)

    # Build or find target
    if skip_build:
        output_path = find_built_package(target)
        if output_path is None:
            print(f"✗ No built package found for {target}, skipping")
            return None
    else:
        output_path = build_target(target)

    # Calculate file hash
    file_hash = calculate_file_hash(output_path)

    # Create package
    package_path = create_package(
        target,
        output_path,
        package_name,
        version,
        config_hash,
        file_hash,
        output_dir
    )

    # Upload if requested
    if upload:
        if not mirror_url:
            print("Error: --upload specified but no --mirror-url provided")
            sys.exit(1)
        upload_package(package_path, mirror_url)
        # Also upload the .sha256 file
        hash_path = package_path.parent / f"{package_path.name}.sha256"
        if hash_path.exists():
            upload_package(hash_path, mirror_url)

    return package_path


def main():
    parser = argparse.ArgumentParser(
        description="Package Buck targets as precompiled binaries"
    )
    parser.add_argument(
        "targets",
        nargs="+",
        help="Buck targets to package (e.g., //packages/linux/core/bash:bash)"
    )
    parser.add_argument(
        "--output-dir",
        "-o",
        type=Path,
        default=Path("binaries"),
        help="Output directory for packages (default: ./binaries)"
    )
    parser.add_argument(
        "--upload",
        "-u",
        action="store_true",
        help="Upload packages to mirror after creation"
    )
    parser.add_argument(
        "--mirror-url",
        "-m",
        type=str,
        help="Mirror URL for upload (ssh://user@host/path or /local/path)"
    )
    parser.add_argument(
        "--skip-build",
        "-s",
        action="store_true",
        help="Package already-built targets without rebuilding"
    )

    args = parser.parse_args()

    print("BuckOS Binary Packager")
    print("=" * 60)
    print(f"Targets: {len(args.targets)}")
    print(f"Output: {args.output_dir}")
    if args.skip_build:
        print("Mode: Package already-built targets")
    if args.upload:
        print(f"Mirror: {args.mirror_url}")
    print("=" * 60)
    print()

    packages = []
    for target in args.targets:
        try:
            package_path = package_target(
                target,
                args.output_dir,
                args.upload,
                args.mirror_url,
                args.skip_build
            )
            if package_path:
                packages.append(package_path)
            print()
        except Exception as e:
            print(f"✗ Failed to package {target}: {e}")
            import traceback
            traceback.print_exc()
            print()

    # Summary
    print("=" * 60)
    print(f"Packaged {len(packages)}/{len(args.targets)} targets")
    print("=" * 60)

    for pkg in packages:
        print(f"  {pkg.name}")

    return 0 if len(packages) == len(args.targets) else 1


if __name__ == "__main__":
    sys.exit(main())
