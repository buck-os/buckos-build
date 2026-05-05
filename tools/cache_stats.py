#!/usr/bin/env python3
"""Show ccache and sccache statistics.

Usage: buck2 run //tools:cache-stats
"""

import os
import subprocess
import sys


def _find_cache_dir(env_var, internal_subdir):
    """Resolve cache directory from env or defaults."""
    val = os.environ.get(env_var, "")
    if val:
        return os.path.abspath(os.path.expanduser(val))
    # Try internal (per-checkout) location
    internal = os.path.join(os.getcwd(), ".buckos", "cache", internal_subdir)
    if os.path.isdir(internal):
        return internal
    # Try external location
    external = os.path.expanduser(os.path.join("~", ".buckos", "caches", internal_subdir))
    if os.path.isdir(external):
        return external
    return internal  # default even if it doesn't exist yet


def main():
    ccache_dir = _find_cache_dir("CCACHE_DIR", "ccache")
    sccache_dir = _find_cache_dir("SCCACHE_DIR", "sccache")

    print("=" * 60)
    print("ccache")
    print("=" * 60)
    if os.path.isdir(ccache_dir):
        env = dict(os.environ)
        env["CCACHE_DIR"] = ccache_dir
        result = subprocess.run(["ccache", "-s"], env=env, capture_output=True, text=True)
        if result.returncode == 0:
            print(result.stdout)
        else:
            print(f"  ccache -s failed: {result.stderr.strip()}")
    else:
        print(f"  cache dir not found: {ccache_dir}")

    print()
    print("=" * 60)
    print("sccache")
    print("=" * 60)
    if os.path.isdir(sccache_dir):
        env = dict(os.environ)
        env["SCCACHE_DIR"] = sccache_dir
        result = subprocess.run(["sccache", "--show-stats"], env=env, capture_output=True, text=True)
        if result.returncode == 0:
            print(result.stdout)
        else:
            print(f"  sccache --show-stats failed: {result.stderr.strip()}")
    else:
        print(f"  cache dir not found: {sccache_dir}")


if __name__ == "__main__":
    main()
