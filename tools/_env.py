"""Shared environment sanitization for build helpers.

Buck2's local executor inherits the daemon's full host environment into
action subprocesses, but action cache keys only include explicitly declared
env={}.  Two hosts sharing a NativeLink CAS compute identical digests but
may produce different outputs when host env differs -- cache poisoning.

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
_PASSTHROUGH = frozenset(
    {
        "HOME",
        "USER",
        "LOGNAME",
        "TMPDIR",
        "TEMP",
        "TMP",
        "TERM",
        "BUCK_SCRATCH_PATH",
        # Proxy — needed for cargo crate fetches when building behind squid.
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "NO_PROXY",
        "http_proxy",
        "https_proxy",
        "no_proxy",
        # TLS trust — squid TLS interception CA and system bundle.
        "SSL_CERT_FILE",
        "REQUESTS_CA_BUNDLE",
        "NODE_EXTRA_CA_CERTS",
        # GitHub Actions cache API — present in CI, absent on dev machines.
        "ACTIONS_RESULTS_URL",
        "ACTIONS_RUNTIME_TOKEN",
        "ACTIONS_CACHE_SERVICE_V2",
        "SCCACHE_GHA_ENABLED",
    }
)

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
    # Prevent openssl from reading host system config (e.g. Fedora's
    # /etc/pki/tls/openssl.cnf has rh-allow-sha1-signatures which
    # upstream openssl doesn't understand).
    "OPENSSL_CONF": "/dev/null",
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


def apply_cache_config(env):
    """Override determinism pins based on BUCKOS_CCACHE/BUCKOS_SCCACHE env vars.

    Must be called after extra_env is applied to the env dict so
    BUCKOS_CCACHE/BUCKOS_SCCACHE are present.  Resolves relative/~
    paths for cache dirs and creates them if needed.
    """
    if env.get("BUCKOS_CCACHE") == "1":
        env.pop("CCACHE_DISABLE", None)
        ccache_dir = env.get("CCACHE_DIR", "")
        if ccache_dir:
            ccache_dir = os.path.abspath(os.path.expanduser(ccache_dir))
            env["CCACHE_DIR"] = ccache_dir
            os.makedirs(ccache_dir, exist_ok=True)
        # Prefix CC/CXX with ccache so full-path compiler invocations
        # are cached.  PATH symlink masquerading doesn't work for buckos
        # because autotools records the full absolute CC path.
        # apply_cache_config runs AFTER extra_env but BEFORE symlink
        # creation, so helpers that do cc.split()[0] for symlinks will
        # get "ccache" — they should skip symlink creation when CC
        # starts with ccache (the real gcc is still findable via the
        # second token).
        # Skip CC/CXX prefixing for cmake (uses CMAKE_COMPILER_LAUNCHER).
        if env.get("_BUCKOS_CCACHE_NO_CC_PREFIX") != "1":
            _ccache_bin = shutil.which("ccache", path=env.get("PATH", ""))
            if _ccache_bin:
                for _var in ("CC", "CXX"):
                    _val = env.get(_var, "")
                    if _val and "ccache" not in _val:
                        env[_var] = _ccache_bin + " " + _val


def setup_ccache_symlinks(env, scratch_dir):
    """Create ccache masquerade symlinks and prepend to PATH.

    When BUCKOS_CCACHE=1, creates a directory with gcc/cc/g++/etc.
    symlinks pointing to ccache.  This dir is prepended to PATH BEFORE
    the real gcc symlink dir.  ccache's find_non_ccache_executable()
    skips itself by inode and finds the real gcc further down PATH.

    Also creates symlinks for cross-prefixed compiler names found in
    CC/CXX env vars (e.g. x86_64-buckos-linux-gnu-gcc) so ccache
    intercepts cross-compilation during bootstrap.

    Returns the ccache symlink dir path, or None if ccache is disabled
    or ccache is not found on PATH.
    """
    if env.get("BUCKOS_CCACHE") != "1":
        return None
    ccache_bin = shutil.which("ccache", path=env.get("PATH", ""))
    if not ccache_bin:
        return None
    ccache_dir = os.path.join(os.path.abspath(scratch_dir), "ccache-symlinks")
    os.makedirs(ccache_dir, exist_ok=True)
    names = ["gcc", "cc", "clang", "g++", "c++", "clang++"]
    # Add cross-prefixed names from CC/CXX only if the real compiler is
    # already on PATH under that name (bootstrap).  In non-bootstrap
    # builds, CC is a full path — masquerading the cross name breaks
    # sub-configures that find the ccache symlink but ccache can't
    # locate the real compiler.
    for var in ("CC", "CXX"):
        val = env.get(var, "")
        if val:
            basename = os.path.basename(val.split()[0])
            if basename not in names and shutil.which(
                basename, path=env.get("PATH", "")
            ):
                names.append(basename)
    for name in names:
        link = os.path.join(ccache_dir, name)
        if not os.path.exists(link):
            os.symlink(ccache_bin, link)
    env["PATH"] = ccache_dir + ":" + env.get("PATH", "")
    return ccache_dir


def _has_unsafe_chars(name):
    """True if *name* contains characters Buck2 cannot relativize."""
    return any(ord(c) < 32 or ord(c) == 127 or c == "\\" for c in name)


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
    parser.add_argument(
        "--hermetic-path",
        action="append",
        dest="hermetic_path",
        default=[],
        help="Set PATH to only these dirs (repeatable)",
    )
    parser.add_argument(
        "--allow-host-path",
        action="store_true",
        help="Allow host PATH (bootstrap escape hatch)",
    )
    parser.add_argument(
        "--hermetic-empty", action="store_true", help="Start with empty PATH"
    )
    parser.add_argument(
        "--path-prepend",
        action="append",
        dest="path_prepend",
        default=[],
        help="Dir to prepend to PATH (repeatable)",
    )
    parser.add_argument(
        "--ld-linux", default=None, help="Buckos ld-linux path (disables posix_spawn)"
    )


def setup_path(args, env, host_path=""):
    """Set env["PATH"] from the standard three-way PATH arguments.

    Requires args parsed by add_path_args().  host_path is the original
    host PATH captured before sanitization (used with --allow-host-path).
    If --ld-linux was provided, portabilizes hermetic-path and
    path-prepend ELF binaries so they use the sysroot ld-linux + glibc.
    """
    ld_linux = getattr(args, "ld_linux", None)
    scratch = os.environ.get("BUCK_SCRATCH_PATH", os.environ.get("TMPDIR", "/tmp"))

    if args.hermetic_path:
        dirs = [os.path.abspath(p) for p in args.hermetic_path]
        if ld_linux:
            from portabilize import portabilize_toolchain

            patchelf = shutil.which("patchelf", path=":".join(dirs))
            dirs = portabilize_toolchain(dirs, ld_linux, patchelf_path=patchelf)
        env["PATH"] = ":".join(dirs)
        derive_lib_paths(dirs, env)
    elif args.hermetic_empty:
        env["PATH"] = ""
    elif args.allow_host_path:
        env["PATH"] = host_path
    else:
        print(
            "error: requires --hermetic-path, --hermetic-empty, or --allow-host-path",
            file=sys.stderr,
        )
        sys.exit(1)
    if hasattr(args, "path_prepend") and args.path_prepend:
        pp_dirs = [os.path.abspath(p) for p in args.path_prepend]
        if ld_linux:
            from portabilize import portabilize_toolchain

            patchelf = shutil.which("patchelf", path=env.get("PATH", ""))
            pp_dirs = portabilize_toolchain(pp_dirs, ld_linux, patchelf_path=patchelf)
        prepend = ":".join(pp_dirs)
        env["PATH"] = prepend + (":" + env["PATH"] if env.get("PATH") else "")
        derive_lib_paths(pp_dirs, env)
    if ld_linux:
        _rewrite_toolchain_env(env)
        disable_posix_spawn(env)
    _ensure_which_shim(env)


def _ensure_which_shim(env):
    """Create a 'which' shim if not already on PATH.

    Many build systems call 'which' for tool detection but it's not
    available in hermetic environments.  This creates a simple shell
    script that uses 'command -v' (POSIX builtin) as a drop-in.
    """
    if shutil.which("which", path=env.get("PATH", "")):
        return
    scratch = os.environ.get("BUCK_SCRATCH_PATH", os.environ.get("TMPDIR", "/tmp"))
    shim_dir = os.path.join(scratch, "buckos-shims")
    shim = os.path.join(shim_dir, "which")
    if not os.path.exists(shim):
        os.makedirs(shim_dir, exist_ok=True)
        with open(shim, "w") as f:
            f.write('#!/bin/sh\nfor arg; do command -v "$arg" || exit 1; done\n')
        os.chmod(shim, 0o755)
    env["PATH"] = shim_dir + ":" + env.get("PATH", "")


def _rewrite_toolchain_env(env):
    """Rewrite CC/CXX/AR env values to use portabilized copies from PATH.

    After portabilize_toolchain copies and patches ELF binaries to
    scratch, the original CC/CXX/AR paths still point to the unpatched
    originals.  This resolves them to the portabilized copies on PATH.
    """
    for var in ("CC", "CXX", "AR"):
        val = env.get(var, "")
        if not val:
            continue
        parts = val.split()
        bin_path = parts[0]
        bin_name = os.path.basename(bin_path)
        resolved = shutil.which(bin_name, path=env.get("PATH", ""))
        if resolved and resolved != os.path.abspath(bin_path):
            parts[0] = resolved
            env[var] = " ".join(parts)


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
        scratch_dir = os.environ.get(
            "BUCK_SCRATCH_PATH", os.environ.get("TMPDIR", "/tmp")
        )
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
    """Disable posix_spawn for buckos-built binaries.

    Compiler binary ELF interpreters are patched to the sysroot
    ld-linux by the toolchain rule (patch_compiler action), so
    LD_LIBRARY_PATH is not needed.  The sysroot ld-linux loads
    sysroot glibc directly — matching versions, no ABI mismatch.
    """
    disable_posix_spawn(env)


def _is_sysroot_lib_dir(d):
    """Return True if directory contains sysroot-only libraries.

    These dirs must NOT be added to LD_LIBRARY_PATH because host
    binaries (perl, python, etc.) would load sysroot libs built
    against a different glibc, causing ABI mismatch crashes.
    """
    for marker in ("libc.so.6", "libcrypt.so", "libgcc_s.so.1"):
        if os.path.exists(os.path.join(d, marker)):
            return True
    return False


def derive_lib_paths(bin_dirs, env, skip_ld_library_path=False):
    """Derive LD_LIBRARY_PATH and tool data dirs from bin dirs.

    Given {prefix}/bin, adds {prefix}/lib and {prefix}/lib64 to
    LD_LIBRARY_PATH so dynamically linked host tools can find their
    shared libraries, and sets BISON_PKGDATADIR so relocated bison
    finds its m4sugar data files.

    Directories containing sysroot-only libraries are EXCLUDED from
    LD_LIBRARY_PATH to avoid poisoning host processes.  Buckos binaries
    find these libs via $ORIGIN RPATH set at build time by GCC specs.
    Including them in LD_LIBRARY_PATH would poison host binaries
    (e.g. host perl loading sysroot libcrypt.so → glibc ABI mismatch).

    Excluded markers: libc.so.6, libcrypt.so (libxcrypt), libgcc_s.so.1.
    """
    lib_parts = []
    for bin_dir in bin_dirs:
        parent = os.path.dirname(os.path.abspath(bin_dir))
        for ld in ("lib", "lib64"):
            d = os.path.join(parent, ld)
            if os.path.isdir(d) and not _is_sysroot_lib_dir(d):
                lib_parts.append(d)
        # Bison looks for data at compiled-in /usr/share/bison; set
        # BISON_PKGDATADIR so it finds data in the relocated prefix.
        bison_data = os.path.join(parent, "share", "bison")
        if os.path.isdir(bison_data) and "BISON_PKGDATADIR" not in env:
            env["BISON_PKGDATADIR"] = bison_data
        # gettext msgfmt --xml needs ITS rules from its versioned data dir
        # (e.g. share/gettext-0.26/its/).  GETTEXTDATADIRS tells msgfmt
        # where to find them.
        _share = os.path.join(parent, "share")
        if os.path.isdir(_share) and "GETTEXTDATADIRS" not in env:
            for _entry in os.listdir(_share):
                if _entry.startswith("gettext-") and os.path.isdir(
                    os.path.join(_share, _entry, "its")
                ):
                    env["GETTEXTDATADIRS"] = os.path.join(_share, _entry)
                    break
        # glibc iconv/msgfmt needs GCONV_PATH to find charset conversion
        # modules in the relocated prefix (otherwise ISO-8859-1 etc. fail).
        for ld in ("lib64", "lib"):
            gconv = os.path.join(parent, ld, "gconv")
            if os.path.isdir(gconv) and "GCONV_PATH" not in env:
                env["GCONV_PATH"] = gconv
                break
    if lib_parts and not skip_ld_library_path:
        existing = env.get("LD_LIBRARY_PATH", "")
        merged = ":".join(lib_parts)
        env["LD_LIBRARY_PATH"] = (
            (merged + ":" + existing).rstrip(":") if existing else merged
        )


def inject_rpath_for_deps(env, lib_dirs, ld_linux):
    """Add -Wl,-rpath for dep lib dirs to LDFLAGS when using ld-linux wrappers.

    Freshly-built binaries (e.g. gcc's cc1) run directly, not through
    wrappers. They need RPATH to find dep shared libs at runtime.
    Only applied when ld-linux is set (host-tools builds), so target
    packages don't get polluted with buck-out paths.
    """
    if not ld_linux or not lib_dirs:
        return
    rpath_flags = []
    for d in lib_dirs:
        d = os.path.abspath(d)
        if os.path.isdir(d) and not _is_sysroot_lib_dir(d):
            rpath_flags.append(f"-Wl,-rpath,{d}")
    if rpath_flags:
        existing = env.get("LDFLAGS", "")
        env["LDFLAGS"] = (existing + " " + " ".join(rpath_flags)).strip()


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

                print(
                    f"⚠ filter_path_flags: keeping {flag} (dep prefix not materialized?)",
                    file=sys.stderr,
                )
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


def suppress_makefile_reconfiguration(root):
    """Append no-op overrides to Makefile targets whose recipes re-run
    config.status / meson --reconfigure / cmake --check-build-system.

    GNU make uses the last recipe defined for a target, so this makes those
    reconfiguration rules harmless.  Needed because on remote execution the
    build tree is materialized from CAS with normalized mtimes, so make sees
    Makefiles as stale and tries to reconfigure during ``make install`` --
    which fails because the configure scripts aren't part of the build
    output.  Mirrors the neutralization build_helper applies during compile.
    """
    import glob as _glob

    _CLEAN_TARGETS = frozenset(
        ("distclean", "clean", "maintainer-clean", "mostlyclean", "realclean")
    )
    _RECONFIG_TRIGGERS = ("config.status", "check-build-system")
    _RECONFIG_RECIPE_PATTERNS = (
        "./config.status",
        "$(SHELL) config.status",
        "--reconfigure",
        "--check-build-system",
    )
    for _mf in _glob.glob(os.path.join(root, "**/Makefile"), recursive=True):
        try:
            with open(_mf, "r") as f:
                _mf_content = f.read()
        except (UnicodeDecodeError, PermissionError, OSError):
            continue
        if not any(t in _mf_content for t in _RECONFIG_TRIGGERS):
            continue
        _mf_stat = os.stat(_mf)
        _suppressed = {}  # target -> "::" or ":"
        _current_target = None
        _current_colon = ":"
        for line in _mf_content.splitlines():
            if line.startswith("\t"):
                if (
                    _current_target
                    and _current_target not in _CLEAN_TARGETS
                    and any(p in line for p in _RECONFIG_RECIPE_PATTERNS)
                ):
                    _suppressed[_current_target] = _current_colon
            elif ":" in line and not line.startswith(("#", "\t", ".PHONY")):
                colon_idx = line.index(":")
                _current_colon = (
                    "::" if line[colon_idx : colon_idx + 2] == "::" else ":"
                )
                target_part = line[:colon_idx].strip()
                if target_part and not target_part.startswith(("$", "@", "-")):
                    _current_target = target_part
                    # Doc/codegen stamp targets (e.g. binutils bfd/doc
                    # *.stamp) re-run during `make install` and their
                    # `ln -s` fails because the generated file already
                    # exists in the copied build tree.  These outputs are
                    # not needed for installation, so no-op them.
                    for _t in target_part.split():
                        if _t.endswith(".stamp"):
                            _suppressed[_t] = _current_colon
                else:
                    _current_target = None
            else:
                _current_target = None
        # Unconditionally no-op the canonical autotools remake targets in any
        # Makefile that references config.status.  The recipe for the
        # `config.status` target itself execs configure (via `./config.status
        # --recheck`), and detecting it by recipe text is brittle across the
        # many sub-Makefiles; force-overriding the well-known target names is
        # robust.  An empty recipe makes make treat them as up-to-date.
        _suppressed.setdefault("Makefile", ":")
        _suppressed.setdefault("config.status", ":")
        if _suppressed:
            _overrides = ["\n# Reconfiguration suppressed by install_helper"]
            _overrides.append("makefile-targets += " + " ".join(sorted(_suppressed)))
            for _t in sorted(_suppressed):
                _overrides.append(f"{_t}{_suppressed[_t]} ;")
            try:
                with open(_mf, "a") as f:
                    f.write("\n".join(_overrides) + "\n")
                os.utime(_mf, (_mf_stat.st_atime, _mf_stat.st_mtime))
            except OSError:
                pass


def make_tree_writable(root):
    """Add owner-write to every directory and regular file under ``root``.

    ``shutil.copytree`` preserves the source's permission bits.  On remote
    execution the source is a read-only materialized input, so a scratch
    copy of it would be read-only and the configure/compile/install phases
    could not mutate it (PermissionError).  Call this right after copying a
    source/build tree into scratch.  Locally this is a no-op in effect
    (inputs are already writable).
    """
    os.chmod(root, os.stat(root).st_mode | 0o200)
    for dirpath, dirnames, filenames in os.walk(root):
        for name in dirnames + filenames:
            p = os.path.join(dirpath, name)
            if os.path.islink(p):
                continue
            try:
                os.chmod(p, os.stat(p).st_mode | 0o200)
            except OSError:
                pass


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
            shebang + "\n"
            "import os, shutil, sys\n"
            "sd = os.path.dirname(os.path.abspath(__file__))\n"
            'p = os.environ.get("PATH", "").split(":")\n'
            'os.environ["PATH"] = ":".join(d for d in p if os.path.abspath(d) != sd)\n'
            '_pc = shutil.which("pkg-config")\n'
            "if not _pc:\n"
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
            if (
                candidate
                and os.path.isfile(candidate)
                and os.access(candidate, os.X_OK)
            ):
                return candidate
    return None


def preferred_linker_flag(env):
    """Return preferred linker flag, or empty string.

    Disabled for now — mold requires portabilization of both the
    linker binary and its interaction with gcc's collect2.  Use the
    default ld.bfd from the toolchain until mold portabilization
    is implemented.
    """
    return ""


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
    """Parse a shebang line and rewrite to #!/usr/bin/env <name>.

    Returns (new_shebang_prefix, args_suffix) if the interpreter
    basename exists on PATH, otherwise (None, None).

    Uses #!/usr/bin/env <name> so the interpreter is resolved via
    PATH at runtime.  This works with both native binaries and
    ld-linux wrapper scripts on PATH.
    """
    if not line.startswith(b"#!"):
        return None, None
    rest = line[2:].strip()
    # #!/usr/bin/env interp [args...]
    if rest.startswith(b"/usr/bin/env ") or rest.startswith(b"/usr/bin/env\t"):
        parts = rest.split(None, 2)
        if len(parts) < 2:
            return None, None
        interp_name = parts[1].decode("ascii", errors="replace")
        if interp_name not in path_lookup:
            return None, None
        # Already env-style — don't rewrite
        return None, None
    # #!/path/to/interp [args...]
    parts = rest.split(None, 1)
    if not parts:
        return None, None
    interp_path = parts[0]
    if not interp_path.startswith(b"/"):
        return None, None
    interp_name = os.path.basename(interp_path).decode("ascii", errors="replace")
    if interp_name not in path_lookup:
        return None, None
    if len(parts) > 1:
        return b"/usr/bin/env -S " + interp_name.encode(), b" " + parts[1]
    return b"/usr/bin/env " + interp_name.encode(), b""


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
                new_content = new_shebang + content[old_end + 1 :]
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
            interp_name = os.path.basename(interp_path).decode(
                "ascii", errors="replace"
            )
            if not interp_name:
                continue
            # Preserve arguments after interpreter path
            args_suffix = b" " + parts[1] if len(parts) > 1 else b""
            new_shebang = (
                b"#!/usr/bin/env " + interp_name.encode() + args_suffix + b"\n"
            )
            try:
                with open(path, "rb") as f:
                    content = f.read()
                old_end = content.find(b"\n")
                if old_end < 0:
                    continue
                new_content = new_shebang + content[old_end + 1 :]
                mode = os.stat(path).st_mode
                with open(path, "wb") as f:
                    f.write(new_content)
                os.chmod(path, mode)
                rewritten += 1
            except (OSError, PermissionError):
                continue
    if rewritten:
        print(
            f"Portabilized {rewritten} shebangs (buck-out -> /usr/bin/env)",
            file=sys.stderr,
        )


def write_stub_script(path, exit_code=0):
    """Write a no-op stub script (e.g. for makeinfo, autotools regen).

    Uses Python instead of shell so it works without /bin/sh.
    """
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(
            "#!/usr/bin/env python3\n" "import sys; sys.exit({})\n".format(exit_code)
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
