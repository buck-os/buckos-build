"""
Bootstrap toolchain rules for building a self-hosted GCC/glibc toolchain.

Six rules following autotools_build's 5-phase pattern.  All phases
delegate to Python helpers for env sanitisation and determinism.

  bootstrap_binutils      — cross-binutils for target triple
  bootstrap_linux_headers — kernel headers via make headers_install
  bootstrap_gcc           — GCC (cross or native, multi-pass)
  bootstrap_glibc         — glibc built with cross-gcc
  bootstrap_package       — generic autotools using BootstrapStageInfo
  bootstrap_python        — cross-compiled Python interpreter
"""

load("//defs:providers.bzl", "BootstrapStageInfo", "PackageInfo")
load("//tc:transitions.bzl", "strip_toolchain_mode")

TARGET_TRIPLE = "x86_64-buckos-linux-gnu"

# ── Shared helpers ───────────────────────────────────────────────────

# ── Compiler cache for bootstrap (opportunistic host ccache) ─────────
_BOOTSTRAP_CACHE_MODE = read_config("buckos.cache", "mode", "enabled")
_BOOTSTRAP_CACHE_LOCATION = read_config("buckos.cache", "location", "homedir")
_BOOTSTRAP_CCACHE_SIZE = read_config("buckos.cache", "ccache_size", "100G")

def _bootstrap_cache_env():
    """Return cache env dict for bootstrap builds.

    Uses the same buckconfig-controlled settings as normal builds
    (CCACHE_DIR, COMPILERCHECK, etc.) but relies on the host's ccache
    binary.  If ccache isn't on the host PATH, setup_ccache_symlinks()
    in the helper is a no-op — no error.
    """
    if _BOOTSTRAP_CACHE_MODE != "enabled":
        return {}
    ccache_dir = ".buckos/cache/ccache" if _BOOTSTRAP_CACHE_LOCATION == "projectdir" else "~/.buckos/caches/ccache"
    return {
        "BUCKOS_CCACHE": "1",
        "CCACHE_COMPILERCHECK": "content",
        "CCACHE_DIR": ccache_dir,
        "CCACHE_MAXSIZE": _BOOTSTRAP_CCACHE_SIZE,
        "CCACHE_NOHASHDIR": "1",
        "CCACHE_SLOPPINESS": "pch_defines,time_macros,include_file_mtime",
    }

def _env_args(cmd, env_dict):
    """Append --env KEY=VALUE flags to a cmd_args."""
    for k, v in env_dict.items():
        cmd.add("--env", cmd_args(k, "=", v, delimiter = ""))

def _toolchain_env(ctx):
    """Build environment dict from BootstrapStageInfo or host_cc attrs."""
    env = {}
    # Compiler cache env first — toolchain env can override if needed.
    env.update(_bootstrap_cache_env())
    if getattr(ctx.attrs, "prev_stage", None) and BootstrapStageInfo in ctx.attrs.prev_stage:
        stage = ctx.attrs.prev_stage[BootstrapStageInfo]
        env["CC"] = stage.cc
        env["CXX"] = stage.cxx
        env["AR"] = stage.ar
    else:
        if getattr(ctx.attrs, "host_cc", None):
            env["CC"] = ctx.attrs.host_cc
        if getattr(ctx.attrs, "host_cxx", None):
            env["CXX"] = ctx.attrs.host_cxx
        if getattr(ctx.attrs, "host_ar", None):
            env["AR"] = ctx.attrs.host_ar
    return env

# ── bootstrap_binutils ───────────────────────────────────────────────

# ── single-action helper ─────────────────────────────────────────────
#
# Run all phases (prepare/configure/compile/install) as ONE action with
# plain scratch intermediates (under BUCK_SCRATCH_PATH), only `installed`
# declared.  Splitting phases into separate actions makes Buck2
# re-materialize the build tree between them; under buck2 with content-based artifact paths that
# loses/relocates generated files (e.g. autotools doc .stamp files, math
# lib headers) and produces inconsistent trees where `make`/`make install`
# spuriously regenerates and fails.  One action preserves real on-disk
# mtimes and the full tree, like a hand-run ./configure && make && make
# install.
#
# Each phase command is written to its own argfile (one arg per line, so
# values with spaces survive), with `@WORK@`/`@OUT@` placeholders the
# orchestrator substitutes at runtime (@WORK@ -> scratch, @OUT@ -> the
# declared `installed` output).  The orchestrator mapfile-reads each
# argfile and execs it, preserving arg boundaries.

def _bootstrap_phases_action(ctx, name, phases, extra_hidden = []):
    installed = ctx.actions.declare_output("installed", dir = True)

    argfiles = []
    for i, ph in enumerate(phases):
        af, _macro = ctx.actions.write(
            "{}_p{}.args".format(name, i),
            ph,
            allow_args = True,
        )
        argfiles.append(af)

    lines = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        'OUT="$1"; shift',
        'WORK="${BUCK_SCRATCH_PATH:-${TMPDIR:-/tmp}}/' + name + '"',
        'rm -rf "$WORK"; mkdir -p "$WORK"',
        "run() {",
        "  local a=() l",
        '  while IFS= read -r l || [ -n "$l" ]; do',
        '    l="${l//@WORK@/$WORK}"; l="${l//@OUT@/$OUT}"; a+=("$l")',
        '  done < "$1"',
        '  "${a[@]}"',
        "}",
        'for f in "$@"; do run "$f"; done',
    ]
    orch = ctx.actions.write(name + ".sh", "\n".join(lines) + "\n", is_executable = True)

    run_cmd = cmd_args([orch, installed.as_output()] + argfiles, hidden = phases + extra_hidden)
    # The bootstrap toolchain is built before any buckos host tools exist, so
    # it relies on the host's build tools (bison, msgfmt, flex, ...) via
    # --allow-host-path. RE workers don't have all of these (e.g. bison), so
    # run the bootstrap locally; regular packages still build on RE.
    ctx.actions.run(run_cmd, category = name, identifier = ctx.attrs.name, allow_cache_upload = True, local_only = True)

    return installed

