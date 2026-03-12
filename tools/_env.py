"""Shared environment sanitization for build helpers.

Buck2's local executor inherits the daemon's full host environment into
action subprocesses, but action cache keys only include explicitly declared
env={}.  Two hosts sharing a NativeLink CAS compute identical digests but
may produce different outputs when host env differs — cache poisoning.

This module provides a whitelist-based approach: start from a clean env
with only functional vars, pin determinism vars, and let each helper add
what it needs on top.
"""

import atexit
import os
import signal
import shutil
import sys

# Vars passed through from the host environment when present.
_PASSTHROUGH = frozenset({
    "HOME", "USER", "LOGNAME",
    "TMPDIR", "TEMP", "TMP",
    "TERM",
    "BUCK_SCRATCH_PATH",
})

# Vars pinned to fixed values for determinism.
_DETERMINISM_PINS = {
    "LC_ALL": "C",
    "LANG": "C",
    "SOURCE_DATE_EPOCH": "315576000",
    "CCACHE_DISABLE": "1",
    "RUSTC_WRAPPER": "",
    "CARGO_BUILD_RUSTC_WRAPPER": "",
    # Prevent pkg-config from falling through to host system .pc files.
    # The compiled-in default search path (/usr/lib64/pkgconfig, etc.) is
    # replaced with a nonexistent dir — helpers set PKG_CONFIG_PATH to
    # buckos deps.  Empty string doesn't work: pkgconf treats "" as unset.
    "PKG_CONFIG_LIBDIR": "/nonexistent-buckos-pkgconfig",
}


def clean_env():
    """Return a clean env dict for subprocess env= parameter.

    Copies only whitelisted vars from the host, then applies
    determinism pins.  Callers layer helper-specific vars on top.
    """
    env = {}
    for key in _PASSTHROUGH:
        val = os.environ.get(key)
        if val is not None:
            env[key] = val
    env.update(_DETERMINISM_PINS)
    # Isolate cargo from host ~/.cargo — cargo reads
    # $CARGO_HOME/config.toml and shells may add ~/.cargo/bin to PATH.
    # RUSTUP_HOME is NOT redirected here because rustup proxies need
    # a configured toolchain in $RUSTUP_HOME; empty dir causes
    # "no default toolchain" errors.  Helpers that need rustup
    # isolation (mozbuild_helper) set RUSTUP_HOME themselves.
    scratch = env.get("BUCK_SCRATCH_PATH") or env.get("TMPDIR") or "/tmp"
    env["CARGO_HOME"] = os.path.join(scratch, "buckos-cargo-home")
    # Disable posix_spawn in the current process — buckos-built
    # binaries have padded ELF interpreters that cause ENOEXEC/ENOTCONN.
    # Child processes get it via sysroot_lib_paths or explicit calls.
    import subprocess as _subprocess
    _subprocess._USE_POSIX_SPAWN = False
    return env


def _has_unsafe_chars(name):
    """True if *name* contains characters Buck2 cannot relativize."""
    return any(ord(c) < 32 or ord(c) == 127 or c == '\\' for c in name)


def sanitize_filenames(*roots):
    """Delete files/dirs whose names contain control chars or backslashes.

    Some build systems (autoconf's filesystem character test, conftest.t<TAB>)
    create files that Buck2's path handling cannot relativize.  Walk each
    root bottom-up and remove offending entries before Buck2 sees them.
    """
    for root in roots:
        if not root or not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root, topdown=False):
            for fname in filenames:
                if _has_unsafe_chars(fname):
                    try:
                        os.unlink(os.path.join(dirpath, fname))
                    except OSError:
                        pass
            for dname in list(dirnames):
                if _has_unsafe_chars(dname):
                    try:
                        shutil.rmtree(os.path.join(dirpath, dname))
                    except OSError:
                        pass


