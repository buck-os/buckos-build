#!/usr/bin/env -S uvx --with httpx --with tqdm --with click python3
"""
Update signature checksums for download_source targets in BUCK files.

This script:
1. Parses BUCK files to find download_source calls
2. Checks for .sig signature file (matching Buck's hardcoded extension)
3. For packages WITH .sig signatures: adds signature_sha256
4. For packages WITHOUT .sig signatures: sets signature_required=False
5. Can fix packages that failed in the last build
"""

import asyncio
import hashlib
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

import click
import httpx
from tqdm import tqdm


@dataclass
class DownloadSource:
    """Parsed download_source call from a BUCK file."""
    name: str
    src_uri: str
    sha256: str
    signature_sha256: str | None
    signature_required: bool
    buck_file: Path
    content: str


@dataclass
class SignatureResult:
    """Result of signature fetch attempt."""
    source: DownloadSource
    sig_sha256: str | None
    sig_url: str | None


def compute_sha256(data: bytes) -> str:
    """Compute SHA256 checksum of data."""
    return hashlib.sha256(data).hexdigest()


async def try_download_signature(client: httpx.AsyncClient, src_uri: str) -> tuple[str | None, bytes | None]:
    """Try downloading signature file, checking .sig, .asc, .sign extensions."""
    extensions = ['.sig', '.asc', '.sign']

    for ext in extensions:
        sig_url = src_uri + ext
        try:
            response = await client.get(sig_url)
            if response.status_code == 200:
                content = response.content
                # Verify it's actually a GPG signature (ASCII armor or binary)
                if b'-----BEGIN PGP' in content[:100] or content[:2] in [b'\x89\x01', b'\x89\x02']:
                    return sig_url, content
        except httpx.RequestError:
            pass

    return None, None


async def process_source(client: httpx.AsyncClient, source: DownloadSource) -> SignatureResult:
    """Process a single source - fetch signature and compute hash."""
    sig_url, sig_content = await try_download_signature(client, source.src_uri)

    if sig_url and sig_content:
        sig_sha256 = compute_sha256(sig_content)
        return SignatureResult(source, sig_sha256, sig_url)

    return SignatureResult(source, None, None)


async def process_all_sources(sources: list[DownloadSource], concurrency: int = 20) -> list[SignatureResult]:
    """Process all sources in parallel with limited concurrency."""
    semaphore = asyncio.Semaphore(concurrency)

    async def bounded_process(client: httpx.AsyncClient, source: DownloadSource) -> SignatureResult:
        async with semaphore:
            return await process_source(client, source)

    async with httpx.AsyncClient(timeout=30, follow_redirects=True) as client:
        tasks = [bounded_process(client, source) for source in sources]

        results = []
        for coro in tqdm(asyncio.as_completed(tasks), total=len(tasks), desc="Fetching signatures"):
            result = await coro
            results.append(result)

        return results


def parse_download_sources(buck_file: Path) -> list[DownloadSource]:
    """Parse download_source and package macro calls from BUCK file."""
    content = buck_file.read_text()
    results = []

    # Match download_source and all convenience package macros that have src_uri/sha256
    macros = [
        'download_source',
        'autotools_package',
        'cmake_package',
        'meson_package',
        'simple_package',
        'cargo_package',
        'go_package',
        'python_package',
    ]
    pattern = r'(?:' + '|'.join(macros) + r')\s*\(\s*([^)]+(?:\([^)]*\)[^)]*)*)\)'

    for match in re.finditer(pattern, content, re.DOTALL):
        call_content = match.group(1)

        # Extract parameters
        name = re.search(r'name\s*=\s*["\']([^"\']+)["\']', call_content)
        src_uri = re.search(r'src_uri\s*=\s*["\']([^"\']+)["\']', call_content)
        sha256 = re.search(r'(?<![_a-z])sha256\s*=\s*["\']([^"\']+)["\']', call_content)
        sig_sha256 = re.search(r'signature_sha256\s*=\s*["\']([^"\']+)["\']', call_content)
        sig_req = re.search(r'signature_required\s*=\s*(True|False)', call_content)

        # Skip if no src_uri (some packages use 'source' instead)
        if not src_uri:
            continue

        if name and sha256:
            results.append(DownloadSource(
                name=name.group(1),
                src_uri=src_uri.group(1),
                sha256=sha256.group(1),
                signature_sha256=sig_sha256.group(1) if sig_sha256 else None,
                signature_required=sig_req.group(1) == 'True' if sig_req else False,
                buck_file=buck_file,
                content=match.group(0),
            ))

    return results


