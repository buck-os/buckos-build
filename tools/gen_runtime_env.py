#!/usr/bin/env python3
"""Generate run-env wrapper that sets LD_LIBRARY_PATH.

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
        f.write(
            '#!/usr/bin/env python3\n'
            'import os, sys\n'
            f'_rel = "{lib_dirs}"\n'
            '_abs = []\n'
            'for d in _rel.split(":"):\n'
            '    if not d: continue\n'
            '    _abs.append(d if os.path.isabs(d) else os.path.join(os.getcwd(), d))\n'
            'os.environ["LD_LIBRARY_PATH"] = ":".join(_abs)\n'
            'os.execvp(sys.argv[1], sys.argv[1:])\n'
        )

    os.chmod(output, 0o755)


if __name__ == "__main__":
    main()
