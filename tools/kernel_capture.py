#!/usr/bin/env python3
"""kernel_capture.py — run a full kernel build under libkbuild_trace.so
and produce a build plan suitable for replay.

Captures every exec(2) issued by the build (compile, link,
archive, host tools, headers_install, modules_install, BTF generation),
post-processes the raw JSONL trace into a build_plan.json with one
ordered action per captured exec, and stages all final outputs
(vmlinux, bzImage, modules/, headers/, vmlinux.h) alongside.

The plan format is intentionally minimal:

    {
      "version": 1,
      "kernel_version": "<string>",
      "kbuild_release": "<string>",
      "arch": "<x86|arm64>",
      "build_tree": "<absolute path used at capture time>",
      "config_sha256": "<hex>",
      "actions": [
        {"id": 0, "phase": "compile", "cwd": "...", "argv": [...], "env": [...]},
        ...
      ]
    }

The replay rule enriches each action with declared inputs/outputs and
DAG edges so Buck can schedule them in parallel.

Usage:
    kernel_capture.py \
        --source-dir <linux source> \
        --config <kernel.config> \
        --arch x86_64 \
        --output-dir /tmp/cap \
        --trace-lib /path/to/libkbuild_trace.so
"""

import argparse
import hashlib
import json
import multiprocessing
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from _env import derive_lib_paths, sanitize_global_env, sysroot_lib_paths

# Tools whose execs we drop entirely from the replay plan because they
# only inspect or mutate state during the capture itself (status output,
# stat, ls, etc.). Conservative — we keep almost everything.
_NOISY_BASENAMES = frozenset({
    "uname", "stty", "tty", "id", "whoami", "hostname",
    "tput", "clear", "reset",
})


