#!/usr/bin/env python3
"""Generate run-env wrapper that sets LD_LIBRARY_PATH and portabilizes deps.

Called by the runtime_env rule via ctx.actions.run so that all lib-dir
artifacts are action inputs (must be materialised).  This is stronger
than write+allow_args whose other_outputs may not survive daemon
restarts or garbage collection.

The generated wrapper:
  1. Sets LD_LIBRARY_PATH from the package's transitive lib_dirs tset.
  2. If _LD_LINUX, _PATCHELF, _PORTABILIZE_RUN, and _PREFIX env vars are
     all set at gen time, the wrapper hands off to portabilize_run.pex
     to patch the package's bin dirs and rewrite sys.argv[1] to the
     portabilized binary path before exec.
  3. Otherwise (bootstrap or non-portable target), it just execvp's
     sys.argv[1:] directly with LD_LIBRARY_PATH set.
"""

import os
import sys


def main():
    output = sys.argv[1]
    lib_dirs = os.environ.get("_LIB_DIRS", "")
    ld_linux = os.environ.get("_LD_LINUX", "")
    patchelf = os.environ.get("_PATCHELF", "")
    portabilize_run = os.environ.get("_PORTABILIZE_RUN", "")
    prefix = os.environ.get("_PREFIX", "")

    if ld_linux and patchelf and portabilize_run and prefix:
        # Hand off to portabilize_run, which patches the package's bin
        # dirs and rewrites sys.argv[1] to the portabilized binary path
        # before exec.
        exec_block = (
            f'_ld_linux = {ld_linux!r}\n'
            f'_patchelf = {patchelf!r}\n'
            f'_portabilize_run = {portabilize_run!r}\n'
            f'_prefix = {prefix!r}\n'
            'def _abspath(p):\n'
            '    return p if os.path.isabs(p) else os.path.join(os.getcwd(), p)\n'
            '_argv = [_abspath(_portabilize_run),\n'
            '         "--ld-linux", _abspath(_ld_linux),\n'
            '         "--patchelf", _abspath(_patchelf),\n'
            '         "--prefix", _abspath(_prefix), "--"] + sys.argv[1:]\n'
            'os.execvp(_argv[0], _argv)\n'
        )
    else:
        # Bootstrap or non-portable target: just exec sys.argv[1:] with
        # LD_LIBRARY_PATH set.
        exec_block = 'os.execvp(sys.argv[1], sys.argv[1:])\n'

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
            + exec_block
        )

    os.chmod(output, 0o755)


if __name__ == "__main__":
    main()