def update_buck_file_signature(source: DownloadSource, sig_sha256: str) -> bool:
    """Update a download_source call with signature_sha256. Returns True if changed."""
    content = source.buck_file.read_text()

    if source.signature_sha256:
        # Update existing
        new_call = re.sub(
            r'signature_sha256\s*=\s*["\'][^"\']*["\']',
            f'signature_sha256 = "{sig_sha256}"',
            source.content
        )
    else:
        # Add new - after sha256
        sha_match = re.search(r'(sha256\s*=\s*["\'][^"\']*["\'],?)', source.content)
        if sha_match:
            insert_pos = sha_match.end()
            new_call = source.content[:insert_pos] + f'\n    signature_sha256 = "{sig_sha256}",' + source.content[insert_pos:]
        else:
            return False

    if new_call == source.content:
        return False

    new_content = content.replace(source.content, new_call)
    source.buck_file.write_text(new_content)
    return True


def update_buck_file_no_signature(source: DownloadSource) -> bool:
    """Set signature_required=False for packages without signatures. Returns True if changed."""
    content = source.buck_file.read_text()

    new_call = source.content

    # Remove signature_sha256 if present
    if source.signature_sha256:
        new_call = re.sub(r'\n\s*signature_sha256\s*=\s*["\'][^"\']*["\'],?', '', new_call)

    # Add signature_required=False after sha256 if not already present
    if 'signature_required' not in new_call:
        sha_match = re.search(r'(sha256\s*=\s*["\'][^"\']*["\'],?)', new_call)
        if sha_match:
            insert_pos = sha_match.end()
            new_call = new_call[:insert_pos] + '\n    signature_required = False,' + new_call[insert_pos:]

    if new_call == source.content:
        return False

    new_content = content.replace(source.content, new_call)
    source.buck_file.write_text(new_content)
    return True


def collect_sources(packages_dir: Path, package_filter: str | None) -> list[DownloadSource]:
    """Collect all download_source entries needing signature updates."""
    sources = []
    buck_files = sorted(packages_dir.rglob('BUCK'))

    for buck_file in buck_files:
        for source in parse_download_sources(buck_file):
            # Filter by package if specified
            if package_filter and package_filter not in source.name:
                continue
            # Skip if already has signature_sha256 or signature_required=False
            if source.signature_sha256 or not source.signature_required:
                continue
            sources.append(source)

    return sources


def collect_all_sources(packages_dir: Path) -> list[DownloadSource]:
    """Collect ALL download_source entries (for --fix-failed)."""
    sources = []
    buck_files = sorted(packages_dir.rglob('BUCK'))

    for buck_file in buck_files:
        for source in parse_download_sources(buck_file):
            sources.append(source)

    return sources


def get_failed_targets_from_log(root: Path) -> set[str]:
    """Parse buck2 log to find targets that failed signature download."""
    failed = set()
    try:
        # Get last build log
        result = subprocess.run(
            ['buck2', 'log', 'what-failed'],
            capture_output=True,
            text=True,
            cwd=root
        )
        output = result.stdout + result.stderr

        # Look for signature download failures
        # Pattern: buckos//packages/linux/foo/bar:name-src-sig
        for line in output.split('\n'):
            if '-src-sig' in line and ('404' in line or 'download_file' in line or 'Error' in line):
                # Extract target path
                match = re.search(r'(buckos//[^:]+:[^\s]+)-sig', line)
                if match:
                    # Convert to source name (remove -sig suffix)
                    target = match.group(1)
                    # Extract package name from target
                    parts = target.split(':')
                    if len(parts) == 2:
                        name = parts[1]
                        failed.add(name)

        # Also try parsing raw output for package names
        for match in re.finditer(r'buckos//packages/[^:]+:([^-\s]+)-src-sig', output):
            failed.add(match.group(1) + '-src')

    except Exception as e:
        click.echo(f"Warning: Could not parse build log: {e}", err=True)

    return failed