def _bootstrap_binutils_impl(ctx):
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]
    target_triple = ctx.attrs.target_triple
    env = _toolchain_env(ctx)

    configure_args = [
        "--target=" + target_triple,
        "--prefix=/tools",
        "--with-sysroot=/tools",
        "--disable-nls",
        "--disable-werror",
        "--disable-shared",
        "--disable-gdb",
        "--disable-gdbserver",
        "--disable-sim",
        "--disable-libdecnumber",
        "--disable-readline",
        "--enable-gprofng=no",
        "--enable-default-hash-style=gnu",
        "--without-xxhash",
    ] + ctx.attrs.extra_configure_args

    conf = cmd_args(ctx.attrs._configure_tool[RunInfo])
    conf.add("--source-dir", source)
    conf.add("--output-dir", "@WORK@/configured")
    conf.add("--build-subdir", "build")
    for arg in configure_args:
        conf.add(cmd_args("--configure-arg=", arg, delimiter = ""))
    _env_args(conf, env)
    conf.add("--allow-host-path")

    build = cmd_args(ctx.attrs._build_tool[RunInfo])
    build.add("--build-dir", "@WORK@/configured")
    build.add("--output-dir", "@WORK@/built")
    build.add("--build-subdir", "build")
    build.add("--make-arg", "MAKEINFO=true")
    _env_args(build, env)
    build.add("--allow-host-path")

    inst = cmd_args(ctx.attrs._install_tool[RunInfo])
    inst.add("--build-dir", "@WORK@/built")
    inst.add("--build-subdir", "build")
    inst.add("--prefix", "@OUT@")
    inst.add("--make-arg", "MAKEINFO=true")
    _env_args(inst, env)
    inst.add("--allow-host-path")

    installed = _bootstrap_phases_action(ctx, "bootstrap_binutils", [conf, build, inst])
    return [DefaultInfo(default_output = installed)]

bootstrap_binutils = rule(
    impl = _bootstrap_binutils_impl,
    attrs = {
        "extra_configure_args": attrs.list(attrs.string(), default = []),
        "host_ar": attrs.option(attrs.string(), default = None),
        "host_cc": attrs.option(attrs.string(), default = None),
        "host_cxx": attrs.option(attrs.string(), default = None),
        "source": attrs.dep(),
        "target_triple": attrs.string(default = TARGET_TRIPLE),
        "_build_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:build_helper"),
        ),
        "_configure_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:configure_helper"),
        ),
        "_install_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:install_helper"),
        ),
    },
    cfg = strip_toolchain_mode,
)

# ── bootstrap_linux_headers ──────────────────────────────────────────

def _bootstrap_linux_headers_impl(ctx):
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]

    # Copy source tree (skip configure)
    prepared = ctx.actions.declare_output("prepared", dir = True)
    prep_cmd = cmd_args(ctx.attrs._configure_tool[RunInfo])
    prep_cmd.add("--source-dir", source)
    prep_cmd.add("--output-dir", prepared.as_output())
    prep_cmd.add("--skip-configure")
    prep_cmd.add("--allow-host-path")
    ctx.actions.run(prep_cmd, category = "bootstrap_prepare", identifier = ctx.attrs.name, allow_cache_upload = True)

    # Build headers + install in one action (make headers then copy)
    installed = ctx.actions.declare_output("installed", dir = True)
    build_cmd = cmd_args(ctx.attrs._build_tool[RunInfo])
    build_cmd.add("--build-dir", prepared)
    build_cmd.add("--output-dir", installed.as_output())
    # Use pre-cmds to run mrproper + headers, then copy
    kernel_arch = ctx.attrs.kernel_arch
    build_cmd.add("--pre-cmd", "make ARCH=" + kernel_arch + " mrproper")
    build_cmd.add("--pre-cmd", "make ARCH=" + kernel_arch + " headers")
    build_cmd.add("--pre-cmd", "find usr/include -type f ! -name '*.h' -delete")
    build_cmd.add(
        "--pre-cmd",
        cmd_args(
            "mkdir -p ",
            installed.as_output(),
            "/usr/include && ",
            "cp -r usr/include/* ",
            installed.as_output(),
            "/usr/include/",
            delimiter = "",
        ),
    )
    # Create stub sys/sdt.h for SystemTap SDT probes
    build_cmd.add(
        "--pre-cmd",
        cmd_args(
            "mkdir -p ",
            installed.as_output(),
            "/usr/include/sys && ",
            "printf '",
            "#ifndef _SYS_SDT_H\\n#define _SYS_SDT_H\\n",
            "#define STAP_PROBE(p,n)\\n",
            "#define STAP_PROBE1(p,n,a1)\\n",
            "#define STAP_PROBE2(p,n,a1,a2)\\n",
            "#define STAP_PROBE3(p,n,a1,a2,a3)\\n",
            "#define DTRACE_PROBE(p,n) STAP_PROBE(p,n)\\n",
            "#define DTRACE_PROBE1(p,n,a1) STAP_PROBE1(p,n,a1)\\n",
            "#define DTRACE_PROBE2(p,n,a1,a2) STAP_PROBE2(p,n,a1,a2)\\n",
            "#endif\\n",
            "' > ",
            installed.as_output(),
            "/usr/include/sys/sdt.h",
            delimiter = "",
        ),
    )
    # All work is done in pre-cmds; skip the make invocation
    build_cmd.add("--skip-make")
    build_cmd.add("--allow-host-path")
    ctx.actions.run(build_cmd, category = "bootstrap_install", identifier = ctx.attrs.name, allow_cache_upload = True)

    return [DefaultInfo(default_output = installed)]

bootstrap_linux_headers = rule(
    impl = _bootstrap_linux_headers_impl,
    attrs = {
        "kernel_arch": attrs.string(default = "x86_64"),
        "source": attrs.dep(),
        "_build_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:build_helper"),
        ),
        "_configure_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:configure_helper"),
        ),
    },
    cfg = strip_toolchain_mode,
)

