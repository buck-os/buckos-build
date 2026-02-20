#!/usr/bin/env python3
"""Go build helper for Go packages.

Runs go build in the source directory, producing a binary in the output
directory.
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
    parser = argparse.ArgumentParser(description="Run go build")
    parser.add_argument("--source-dir", required=True,
                        help="Go source directory (contains go.mod)")
    parser.add_argument("--output-dir", required=True,
                        help="Output directory for installed binary")
    parser.add_argument("--go-arg", action="append", dest="go_args", default=[],
                        help="Extra argument to pass to go build (repeatable)")
    parser.add_argument("--ldflags", default=None,
                        help="Linker flags for go build (-ldflags value)")
    parser.add_argument("--env", action="append", dest="extra_env", default=[],
                        help="Extra environment variable KEY=VALUE (repeatable)")
    args = parser.parse_args()

    if not os.path.isdir(args.source_dir):
        print(f"error: source directory not found: {args.source_dir}", file=sys.stderr)
        sys.exit(1)

    bin_dir = os.path.join(args.output_dir, "usr", "bin")
    os.makedirs(bin_dir, exist_ok=True)

    cmd = [
        "go", "build",
        "-o", bin_dir,
    ]

    if args.ldflags:
        cmd.extend(["-ldflags", args.ldflags])

    cmd.extend(args.go_args)

    # Build from the source directory so go.mod is found
    cmd.append("./...")

    env = os.environ.copy()
    for entry in args.extra_env:
        key, _, value = entry.partition("=")
        if key:
            env[key] = _resolve_env_paths(value)
    env["GOFLAGS"] = env.get("GOFLAGS", "")

    result = subprocess.run(cmd, cwd=args.source_dir, env=env)
    if result.returncode != 0:
        print(f"error: go build failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(1)

    # Verify at least one binary was produced
    binaries = [f for f in os.listdir(bin_dir)
                if os.path.isfile(os.path.join(bin_dir, f))
                and os.access(os.path.join(bin_dir, f), os.X_OK)]
    if not binaries:
        print("warning: no executable binaries found in output directory", file=sys.stderr)


if __name__ == "__main__":
    main()
