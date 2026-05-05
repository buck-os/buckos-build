#!/usr/bin/env python3
"""Generate test wrapper that sets up hermetic host-tools environment.

Called by the test_host_env rule.  Generates a wrapper script that
prepends seed host-tools/bin to PATH so tests find make, file, cc,
etc. from the seed without host-installed packages.

Does NOT set LD_LIBRARY_PATH — seed tools use RPATH to find their
libs.  Setting LD_LIBRARY_PATH globally would poison host-linked
binaries (e.g. the host python3 used to run tests).

When the toolchain has no host_bin_dir, generates a passthrough that
just execs the test directly.
"""

import os
import sys


def main():
    output = sys.argv[1]
    bin_dir = os.environ.get("_HOST_BIN_DIR", "")

    if bin_dir:
        with open(output, "w") as f:
            f.write(
                '#!/usr/bin/env python3\n'
                'import os, sys\n'
                f'_rel_bin = "{bin_dir}"\n'
                '_bin = _rel_bin if os.path.isabs(_rel_bin) else '
                'os.path.join(os.getcwd(), _rel_bin)\n'
                'os.environ["PATH"] = _bin + ":" + os.environ.get("PATH", "")\n'
                '_test = os.environ.get("_BUCKOS_TEST", "")\n'
                'if _test:\n'
                '    _test = os.path.realpath(_test)\n'
                '    os.chmod(_test, 0o755)\n'
                '    os.execv(_test, [_test] + sys.argv[1:])\n'
                'elif len(sys.argv) > 1:\n'
                '    os.execvp(sys.argv[1], sys.argv[1:])\n'
            )
    else:
        # No host tools — passthrough
        with open(output, "w") as f:
            f.write(
                '#!/usr/bin/env python3\n'
                'import os, sys\n'
                '_test = os.environ.get("_BUCKOS_TEST", "")\n'
                'if _test:\n'
                '    _test = os.path.realpath(_test)\n'
                '    os.chmod(_test, 0o755)\n'
                '    os.execv(_test, [_test] + sys.argv[1:])\n'
                'elif len(sys.argv) > 1:\n'
                '    os.execvp(sys.argv[1], sys.argv[1:])\n'
            )

    os.chmod(output, 0o755)


if __name__ == "__main__":
    main()