# ── bootstrap_gcc ────────────────────────────────────────────────────

def _bootstrap_gcc_impl(ctx):
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]
    target_triple = ctx.attrs.target_triple
    is_cross = ctx.attrs.is_cross

    # Phase 1+2: prepare + src_prepare — copy source, symlink math libs,
    # patch Makefile.in, fix obstack.h.  Uses configure_helper with
    # --skip-configure and --pre-cmd to get env sanitisation for free.
    prep_cmd = cmd_args(ctx.attrs._configure_tool[RunInfo])
    prep_cmd.add("--source-dir", source)
    prep_cmd.add("--output-dir", "@WORK@/prepared")
    prep_cmd.add("--skip-configure")

    # Build the pre-cmd chain for src_prepare.  $PROJECT_ROOT is set by
    # configure_helper so artifact paths (relative to project root) resolve.
    #
    # Collect math lib source artifacts — downstream actions (configure,
    # compile, install) need these as hidden inputs because the prepare
    # phase creates symlinks into these artifacts.  Without declaring
    # them, Buck2 won't materialize the targets for downstream actions.
    math_lib_srcs = []
    pre_parts = []
    # Copy math libs into the source tree (GCC configure expects in-tree
    # gmp/, mpfr/, mpc/ directories).  We use cp -a instead of symlinks
    # because symlinks embed absolute paths that break when the action
    # output is restored from remote cache on a different machine.
    if ctx.attrs.gmp_source:
        gmp_src = ctx.attrs.gmp_source[DefaultInfo].default_outputs[0]
        math_lib_srcs.append(gmp_src)
        pre_parts.append(cmd_args("cp -a $PROJECT_ROOT/", gmp_src, " gmp", delimiter = ""))
    if ctx.attrs.mpfr_source:
        mpfr_src = ctx.attrs.mpfr_source[DefaultInfo].default_outputs[0]
        math_lib_srcs.append(mpfr_src)
        pre_parts.append(cmd_args("cp -a $PROJECT_ROOT/", mpfr_src, " mpfr", delimiter = ""))
    if ctx.attrs.mpc_source:
        mpc_src = ctx.attrs.mpc_source[DefaultInfo].default_outputs[0]
        math_lib_srcs.append(mpc_src)
        pre_parts.append(cmd_args("cp -a $PROJECT_ROOT/", mpc_src, " mpc", delimiter = ""))

    # For pass1 (C only, no libc): remove libcody and c++tools
    if not ctx.attrs.with_headers:
        pre_parts.append(
            "sed -i 's|libcody ||g' Makefile.in && "
            + "sed -i 's|c++tools ||g' Makefile.in && "
            + "sed -i '/: all-libcody$/d' Makefile.in && "
            + "sed -i '/: all-stage.*-libcody$/d' Makefile.in && "
            + "sed -i 's/ all-libcody / /g' Makefile.in && "
            + "sed -i 's/ all-libcody$//g' Makefile.in && "
            + "sed -i 's/ maybe-all-libcody / /g' Makefile.in && "
            + "sed -i 's/ maybe-all-libcody$//g' Makefile.in && "
            + "sed -i '/: configure-libcody$/d' Makefile.in && "
            + "sed -i '/: maybe-configure-libcody$/d' Makefile.in && "
            + "rm -rf libcody c++tools",
        )

    # For pass2: fix gthr-posix.h path
    if ctx.attrs.with_headers:
        pre_parts.append(
            "sed '/thread_header =/s/@.*@/gthr-posix.h/' " + "-i libgcc/Makefile.in libstdc++-v3/include/Makefile.in 2>/dev/null || true",
        )

    # GCC 14's libiberty/obstack.c expects the struct layout from GCC's
    # bundled include/obstack.h, but the host compiler picks up the system
    # header first.  glibc >=2.41 changed the obstack struct which breaks
    # compilation.  Copy the bundled header into libiberty/ so it's found
    # via -I$(srcdir) before the system header.
    pre_parts.append("cp include/obstack.h libiberty/obstack.h")

    for part in pre_parts:
        prep_cmd.add("--pre-cmd", part)
    prep_cmd.add("--allow-host-path")

    # Phase 3: configure — Python helper handles sysroot assembly and
    # runs ../configure from an out-of-tree build dir.
    conf_cmd = cmd_args(ctx.attrs._gcc_configure_tool[RunInfo])
    conf_cmd.add("--source-dir", "@WORK@/prepared")
    conf_cmd.add("--output-dir", "@WORK@/configured")
    if math_lib_srcs:
        conf_cmd.add(cmd_args(hidden = math_lib_srcs))
    conf_cmd.add("--target-triple", target_triple)
    if ctx.attrs.libc_headers:
        conf_cmd.add("--headers-dir", ctx.attrs.libc_headers[DefaultInfo].default_outputs[0])
    if ctx.attrs.libc_dep:
        conf_cmd.add("--libc-dir", ctx.attrs.libc_dep[DefaultInfo].default_outputs[0])
    if ctx.attrs.binutils:
        conf_cmd.add("--binutils-dir", ctx.attrs.binutils[DefaultInfo].default_outputs[0])
    if ctx.attrs.with_headers:
        conf_cmd.add("--with-headers")
    conf_cmd.add("--languages", ctx.attrs.languages)

    # Build configure args
    configure_args = ["--prefix=/tools"]
    if is_cross:
        configure_args.append("--target=" + target_triple)
    if ctx.attrs.with_headers and ctx.attrs.libc_dep:
        configure_args.extend(["--with-sysroot", "--with-native-system-header-dir=/usr/include"])
    elif not ctx.attrs.with_headers:
        configure_args.extend(["--with-sysroot=/tools", "--with-newlib", "--without-headers"])
    configure_args.extend([
        "--enable-languages=" + ctx.attrs.languages,
        "--disable-multilib",
        "--disable-bootstrap",
    ])

    if not ctx.attrs.with_headers:
        configure_args.extend([
            "--disable-nls",
            "--disable-shared",
            "--disable-threads",
            "--disable-libatomic",
            "--disable-libgomp",
            "--disable-libquadmath",
            "--disable-libssp",
            "--disable-libvtv",
            "--disable-libstdcxx",
            "--disable-c++tools",
            "--disable-decimal-float",
            "--disable-libgcov",
            "--disable-fixincludes",
        ])
    else:
        configure_args.extend([
            "--enable-default-pie",
            "--enable-default-ssp",
            "--disable-nls",
            "--disable-libatomic",
            "--disable-libgomp",
            "--disable-libquadmath",
            "--disable-libsanitizer",
            "--disable-libssp",
            "--disable-libvtv",
            "--enable-libstdcxx",
            "--disable-libstdcxx-sdt",
            "--disable-c++tools",
            "--disable-cet",
            "--disable-systemtap",
        ])
        if is_cross:
            configure_args.append("--with-system-zlib")

    for arg in ctx.attrs.extra_configure_args:
        configure_args.append(arg)

    configure_args.append("MAKEINFO=true")
    for arg in configure_args:
        conf_cmd.add(cmd_args("--configure-arg=", arg, delimiter = ""))

    env = _toolchain_env(ctx)
    _env_args(conf_cmd, env)
    conf_cmd.add("--allow-host-path")

    # Phase 4: compile — use build_helper for timestamp management, env
    # sanitisation, and path resolution.  Custom make targets via --pre-cmd
    # with --skip-make since GCC's build sequence is non-standard.
    build_cmd = cmd_args(ctx.attrs._build_tool[RunInfo])
    build_cmd.add("--build-dir", "@WORK@/configured")
    build_cmd.add("--output-dir", "@WORK@/built")
    build_cmd.add("--skip-make")
    if math_lib_srcs:
        build_cmd.add(cmd_args(hidden = math_lib_srcs))

    # Cross-binutils must be on PATH for libgcc's ar/ranlib steps
    if ctx.attrs.binutils:
        _bdir = ctx.attrs.binutils[DefaultInfo].default_outputs[0]
        build_cmd.add("--path-prepend", cmd_args(_bdir, "/tools/bin", delimiter = ""))
    # For Canadian cross: stage tools must be on PATH
    if ctx.attrs.prev_stage and BootstrapStageInfo in ctx.attrs.prev_stage:
        _stage_out = ctx.attrs.prev_stage[DefaultInfo].default_outputs[0]
        build_cmd.add("--path-prepend", cmd_args(_stage_out, "/tools/bin", delimiter = ""))

    _env_args(build_cmd, _toolchain_env(ctx))
    build_cmd.add("--allow-host-path")

    # Ensure makeinfo stub is on PATH for GMP/MPFR sub-configures
    _mi = 'command -v makeinfo >/dev/null 2>&1 || { mkdir -p .stub-bin && printf "#!/bin/sh\\nexit 0\\n" > .stub-bin/makeinfo && chmod +x .stub-bin/makeinfo && export PATH="$PWD/.stub-bin:$PATH"; } && '
    # Suppress autotools regeneration — build_helper resets timestamps
    # which makes make think aclocal.m4 etc. are stale in GMP/MPFR.
    _at = "ACLOCAL=true AUTOMAKE=true AUTOCONF=true AUTOHEADER=true MAKEINFO=true "

    if not ctx.attrs.with_headers:
        # Pass1: build just gcc and minimal libgcc
        build_cmd.add(
            "--pre-cmd",
            _mi
            + "cd build && make "
            + _at
            + "-j$(nproc) all-gcc && "
            + "make "
            + _at
            + "configure-target-libgcc && "
            + "cd "
            + target_triple
            + "/libgcc && "
            + "make -j$(nproc) libgcc.a INHIBIT_LIBC_CFLAGS='-Dinhibit_libc' && "
            + "{ make -j$(nproc) crtbegin.o crtend.o crtbeginS.o crtendS.o crtbeginT.o 2>/dev/null || true; }",
        )
    else:
        # Pass2: full build
        build_cmd.add(
            "--pre-cmd",
            _mi
            + "cd build && "
            + "make "
            + _at
            + "-j$(nproc) all-gcc && "
            + "make "
            + _at
            + "-j$(nproc) all-target-libgcc && "
            + "make "
            + _at
            + "-j$(nproc) all-target-libstdc++-v3",
        )

    # Phase 5: install — use install_helper for timestamp management and
    # env sanitisation.  Custom targets via --make-target, post-install
    # steps via --post-cmd.
    inst_cmd = cmd_args(ctx.attrs._install_tool[RunInfo])
    inst_cmd.add("--build-dir", "@WORK@/built")
    inst_cmd.add("--build-subdir", "build")
    inst_cmd.add("--prefix", "@OUT@")
    # Serialize the install make (-j1, last -j wins over install_helper's
    # -j{cpu}).  gcc's `make install` relinks xgcc and recompiles libstdc++
    # explicit-instantiation objects; with parallel jobs, one job rewrites
    # xgcc while others exec it -> "xgcc: Permission denied" (EACCES
    # write-while-exec race).  Serial install makes the race impossible.
    inst_cmd.add("--make-arg=-j1")
    if math_lib_srcs:
        inst_cmd.add(cmd_args(hidden = math_lib_srcs))

    if ctx.attrs.binutils:
        _bdir2 = ctx.attrs.binutils[DefaultInfo].default_outputs[0]
        inst_cmd.add("--path-prepend", cmd_args(_bdir2, "/tools/bin", delimiter = ""))
    if ctx.attrs.prev_stage and BootstrapStageInfo in ctx.attrs.prev_stage:
        _stage_out2 = ctx.attrs.prev_stage[DefaultInfo].default_outputs[0]
        inst_cmd.add("--path-prepend", cmd_args(_stage_out2, "/tools/bin", delimiter = ""))

    _env_args(inst_cmd, _toolchain_env(ctx))
    inst_cmd.add("--allow-host-path")

    if not ctx.attrs.with_headers:
        # Pass1: install gcc + manually copy libgcc.a and CRT objects
        inst_cmd.add("--make-target", "install-gcc")
        inst_cmd.add(
            "--post-cmd",
            "GCC_VERSION=$(cat $BUILD_DIR/gcc/BASE-VER 2>/dev/null || echo '14.3.0') && "
            + "LIBGCC_DIR=$DESTDIR/tools/lib/gcc/"
            + target_triple
            + "/$GCC_VERSION && "
            + "mkdir -p $LIBGCC_DIR && "
            + "cp $BUILD_DIR/"
            + target_triple
            + "/libgcc/libgcc.a $LIBGCC_DIR/ && "
            + "for crt in crtbegin.o crtend.o crtbeginS.o crtendS.o crtbeginT.o; do "
            + "[ -f $BUILD_DIR/"
            + target_triple
            + "/libgcc/$crt ] && "
            + "cp $BUILD_DIR/"
            + target_triple
            + "/libgcc/$crt $LIBGCC_DIR/; "
            + "done; true",
        )
    else:
        # Pass2: full install with sysroot
        inst_cmd.add("--make-target", "install-gcc")
        inst_cmd.add("--make-target", "install-target-libgcc")
        inst_cmd.add("--make-target", "install-target-libstdc++-v3")

        # Copy binutils tools into the gcc install tree
        if ctx.attrs.binutils:
            _bdir3 = ctx.attrs.binutils[DefaultInfo].default_outputs[0]
            inst_cmd.add(
                "--post-cmd",
                cmd_args(
                    "cp -a $PROJECT_ROOT/",
                    _bdir3,
                    "/tools/bin/* $DESTDIR/tools/bin/ 2>/dev/null || true && ",
                    "cp -an $PROJECT_ROOT/",
                    _bdir3,
                    "/tools/",
                    target_triple,
                    "/* ",
                    "$DESTDIR/tools/",
                    target_triple,
                    "/ 2>/dev/null || true",
                    delimiter = "",
                ),
            )

        # Create symlinks and sysroot
        if ctx.attrs.libc_dep:
            libc_dir2 = ctx.attrs.libc_dep[DefaultInfo].default_outputs[0]
            inst_cmd.add(
                "--post-cmd",
                "cd $DESTDIR/tools/bin && "
                + "ln -sfv "
                + target_triple
                + "-gcc gcc && "
                + "ln -sfv "
                + target_triple
                + "-gcc cc && "
                + "ln -sfv "
                + target_triple
                + "-gcc "
                + target_triple
                + "-cc && "
                + "ln -sfv "
                + target_triple
                + "-g++ g++ && "
                + "ln -sfv "
                + target_triple
                + "-g++ c++ && "
                + "ln -sfv "
                + target_triple
                + "-cpp cpp",
            )
            sysroot_cmd = cmd_args(
                "mkdir -p $DESTDIR/tools/",
                target_triple,
                "/sys-root && ",
                "cp -a $PROJECT_ROOT/",
                libc_dir2,
                "/* $DESTDIR/tools/",
                target_triple,
                "/sys-root/",
                delimiter = "",
            )
            if ctx.attrs.libc_headers:
                headers_dir2 = ctx.attrs.libc_headers[DefaultInfo].default_outputs[0]
                sysroot_cmd = cmd_args(
                    "mkdir -p $DESTDIR/tools/",
                    target_triple,
                    "/sys-root && ",
                    "cp -a $PROJECT_ROOT/",
                    libc_dir2,
                    "/* $DESTDIR/tools/",
                    target_triple,
                    "/sys-root/ && ",
                    "cp -a $PROJECT_ROOT/",
                    headers_dir2,
                    "/* $DESTDIR/tools/",
                    target_triple,
                    "/sys-root/",
                    delimiter = "",
                )
            inst_cmd.add("--post-cmd", sysroot_cmd)

    installed = _bootstrap_phases_action(
        ctx,
        "bootstrap_gcc",
        [prep_cmd, conf_cmd, build_cmd, inst_cmd],
        extra_hidden = math_lib_srcs,
    )

    # Return BootstrapStageInfo if this is a final stage compiler
    providers = [DefaultInfo(default_output = installed)]
    if ctx.attrs.with_headers and ctx.attrs.libc_dep:
        providers.append(
            BootstrapStageInfo(
                stage = ctx.attrs.stage_number,
                cc = installed.project("tools/bin/" + target_triple + "-gcc"),
                cxx = installed.project("tools/bin/" + target_triple + "-g++"),
                ar = installed.project("tools/bin/" + target_triple + "-ar") if ctx.attrs.binutils else installed.project("tools/bin/ar"),
                sysroot = installed.project("tools/" + target_triple + "/sys-root"),
                gcc_lib_dir = installed.project("tools/" + target_triple + "/" + ctx.attrs.lib_dir),
                target_triple = target_triple,
                python = None,
                python_version = None,
            )
        )

    return providers

