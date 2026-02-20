#!/usr/bin/env python3
"""Build smoke test: verify a package built successfully.

Checks that expected files exist in the build output directory.

Env vars from sh_test:
    OUTPUT_DIR    — build output directory
    EXPECT_FILES  — colon-separated list of expected relative paths
"""

import os
import sys


def main():
    output_dir = os.environ.get("OUTPUT_DIR", "")
    if not output_dir:
        print("ERROR: OUTPUT_DIR not set")
        sys.exit(1)

    expect_files = os.environ.get("EXPECT_FILES", "").split(":")
    expect_files = [f for f in expect_files if f]  # filter empty strings

    if not expect_files:
        # No specific files requested — just verify the output dir exists
        # and is non-empty
        if os.path.isdir(output_dir) and os.listdir(output_dir):
            print(f"PASS: {output_dir} exists and is non-empty")
            sys.exit(0)
        else:
            print(f"FAIL: {output_dir} missing or empty")
            sys.exit(1)

    passed = 0
    failed = 0
    for f in expect_files:
        path = os.path.join(output_dir, f)
        if os.path.exists(path):
            print(f"  PASS: {f}")
            passed += 1
        else:
            print(f"  FAIL: {f} missing")
            failed += 1

    print(f"--- {passed} passed, {failed} failed ---")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