# ── Guaranteed cleanup ────────────────────────────────────────────────
# Helpers register directories here so sanitize_filenames runs on ANY
# exit path — normal return, exception, or SIGTERM.  Only SIGKILL
# bypasses this (unavoidable).

_cleanup_dirs = []
_cleanup_ran = False


def register_cleanup(*dirs):
    """Register directories for filename sanitization on exit.

    Call early (before builds start) so cleanup runs even if the
    build is interrupted.
    """
    _cleanup_dirs.extend(d for d in dirs if d)


def _run_cleanup():
    global _cleanup_ran
    if _cleanup_ran:
        return
    _cleanup_ran = True
    sanitize_filenames(*_cleanup_dirs)


atexit.register(_run_cleanup)


def _sigterm_cleanup(signum, frame):
    _run_cleanup()
    sys.exit(128 + signum)


signal.signal(signal.SIGTERM, _sigterm_cleanup)


def add_path_args(parser):
    """Register the standard three-way PATH arguments on an argparse parser."""
    parser.add_argument("--hermetic-path", action="append",
                        dest="hermetic_path", default=[],
                        help="Set PATH to only these dirs (repeatable)")
    parser.add_argument("--allow-host-path", action="store_true",
                        help="Allow host PATH (bootstrap escape hatch)")
    parser.add_argument("--hermetic-empty", action="store_true",
                        help="Start with empty PATH")
    parser.add_argument("--path-prepend", action="append",
                        dest="path_prepend", default=[],
                        help="Dir to prepend to PATH (repeatable)")
    parser.add_argument("--ld-linux", default=None,
                        help="Buckos ld-linux path (disables posix_spawn)")


def setup_path(args, env, host_path=""):
    """Set env["PATH"] from the standard three-way PATH arguments.

    Requires args parsed by add_path_args().  host_path is the original
    host PATH captured before sanitization (used with --allow-host-path).
    If --ld-linux was provided, disables posix_spawn in child Python
    processes to avoid ENOEXEC with padded ELF interpreters.
    """
    if args.hermetic_path:
        env["PATH"] = ":".join(os.path.abspath(p) for p in args.hermetic_path)
        derive_lib_paths(args.hermetic_path, env)
    elif args.hermetic_empty:
        env["PATH"] = ""
    elif args.allow_host_path:
        env["PATH"] = host_path
    else:
        print("error: requires --hermetic-path, --hermetic-empty, or --allow-host-path",
              file=sys.stderr)
        sys.exit(1)
    if hasattr(args, 'path_prepend') and args.path_prepend:
        prepend = ":".join(os.path.abspath(p) for p in args.path_prepend)
        env["PATH"] = prepend + (":" + env["PATH"] if env.get("PATH") else "")
        derive_lib_paths(args.path_prepend, env)
    if getattr(args, 'ld_linux', None):
        disable_posix_spawn(env)


def disable_posix_spawn(env, scratch_dir=None):
    """Disable posix_spawn in this process and all child Python processes.

    Python 3.12+ defaults to posix_spawn for subprocess.Popen, which
    fails with ENOEXEC/ENOTCONN on some kernels/configurations when
    the ELF interpreter is padded (///...///lib64/ld-linux-x86-64.so.2).
    Fork+exec handles padded interpreters correctly everywhere.

    Disables in the current process immediately, and creates a
    sitecustomize.py in a scratch directory (prepended to PYTHONPATH)
    so all child Python processes inherit the fix.
    """
    # Disable in the current process immediately.
    import subprocess as _subprocess
    _subprocess._USE_POSIX_SPAWN = False
    # Disable in child Python processes via sitecustomize.
    if scratch_dir is None:
        scratch_dir = os.environ.get("BUCK_SCRATCH_PATH",
                                     os.environ.get("TMPDIR", "/tmp"))
    pysite = os.path.join(scratch_dir, "buckos-pysite")
    sitecust = os.path.join(pysite, "sitecustomize.py")
    if not os.path.exists(sitecust):
        os.makedirs(pysite, exist_ok=True)
        with open(sitecust, "w") as f:
            f.write("import subprocess as _sp\n")
            f.write("_sp._USE_POSIX_SPAWN = False\n")
    existing = env.get("PYTHONPATH", "")
    env["PYTHONPATH"] = pysite + (":" + existing if existing else "")