bootstrap_gcc = rule(
    impl = _bootstrap_gcc_impl,
    attrs = {
        "binutils": attrs.option(attrs.dep(), default = None),
        "extra_configure_args": attrs.list(attrs.string(), default = []),
        "gmp_source": attrs.option(attrs.dep(), default = None),
        "host_ar": attrs.option(attrs.string(), default = None),
        "host_cc": attrs.option(attrs.string(), default = None),
        "host_cxx": attrs.option(attrs.string(), default = None),
        "is_cross": attrs.bool(default = True),
        "languages": attrs.string(default = "c"),
        "lib_dir": attrs.string(default = "lib64"),
        "libc_dep": attrs.option(attrs.dep(), default = None),
        "libc_headers": attrs.option(attrs.dep(), default = None),
        "mpc_source": attrs.option(attrs.dep(), default = None),
        "mpfr_source": attrs.option(attrs.dep(), default = None),
        "prev_stage": attrs.option(attrs.dep(), default = None),
        "source": attrs.dep(),
        "stage_number": attrs.int(default = 1),
        "target_triple": attrs.string(default = TARGET_TRIPLE),
        "with_headers": attrs.bool(default = False),
        "_build_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:build_helper"),
        ),
        "_configure_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:configure_helper"),
        ),
        "_gcc_configure_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:bootstrap_gcc_configure"),
        ),
        "_install_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:install_helper"),
        ),
    },
    cfg = strip_toolchain_mode,
)