def main() -> int:
    p = argparse.ArgumentParser(description="Capture a kernel build into a replay plan")
    p.add_argument("--source-dir", required=True)
    p.add_argument("--config", required=True, help="Resolved .config to use")
    p.add_argument("--arch", required=True, choices=["x86_64", "aarch64"])
    p.add_argument("--output-dir",
                   help="Output dir for build_plan.json + staged artifacts "
                        "(legacy single-output mode; --plan-out and "
                        "--build-tree-out are preferred for Buck integration)")
    p.add_argument("--plan-out",
                   help="Explicit output path for build_plan.json")
    p.add_argument("--build-tree-out",
                   help="Explicit output dir for the captured build tree")
    # The Buck rule pre-declares these as first-class outputs
    # so the replay rule can wire them directly without cp-fallbacks.
    p.add_argument("--vmlinux-out",      help="Output path for vmlinux")
    p.add_argument("--bzimage-out",      help="Output path for bzImage / Image")
    p.add_argument("--symvers-out",      help="Output path for Module.symvers")
    p.add_argument("--config-out",       help="Output path for the resolved .config")
    p.add_argument("--headers-out",      help="Output dir for headers_install")
    p.add_argument("--modules-out",      help="Output dir for modules_install")
    p.add_argument("--vmlinux-h-out",    help="Output path for vmlinux.h (BTF)")
    p.add_argument("--trace-lib", required=True,
                   help="Path to libkbuild_trace.so")
    p.add_argument("--cross-compile", default="",
                   help="CROSS_COMPILE prefix for cross builds")
    p.add_argument("--jobs", type=int, default=None)
    p.add_argument("--make-flag", action="append", dest="make_flags", default=[],
                   help="Extra KEY=VAL passed to make (repeatable)")
    p.add_argument("--phase", action="append", dest="phases", default=[],
                   choices=["compile", "headers_install", "modules_install", "btf"],
                   help="Subset of phases to run (default: all)")
    p.add_argument("--skip-build", action="store_true",
                   help="Reuse existing build-tree/ and trace.jsonl, only re-emit plan")
    # Toolchain plumbing — mirrors tools/kernel_build.py so the Buck rule
    # can pass the same toolchain_helpers args.
    p.add_argument("--hermetic-path", action="append", dest="hermetic_path", default=[],
                   help="Set PATH to only these dirs (repeatable)")
    p.add_argument("--hermetic-empty", action="store_true",
                   help="Start with empty PATH (populated by --path-prepend)")
    p.add_argument("--allow-host-path", action="store_true",
                   help="Allow host PATH (bootstrap escape hatch)")
    p.add_argument("--path-prepend", action="append", dest="path_prepend", default=[],
                   help="Prepend dir to PATH (repeatable)")
    p.add_argument("--lib-prepend", action="append", dest="lib_prepend", default=[],
                   help="Prepend dir to LD_LIBRARY_PATH (repeatable)")
    p.add_argument("--ld-linux", default=None,
                   help="Buckos ld-linux path (disables posix_spawn)")
    args = p.parse_args()

    source_dir = Path(args.source_dir).resolve()
    config = Path(args.config).resolve()
    trace_lib = Path(args.trace_lib).resolve()

    if not source_dir.is_dir():
        die(f"source dir not found: {source_dir}")
    if not config.is_file():
        die(f"config file not found: {config}")
    if not trace_lib.is_file():
        die(f"trace lib not found: {trace_lib}")

    if args.plan_out and args.build_tree_out:
        plan_path = Path(args.plan_out).resolve()
        build_tree = Path(args.build_tree_out).resolve()
        # Auxiliary outputs (trace) share the build_tree's parent so
        # they're easy to inspect.
        aux_dir = build_tree.parent
    elif args.output_dir:
        aux_dir = Path(args.output_dir).resolve()
        aux_dir.mkdir(parents=True, exist_ok=True)
        build_tree = aux_dir / "build-tree"
        plan_path = aux_dir / "build_plan.json"
    else:
        die("must pass either --output-dir or both --plan-out and --build-tree-out")

    aux_dir.mkdir(parents=True, exist_ok=True)
    trace_path = aux_dir / "trace.jsonl"
    # When Buck-declared outputs are passed, capture writes
    # straight to them.  Otherwise fall back to aux-dir paths so the
    # standalone --output-dir mode still works.
    staged_headers = Path(args.headers_out).resolve() if args.headers_out \
                     else aux_dir / "staged-headers"
    staged_modules = Path(args.modules_out).resolve() if args.modules_out \
                     else aux_dir / "staged-modules"
    vmlinux_h_out = Path(args.vmlinux_h_out).resolve() if args.vmlinux_h_out \
                    else aux_dir / "vmlinux.h"
    vmlinux_target = Path(args.vmlinux_out).resolve() if args.vmlinux_out else None
    bzimage_target = Path(args.bzimage_out).resolve() if args.bzimage_out else None
    symvers_target = Path(args.symvers_out).resolve() if args.symvers_out else None
    config_target = Path(args.config_out).resolve() if args.config_out else None

    arch_kbuild = {"x86_64": "x86", "aarch64": "arm64"}[args.arch]
    image_path = {"x86_64": "arch/x86/boot/bzImage",
                  "aarch64": "arch/arm64/boot/Image"}[args.arch]
    phases = args.phases or ["compile", "headers_install", "modules_install", "btf"]

    if not args.skip_build:
        if build_tree.exists():
            shutil.rmtree(build_tree)
        log(f"copying source: {source_dir} -> {build_tree}")
        shutil.copytree(source_dir, build_tree, symlinks=True)

        # Apply toolchain plumbing to os.environ before deriving the
        # capture env.  Same recipe as tools/kernel_build.py.
        apply_toolchain_env(args)
        env = capture_env(trace_lib, trace_path)
        jobs = args.jobs or multiprocessing.cpu_count()
        make_base = [
            "make", "-C", str(build_tree),
            f"ARCH={arch_kbuild}",
            f"-j{jobs}",
            "WERROR=0",
            "KBUILD_BUILD_TIMESTAMP=Thu Jan  1 00:00:00 UTC 1970",
            "KBUILD_BUILD_USER=buckos",
            "KBUILD_BUILD_HOST=buckos",
        ]
        if args.cross_compile:
            make_base.append(f"CROSS_COMPILE={args.cross_compile}")
        for flag in args.make_flags:
            make_base.append(resolve_make_flag(flag))

        # Wipe build artifacts that may have been carried over from a
        # prior in-tree build (the source dir may have stale .o/.cmd/
        # vmlinux from someone's local make).  mrproper removes .config
        # too, so do this BEFORE staging the .config.
        log("running mrproper (not captured)")
        run(make_base + ["mrproper"], env=baseline_env(env))

        shutil.copy2(config, build_tree / ".config")

        # Truncate the trace file
        trace_path.write_bytes(b"")

        # olddefconfig is *not* captured — it produces .config from the
        # given fragment, not build artifacts. Run it without the shim.
        log("running olddefconfig (not captured)")
        run(make_base + ["olddefconfig"], env=baseline_env(env))

        # Detect whether modules are enabled — tinyconfig and similar
        # disable CONFIG_MODULES, in which case `make modules` is a hard
        # error.  We compile/install modules conditionally.
        modules_enabled = config_has(build_tree / ".config", "CONFIG_MODULES=y")

        if "compile" in phases:
            image_target = os.path.basename(image_path)
            targets = ["vmlinux", image_target]
            if modules_enabled:
                targets.append("modules")
            log(f"capturing compile phase: {' '.join(targets)}")
            run(make_base + targets, env=env)

        if "headers_install" in phases:
            log("capturing headers_install")
            staged_headers.mkdir(exist_ok=True)
            run(make_base + [f"INSTALL_HDR_PATH={staged_headers}", "headers_install"],
                env=env)

        if "modules_install" in phases:
            if modules_enabled:
                log("capturing modules_install")
                staged_modules.mkdir(exist_ok=True)
                run(make_base + [f"INSTALL_MOD_PATH={staged_modules}", "modules_install"],
                    env=env)
            else:
                log("skipping modules_install (CONFIG_MODULES not set)")

        if "btf" in phases:
            log("capturing BTF generation")
            generate_btf(build_tree, vmlinux_h_out, env)

        # Copy first-class artifacts to Buck-declared paths.
        # These are byte-identical to what legacy kernel_build emits.
        image_rel = {"x86_64": "arch/x86/boot/bzImage",
                     "aarch64": "arch/arm64/boot/Image"}[args.arch]
        for src_rel, dest in (
            ("vmlinux", vmlinux_target),
            (image_rel, bzimage_target),
            ("Module.symvers", symvers_target),
            (".config", config_target),
        ):
            if dest is None:
                continue
            src = build_tree / src_rel
            if src.is_file():
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dest)
                log(f"staged {src_rel} -> {dest}")
            else:
                log(f"WARN: {src_rel} not produced by capture; writing empty {dest}")
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(b"")

    if not trace_path.exists():
        die(f"trace not found at {trace_path} (did capture run?)")

    log(f"parsing trace: {trace_path}")
    plan = build_plan(
        trace_path=trace_path,
        build_tree=build_tree,
        config_path=config,
        arch=arch_kbuild,
        image_path=image_path,
    )
    plan_path.write_text(json.dumps(plan, indent=2))
    log(f"wrote plan: {plan_path} ({len(plan['actions'])} actions)")

    return 0