def sysroot_lib_paths(ld_linux_path, env):
    """Set LD_LIBRARY_PATH for sysroot so buckos compiler can execute.

    The buckos GCC binary runs via the host's dynamic linker (its
    PT_INTERP resolves to /lib64/ld-linux on the host).  GCC's
    libstdc++ needs buckos glibc symbols (GLIBC_2.38+) that the
    host glibc may lack.  Adding sysroot glibc and GCC runtime
    lib dirs to LD_LIBRARY_PATH lets the host ld-linux satisfy
    those references.

    Only sysroot dirs (glibc + gcc runtime) are added — dep-specific
    lib dirs are handled separately by derive_lib_paths() which
    excludes glibc to avoid host tool contamination.
    """
    disable_posix_spawn(env)

    ld_linux = os.path.abspath(ld_linux_path)
    # sysroot is two dirs up from ld-linux:
    # <sysroot>/lib64/ld-linux-x86-64.so.2
    sysroot = os.path.dirname(os.path.dirname(ld_linux))

    lib_dirs = []
    for sub in ("lib64", "lib", "usr/lib64", "usr/lib"):
        d = os.path.join(sysroot, sub)
        if os.path.isdir(d):
            lib_dirs.append(d)

    # GCC's libstdc++/libgcc_s live alongside the sysroot:
    # sysroot = <prefix>/x86_64-buckos-linux-gnu/sys-root
    # libstdc++ = <prefix>/x86_64-buckos-linux-gnu/lib64
    gcc_target = os.path.dirname(sysroot)
    for sub in ("lib64", "lib"):
        d = os.path.join(gcc_target, sub)
        if os.path.isdir(d):
            lib_dirs.append(d)

    if lib_dirs:
        existing = env.get("LD_LIBRARY_PATH", "")
        merged = ":".join(lib_dirs)
        env["LD_LIBRARY_PATH"] = (merged + ":" + existing).rstrip(":") if existing else merged


def derive_lib_paths(bin_dirs, env):
    """Derive LD_LIBRARY_PATH and tool data dirs from bin dirs.

    Given {prefix}/bin, adds {prefix}/lib and {prefix}/lib64 to
    LD_LIBRARY_PATH so dynamically linked host tools can find their
    shared libraries, and sets BISON_PKGDATADIR so relocated bison
    finds its m4sugar data files.

    Directories containing libc.so.6 are EXCLUDED from LD_LIBRARY_PATH
    to avoid poisoning host processes with buckos glibc.  Buckos binaries
    find glibc via $ORIGIN RPATH set at build time by GCC specs.
    Including glibc in LD_LIBRARY_PATH would poison the cross-compiler
    (a host binary) causing segfaults on hosts with older glibc.
    """
    lib_parts = []
    for bin_dir in bin_dirs:
        parent = os.path.dirname(os.path.abspath(bin_dir))
        for ld in ("lib", "lib64"):
            d = os.path.join(parent, ld)
            if os.path.isdir(d) and not os.path.exists(os.path.join(d, "libc.so.6")):
                lib_parts.append(d)
        # Bison looks for data at compiled-in /usr/share/bison; set
        # BISON_PKGDATADIR so it finds data in the relocated prefix.
        bison_data = os.path.join(parent, "share", "bison")
        if os.path.isdir(bison_data) and "BISON_PKGDATADIR" not in env:
            env["BISON_PKGDATADIR"] = bison_data
        # glibc iconv/msgfmt needs GCONV_PATH to find charset conversion
        # modules in the relocated prefix (otherwise ISO-8859-1 etc. fail).
        for ld in ("lib64", "lib"):
            gconv = os.path.join(parent, ld, "gconv")
            if os.path.isdir(gconv) and "GCONV_PATH" not in env:
                env["GCONV_PATH"] = gconv
                break
    if lib_parts:
        existing = env.get("LD_LIBRARY_PATH", "")
        merged = ":".join(lib_parts)
        env["LD_LIBRARY_PATH"] = (merged + ":" + existing).rstrip(":") if existing else merged