# ── bootstrap_glibc ──────────────────────────────────────────────────

def _bootstrap_glibc_impl(ctx):
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]
    target_triple = ctx.attrs.target_triple
    compiler_dir = ctx.attrs.compiler[DefaultInfo].default_outputs[0]
    headers_dir = ctx.attrs.linux_headers[DefaultInfo].default_outputs[0]
    binutils_dir = ctx.attrs.binutils[DefaultInfo].default_outputs[0] if ctx.attrs.binutils else None

    # Phase 1+2: prepare — copy source + patch .eh_frame section attributes.
    # gcc-pass1 generates .eh_frame,"aw" (writable) but glibc's hand-written
    # assembly in libc_sigaction.c uses .eh_frame,"a" (read-only).  Patch to
    # match the compiler output so the assembler doesn't reject the mismatch.
    prep_cmd = cmd_args(ctx.attrs._configure_tool[RunInfo])
    prep_cmd.add("--source-dir", source)
    prep_cmd.add("--output-dir", "@WORK@/prepared")
    prep_cmd.add("--skip-configure")
    prep_cmd.add(
        "--pre-cmd",
        "find . -name 'libc_sigaction.c' " + '-exec sed -i \'s/eh_frame,\\\\"a\\\\"/eh_frame,\\\\"aw\\\\"/g\' {} +',
    )
    prep_cmd.add("--allow-host-path")

    # Phase 3: configure — Python helper handles cross-tool discovery
    # and runs ../configure from an out-of-tree build dir.
    conf_cmd = cmd_args(ctx.attrs._glibc_configure_tool[RunInfo])
    conf_cmd.add("--source-dir", "@WORK@/prepared")
    conf_cmd.add("--output-dir", "@WORK@/configured")
    conf_cmd.add("--target-triple", target_triple)
    conf_cmd.add("--compiler-dir", compiler_dir)
    conf_cmd.add("--headers-dir", headers_dir)
    if binutils_dir:
        conf_cmd.add("--binutils-dir", binutils_dir)
    conf_cmd.add("--lib-dir", ctx.attrs.lib_dir)
    conf_cmd.add("--dynamic-linker", ctx.attrs.dynamic_linker)
    for arg in ctx.attrs.extra_configure_args:
        conf_cmd.add(cmd_args("--configure-arg=", arg, delimiter = ""))
    conf_cmd.add("--allow-host-path")

    # Phase 4: compile — use build_helper for timestamp management.
    # Standard make -j$(nproc) in build subdir, just needs cross-tool PATH.
    # headers_dir is a hidden dep because configure bakes its absolute path
    # into the Makefile — buck2 must materialise it before make runs.
    build_cmd = cmd_args(ctx.attrs._build_tool[RunInfo])
    build_cmd.add("--build-dir", "@WORK@/configured")
    build_cmd.add("--output-dir", "@WORK@/built")
    build_cmd.add("--build-subdir", "build")
    build_cmd.add("--path-prepend", cmd_args(compiler_dir, "/tools/bin", delimiter = ""))
    if binutils_dir:
        build_cmd.add("--path-prepend", cmd_args(binutils_dir, "/tools/bin", delimiter = ""))
    build_cmd.add(cmd_args(hidden = [headers_dir]))
    build_cmd.add("--allow-host-path")

    # Phase 5: install — use install_helper with post-cmds for linker
    # script fixups and /lib64 symlink creation.
    inst_cmd = cmd_args(ctx.attrs._install_tool[RunInfo])
    inst_cmd.add("--build-dir", "@WORK@/built")
    inst_cmd.add("--build-subdir", "build")
    inst_cmd.add("--prefix", "@OUT@")
    inst_cmd.add("--path-prepend", cmd_args(compiler_dir, "/tools/bin", delimiter = ""))
    if binutils_dir:
        inst_cmd.add("--path-prepend", cmd_args(binutils_dir, "/tools/bin", delimiter = ""))

    # glibc's `make install` can otherwise re-run configure/config.status
    # (its parallel build is racy and can clobber config.status), which then
    # fails ("GNU ld missing"/"No rule to make config.status").  The build is
    # already done, so tell make to treat the autotools config files as old
    # and never remake them during install.
    for _old in ("config.status", "config.make", "Makefile", "configure"):
        inst_cmd.add("--make-arg=-o")
        inst_cmd.add(cmd_args("--make-arg=", _old, delimiter = ""))

    # Fix glibc linker scripts to use relative paths
    inst_cmd.add(
        "--post-cmd",
        "for script in $DESTDIR/usr/lib*/libc.so $DESTDIR/usr/lib*/libpthread.so $DESTDIR/usr/lib*/libm.so; do "
        + 'if [ -f "$script" ] && file "$script" | grep -q ASCII; then '
        + "sed -i -e 's|/usr/lib64/||g' -e 's|/usr/lib/||g' -e 's|/lib64/||g' -e 's|/lib/||g' \"$script\"; "
        + "fi; done",
    )
    # Create dynamic linker symlink
    lib_dir = ctx.attrs.lib_dir
    dynamic_linker = ctx.attrs.dynamic_linker
    inst_cmd.add(
        "--post-cmd",
        "mkdir -p $DESTDIR/" + lib_dir + " && " + "ln -sfv ../usr/" + lib_dir + "/" + dynamic_linker + " $DESTDIR/" + lib_dir + "/" + dynamic_linker,
    )
    inst_cmd.add("--allow-host-path")

    installed = _bootstrap_phases_action(
        ctx,
        "bootstrap_glibc",
        [prep_cmd, conf_cmd, build_cmd, inst_cmd],
        extra_hidden = [headers_dir],
    )
    return [DefaultInfo(default_output = installed)]