def resolve_make_flag(flag: str) -> str:
    """Make `KEY=VAL` flags safe to pass to make running in a subdir.

    make changes cwd to the build tree, so relative buck-out paths in
    KEY=VAL (e.g. CC=buck-out/v2/gen/.../gcc) won't resolve from the
    subdir.  Convert any token that looks like a buck-out-relative path
    to an absolute path.  Same logic as tools/kernel_build.py.
    """
    if "=" not in flag:
        return flag
    key, _, val = flag.partition("=")
    tokens = val.split()
    resolved = []
    for t in tokens:
        absorbed = False
        for prefix in ("--sysroot=", "-specs=", "-I", "-L", "-Wl,-rpath-link,"):
            if t.startswith(prefix):
                path = t[len(prefix):]
                if not os.path.isabs(path) and (path.startswith("buck-out") or os.path.exists(path)):
                    t = prefix + os.path.abspath(path)
                absorbed = True
                break
        if not absorbed:
            if not os.path.isabs(t) and (t.startswith("buck-out") or os.path.exists(t)):
                t = os.path.abspath(t)
        resolved.append(t)
    return f"{key}={' '.join(resolved)}"


def _derive_perl5lib(args) -> None:
    """Point PERL5LIB at the buckos perl's core module dirs.

    The buckos perl's compiled-in @INC is *relative* ("../lib/perl5/...").
    A normal kernel_build resolves it because perl anchors @INC to its own
    binary location, but under the captured make (perl invoked indirectly
    by kbuild recipes under LD_PRELOAD) that anchoring doesn't kick in, so
    perl can't load even core modules like strict.pm and aborts
    (lib/build_OID_registry -> lib/oid_registry_data.c).

    Mirrors tools/perl_helper._build_perl5lib, but also adds the *versioned*
    core dirs (lib/perl5/<ver> + arch subdir) where the stdlib lives, not
    just lib/perl5 -- that is where strict.pm actually is.
    """
    perl5lib = []
    bins = list(args.path_prepend or []) + list(args.hermetic_path or [])
    for bin_dir in bins:
        parent = os.path.dirname(os.path.abspath(bin_dir))
        for base in (parent, os.path.join(parent, "usr")):
            for libname in ("lib/perl5", "lib64/perl5", "share/perl5"):
                root = os.path.join(base, libname)
                if not os.path.isdir(root):
                    continue
                perl5lib.append(root)
                for cand in (root, os.path.join(root, "site_perl"),
                             os.path.join(root, "vendor_perl")):
                    if not os.path.isdir(cand):
                        continue
                    for ver in sorted(os.listdir(cand)):
                        vdir = os.path.join(cand, ver)
                        if not (ver[:1].isdigit() and os.path.isdir(vdir)):
                            continue
                        perl5lib.append(vdir)
                        for sub in sorted(os.listdir(vdir)):
                            adir = os.path.join(vdir, sub)
                            if "-linux-" in sub and os.path.isdir(adir):
                                perl5lib.append(adir)
    seen = set()
    ordered = [d for d in perl5lib if not (d in seen or seen.add(d))]
    if ordered:
        existing = os.environ.get("PERL5LIB", "")
        os.environ["PERL5LIB"] = ":".join(ordered) + (
            ":" + existing if existing else "")