def filter_path_flags(flags):
    """Filter out -I/-L/-Wl,-rpath-link flags for non-existent directories.

    Tset projections emit flags for every possible lib layout
    ({prefix}/usr/lib64, usr/lib, lib64, lib) but most only exist
    for one or two.  Filtering avoids blowing the execve arg limit
    on packages with 100+ transitive deps.

    Only filters layout variants (usr/lib vs lib64 etc.) — if an
    entire dep prefix is missing, all its flags pass through to
    preserve the link error signal rather than silently dropping deps.
    """
    # Group flags by prefix to detect entirely missing dep prefixes.
    # A missing prefix means Buck2 didn't materialize the dep — pass
    # the flags through so the link error is visible rather than
    # manifesting as a confusing "function not found" configure check.
    result = []
    for flag in flags:
        if flag.startswith("-I"):
            path = os.path.abspath(flag[2:])
            if os.path.isdir(path):
                result.append(flag)
        elif flag.startswith("-L"):
            path = os.path.abspath(flag[2:])
            if os.path.isdir(path):
                result.append(flag)
            elif not os.path.isdir(os.path.dirname(path)):
                # Parent dir missing — entire dep prefix absent.
                # Keep the flag to surface the real error.
                import sys
                print(f"⚠ filter_path_flags: keeping {flag} (dep prefix not materialized?)", file=sys.stderr)
                result.append(flag)
        elif flag.startswith("-Wl,-rpath-link,"):
            if os.path.isdir(os.path.abspath(flag[16:])):
                result.append(flag)
        else:
            result.append(flag)
    return result


def find_dep_python3(env):
    """Find buckos python3 from PATH in the given env dict.

    Returns the absolute path if found, None otherwise.  Used to
    pick buckos python over host python for generated wrapper scripts.
    """
    path = env.get("PATH", "")
    for d in path.split(":"):
        candidate = os.path.join(d, "python3")
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return os.path.abspath(candidate)
    return None


def write_pkg_config_wrapper(wrapper_dir, python=None):
    """Write a pkg-config wrapper that passes --define-prefix.

    Uses a Python script so it works in environments without /bin/sh
    (e.g. remote execution).  When ``python`` is provided (buckos
    python from deps), the wrapper uses it instead of the host python
    to avoid glibc ABI mismatches when buckos libs are on
    LD_LIBRARY_PATH.

    Before bootstrap completes, ``python`` is None and the wrapper
    falls back to ``/usr/bin/env python3`` (host python), which is
    fine because buckos libs aren't on LD_LIBRARY_PATH yet.
    """
    os.makedirs(wrapper_dir, exist_ok=True)
    wrapper = os.path.join(wrapper_dir, "pkg-config")
    if python:
        shebang = "#!" + os.path.abspath(python)
    else:
        shebang = "#!/usr/bin/env python3"
    with open(wrapper, "w") as f:
        f.write(
            shebang + '\n'
            'import os, shutil, sys\n'
            'sd = os.path.dirname(os.path.abspath(__file__))\n'
            'p = os.environ.get("PATH", "").split(":")\n'
            'os.environ["PATH"] = ":".join(d for d in p if os.path.abspath(d) != sd)\n'
            '_pc = shutil.which("pkg-config")\n'
            'if not _pc:\n'
            '    print("pkg-config: not found on PATH", file=sys.stderr); sys.exit(1)\n'
            'os.execv(_pc, [_pc, "--define-prefix"] + sys.argv[1:])\n'
        )
    os.chmod(wrapper, 0o755)
    return wrapper_dir