bootstrap_glibc = rule(
    impl = _bootstrap_glibc_impl,
    attrs = {
        "binutils": attrs.option(attrs.dep(), default = None),
        "compiler": attrs.dep(),
        "dynamic_linker": attrs.string(default = "ld-linux-x86-64.so.2"),
        "extra_configure_args": attrs.list(attrs.string(), default = []),
        "lib_dir": attrs.string(default = "lib64"),
        "linux_headers": attrs.dep(),
        "source": attrs.dep(),
        "target_triple": attrs.string(default = TARGET_TRIPLE),
        "_build_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:build_helper"),
        ),
        "_configure_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:configure_helper"),
        ),
        "_glibc_configure_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:bootstrap_glibc_configure"),
        ),
        "_install_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:install_helper"),
        ),
    },
    cfg = strip_toolchain_mode,
)

# ── bootstrap_package ────────────────────────────────────────────────

def _bootstrap_package_impl(ctx):
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]
    stage = ctx.attrs.stage[BootstrapStageInfo]

    # Phase 1-2: prepare
    prepared = ctx.actions.declare_output("prepared", dir = True)
    prep_cmd = cmd_args(ctx.attrs._configure_tool[RunInfo])
    prep_cmd.add("--source-dir", source)
    prep_cmd.add("--output-dir", prepared.as_output())
    prep_cmd.add("--skip-configure")
    prep_cmd.add("--allow-host-path")
    ctx.actions.run(prep_cmd, category = "bootstrap_prepare", identifier = ctx.attrs.name, allow_cache_upload = True)

    # Build environment from stage info
    sysroot_flag = cmd_args("--sysroot=", stage.sysroot, delimiter = "")
    env = {}
    env["CC"] = cmd_args(stage.cc, sysroot_flag, delimiter = " ")
    env["CXX"] = cmd_args(stage.cxx, sysroot_flag, delimiter = " ")
    env["AR"] = stage.ar

    # Stage tools bin directory — prepended to PATH so configure/make find
    # cross-tools (strip, ranlib, etc.) alongside the compiler
    stage_output = ctx.attrs.stage[DefaultInfo].default_outputs[0]
    tools_bin = stage_output.project("tools/bin")

    # Phase 3: configure
    configured = ctx.actions.declare_output("configured", dir = True)
    conf_cmd = cmd_args(ctx.attrs._configure_tool[RunInfo])
    conf_cmd.add("--source-dir", prepared)
    conf_cmd.add("--output-dir", configured.as_output())
    if ctx.attrs.build_subdir:
        conf_cmd.add("--build-subdir", ctx.attrs.build_subdir)

    if ctx.attrs.skip_configure:
        conf_cmd.add("--skip-configure")
    else:
        for arg in ctx.attrs.configure_args:
            conf_cmd.add(cmd_args("--configure-arg=", arg, delimiter = ""))
    _env_args(conf_cmd, env)
    conf_cmd.add("--path-prepend", tools_bin)
    for e in ctx.attrs.extra_env:
        conf_cmd.add("--env", e)
    conf_cmd.add("--allow-host-path")
    ctx.actions.run(conf_cmd, category = "bootstrap_configure", identifier = ctx.attrs.name, allow_cache_upload = True)

    # Phase 4: compile (copy whole configured tree, use build-subdir if set)
    built = ctx.actions.declare_output("built", dir = True)
    build_cmd = cmd_args(ctx.attrs._build_tool[RunInfo])
    build_cmd.add("--build-dir", configured)
    build_cmd.add("--output-dir", built.as_output())
    if ctx.attrs.build_subdir:
        build_cmd.add("--build-subdir", ctx.attrs.build_subdir)
    for arg in ctx.attrs.make_args:
        build_cmd.add("--make-arg", arg)
    # For non-autotools packages (e.g. bzip2) that hardcode CC in their
    # Makefile, pass CC/CXX/AR/RANLIB as make command-line overrides
    if ctx.attrs.cc_as_make_arg:
        stage_ranlib = stage_output.project("tools/bin/" + stage.target_triple + "-ranlib")
        build_cmd.add("--make-arg", cmd_args("CC=", env["CC"], delimiter = ""))
        build_cmd.add("--make-arg", cmd_args("AR=", env["AR"], delimiter = ""))
        build_cmd.add("--make-arg", cmd_args("RANLIB=", stage_ranlib, delimiter = ""))
    _env_args(build_cmd, env)
    build_cmd.add("--path-prepend", tools_bin)
    for e in ctx.attrs.extra_env:
        build_cmd.add("--env", e)
    build_cmd.add("--allow-host-path")
    ctx.actions.run(build_cmd, category = "bootstrap_compile", identifier = ctx.attrs.name, allow_cache_upload = True)

    # Phase 5: install (use built dir which has compiled objects)
    installed = ctx.actions.declare_output("installed", dir = True)
    inst_cmd = cmd_args(ctx.attrs._install_tool[RunInfo])
    inst_cmd.add("--build-dir", built)
    if ctx.attrs.build_subdir:
        inst_cmd.add("--build-subdir", ctx.attrs.build_subdir)
    inst_cmd.add("--prefix", installed.as_output())
    if ctx.attrs.destdir_var != "DESTDIR":
        inst_cmd.add("--destdir-var", ctx.attrs.destdir_var)
    for arg in ctx.attrs.make_args:
        inst_cmd.add("--make-arg", arg)
    if ctx.attrs.cc_as_make_arg:
        stage_ranlib2 = stage_output.project("tools/bin/" + stage.target_triple + "-ranlib")
        inst_cmd.add("--make-arg", cmd_args("CC=", env["CC"], delimiter = ""))
        inst_cmd.add("--make-arg", cmd_args("AR=", env["AR"], delimiter = ""))
        inst_cmd.add("--make-arg", cmd_args("RANLIB=", stage_ranlib2, delimiter = ""))
    _env_args(inst_cmd, env)
    inst_cmd.add("--path-prepend", tools_bin)
    for e in ctx.attrs.extra_env:
        inst_cmd.add("--env", e)
    inst_cmd.add("--allow-host-path")
    ctx.actions.run(inst_cmd, category = "bootstrap_install", identifier = ctx.attrs.name, allow_cache_upload = True)

    pkg_info = PackageInfo(
        name = ctx.attrs.name,
        version = ctx.attrs.version,
        prefix = installed,
        libraries = ctx.attrs.libraries,
        cflags = [],
        ldflags = [],
        compile_info = None,
        link_info = None,
        path_info = None,
        runtime_deps = None,
        license = ctx.attrs.license,
        src_uri = ctx.attrs.src_uri,
        src_sha256 = ctx.attrs.src_sha256,
        homepage = ctx.attrs.homepage,
        supplier = "Organization: BuckOS",
        description = ctx.attrs.description,
        cpe = None,
    )

    return [DefaultInfo(default_output = installed), pkg_info]