def apply_toolchain_env(args) -> None:
    """Apply --hermetic-path / --path-prepend / --ld-linux to os.environ.

    Mirrors tools/kernel_build.py so the same Buck toolchain_helpers
    args produce the same effective PATH/LD_LIBRARY_PATH/etc. inside
    the make process the shim is loaded into.
    """
    host_path = os.environ.get("PATH", "")
    sanitize_global_env()

    if args.hermetic_path:
        os.environ["PATH"] = ":".join(os.path.abspath(p) for p in args.hermetic_path)
    elif args.hermetic_empty:
        os.environ["PATH"] = ""
    elif args.allow_host_path:
        os.environ["PATH"] = host_path
    else:
        die("requires --hermetic-path, --hermetic-empty, or --allow-host-path")

    if args.path_prepend:
        prepend = ":".join(os.path.abspath(p) for p in args.path_prepend if os.path.isdir(p))
        if prepend:
            os.environ["PATH"] = prepend + ":" + os.environ.get("PATH", "")

    if args.hermetic_path:
        derive_lib_paths(args.hermetic_path, os.environ)
    if args.path_prepend:
        derive_lib_paths(args.path_prepend, os.environ)

    if args.lib_prepend:
        lib_dirs = [os.path.abspath(d) for d in args.lib_prepend if os.path.isdir(d)]
        if lib_dirs:
            existing = os.environ.get("LD_LIBRARY_PATH", "")
            os.environ["LD_LIBRARY_PATH"] = ":".join(lib_dirs) + (":" + existing if existing else "")

    if args.ld_linux:
        sysroot_lib_paths(args.ld_linux, os.environ)

    # Anchor the buckos perl's relative @INC so kbuild's perl recipes
    # (e.g. lib/build_OID_registry) can load core modules under capture.
    _derive_perl5lib(args)


