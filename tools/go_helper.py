#!/usr/bin/env python3
"""Go build helper for Go packages.

Runs go build in the source directory, producing a binary in the output
directory.
"""

import argparse
import os
import shutil
import subprocess
import sys

from _env import clean_env, sysroot_lib_paths


def _can_unshare_net():
    """Check if unshare --net is available for network isolation."""
    try:
        result = subprocess.run(
            ["unshare", "--net", "true"],
            capture_output=True,
            timeout=5,
        )
        return result.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


_NETWORK_ISOLATED = _can_unshare_net()


def _resolve_env_paths(value):
    """Resolve relative Buck2 artifact paths in env values to absolute."""
    _FLAG_PREFIXES = ["-specs="]

    parts = []
    for token in value.split():
        flag_resolved = False
        for prefix in _FLAG_PREFIXES:
            if token.startswith(prefix) and len(token) > len(prefix):
                path = token[len(prefix) :]
                if not os.path.isabs(path) and os.path.exists(path):
                    parts.append(prefix + os.path.abspath(path))
                else:
                    parts.append(token)
                flag_resolved = True
                break
        if flag_resolved:
            continue
        if token.startswith("--") and "=" in token:
            idx = token.index("=")
            flag = token[: idx + 1]
            path = token[idx + 1 :]
            if path and os.path.exists(path):
                parts.append(flag + os.path.abspath(path))
            else:
                parts.append(token)
        elif os.path.exists(token):
            parts.append(os.path.abspath(token))
        else:
            parts.append(token)
    return " ".join(parts)