bootstrap_package = rule(
    impl = _bootstrap_package_impl,
    attrs = {
        "build_subdir": attrs.option(attrs.string(), default = None),
        "cc_as_make_arg": attrs.bool(default = False),
        "configure_args": attrs.list(attrs.string(), default = []),
        "description": attrs.string(default = ""),
        "destdir_var": attrs.string(default = "DESTDIR"),
        "extra_env": attrs.list(attrs.string(), default = []),
        "homepage": attrs.option(attrs.string(), default = None),
        "libraries": attrs.list(attrs.string(), default = []),
        "license": attrs.string(default = "UNKNOWN"),
        "make_args": attrs.list(attrs.string(), default = []),
        "skip_configure": attrs.bool(default = False),
        "source": attrs.dep(),
        "src_sha256": attrs.string(default = ""),
        "src_uri": attrs.string(default = ""),
        "stage": attrs.dep(providers = [BootstrapStageInfo]),
        "version": attrs.string(default = ""),
        "_build_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:build_helper"),
        ),
        "_configure_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:configure_helper"),
        ),
        "_install_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:install_helper"),
        ),
    },
)

# ── bootstrap_python ─────────────────────────────────────────────────
# Python requires special handling: it needs deps (zlib, libffi, expat)
# merged into a sysroot, and configure cache variables to bypass tests
# that fail during cross-compilation.