def capture_env(trace_lib: Path, trace_file: Path) -> dict:
    """Build env for make invocations under the shim."""
    env = os.environ.copy()
    env["LD_PRELOAD"] = str(trace_lib)
    env["KBUILD_TRACE_FILE"] = str(trace_file)
    return env


def baseline_env(env: dict) -> dict:
    """Same env minus the trace shim — for unrecorded steps like olddefconfig."""
    out = env.copy()
    out.pop("LD_PRELOAD", None)
    out.pop("KBUILD_TRACE_FILE", None)
    return out


def generate_btf(build_tree: Path, vmlinux_h_out: Path, env: dict) -> None:
    """Run bpftool to generate vmlinux.h from the built vmlinux."""
    vmlinux = build_tree / "vmlinux"
    if not vmlinux.exists():
        log(f"WARN: vmlinux not found at {vmlinux} — skipping BTF")
        vmlinux_h_out.write_text("")
        return
    bpftool = shutil.which("bpftool")
    if not bpftool:
        log("WARN: bpftool not found — skipping BTF")
        vmlinux_h_out.write_text("")
        return
    with vmlinux_h_out.open("w") as f:
        run([bpftool, "btf", "dump", "file", str(vmlinux), "format", "c"],
            env=env, stdout=f)


def build_plan(trace_path: Path, build_tree: Path, config_path: Path,
               arch: str, image_path: str) -> dict:
    """Parse trace.jsonl, drop noise, enrich with .cmd-derived I/O."""
    actions = []
    next_id = 0
    with trace_path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("truncated"):
                log(f"WARN: truncated trace entry pid={rec.get('pid')} — "
                    f"may affect replay fidelity")
            path = rec.get("path", "")
            argv = rec.get("argv") or []
            if not argv:
                continue
            base = os.path.basename(path) if path else os.path.basename(argv[0])
            if base in _NOISY_BASENAMES:
                continue
            actions.append({
                "id": next_id,
                "ts": rec.get("ts", 0),
                "pid": rec.get("pid", 0),
                "ppid": rec.get("ppid", 0),
                "phase": classify_phase(rec, build_tree),
                "category": classify_category(base),
                "cwd": rec.get("cwd", ""),
                "path": path,
                "argv": argv,
                "env": rec.get("env") or [],
                # Filled in by enrich_with_cmd_files()
                "inputs": [],
                "outputs": [],
                "depfile": "",
                "source": "",
                "cmd_str": "",
            })
            next_id += 1

    cmd_index = scan_cmd_files(build_tree)
    log(f"indexed {len(cmd_index)} kbuild .cmd entries")
    enrich_with_cmd_files(actions, cmd_index, build_tree)

    return {
        "version": 1,
        "arch": arch,
        "image_path": image_path,
        "build_tree": str(build_tree),
        "config_sha256": file_sha256(config_path),
        "kernel_version": read_kernel_version(build_tree),
        "kbuild_release": read_kbuild_release(build_tree),
        "actions": actions,
    }


# ── .cmd file parsing ───────────────────────────────────────────────

# Kbuild .cmd files are key=value Makefile fragments dropped next to each
# build artifact, e.g. fs/ext4/.inode.o.cmd contains:
#   savedcmd_fs/ext4/inode.o := gcc -Wp,-MMD,fs/ext4/.inode.o.d ... -o fs/ext4/inode.o fs/ext4/inode.c
#   source_fs/ext4/inode.o := fs/ext4/inode.c
#   deps_fs/ext4/inode.o := \
#     include/linux/fs.h \
#     include/linux/types.h \
#       $(wildcard include/config/SOMETHING) \
#     ...
# Older kernels use `cmd_<out>` instead of `savedcmd_<out>`.

_CMD_KEY_RE = re.compile(r"^(savedcmd|cmd|source|deps)_(.+?) := (.*?)(\\?)$")