def find_buckos_shell(env):
    """Find a buckos shell binary on PATH for hermetic script execution.

    Returns the absolute path to bash (preferred) or sh, or None if
    neither is found.  Callers should use the result for CONFIG_SHELL,
    SHELL, and shebang rewriting.
    """
    for name in ("bash", "sh"):
        for d in env.get("PATH", "").split(":"):
            candidate = os.path.join(d, name) if d else ""
            if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                return candidate
    return None


def _build_path_lookup(env):
    """Build a dict mapping binary names to their absolute paths on PATH.

    Used by rewrite_shebangs to resolve interpreter names to buckos
    paths.  Only includes the first occurrence of each name.
    """
    lookup = {}
    for d in env.get("PATH", "").split(":"):
        if not d or not os.path.isdir(d):
            continue
        try:
            entries = os.listdir(d)
        except OSError:
            continue
        for name in entries:
            if name not in lookup:
                full = os.path.join(d, name)
                if os.path.isfile(full) and os.access(full, os.X_OK):
                    lookup[name] = full
    return lookup


def _parse_shebang(line, path_lookup):
    """Parse a shebang line and resolve the interpreter via PATH.

    Returns (new_interpreter_path, args_suffix) if the interpreter
    basename exists on PATH, otherwise (None, None).

    Handles:
      #!/path/to/interp [args...]
      #!/usr/bin/env interp [args...]
    """
    if not line.startswith(b"#!"):
        return None, None
    rest = line[2:].strip()
    # #!/usr/bin/env interp [args...]
    if rest.startswith(b"/usr/bin/env ") or rest.startswith(b"/usr/bin/env\t"):
        parts = rest.split(None, 2)  # [b"/usr/bin/env", b"interp", b"args..."]
        if len(parts) < 2:
            return None, None
        interp_name = parts[1].decode("ascii", errors="replace")
        buckos_path = path_lookup.get(interp_name)
        if not buckos_path:
            return None, None
        suffix = b" " + parts[2] if len(parts) > 2 else b""
        return buckos_path.encode(), suffix
    # #!/path/to/interp [args...]
    parts = rest.split(None, 1)
    if not parts:
        return None, None
    interp_path = parts[0]
    # Only rewrite absolute paths (skip relative shebangs)
    if not interp_path.startswith(b"/"):
        return None, None
    interp_name = os.path.basename(interp_path).decode("ascii", errors="replace")
    buckos_path = path_lookup.get(interp_name)
    if not buckos_path:
        return None, None
    # Don't rewrite if already pointing to a buckos path
    if interp_path == buckos_path.encode():
        return None, None
    suffix = b" " + parts[1] if len(parts) > 1 else b""
    return buckos_path.encode(), suffix


def rewrite_shebangs(root, env):
    """Rewrite shebangs in a directory tree to use buckos interpreters.

    After copytree() copies source into the build directory, this walks
    the tree and replaces hardcoded shebangs (#!/bin/sh, #!/usr/bin/bash,
    #!/usr/bin/perl, #!/usr/bin/python3, etc.) with the corresponding
    buckos binary found on PATH.  Preserves shebang arguments.

    This prevents the kernel from using host binaries when executing
    scripts during build.  Only rewrites text files; binary files
    (ELF, archives) are skipped.
    """
    if not root or not os.path.isdir(root):
        return
    path_lookup = _build_path_lookup(env)
    if not path_lookup:
        return
    for dirpath, dirnames, filenames in os.walk(root):
        # Skip cargo vendor directories — modifying vendored sources
        # breaks .cargo-checksum.json integrity checks.
        if "vendor" in dirnames:
            dirnames.remove("vendor")
        for fname in filenames:
            path = os.path.join(dirpath, fname)
            if os.path.islink(path):
                continue
            try:
                with open(path, "rb") as f:
                    head = f.read(128)
            except (OSError, PermissionError):
                continue
            if not head.startswith(b"#!"):
                continue
            if b"\x00" in head:
                continue
            first_line_end = head.find(b"\n")
            if first_line_end < 0:
                continue
            first_line = head[:first_line_end].rstrip()
            new_interp, suffix = _parse_shebang(first_line, path_lookup)
            if new_interp is None:
                continue
            new_shebang = b"#!" + new_interp + suffix + b"\n"
            try:
                with open(path, "rb") as f:
                    content = f.read()
                old_end = content.find(b"\n")
                if old_end < 0:
                    continue
                new_content = new_shebang + content[old_end + 1:]
                mode = os.stat(path).st_mode
                with open(path, "wb") as f:
                    f.write(new_content)
                os.chmod(path, mode)
            except (OSError, PermissionError):
                continue