def _bootstrap_python_impl(ctx):
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]
    stage = ctx.attrs.stage[BootstrapStageInfo]
    stage_output = ctx.attrs.stage[DefaultInfo].default_outputs[0]

    # Collect dependency prefixes for merged sysroot
    dep_dirs = []
    for dep in ctx.attrs.deps:
        dep_dirs.append(dep[DefaultInfo].default_outputs[0])

    # Phase 1: prepare — copy source (uses configure_helper --skip-configure)
    prep_cmd = cmd_args(ctx.attrs._configure_tool[RunInfo])
    prep_cmd.add("--source-dir", source)
    prep_cmd.add("--output-dir", "@WORK@/prepared")
    prep_cmd.add("--skip-configure")
    prep_cmd.add("--allow-host-path")

    # Phase 2: configure — Python helper merges deps into build sysroot
    # and runs ../configure with cross-compilation cache variables.
    conf_cmd = cmd_args(ctx.attrs._python_configure_tool[RunInfo])
    conf_cmd.add("--source-dir", "@WORK@/prepared")
    conf_cmd.add("--output-dir", "@WORK@/configured")
    conf_cmd.add("--stage-dir", stage_output)
    conf_cmd.add("--sysroot", stage.sysroot)
    conf_cmd.add("--cc", stage.cc)
    conf_cmd.add("--cxx", stage.cxx)
    conf_cmd.add("--ar", stage.ar)
    for dep_dir in dep_dirs:
        conf_cmd.add("--dep-dir", dep_dir)
    for arg in ctx.attrs.configure_args:
        conf_cmd.add(cmd_args("--configure-arg=", arg, delimiter = ""))
    # Phase 3: compile — use build_helper for timestamp management.
    build_cmd = cmd_args(ctx.attrs._build_tool[RunInfo])
    build_cmd.add("--build-dir", "@WORK@/configured")
    build_cmd.add("--output-dir", "@WORK@/built")
    build_cmd.add("--build-subdir", "build")
    build_cmd.add("--path-prepend", cmd_args(stage_output, "/tools/bin", delimiter = ""))
    build_cmd.add("--allow-host-path")

    # Phase 4: install — use install_helper with post-cmd for ensurepip.
    inst_cmd = cmd_args(ctx.attrs._install_tool[RunInfo])
    inst_cmd.add("--build-dir", "@WORK@/built")
    inst_cmd.add("--build-subdir", "build")
    inst_cmd.add("--prefix", "@OUT@")
    inst_cmd.add("--path-prepend", cmd_args(stage_output, "/tools/bin", delimiter = ""))

    # Ensure pip is installed
    inst_cmd.add(
        "--post-cmd",
        "if [ ! -f $DESTDIR/usr/bin/pip3 ]; then " + "  $DESTDIR/usr/bin/python3 -m ensurepip --upgrade 2>/dev/null || true; " + "fi",
    )
    inst_cmd.add("--allow-host-path")

    installed = _bootstrap_phases_action(
        ctx,
        "bootstrap_python",
        [prep_cmd, conf_cmd, build_cmd, inst_cmd],
        extra_hidden = dep_dirs + [stage_output],
    )
    return [DefaultInfo(default_output = installed)]

bootstrap_python = rule(
    impl = _bootstrap_python_impl,
    attrs = {
        "configure_args": attrs.list(attrs.string(), default = []),
        "deps": attrs.list(attrs.dep(), default = []),
        "description": attrs.string(default = ""),
        "license": attrs.string(default = "UNKNOWN"),
        "source": attrs.dep(),
        "stage": attrs.dep(providers = [BootstrapStageInfo]),
        "version": attrs.string(default = ""),
        "_build_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:build_helper"),
        ),
        "_configure_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:configure_helper"),
        ),
        "_install_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:install_helper"),
        ),
        "_python_configure_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:bootstrap_python_configure"),
        ),
    },
)