def main():
    _host_path = os.environ.get("PATH", "")

    parser = argparse.ArgumentParser(description="Run go build")
    parser.add_argument(
        "--source-dir", required=True, help="Go source directory (contains go.mod)"
    )
    parser.add_argument(
        "--output-dir", required=True, help="Output directory for installed binary"
    )
    parser.add_argument(
        "--go-arg",
        action="append",
        dest="go_args",
        default=[],
        help="Extra argument to pass to go build (repeatable)",
    )
    parser.add_argument(
        "--ldflags", default=None, help="Linker flags for go build (-ldflags value)"
    )
    parser.add_argument(
        "--env",
        action="append",
        dest="extra_env",
        default=[],
        help="Extra environment variable KEY=VALUE (repeatable)",
    )
    parser.add_argument(
        "--hermetic-path",
        action="append",
        dest="hermetic_path",
        default=[],
        help="Set PATH to only these dirs (replaces host PATH, repeatable)",
    )
    parser.add_argument(
        "--allow-host-path",
        action="store_true",
        help="Allow host PATH (bootstrap escape hatch)",
    )
    parser.add_argument(
        "--hermetic-empty",
        action="store_true",
        help="Start with empty PATH (populated by --path-prepend)",
    )
    parser.add_argument(
        "--ld-linux", default=None, help="Buckos ld-linux path (disables posix_spawn)"
    )
    parser.add_argument(
        "--path-prepend",
        action="append",
        dest="path_prepend",
        default=[],
        help="Directory to prepend to PATH (repeatable, resolved to absolute)",
    )
    parser.add_argument(
        "--bin",
        action="append",
        dest="bins",
        default=[],
        help="Specific binary name to install (repeatable; default: all executables)",
    )
    parser.add_argument(
        "--package",
        action="append",
        dest="packages",
        default=[],
        help="Go package to build (repeatable; default: ./...)",
    )
    parser.add_argument(
        "--vendor-dir",
        default=None,
        help="Vendor directory containing pre-downloaded dependencies",
    )
    parser.add_argument(
        "--lib-only",
        action="store_true",
        help="Library-only mode: build to verify compilation but install source instead of binaries",
    )
    parser.add_argument(
        "--run-tests",
        action="store_true",
        help="Run `go test` after the build (opt-in src_test); gates install",
    )
    parser.add_argument(
        "--test-arg",
        action="append",
        dest="test_args",
        default=[],
        help="Extra argument to pass to `go test` (repeatable, --run-tests only)",
    )
    parser.add_argument(
        "--test-package",
        action="append",
        dest="test_packages",
        default=[],
        help="Go package pattern to test (repeatable; default: ./...)",
    )
    args = parser.parse_args()

    if not os.path.isdir(args.source_dir):
        print(f"error: source directory not found: {args.source_dir}", file=sys.stderr)
        sys.exit(1)

    bin_dir = os.path.join(os.path.abspath(args.output_dir), "usr", "bin")
    os.makedirs(bin_dir, exist_ok=True)

    if args.lib_only:
        # Library-only mode: compile to verify but don't produce binaries
        cmd = ["go", "build"]
    else:
        cmd = [
            "go",
            "build",
            "-o",
            bin_dir,
        ]

    if args.ldflags:
        cmd.extend(["-ldflags", args.ldflags])

    cmd.extend(args.go_args)

    # Build specified packages or default to ./...
    if args.packages:
        cmd.extend(args.packages)
    else:
        cmd.append("./...")

    env = clean_env()

    for entry in args.extra_env:
        key, _, value = entry.partition("=")
        if key:
            env[key] = _resolve_env_paths(value)
    if args.hermetic_path:
        _hp_dirs = [os.path.abspath(p) for p in args.hermetic_path]
        if args.ld_linux:
            from portabilize import portabilize_toolchain, portabilize_env

            _patchelf = shutil.which("patchelf", path=":".join(_hp_dirs))
            _hp_dirs = portabilize_toolchain(
                _hp_dirs, args.ld_linux, patchelf_path=_patchelf
            )
            portabilize_env(env, args.ld_linux, patchelf_path=_patchelf)
        env["PATH"] = ":".join(_hp_dirs)
        # Derive LD_LIBRARY_PATH from hermetic bin dirs so dynamically
        # linked tools (e.g. cross-ar needing libzstd) find their libs.
        _lib_dirs = []
        for _bp in args.hermetic_path:
            _parent = os.path.dirname(os.path.abspath(_bp))
            for _ld in ("lib", "lib64"):
                _d = os.path.join(_parent, _ld)
                if os.path.isdir(_d) and not os.path.exists(
                    os.path.join(_d, "libc.so.6")
                ):
                    _lib_dirs.append(_d)
                    _glibc_d = os.path.join(_d, "glibc")
                    if os.path.isdir(_glibc_d):
                        _lib_dirs.append(_glibc_d)
        # Skip when ld-linux active for hermetic isolation
        if _lib_dirs and not args.ld_linux:
            _existing = env.get("LD_LIBRARY_PATH", "")
            env["LD_LIBRARY_PATH"] = ":".join(_lib_dirs) + (
                ":" + _existing if _existing else ""
            )
        _py_paths = []
        for _bp in args.hermetic_path:
            _parent = os.path.dirname(os.path.abspath(_bp))
            for _pattern in (
                "lib/python*/site-packages",
                "lib/python*/dist-packages",
                "lib64/python*/site-packages",
                "lib64/python*/dist-packages",
            ):
                for _sp in __import__("glob").glob(os.path.join(_parent, _pattern)):
                    if os.path.isdir(_sp):
                        _py_paths.append(_sp)
        if _py_paths:
            _existing = env.get("PYTHONPATH", "")
            env["PYTHONPATH"] = ":".join(_py_paths) + (
                ":" + _existing if _existing else ""
            )
    elif args.hermetic_empty:
        env["PATH"] = ""
    elif args.allow_host_path:
        env["PATH"] = _host_path
    else:
        print(
            "error: build requires --hermetic-path, --hermetic-empty, or --allow-host-path",
            file=sys.stderr,
        )
        sys.exit(1)
    if args.path_prepend:
        _pp_dirs = [os.path.abspath(p) for p in args.path_prepend if os.path.isdir(p)]
        if args.ld_linux and _pp_dirs:
            from portabilize import portabilize_toolchain

            _pp_dirs = portabilize_toolchain(_pp_dirs, args.ld_linux)
        if _pp_dirs:
            env["PATH"] = ":".join(_pp_dirs) + ":" + env.get("PATH", "")
        _dep_lib_dirs = []
        for _bp in args.path_prepend:
            _parent = os.path.dirname(os.path.abspath(_bp))
            for _ld in ("lib", "lib64"):
                _d = os.path.join(_parent, _ld)
                if os.path.isdir(_d) and not os.path.exists(
                    os.path.join(_d, "libc.so.6")
                ):
                    _dep_lib_dirs.append(_d)
                    _glibc_d = os.path.join(_d, "glibc")
                    if os.path.isdir(_glibc_d):
                        _dep_lib_dirs.append(_glibc_d)
        # Skip when ld-linux active for hermetic isolation
        if _dep_lib_dirs and not args.ld_linux:
            _existing = env.get("LD_LIBRARY_PATH", "")
            env["LD_LIBRARY_PATH"] = ":".join(_dep_lib_dirs) + (
                ":" + _existing if _existing else ""
            )

    if args.ld_linux:
        sysroot_lib_paths(args.ld_linux, env)

    env["GOFLAGS"] = env.get("GOFLAGS", "")

    # Ensure writable GOPATH/GOMODCACHE (defaults may point to read-only locations)
    _gopath = os.path.join(os.path.dirname(os.path.abspath(args.output_dir)), ".gopath")
    os.makedirs(_gopath, exist_ok=True)
    env.setdefault("GOPATH", _gopath)
    env.setdefault("GOMODCACHE", os.path.join(_gopath, "pkg", "mod"))

    # Set up vendored dependencies if provided
    if args.vendor_dir:
        vendor_src = os.path.abspath(args.vendor_dir)
        target_vendor = os.path.join(args.source_dir, "vendor")
        # Copy vendor/ from the deps archive into the source tree
        if os.path.isdir(os.path.join(vendor_src, "vendor")):
            shutil.copytree(
                os.path.join(vendor_src, "vendor"),
                target_vendor,
                dirs_exist_ok=True,
                symlinks=True,
                ignore_dangling_symlinks=True,
            )
        else:
            # vendor_dir IS the vendor directory itself
            shutil.copytree(
                vendor_src,
                target_vendor,
                dirs_exist_ok=True,
                symlinks=True,
                ignore_dangling_symlinks=True,
            )
        env["GOFLAGS"] = env.get("GOFLAGS", "") + " -mod=vendor"

    # Copy source to a writable working directory (source may be a read-only
    # Buck2 artifact and go build needs to write to the module cache/vendor).
    work_src = os.path.join(
        os.path.dirname(os.path.abspath(args.output_dir)), ".go-src"
    )

    def _safe_copytree(src, dst):
        """copytree that handles symlink conflicts and loops gracefully."""
        os.makedirs(dst, exist_ok=True)
        with os.scandir(src) as entries:
            for entry in entries:
                s = entry.path
                d = os.path.join(dst, entry.name)
                if entry.is_symlink():
                    try:
                        os.stat(s)  # check for broken/loop symlinks
                    except OSError:
                        continue  # skip broken symlinks
                    linkto = os.readlink(s)
                    if os.path.lexists(d):
                        os.unlink(d)
                    try:
                        os.symlink(linkto, d)
                    except OSError:
                        pass
                elif entry.is_dir(follow_symlinks=False):
                    _safe_copytree(s, d)
                else:
                    try:
                        if os.path.lexists(d):
                            os.unlink(d)
                        shutil.copy2(s, d)
                    except OSError:
                        pass

    _safe_copytree(args.source_dir, work_src)

    # When no vendor deps are provided, fetch Go modules before network
    # isolation.  Skip download when -mod=vendor is set (source already
    # includes a vendor/ directory) or when GO111MODULE=off (GOPATH mode).
    _goflags = env.get("GOFLAGS", "")
    _go111module = env.get("GO111MODULE", "")
    if not args.vendor_dir and "-mod=vendor" not in _goflags and _go111module != "off":
        # Check for go.mod existence before attempting module download
        if os.path.isfile(os.path.join(work_src, "go.mod")):
            dl_cmd = ["go", "mod", "download"]
            dl_result = subprocess.run(dl_cmd, cwd=work_src, env=env)
            if dl_result.returncode != 0:
                print("error: go mod download failed", file=sys.stderr)
                sys.exit(1)
        else:
            print("warning: no go.mod found, skipping go mod download", file=sys.stderr)

    # Fix stale vendor/modules.txt: when -mod=vendor is set and vendor/
    # exists but modules.txt is inconsistent, regenerate it with
    # `go mod vendor` before network isolation.
    # Skip this when vendor_deps was explicitly provided — the archive is authoritative.
    if (
        not args.vendor_dir
        and "-mod=vendor" in _goflags
        and os.path.isdir(os.path.join(work_src, "vendor"))
    ):
        if os.path.isfile(os.path.join(work_src, "go.mod")):
            _fix_env = dict(env)
            # Temporarily remove -mod=vendor so `go mod vendor` can run
            _fix_env["GOFLAGS"] = (
                _fix_env.get("GOFLAGS", "").replace("-mod=vendor", "").strip()
            )
            # Skip sum verification to avoid network issues with sum.golang.org
            _fix_env["GONOSUMCHECK"] = "*"
            _fix_env["GONOSUMDB"] = "*"
            # First download modules to cache (needs network, before isolation)
            dl_result = subprocess.run(
                ["go", "mod", "download"],
                cwd=work_src,
                env=_fix_env,
                capture_output=True,
                text=True,
            )
            if dl_result.returncode != 0:
                print(
                    f"warning: go mod download for vendor fix failed (non-fatal): {dl_result.stderr}",
                    file=sys.stderr,
                )
            # Now regenerate vendor/
            vend_result = subprocess.run(
                ["go", "mod", "vendor"],
                cwd=work_src,
                env=_fix_env,
                capture_output=True,
                text=True,
            )
            if vend_result.returncode != 0:
                print(
                    f"warning: go mod vendor failed (non-fatal): {vend_result.stderr}",
                    file=sys.stderr,
                )

    # Fix go.mod / vendor consistency when vendor_deps archive is provided.
    # The source go.mod may have an old `go` directive that doesn't match
    # the language features used by vendored dependencies.  Since go mod
    # tidy requires network access, we patch go.mod and vendor/modules.txt
    # directly.
    if args.vendor_dir and os.path.isfile(os.path.join(work_src, "go.mod")):
        _go_ver_result = subprocess.run(
            ["go", "version"],
            env=env,
            capture_output=True,
            text=True,
        )
        _sdk_ver = None
        if _go_ver_result.returncode == 0:
            import re

            _m = re.search(r"go(\d+\.\d+)", _go_ver_result.stdout)
            if _m:
                _sdk_ver = _m.group(1)

        if _sdk_ver:
            _gomod = os.path.join(work_src, "go.mod")
            with open(_gomod) as f:
                _gomod_content = f.read()

            # Check current go directive
            _cur_go = re.search(r"^go\s+(\d+\.\d+)", _gomod_content, re.MULTILINE)
            _cur_ver = _cur_go.group(1) if _cur_go else "0.0"
            _cur_parts = tuple(int(x) for x in _cur_ver.split("."))

            # Only patch if the current version is old enough to cause issues
            # (before go1.17 which added unsafe.Slice)
            if _cur_parts < (1, 17):
                # Bump go directive to 1.17 (minimum for unsafe.Slice)
                _new_ver = "1.17"
                _gomod_content = re.sub(
                    r"^go\s+\d+\.\d+",
                    f"go {_new_ver}",
                    _gomod_content,
                    count=1,
                    flags=re.MULTILINE,
                )

                # Add missing indirect deps that Go 1.17+ requires
                _modules_txt = os.path.join(work_src, "vendor", "modules.txt")
                if os.path.isfile(_modules_txt):
                    with open(_modules_txt) as f:
                        _mt_content = f.read()
                    # Find all modules listed in modules.txt
                    _vendored = re.findall(r"^# (\S+) (\S+)", _mt_content, re.MULTILINE)
                    # Find modules already required in go.mod
                    _required = set(
                        re.findall(r"^\s+(\S+)\s+\S+", _gomod_content, re.MULTILINE)
                    )
                    # Add missing indirect deps before the closing paren
                    _missing = [(m, v) for m, v in _vendored if m not in _required]
                    if _missing:
                        _indirect_lines = "\n".join(
                            f"\t{m} {v} // indirect" for m, v in _missing
                        )
                        _gomod_content = _gomod_content.replace(
                            "\n)\n",
                            f"\n{_indirect_lines}\n)\n",
                            1,
                        )

                    # Also mark newly-required modules as explicit in
                    # vendor/modules.txt so go build -mod=vendor accepts them
                    for m, v in _missing:
                        _marker = f"# {m} {v}\n"
                        if (
                            _marker in _mt_content
                            and f"# {m} {v}\n## explicit" not in _mt_content
                        ):
                            _mt_content = _mt_content.replace(
                                _marker,
                                f"{_marker}## explicit\n",
                            )

                    # Update all `## explicit` entries without `; go X.Y` to
                    # include the target go version so the compiler uses the
                    # correct language level for each vendored package.
                    _mt_content = re.sub(
                        r"^## explicit$",
                        f"## explicit; go {_new_ver}",
                        _mt_content,
                        flags=re.MULTILINE,
                    )

                    with open(_modules_txt, "w") as f:
                        f.write(_mt_content)

                with open(_gomod, "w") as f:
                    f.write(_gomod_content)

    # Wrap with unshare --net for network isolation (reproducibility)
    if _NETWORK_ISOLATED:
        cmd = ["unshare", "--net"] + cmd
    else:
        print(
            "⚠ Warning: unshare --net unavailable, building without network isolation",
            file=sys.stderr,
        )

    result = subprocess.run(cmd, cwd=work_src, env=env)
    if result.returncode != 0:
        print(
            f"error: go build failed with exit code {result.returncode}",
            file=sys.stderr,
        )
        sys.exit(1)

    # src_test (opt-in): run `go test` in the same hermetic, network-
    # isolated working tree as the build (Gentoo go-module.eclass runs
    # `go test ./...`).  A non-zero exit aborts before install below, so a
    # failing suite gates install (Buck2 discards the action output).
    if args.run_tests:
        test_cmd = ["go", "test"]
        test_cmd.extend(args.test_args)
        if args.test_packages:
            test_cmd.extend(args.test_packages)
        else:
            test_cmd.append("./...")
        if _NETWORK_ISOLATED:
            test_cmd = ["unshare", "--net"] + test_cmd
        test_result = subprocess.run(test_cmd, cwd=work_src, env=env)
        if test_result.returncode != 0:
            print(
                f"error: go test failed with exit code {test_result.returncode}",
                file=sys.stderr,
            )
            sys.exit(1)

    if args.lib_only:
        # Library-only mode: install Go source files instead of binaries
        go_src_dir = os.path.join(
            os.path.abspath(args.output_dir), "usr", "share", "go", "src"
        )
        os.makedirs(go_src_dir, exist_ok=True)
        # Detect module path from go.mod
        go_mod = os.path.join(work_src, "go.mod")
        mod_path = None
        if os.path.isfile(go_mod):
            with open(go_mod) as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("module "):
                        mod_path = line.split(None, 1)[1].strip()
                        break
        if mod_path:
            dest = os.path.join(go_src_dir, mod_path)
        else:
            dest = go_src_dir
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copytree(work_src, dest, dirs_exist_ok=True)
        # Remove empty bin_dir created earlier
        if os.path.isdir(bin_dir) and not os.listdir(bin_dir):
            os.rmdir(bin_dir)
            usr_bin_parent = os.path.dirname(bin_dir)
            if os.path.isdir(usr_bin_parent) and not os.listdir(usr_bin_parent):
                os.rmdir(usr_bin_parent)
    else:
        # Verify at least one binary was produced
        binaries = [
            f
            for f in os.listdir(bin_dir)
            if os.path.isfile(os.path.join(bin_dir, f))
            and os.access(os.path.join(bin_dir, f), os.X_OK)
        ]

        # If specific bins were requested, remove any extras
        if args.bins:
            for f in list(binaries):
                if f not in args.bins:
                    os.remove(os.path.join(bin_dir, f))
            binaries = [f for f in binaries if f in args.bins]

        if not binaries:
            print(
                "error: no executable binaries found in output directory",
                file=sys.stderr,
            )
            sys.exit(1)


if __name__ == "__main__":
    main()