def portabilize_shebangs(root):
    """Rewrite shebangs containing buck-out paths to #!/usr/bin/env <interp>.

    Installed outputs may contain shebangs pointing to absolute buck-out
    interpreter paths (e.g. /home/.../buck-out/.../bash).  These break when
    the output is cached and restored on a different machine.  This pass
    makes shebangs portable by converting them to #!/usr/bin/env form.

    Called after make install / package install on the output prefix.
    """
    if not root or not os.path.isdir(root):
        return
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
            if b"buck-out" not in first_line:
                continue
            # Extract interpreter basename
            rest = first_line[2:].strip()
            parts = rest.split(None, 1)
            if not parts:
                continue
            interp_path = parts[0]
            interp_name = os.path.basename(interp_path).decode("ascii", errors="replace")
            if not interp_name:
                continue
            # Preserve arguments after interpreter path
            args_suffix = b" " + parts[1] if len(parts) > 1 else b""
            new_shebang = b"#!/usr/bin/env " + interp_name.encode() + args_suffix + b"\n"
            try:
                with open(path, "rb") as f:
                    content = f.read()
                old_end = content.find(b"\n")
                if old_end < 0:
                    continue
                new_content = new_shebang + content[old_end + 1:]
                mode = os.stat(path).st_mode
                with open(path, "wb") as f:
                    f.write(new_content)
                os.chmod(path, mode)
                rewritten += 1
            except (OSError, PermissionError):
                continue
    if rewritten:
        print(f"Portabilized {rewritten} shebangs (buck-out -> /usr/bin/env)",
              file=sys.stderr)


def write_stub_script(path, exit_code=0):
    """Write a no-op stub script (e.g. for makeinfo, autotools regen).

    Uses Python instead of shell so it works without /bin/sh.
    """
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(
            '#!/usr/bin/env python3\n'
            'import sys; sys.exit({})\n'.format(exit_code)
        )
    os.chmod(path, 0o755)


def file_prefix_map_flags():
    """Return compiler flags that strip absolute build paths from output.

    Maps the project root (Buck2 cwd) to empty so paths like
    /home/user/repos/buckos-build/buck-out/v2/.../foo.c become
    buck-out/v2/.../foo.c in debug info and __FILE__ expansions.
    """
    cwd = os.getcwd()
    return [f"-ffile-prefix-map={cwd}/="]


def sanitize_global_env():
    """Replace os.environ in-place with a clean environment.

    For helpers that mutate os.environ directly (Pattern B) rather
    than passing env= to subprocess.  Preserves whitelisted vars,
    applies determinism pins, drops everything else.
    """
    keep = {}
    for key in _PASSTHROUGH:
        val = os.environ.get(key)
        if val is not None:
            keep[key] = val
    os.environ.clear()
    os.environ.update(keep)
    os.environ.update(_DETERMINISM_PINS)
    import subprocess as _subprocess
    _subprocess._USE_POSIX_SPAWN = False
