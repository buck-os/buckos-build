#!/usr/bin/env python3
"""Python build helper for Python packages.

Runs pip install in the source directory, producing an installed tree
in the output directory.
"""

import argparse
import os
import subprocess
import sys


def _resolve_env_paths(value):
    """Resolve relative Buck2 artifact paths in env values to absolute."""
    parts = []
    for token in value.split():
        if token.startswith("--") and "=" in token:
            idx = token.index("=")
            flag = token[: idx + 1]
            path = token[idx + 1 :]
            if path and os.path.exists(path):
                parts.append(flag + os.path.abspath(path))
            else:
                parts.append(token)
        elif os.path.exists(token):
            parts.append(os.path.abspath(token))
        else:
            parts.append(token)
    return " ".join(parts)


def main():
    parser = argparse.ArgumentParser(description="Run pip install")
    parser.add_argument("--source-dir", required=True,
                        help="Python source directory (contains setup.py or pyproject.toml)")
    parser.add_argument("--output-dir", required=True,
                        help="Output directory for installed package")
    parser.add_argument("--pip-arg", action="append", dest="pip_args", default=[],
                        help="Extra argument to pass to pip install (repeatable)")
    parser.add_argument("--env", action="append", dest="extra_env", default=[],
                        help="Extra environment variable KEY=VALUE (repeatable)")
    args = parser.parse_args()

    if not os.path.isdir(args.source_dir):
        print(f"error: source directory not found: {args.source_dir}", file=sys.stderr)
        sys.exit(1)

    os.makedirs(args.output_dir, exist_ok=True)

    cmd = [
        sys.executable, "-m", "pip", "install",
        "--no-deps",
        "--no-build-isolation",
        "--prefix=/usr",
        f"--root={os.path.abspath(args.output_dir)}",
    ]
    cmd.extend(args.pip_args)
    cmd.append(os.path.abspath(args.source_dir))

    env = os.environ.copy()

    # Disable host compiler/build caches — Buck2 caches actions itself,
    # and external caches can poison results across build contexts.
    env["CCACHE_DISABLE"] = "1"
    env["RUSTC_WRAPPER"] = ""

    # Pin timestamps for reproducible builds.
    env.setdefault("SOURCE_DATE_EPOCH", "0")

    for entry in args.extra_env:
        key, _, value = entry.partition("=")
        if key:
            env[key] = _resolve_env_paths(value)

    result = subprocess.run(cmd, env=env)
    if result.returncode != 0:
        print(f"error: pip install failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
