#!/usr/bin/env python3
"""Static analysis: find package() calls missing url or sha256.

Scans all BUCK files under packages/ for calls to package() that are
missing the required url= and/or sha256= parameters.  Reports every
violation at once so they can be fixed in bulk.

BXL graph tests cannot detect these because buck2 fails to parse the
BUCK file before BXL can inspect it.

Run:
    python3 tests/graph/verify_package_completeness.py
"""

import os
import re
import sys


def find_project_root():
    """Walk up from this script to find .buckconfig."""
    d = os.path.dirname(os.path.abspath(__file__))
    for _ in range(10):
        if os.path.exists(os.path.join(d, ".buckconfig")):
            return d
        d = os.path.dirname(d)
    return None


def check_buck_file(path):
    """Return list of (issue, detail) for a BUCK file."""
    with open(path) as f:
        content = f.read()

    # Only check files that use package() from package.bzl
    if "package.bzl" not in content:
        return []
    if not re.search(r'\bpackage\s*\(', content):
        return []

    # local_only packages don't need url/sha256
    if re.search(r'\blocal_only\s*=\s*True\b', content):
        return []

    issues = []
    has_url = re.search(r'\burl\s*=', content) is not None
    has_sha = re.search(r'\bsha256\s*=', content) is not None

    if not has_url:
        issues.append("missing url")
    if not has_sha:
        issues.append("missing sha256")

    return issues


def main():
    root = os.environ.get("PROJECT_ROOT") or find_project_root()
    if not root:
        print("ERROR: cannot find project root (.buckconfig)")
        sys.exit(2)

    packages_dir = os.path.join(root, "packages")
    if not os.path.isdir(packages_dir):
        print("ERROR: packages/ directory not found at {}".format(root))
        sys.exit(2)

    violations = []
    for dirpath, _dirs, files in os.walk(packages_dir):
        if "BUCK" not in files:
            continue
        buck_path = os.path.join(dirpath, "BUCK")
        rel_path = os.path.relpath(buck_path, root)
        issues = check_buck_file(buck_path)
        if issues:
            violations.append((rel_path, issues))

    violations.sort()

    if not violations:
        print("PASS: all package() calls have url and sha256")
        sys.exit(0)

    print("FAIL: {} package(s) missing url/sha256:\n".format(len(violations)))
    for path, issues in violations:
        print("  {} — {}".format(path, ", ".join(issues)))

    print("\n{} package(s) need url and sha256 added to their BUCK files.".format(
        len(violations)))
    sys.exit(1)


if __name__ == "__main__":
    main()