def scan_cmd_files(build_tree: Path) -> dict:
    """Walk build_tree, parse every .cmd file. Returns {output_path: meta}."""
    out = {}
    for cmdfile in build_tree.rglob(".*.cmd"):
        try:
            entries = parse_cmd_file(cmdfile)
        except Exception as e:
            log(f"WARN: failed to parse {cmdfile}: {e}")
            continue
        for output_rel, meta in entries.items():
            out[output_rel] = meta
    return out


def parse_cmd_file(cmdfile: Path) -> dict:
    """Parse one .cmd file. Returns {output_rel: {cmd, source, deps}}."""
    entries = {}
    current_key = None
    current_out = None
    text = cmdfile.read_text(errors="replace")
    # Join \-continued lines first to simplify parsing.
    text = text.replace("\\\n", " ")
    for line in text.splitlines():
        line = line.rstrip()
        if not line or line.startswith("#"):
            continue
        m = _CMD_KEY_RE.match(line)
        if not m:
            continue
        kind, output_rel, value, _ = m.groups()
        if output_rel not in entries:
            entries[output_rel] = {"cmd": "", "source": "", "deps": []}
        if kind in ("savedcmd", "cmd"):
            entries[output_rel]["cmd"] = value.strip()
        elif kind == "source":
            entries[output_rel]["source"] = value.strip()
        elif kind == "deps":
            entries[output_rel]["deps"] = parse_deps(value)
    return entries


_WILDCARD_RE = re.compile(r"\$\([^)]*\)")


def parse_deps(deps_value: str) -> list:
    """Strip $(wildcard ...) patterns; return real file paths.

    Kbuild deps lines look like:
      $(wildcard include/config/SMP) include/linux/types.h $(wildcard ...)
    After joining \\-continuations and splitting on whitespace, the
    `$(wildcard ...)` tokens get split into `$(wildcard` + `arg)` halves.
    Easiest: strip `$(...)` patterns from the string first, then split.
    """
    cleaned = _WILDCARD_RE.sub(" ", deps_value)
    return [tok for tok in cleaned.split() if tok and not tok.startswith("$")]


def enrich_with_cmd_files(actions: list, cmd_index: dict, build_tree: Path):
    """Match each captured exec to its .cmd entry by output path."""
    bt_str = str(build_tree)
    matched = 0
    for act in actions:
        out_rel = derive_output_path(act, bt_str)
        if not out_rel:
            continue
        meta = cmd_index.get(out_rel)
        if not meta:
            continue
        act["outputs"] = [out_rel]
        act["inputs"] = list(meta["deps"])
        if meta["source"]:
            act["source"] = meta["source"]
            if meta["source"] not in act["inputs"]:
                act["inputs"].insert(0, meta["source"])
        if meta["cmd"]:
            # Use the kbuild-resolved shell recipe verbatim.  This is
            # what `make V=1` would print: a single shell-string that
            # the wrapper can execute via `sh -c`.  Far more reliable
            # than reconstructing it from argv (which loses pipes,
            # redirections, and multi-step shell logic from $(filechk)
            # and friends).
            act["cmd_str"] = meta["cmd"]
        # Look for an associated .d depfile (gcc -MMD)
        d_path = derive_depfile_path(out_rel)
        if (build_tree / d_path).is_file():
            act["depfile"] = d_path
        matched += 1
    log(f"enriched {matched}/{len(actions)} actions with .cmd metadata")


def derive_output_path(act: dict, build_tree: str) -> str:
    """Extract the captured action's primary output (relative to build tree).

    Heuristic: scan argv for `-o FILE` or `-o=FILE`, return FILE relative
    to build_tree.  Returns empty string if no output detected.
    """
    argv = act["argv"]
    out_arg = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "-o" and i + 1 < len(argv):
            out_arg = argv[i + 1]
            break
        if a.startswith("-o="):
            out_arg = a[3:]
            break
        i += 1
    if not out_arg:
        # ar/ranlib have output as positional arg after flags.
        # `ar cDPrST built-in.a foo.o bar.o` → output is argv[2]
        base = os.path.basename(act.get("path") or argv[0])
        if base in ("ar", "ranlib") and len(argv) >= 3:
            out_arg = argv[2]
    if not out_arg:
        return ""
    cwd = act.get("cwd", "")
    if not os.path.isabs(out_arg) and cwd:
        out_abs = os.path.normpath(os.path.join(cwd, out_arg))
    else:
        out_abs = os.path.normpath(out_arg)
    if out_abs.startswith(build_tree + "/"):
        return out_abs[len(build_tree) + 1:]
    if cwd.startswith(build_tree):
        # Output already relative to build tree
        return out_arg
    return ""