@click.command()
@click.option('--all', 'process_all', is_flag=True, help='Process all packages needing signatures')
@click.option('--fix-failed', is_flag=True, help='Fix packages that failed signature download in last build')
@click.option('--dry-run', is_flag=True, help='Show what would be changed without making changes')
@click.option('--package', type=str, help='Process only packages matching this name')
@click.option('--concurrency', type=int, default=20, help='Number of parallel downloads')
@click.option('--root', type=click.Path(exists=True), default='.', help='Project root directory')
def main(process_all: bool, fix_failed: bool, dry_run: bool, package: str | None, concurrency: int, root: str):
    """Update signature checksums for download_source targets in BUCK files.

    For packages WITH .sig signatures: adds signature_sha256
    For packages WITHOUT .sig signatures: sets signature_required=False
    """

    if not process_all and not package and not fix_failed:
        click.echo("Usage: specify --all, --fix-failed, or --package NAME", err=True)
        raise SystemExit(1)

    root_path = Path(root).resolve()
    packages_dir = root_path / 'packages'

    if not packages_dir.exists():
        click.echo(f"Error: packages directory not found at {packages_dir}", err=True)
        raise SystemExit(1)

    if fix_failed:
        # Fix packages that failed in last build
        click.echo("Parsing last build log for failed signature downloads...")
        failed_targets = get_failed_targets_from_log(root_path)

        if not failed_targets:
            click.echo("No failed signature targets found in build log.")
            click.echo("Tip: Run 'buck2 build /...' first to generate failures.")
            return

        click.echo(f"Found {len(failed_targets)} failed targets")

        # Collect all sources and filter to failed ones
        all_sources = collect_all_sources(packages_dir)
        sources_to_fix = [s for s in all_sources if s.name in failed_targets or any(t in s.name for t in failed_targets)]

        if not sources_to_fix:
            click.echo("Could not match failed targets to BUCK files.")
            click.echo(f"Failed targets: {failed_targets}")
            return

        fixed = 0
        for source in sources_to_fix:
            if dry_run:
                click.echo(f"  Would fix {source.name}")
                fixed += 1
            else:
                if update_buck_file_no_signature(source):
                    click.echo(f"  Fixed {source.name}")
                    fixed += 1

        click.echo(f"\n{'Would fix' if dry_run else 'Fixed'} {fixed} packages")
        return

    # Normal processing
    click.echo("Scanning BUCK files...")
    sources = collect_sources(packages_dir, package)

    if not sources:
        click.echo("No packages need signature updates.")
        return

    click.echo(f"Found {len(sources)} packages needing signature checksums")

    # Fetch signatures in parallel
    results = asyncio.run(process_all_sources(sources, concurrency))

    # Apply updates
    with_sig = 0
    without_sig = 0

    for result in results:
        if result.sig_sha256:
            # Has signature - add signature_sha256
            if dry_run:
                click.echo(f"  [+sig] {result.source.name}")
                with_sig += 1
            else:
                if update_buck_file_signature(result.source, result.sig_sha256):
                    click.echo(f"  [+sig] {result.source.name}")
                    with_sig += 1
        else:
            # No signature - set signature_required=False
            if dry_run:
                click.echo(f"  [-sig] {result.source.name}")
                without_sig += 1
            else:
                if update_buck_file_no_signature(result.source):
                    click.echo(f"  [-sig] {result.source.name}")
                    without_sig += 1

    # Summary
    click.echo()
    if dry_run:
        click.echo(f"Would update {with_sig + without_sig} packages:")
    else:
        click.echo(f"Updated {with_sig + without_sig} packages:")
    click.echo(f"  {with_sig} with signature_sha256")
    click.echo(f"  {without_sig} with signature_required=False")


if __name__ == '__main__':
    main()
