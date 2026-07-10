"""Enhanced shebang portabilizer.

Wraps _env.portabilize_shebangs (which rewrites buck-out-baked shebangs) with
an additional pass that retargets a narrow whitelist of upstream absolute
interpreter paths — /usr/bin/perl, /usr/bin/python* — to
`#!/usr/bin/env <interp>`.

Motivation: upstream tools (help2man, autotools scripts, gtk-doc-tools,
docbook-xsl, ...) ship shebangs like `#!/usr/bin/perl -w`. On the RE
worker's sysroot there is no /usr/bin/perl, so the kernel returns
ENOEXEC, bash falls back to executing the file as a sh script, and every
Perl statement fails with "line N: : No such file or directory".
Rewriting to `#!/usr/bin/env perl` lets the loader find the interpreter
via PATH, which points at the hermetic buckos toolchain both at build
time (host-tools-exec/bin/perl) and inside the final rootfs
(/usr/bin/perl via /usr/bin on PATH).

Kept in a separate module so bootstrap tools (which import only
make_tree_writable / clean_env from _env) don't get invalidated when this
logic evolves — editing _env.py forces a full bootstrap toolchain
rebuild, this module doesn't.
"""

import os
import sys

from _env import portabilize_shebangs as _base_portabilize_shebangs


# Interpreters we forcibly rewrite from a fixed /usr/bin/<interp> shebang.
# Kept narrow so we don't rewrite shebangs that are correct on the target
# system (e.g. /bin/sh, which is guaranteed and doesn't need env lookup).
_RETARGET_BASENAMES = frozenset(
    (
        "perl",
        "python",
        "python2",
        "python3",
    )
) | frozenset(f"python3.{i}" for i in range(6, 20))
_RETARGET_PREFIXES = (b"/usr/bin/", b"/usr/local/bin/")


def _retarget_upstream_shebangs(root):
    """Rewrite /usr/bin/perl and /usr/bin/python* shebangs to /usr/bin/env."""
    if not root or not os.path.isdir(root):
        return 0
    rewritten = 0
    for dirpath, _, filenames in os.walk(root):
        for fname in filenames:
            path = os.path.join(dirpath, fname)
            if os.path.islink(path):
                continue
            try:
                with open(path, "rb") as f:
                    head = f.read(256)
            except (OSError, PermissionError):
                continue
            if not head.startswith(b"#!"):
                continue
            if b"\x00" in head:
                continue
            first_nl = head.find(b"\n")
            if first_nl < 0:
                continue
            first_line = head[:first_nl]
            rest = first_line[2:].strip()
            parts = rest.split(None, 1)
            if not parts:
                continue
            interp_path = parts[0]
            if interp_path == b"/usr/bin/env":
                continue
            interp_name = os.path.basename(interp_path).decode(
                "ascii", errors="replace"
            )
            if interp_name not in _RETARGET_BASENAMES:
                continue
            if not any(interp_path.startswith(p) for p in _RETARGET_PREFIXES):
                continue
            # Drop interpreter args (e.g. -w) — the Linux shebang parser
            # treats the entire trailing string as a single arg, so
            # "#!/usr/bin/env perl -w" makes env look up a binary literally
            # named "perl -w" and fails. `perl` picks up `-w`-equivalent
            # behavior from `use warnings;` in modern scripts anyway.
            new_shebang = b"#!/usr/bin/env " + interp_name.encode() + b"\n"
            try:
                with open(path, "rb") as f:
                    content = f.read()
                new_content = new_shebang + content[first_nl + 1 :]
                mode = os.stat(path).st_mode
                with open(path, "wb") as f:
                    f.write(new_content)
                os.chmod(path, mode)
                rewritten += 1
            except (OSError, PermissionError):
                continue
    if rewritten:
        print(
            f"Portabilized {rewritten} upstream shebangs (/usr/bin/perl,"
            " /usr/bin/python* -> /usr/bin/env)",
            file=sys.stderr,
        )
    return rewritten


def portabilize_shebangs(root):
    """Rewrite both buck-out-baked and known upstream absolute-path shebangs."""
    _base_portabilize_shebangs(root)
    _retarget_upstream_shebangs(root)
