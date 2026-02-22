#!/usr/bin/env python3
"""Verify a CH boot script has resolved paths (no artifact placeholders).

Env vars from sh_test:
    SCRIPT_DIR — build output directory containing the boot script
"""

import os
import re
import sys


def main():
    script_dir = os.environ.get("SCRIPT_DIR", "")
    if not script_dir:
        print("ERROR: SCRIPT_DIR not set")
        sys.exit(1)

    # Find the boot script (should be a single file or in a known location)
    script_path = None
    if os.path.isfile(script_dir):
        script_path = script_dir
    elif os.path.isdir(script_dir):
        for f in os.listdir(script_dir):
            if f.startswith("ch-boot-") and not f.endswith(".bak"):
                script_path = os.path.join(script_dir, f)
                break
        if not script_path:
            # Recurse one level
            for root, dirs, files in os.walk(script_dir):
                for f in files:
                    if f.startswith("ch-boot-"):
                        script_path = os.path.join(root, f)
                        break
                if script_path:
                    break

    if not script_path or not os.path.exists(script_path):
        print(f"FAIL: boot script not found in {script_dir}")
        sys.exit(1)

    content = open(script_path).read()
    failed = 0

    # No unresolved artifact references
    if "<build artifact" in content:
        print("FAIL: script contains unresolved artifact references")
        failed += 1
    else:
        print("PASS: no unresolved artifact references")

    # KERNEL variable present
    if "KERNEL=" in content:
        print("PASS: KERNEL variable present")
    else:
        print("FAIL: KERNEL variable missing")
        failed += 1

    # KERNEL is not empty or a placeholder
    m = re.search(r'KERNEL="([^"]*)"', content)
    if m:
        val = m.group(1)
        if val and "PLACEHOLDER" not in val:
            print("PASS: KERNEL has resolved value")
        else:
            print(f"FAIL: KERNEL unresolved: {val}")
            failed += 1
    elif "KERNEL=" in content:
        # Non-quoted assignment
        print("PASS: KERNEL assigned (non-quoted)")

    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
