#!/usr/bin/env python3
"""Generate automake/aclocal wrapper scripts.

Creates wrapper scripts that set up PERL5LIB and other env vars so
automake/aclocal find their m4 macros regardless of install prefix.
The original scripts are renamed to .real and the wrappers exec them.
"""
import os
import sys

def write_wrapper(bindir, tool, ver, extra_exports, extra_lines, exec_args=""):
    real = tool + ".real"
    src = os.path.join(bindir, tool)
    dst = os.path.join(bindir, real)
    if not os.path.isfile(src):
        return
    os.rename(src, dst)
    # Fix shebang in .real if it has a buck-out path
    with open(dst, "rb") as f:
        head = f.read(256)
    if head.startswith(b"#!") and b"buck-out" in head.split(b"\n")[0]:
        interp = os.path.basename(head[2:].split()[0]).decode()
        content = open(dst, "rb").read()
        nl = content.find(b"\n")
        new_content = b"#!/usr/bin/env " + interp.encode() + b"\n" + content[nl + 1:]
        with open(dst, "wb") as f:
            f.write(new_content)
    lines = [
        "#!/bin/sh",
        'SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"',
        'SHARE="${SCRIPT_DIR}/../share"',
        "export AUTOMAKE_UNINSTALLED=1",
        'export PERL5LIB="$SHARE/automake-{v}:${{PERL5LIB:+:$PERL5LIB}}"'.format(v=ver),
    ]
    lines.extend(extra_exports)
    lines.extend(extra_lines)
    lines.append('exec "$SCRIPT_DIR/{r}"{a} "$@"'.format(r=real, a=exec_args))
    with open(src, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(src, 0o755)

def main():
    destdir = os.environ.get("DESTDIR", "")
    bindir = os.path.join(destdir, "usr/bin")
    ver = "1.16"

    for t in ["aclocal", "aclocal-" + ver]:
        write_wrapper(bindir, t, ver,
            ['export ACLOCAL_AUTOMAKE_DIR="$SHARE/aclocal-{v}"'.format(v=ver)],
            [],
            ' --automake-acdir="$SHARE/aclocal-{v}" --system-acdir="$SHARE/aclocal"'.format(v=ver))

    for t in ["automake", "automake-" + ver]:
        write_wrapper(bindir, t, ver,
            ['export AUTOMAKE_LIBDIR="$SHARE/automake-{v}"'.format(v=ver)],
            [
                'AUTOCONF_BIN="$(command -v autoconf 2>/dev/null)"',
                '[ -n "$AUTOCONF_BIN" ] && export AUTOCONF="$AUTOCONF_BIN"',
            ])

if __name__ == "__main__":
    main()
