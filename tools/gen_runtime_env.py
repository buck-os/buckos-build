#!/usr/bin/env python3
"""Generate run-env.sh wrapper that sets LD_LIBRARY_PATH.

Called by the runtime_env rule via ctx.actions.run so that all lib-dir
artifacts are action inputs (must be materialised).  This is stronger
than write+allow_args whose other_outputs may not survive daemon
restarts or garbage collection.
"""

import os
import sys


def main():
    output = sys.argv[1]
    lib_dirs = os.environ.get("_LIB_DIRS", "")

    with open(output, "w") as f:
        f.write("#!/bin/sh\n")
        f.write(f'_rel="{lib_dirs}"\n')
        f.write('_abs=""\n')
        f.write("IFS=:\n")
        f.write('for _d in $_rel; do\n')
        f.write('  case "$_d" in /*) _p="$_d" ;; *) _p="$PWD/$_d" ;; esac\n')
        f.write('  _abs="${_abs:+$_abs:}$_p"\n')
        f.write('done\n')
        f.write('export LD_LIBRARY_PATH="$_abs"\n')
        f.write('exec "$@"\n')

    os.chmod(output, 0o755)


if __name__ == "__main__":
    main()