def derive_depfile_path(output_rel: str) -> str:
    """Map fs/ext4/inode.o → fs/ext4/.inode.o.d (kbuild convention)."""
    d = os.path.dirname(output_rel)
    b = os.path.basename(output_rel)
    return os.path.join(d, "." + b + ".d")


def classify_category(basename: str) -> str:
    if basename in ("gcc", "cc", "g++", "c++", "clang", "clang++"):
        return "cc"
    if basename in ("cc1", "cc1plus", "cc1obj"):
        return "cc1"
    if basename in ("ld", "ld.bfd", "ld.gold", "ld.lld", "collect2"):
        return "ld"
    if basename in ("ar",):
        return "ar"
    if basename in ("as",):
        return "as"
    if basename in ("ranlib",):
        return "ranlib"
    if basename in ("nm",):
        return "nm"
    if basename in ("objcopy",):
        return "objcopy"
    if basename in ("strip",):
        return "strip"
    if basename in ("make",):
        return "make"
    if basename in ("bpftool",):
        return "bpftool"
    if basename in ("depmod",):
        return "depmod"
    if basename in ("python", "python3"):
        return "python"
    if basename in ("perl",):
        return "perl"
    if basename in ("sh", "bash", "dash"):
        return "shell"
    return "other"


def classify_phase(rec: dict, build_tree: Path) -> str:
    """Heuristic phase tag from argv. Used by replay for routing outputs."""
    argv = rec.get("argv") or []
    cmdline = " ".join(argv)
    if "INSTALL_HDR_PATH=" in cmdline or "headers_install" in cmdline:
        return "headers_install"
    if "INSTALL_MOD_PATH=" in cmdline or "modules_install" in cmdline:
        return "modules_install"
    if "btf" in cmdline and "bpftool" in cmdline:
        return "btf"
    return "compile"


def config_has(config: Path, line: str) -> bool:
    """Return True iff `line` appears as a non-comment line in .config."""
    if not config.is_file():
        return False
    target = line.strip()
    with config.open() as f:
        for raw in f:
            if raw.strip() == target:
                return True
    return False


def file_sha256(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def read_kbuild_release(build_tree: Path) -> str:
    f = build_tree / "include" / "config" / "kernel.release"
    return f.read_text().strip() if f.is_file() else ""


def read_kernel_version(build_tree: Path) -> str:
    """Read VERSION/PATCHLEVEL/SUBLEVEL from top-level Makefile."""
    mk = build_tree / "Makefile"
    if not mk.is_file():
        return ""
    parts = {"VERSION": "", "PATCHLEVEL": "", "SUBLEVEL": ""}
    with mk.open() as f:
        for line in f:
            for k in parts:
                if line.startswith(k + " ="):
                    parts[k] = line.split("=", 1)[1].strip()
        return f"{parts['VERSION']}.{parts['PATCHLEVEL']}.{parts['SUBLEVEL']}"


def run(cmd, env=None, stdout=None) -> None:
    log(f"+ {' '.join(str(c) for c in cmd[:6])}{' ...' if len(cmd) > 6 else ''}")
    r = subprocess.run(cmd, env=env, stdout=stdout)
    if r.returncode != 0:
        die(f"command failed (exit {r.returncode}): {' '.join(str(c) for c in cmd[:8])}")


def log(msg: str) -> None:
    print(f"[capture] {msg}", file=sys.stderr, flush=True)


def die(msg: str):
    print(f"[capture] error: {msg}", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    sys.exit(main())
