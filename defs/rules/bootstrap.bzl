"""
Bootstrap toolchain rules for building a self-hosted GCC/glibc toolchain.

Five rules following autotools_package's 5-phase pattern with explicit
toolchain injection via --env flags to Python helpers:

  bootstrap_binutils      — cross-binutils for target triple
  bootstrap_linux_headers — kernel headers via make headers_install
  bootstrap_gcc           — GCC (cross or native, multi-pass)
  bootstrap_glibc         — glibc built with cross-gcc
  bootstrap_package       — generic autotools using BootstrapStageInfo
"""

load("//defs:providers.bzl", "BootstrapStageInfo", "PackageInfo")

TARGET_TRIPLE = "x86_64-buckos-linux-gnu"

# ── Shared helpers ───────────────────────────────────────────────────

def _env_args(cmd, env_dict):
    """Append --env KEY=VALUE flags to a cmd_args."""
    for k, v in env_dict.items():
        cmd.add("--env", cmd_args(k, "=", v, delimiter = ""))

def _toolchain_env(ctx):
    """Build environment dict from BootstrapStageInfo or host_cc attrs."""
    env = {}
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

def _bootstrap_binutils_impl(ctx):
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]
    target_triple = ctx.attrs.target_triple

    # Phase 1-2: prepare (copy source)
    prepared = ctx.actions.declare_output("prepared", dir = True)
    prep_cmd = cmd_args(ctx.attrs._configure_tool[RunInfo])
    prep_cmd.add("--source-dir", source)
    prep_cmd.add("--output-dir", prepared.as_output())
    prep_cmd.add("--skip-configure")
    ctx.actions.run(prep_cmd, category = "prepare", identifier = ctx.attrs.name)

    # Phase 3: configure
    configured = ctx.actions.declare_output("configured", dir = True)
    conf_cmd = cmd_args(ctx.attrs._configure_tool[RunInfo])
    conf_cmd.add("--source-dir", prepared)
    conf_cmd.add("--output-dir", configured.as_output())
    conf_cmd.add("--build-subdir", "build")
    for arg in [
        "--target=" + target_triple,
        "--prefix=/tools",
        "--with-sysroot=/tools",
        "--disable-nls",
        "--disable-werror",
        "--disable-gdb",
        "--disable-gdbserver",
        "--disable-sim",
        "--disable-libdecnumber",
        "--disable-readline",
        "--enable-gprofng=no",
        "--enable-default-hash-style=gnu",
    ]:
        conf_cmd.add(cmd_args("--configure-arg=", arg, delimiter = ""))
    for arg in ctx.attrs.extra_configure_args:
        conf_cmd.add(cmd_args("--configure-arg=", arg, delimiter = ""))
    env = _toolchain_env(ctx)
    _env_args(conf_cmd, env)
    ctx.actions.run(conf_cmd, category = "configure", identifier = ctx.attrs.name)

    # Phase 4: compile (copy whole configured tree; make runs in build subdir)
    built = ctx.actions.declare_output("built", dir = True)
    build_cmd = cmd_args(ctx.attrs._build_tool[RunInfo])
    build_cmd.add("--build-dir", configured)
    build_cmd.add("--output-dir", built.as_output())
    build_cmd.add("--build-subdir", "build")
    build_cmd.add("--make-arg", "MAKEINFO=true")
    _env_args(build_cmd, env)
    ctx.actions.run(build_cmd, category = "compile", identifier = ctx.attrs.name)

    # Phase 5: install (run from built tree's build subdir)
    installed = ctx.actions.declare_output("installed", dir = True)
    inst_cmd = cmd_args(ctx.attrs._install_tool[RunInfo])
    inst_cmd.add("--build-dir", built)
    inst_cmd.add("--build-subdir", "build")
    inst_cmd.add("--prefix", installed.as_output())
    inst_cmd.add("--make-arg", "MAKEINFO=true")
    _env_args(inst_cmd, env)
    ctx.actions.run(inst_cmd, category = "install", identifier = ctx.attrs.name)

    return [DefaultInfo(default_output = installed)]

bootstrap_binutils = rule(
    impl = _bootstrap_binutils_impl,
    attrs = {
        "source": attrs.dep(),
        "target_triple": attrs.string(default = TARGET_TRIPLE),
        "host_cc": attrs.option(attrs.string(), default = None),
        "host_cxx": attrs.option(attrs.string(), default = None),
        "host_ar": attrs.option(attrs.string(), default = None),
        "extra_configure_args": attrs.list(attrs.string(), default = []),
        "_configure_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:configure_helper"),
        ),
        "_build_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:build_helper"),
        ),
        "_install_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:install_helper"),
        ),
    },
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
    ctx.actions.run(prep_cmd, category = "prepare", identifier = ctx.attrs.name)

    # Build headers + install in one action (make headers then copy)
    installed = ctx.actions.declare_output("installed", dir = True)
    build_cmd = cmd_args(ctx.attrs._build_tool[RunInfo])
    build_cmd.add("--build-dir", prepared)
    build_cmd.add("--output-dir", installed.as_output())
    # Use pre-cmds to run mrproper + headers, then copy
    build_cmd.add("--pre-cmd", "make ARCH=x86_64 mrproper")
    build_cmd.add("--pre-cmd", "make ARCH=x86_64 headers")
    build_cmd.add("--pre-cmd", "find usr/include -type f ! -name '*.h' -delete")
    build_cmd.add("--pre-cmd", cmd_args(
        "mkdir -p ", installed.as_output(), "/usr/include && ",
        "cp -r usr/include/* ", installed.as_output(), "/usr/include/",
        delimiter = "",
    ))
    # Create stub sys/sdt.h for SystemTap SDT probes
    build_cmd.add("--pre-cmd", cmd_args(
        "mkdir -p ", installed.as_output(), "/usr/include/sys && ",
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
        "' > ", installed.as_output(), "/usr/include/sys/sdt.h",
        delimiter = "",
    ))
    # All work is done in pre-cmds; skip the make invocation
    build_cmd.add("--skip-make")
    ctx.actions.run(build_cmd, category = "install", identifier = ctx.attrs.name)

    return [DefaultInfo(default_output = installed)]

bootstrap_linux_headers = rule(
    impl = _bootstrap_linux_headers_impl,
    attrs = {
        "source": attrs.dep(),
        "_configure_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:configure_helper"),
        ),
        "_build_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:build_helper"),
        ),
    },
)

# ── bootstrap_gcc ────────────────────────────────────────────────────

def _bootstrap_gcc_impl(ctx):
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]
    target_triple = ctx.attrs.target_triple
    is_cross = ctx.attrs.is_cross

    # Phase 1-2: prepare — copy source, symlink gmp/mpfr/mpc, patch Makefile.in
    prepared = ctx.actions.declare_output("prepared", dir = True)
    prep_cmd = cmd_args(ctx.attrs._configure_tool[RunInfo])
    prep_cmd.add("--source-dir", source)
    prep_cmd.add("--output-dir", prepared.as_output())
    prep_cmd.add("--skip-configure")
    ctx.actions.run(prep_cmd, category = "prepare", identifier = ctx.attrs.name + "-copy")

    # Phase 2b: src_prepare — symlink math libs and apply patches
    # Resolve artifact paths to absolute before cd
    src_prepared = ctx.actions.declare_output("src_prepared", dir = True)
    prepare_script = cmd_args("/bin/bash", "-ce")
    script_body = cmd_args("PROJECT_ROOT=$PWD && ", delimiter = "")
    if ctx.attrs.gmp_source:
        gmp_src = ctx.attrs.gmp_source[DefaultInfo].default_outputs[0]
        script_body.add(cmd_args("GMP_ABS=$PROJECT_ROOT/", gmp_src, " && ", delimiter = ""))
    if ctx.attrs.mpfr_source:
        mpfr_src = ctx.attrs.mpfr_source[DefaultInfo].default_outputs[0]
        script_body.add(cmd_args("MPFR_ABS=$PROJECT_ROOT/", mpfr_src, " && ", delimiter = ""))
    if ctx.attrs.mpc_source:
        mpc_src = ctx.attrs.mpc_source[DefaultInfo].default_outputs[0]
        script_body.add(cmd_args("MPC_ABS=$PROJECT_ROOT/", mpc_src, " && ", delimiter = ""))
    script_body.add(cmd_args(
        "cp -a ", prepared, "/. ", src_prepared.as_output(), "/ && ",
        "cd ", src_prepared.as_output(), " && ",
        delimiter = "",
    ))
    # Symlink GMP, MPFR, MPC source trees (using absolute paths)
    if ctx.attrs.gmp_source:
        script_body.add("ln -sfn $GMP_ABS gmp && ")
    if ctx.attrs.mpfr_source:
        script_body.add("ln -sfn $MPFR_ABS mpfr && ")
    if ctx.attrs.mpc_source:
        script_body.add("ln -sfn $MPC_ABS mpc && ")

    # For pass1 (C only, no libc): remove libcody and c++tools
    if not ctx.attrs.with_headers:
        script_body.add(
            "sed -i 's|libcody ||g' Makefile.in && " +
            "sed -i 's|c++tools ||g' Makefile.in && " +
            "sed -i '/: all-libcody$/d' Makefile.in && " +
            "sed -i '/: all-stage.*-libcody$/d' Makefile.in && " +
            "sed -i 's/ all-libcody / /g' Makefile.in && " +
            "sed -i 's/ all-libcody$//g' Makefile.in && " +
            "sed -i 's/ maybe-all-libcody / /g' Makefile.in && " +
            "sed -i 's/ maybe-all-libcody$//g' Makefile.in && " +
            "sed -i '/: configure-libcody$/d' Makefile.in && " +
            "sed -i '/: maybe-configure-libcody$/d' Makefile.in && " +
            "rm -rf libcody c++tools && ",
        )

    # For pass2: fix gthr-posix.h path
    if ctx.attrs.with_headers:
        script_body.add(
            "sed '/thread_header =/s/@.*@/gthr-posix.h/' " +
            "-i libgcc/Makefile.in libstdc++-v3/include/Makefile.in 2>/dev/null || true && ",
        )

    script_body.add("true")
    prepare_script.add(script_body)
    ctx.actions.run(prepare_script, category = "src_prepare", identifier = ctx.attrs.name)

    # Phase 3: configure — build sysroot and run configure
    configured = ctx.actions.declare_output("configured", dir = True)
    conf_script = cmd_args("/bin/bash", "-ce")

    # Resolve artifact paths to absolute BEFORE cd (Buck2 paths are relative to project root)
    conf_body = cmd_args("PROJECT_ROOT=$PWD && ", delimiter = "")
    if ctx.attrs.libc_headers:
        headers_dir = ctx.attrs.libc_headers[DefaultInfo].default_outputs[0]
        conf_body.add(cmd_args("HEADERS_ABS=$PROJECT_ROOT/", headers_dir, " && ", delimiter = ""))
    if ctx.attrs.libc_dep:
        libc_dir = ctx.attrs.libc_dep[DefaultInfo].default_outputs[0]
        conf_body.add(cmd_args("LIBC_ABS=$PROJECT_ROOT/", libc_dir, " && ", delimiter = ""))
    if ctx.attrs.binutils:
        binutils_dir = ctx.attrs.binutils[DefaultInfo].default_outputs[0]
        conf_body.add(cmd_args("BINUTILS_ABS=$PROJECT_ROOT/", binutils_dir, " && ", delimiter = ""))

    # Copy source and cd into configured dir
    conf_body.add(cmd_args(
        "cp -a ", src_prepared, "/. ", configured.as_output(), "/ && ",
        "cd ", configured.as_output(), " && ",
        delimiter = "",
    ))

    # Create build sysroot from dependencies (using absolute paths)
    if ctx.attrs.libc_headers:
        conf_body.add(
            "BUILD_SYSROOT=$PWD/build-sysroot && " +
            "mkdir -p $BUILD_SYSROOT/usr/include && " +
            "cp -r $HEADERS_ABS/usr/include/* $BUILD_SYSROOT/usr/include/ && ",
        )
    if ctx.attrs.libc_dep:
        conf_body.add(
            "BUILD_SYSROOT=$PWD/build-sysroot && " +
            "cp -a $LIBC_ABS/* $BUILD_SYSROOT/ && ",
        )
        if ctx.attrs.libc_headers:
            conf_body.add(
                "cp -a $HEADERS_ABS/* $BUILD_SYSROOT/ && ",
            )
        # Create stub sdt.h in merged sysroot
        conf_body.add(
            "mkdir -p $BUILD_SYSROOT/usr/include/sys && " +
            "printf '#ifndef _SYS_SDT_H\\n#define _SYS_SDT_H\\n" +
            "#define STAP_PROBE(p,n)\\n#endif\\n' > $BUILD_SYSROOT/usr/include/sys/sdt.h && ",
        )

    # Find cross-binutils
    if ctx.attrs.binutils:
        conf_body.add("BINUTILS_BIN=$BINUTILS_ABS/tools/bin && ")

    conf_body.add("mkdir -p build && cd build && ")

    # Build configure command
    configure_args = []
    configure_args.append("--prefix=/tools")
    if is_cross:
        configure_args.append("--target=" + target_triple)
    if ctx.attrs.with_headers and ctx.attrs.libc_dep:
        configure_args.append("--with-sysroot")
        configure_args.append("--with-native-system-header-dir=/usr/include")
    elif not ctx.attrs.with_headers:
        configure_args.append("--with-sysroot=/tools")
        configure_args.append("--with-newlib")
        configure_args.append("--without-headers")
    configure_args.append("--enable-languages=" + ctx.attrs.languages)
    configure_args.append("--disable-multilib")
    configure_args.append("--disable-bootstrap")

    if not ctx.attrs.with_headers:
        # Pass1: minimal build
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
        # Pass2: full build with libc
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
        # Only use system zlib for cross builds where the host has zlib.
        # Canadian cross builds don't have zlib in the sysroot.
        if is_cross:
            configure_args.append("--with-system-zlib")

    for arg in ctx.attrs.extra_configure_args:
        configure_args.append(arg)

    # Build the ../configure command with env vars
    env = _toolchain_env(ctx)
    for k, v in env.items():
        if type(v) == type(""):
            conf_body.add(k + "=\"" + v + "\" ")
        else:
            # Artifact value from prev_stage — needs $PROJECT_ROOT prefix
            conf_body.add(cmd_args(k + "=\"$PROJECT_ROOT/", v, "\" ", delimiter = ""))

    # Add sysroot args
    if ctx.attrs.libc_headers and not ctx.attrs.libc_dep:
        conf_body.add("../configure --with-build-sysroot=$BUILD_SYSROOT ")
        if ctx.attrs.binutils:
            conf_body.add(cmd_args(
                "--with-as=$BINUTILS_BIN/", target_triple, "-as ",
                "--with-ld=$BINUTILS_BIN/", target_triple, "-ld ",
                delimiter = "",
            ))
    elif ctx.attrs.libc_dep:
        conf_body.add("../configure --with-build-sysroot=$BUILD_SYSROOT ")
    else:
        conf_body.add("../configure ")
        if ctx.attrs.binutils:
            conf_body.add(cmd_args(
                "--with-as=$BINUTILS_BIN/", target_triple, "-as ",
                "--with-ld=$BINUTILS_BIN/", target_triple, "-ld ",
                delimiter = "",
            ))

    for arg in configure_args:
        conf_body.add(arg + " ")

    conf_script.add(conf_body)
    ctx.actions.run(conf_script, category = "configure", identifier = ctx.attrs.name)

    # Phase 4: compile
    built = ctx.actions.declare_output("built", dir = True)
    compile_script = cmd_args("/bin/bash", "-ce")
    compile_body = cmd_args(
        "PROJECT_ROOT=$PWD && ",
        "cp -a ", configured, "/. ", built.as_output(), "/ && ",
        "cd ", built.as_output(), "/build && ",
        delimiter = "",
    )
    # Cross-binutils must be on PATH for libgcc's ar/ranlib steps
    if ctx.attrs.binutils:
        _bdir = ctx.attrs.binutils[DefaultInfo].default_outputs[0]
        compile_body.add(cmd_args("export PATH=$PROJECT_ROOT/", _bdir, "/tools/bin:$PATH && ", delimiter = ""))
    # For Canadian cross (prev_stage set): stage tools must be on PATH so
    # make can find x86_64-buckos-linux-gnu-gcc, -as, -ld, etc.
    if ctx.attrs.prev_stage and BootstrapStageInfo in ctx.attrs.prev_stage:
        _stage_out = ctx.attrs.prev_stage[DefaultInfo].default_outputs[0]
        compile_body.add(cmd_args("export PATH=$PROJECT_ROOT/", _stage_out, "/tools/bin:$PATH && ", delimiter = ""))

    if not ctx.attrs.with_headers:
        # Pass1: build just gcc and minimal libgcc
        compile_body.add(
            "make -j$(nproc) all-gcc && " +
            "make configure-target-libgcc && " +
            "cd " + target_triple + "/libgcc && " +
            "make -j$(nproc) libgcc.a INHIBIT_LIBC_CFLAGS='-Dinhibit_libc' && " +
            "{ make -j$(nproc) crtbegin.o crtend.o crtbeginS.o crtendS.o crtbeginT.o 2>/dev/null || true; }",
        )
    else:
        # Pass2: full build
        env_make_args = ""
        compile_body.add(
            "make -j$(nproc) " + env_make_args + "all-gcc && " +
            "make -j$(nproc) " + env_make_args + "all-target-libgcc && " +
            "make -j$(nproc) " + env_make_args + "all-target-libstdc++-v3",
        )

    compile_script.add(compile_body)
    ctx.actions.run(compile_script, category = "compile", identifier = ctx.attrs.name)

    # Phase 5: install (resolve paths to absolute before cd)
    installed = ctx.actions.declare_output("installed", dir = True)
    install_script = cmd_args("/bin/bash", "-ce")
    install_body = cmd_args(
        "PROJECT_ROOT=$PWD && ",
        "BUILD_DIR=$PROJECT_ROOT/", built, "/build && ",
        "INSTALL_DIR=$PROJECT_ROOT/", installed.as_output(), " && ",
        delimiter = "",
    )
    if ctx.attrs.binutils:
        _bdir2 = ctx.attrs.binutils[DefaultInfo].default_outputs[0]
        install_body.add(cmd_args("export PATH=$PROJECT_ROOT/", _bdir2, "/tools/bin:$PATH && ", delimiter = ""))
    if ctx.attrs.prev_stage and BootstrapStageInfo in ctx.attrs.prev_stage:
        _stage_out2 = ctx.attrs.prev_stage[DefaultInfo].default_outputs[0]
        install_body.add(cmd_args("export PATH=$PROJECT_ROOT/", _stage_out2, "/tools/bin:$PATH && ", delimiter = ""))
    if ctx.attrs.libc_dep:
        libc_dir2 = ctx.attrs.libc_dep[DefaultInfo].default_outputs[0]
        install_body.add(cmd_args("LIBC_DIR=$PROJECT_ROOT/", libc_dir2, " && ", delimiter = ""))
    if ctx.attrs.libc_headers:
        headers_dir2 = ctx.attrs.libc_headers[DefaultInfo].default_outputs[0]
        install_body.add(cmd_args("HEADERS_DIR=$PROJECT_ROOT/", headers_dir2, " && ", delimiter = ""))
    install_body.add("cd $BUILD_DIR && ")

    if not ctx.attrs.with_headers:
        # Pass1: install gcc + manually install libgcc.a and CRT objects
        install_body.add(
            "make -j$(nproc) DESTDIR=$INSTALL_DIR install-gcc && " +
            "GCC_VERSION=$(cat gcc/BASE-VER 2>/dev/null || echo '14.3.0') && " +
            "LIBGCC_DIR=$INSTALL_DIR/tools/lib/gcc/" + target_triple + "/$GCC_VERSION && " +
            "mkdir -p $LIBGCC_DIR && " +
            "cp " + target_triple + "/libgcc/libgcc.a $LIBGCC_DIR/ && " +
            "for crt in crtbegin.o crtend.o crtbeginS.o crtendS.o crtbeginT.o; do " +
            "[ -f " + target_triple + "/libgcc/$crt ] && cp " + target_triple + "/libgcc/$crt $LIBGCC_DIR/; " +
            "done; true",
        )
    else:
        # Pass2: full install with sysroot
        install_body.add(
            "make -j$(nproc) DESTDIR=$INSTALL_DIR install-gcc install-target-libgcc install-target-libstdc++-v3 && ",
        )
        # Copy binutils tools into the gcc install tree so the cross-compiler
        # can find as/ld/etc relative to itself (via -B search)
        if ctx.attrs.binutils:
            _bdir3 = ctx.attrs.binutils[DefaultInfo].default_outputs[0]
            install_body.add(cmd_args(
                "BINUTILS_DIR=$PROJECT_ROOT/", _bdir3, " && ",
                delimiter = "",
            ))
            install_body.add(
                "cp -a $BINUTILS_DIR/tools/bin/* $INSTALL_DIR/tools/bin/ 2>/dev/null || true && " +
                "cp -an $BINUTILS_DIR/tools/" + target_triple + "/* $INSTALL_DIR/tools/" + target_triple + "/ 2>/dev/null || true && ",
            )
        # Create symlinks and sysroot
        if ctx.attrs.libc_dep:
            install_body.add(
                "cd $INSTALL_DIR/tools/bin && " +
                "ln -sfv " + target_triple + "-gcc gcc && " +
                "ln -sfv " + target_triple + "-gcc cc && " +
                "ln -sfv " + target_triple + "-gcc " + target_triple + "-cc && " +
                "ln -sfv " + target_triple + "-g++ g++ && " +
                "ln -sfv " + target_triple + "-g++ c++ && " +
                "ln -sfv " + target_triple + "-cpp cpp && " +
                "cd $INSTALL_DIR && " +
                "mkdir -p tools/" + target_triple + "/sys-root && " +
                "cp -a $LIBC_DIR/* tools/" + target_triple + "/sys-root/ && ",
            )
            if ctx.attrs.libc_headers:
                install_body.add(
                    "cp -a $HEADERS_DIR/* tools/" + target_triple + "/sys-root/ && ",
                )
            install_body.add("true")
        else:
            install_body.add("true")

    install_script.add(install_body)
    ctx.actions.run(install_script, category = "install", identifier = ctx.attrs.name)

    # Return BootstrapStageInfo if this is a final stage compiler
    providers = [DefaultInfo(default_output = installed)]
    if ctx.attrs.with_headers and ctx.attrs.libc_dep:
        providers.append(BootstrapStageInfo(
            stage = ctx.attrs.stage_number,
            cc = installed.project("tools/bin/" + target_triple + "-gcc"),
            cxx = installed.project("tools/bin/" + target_triple + "-g++"),
            ar = installed.project("tools/bin/" + target_triple + "-ar") if ctx.attrs.binutils else installed.project("tools/bin/ar"),
            sysroot = installed.project("tools/" + target_triple + "/sys-root"),
            target_triple = target_triple,
        ))

    return providers

bootstrap_gcc = rule(
    impl = _bootstrap_gcc_impl,
    attrs = {
        "source": attrs.dep(),
        "gmp_source": attrs.option(attrs.dep(), default = None),
        "mpfr_source": attrs.option(attrs.dep(), default = None),
        "mpc_source": attrs.option(attrs.dep(), default = None),
        "binutils": attrs.option(attrs.dep(), default = None),
        "libc_dep": attrs.option(attrs.dep(), default = None),
        "libc_headers": attrs.option(attrs.dep(), default = None),
        "prev_stage": attrs.option(attrs.dep(), default = None),
        "host_cc": attrs.option(attrs.string(), default = None),
        "host_cxx": attrs.option(attrs.string(), default = None),
        "host_ar": attrs.option(attrs.string(), default = None),
        "languages": attrs.string(default = "c"),
        "is_cross": attrs.bool(default = True),
        "with_headers": attrs.bool(default = False),
        "target_triple": attrs.string(default = TARGET_TRIPLE),
        "stage_number": attrs.int(default = 1),
        "extra_configure_args": attrs.list(attrs.string(), default = []),
        "_configure_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:configure_helper"),
        ),
        "_build_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:build_helper"),
        ),
        "_install_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:install_helper"),
        ),
    },
)

# ── bootstrap_glibc ──────────────────────────────────────────────────

def _bootstrap_glibc_impl(ctx):
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]
    target_triple = ctx.attrs.target_triple
    compiler_dir = ctx.attrs.compiler[DefaultInfo].default_outputs[0]
    headers_dir = ctx.attrs.linux_headers[DefaultInfo].default_outputs[0]
    binutils_dir = ctx.attrs.binutils[DefaultInfo].default_outputs[0] if ctx.attrs.binutils else None

    # Phase 1-2: prepare (copy source + patch .eh_frame section attributes)
    # gcc-pass1 generates .eh_frame,"aw" (writable) but glibc's hand-written
    # assembly in libc_sigaction.c uses .eh_frame,"a" (read-only).  Patch to
    # match the compiler output so the assembler doesn't reject the mismatch.
    prepared = ctx.actions.declare_output("prepared", dir = True)
    prep_script = cmd_args("/bin/bash", "-ce")
    prep_body = cmd_args(
        "cp -a ", source, "/. ", prepared.as_output(), "/ && ",
        "find ", prepared.as_output(), " -name 'libc_sigaction.c' ",
        "-exec sed -i 's/eh_frame,\\\\\"a\\\\\"/eh_frame,\\\\\"aw\\\\\"/g' {} + ",
        delimiter = "",
    )
    prep_script.add(prep_body)
    ctx.actions.run(prep_script, category = "prepare", identifier = ctx.attrs.name)

    # Phase 3: configure — glibc requires out-of-tree build
    # Resolve artifact paths to absolute before any cd
    configured = ctx.actions.declare_output("configured", dir = True)
    conf_script = cmd_args("/bin/bash", "-ce")
    conf_body = cmd_args("PROJECT_ROOT=$PWD && ", delimiter = "")
    conf_body.add(cmd_args("COMPILER_ABS=$PROJECT_ROOT/", compiler_dir, " && ", delimiter = ""))
    conf_body.add(cmd_args("HEADERS_ABS=$PROJECT_ROOT/", headers_dir, " && ", delimiter = ""))
    if binutils_dir:
        conf_body.add(cmd_args("BINUTILS_ABS=$PROJECT_ROOT/", binutils_dir, " && ", delimiter = ""))

    conf_body.add(cmd_args(
        "cp -a ", prepared, "/. ", configured.as_output(), "/ && ",
        "cd ", configured.as_output(), " && ",
        "mkdir -p build && cd build && ",
        "echo 'rootsbindir=/usr/sbin' > configparms && ",
        delimiter = "",
    ))

    # Set cross-tool paths (using absolute paths)
    tool_prefix = target_triple + "-"
    conf_body.add("CROSS_CC=$(PATH=$COMPILER_ABS/tools/bin:")
    if binutils_dir:
        conf_body.add("$BINUTILS_ABS/tools/bin:")
    conf_body.add("$PATH which " + tool_prefix + "gcc) && ")
    conf_body.add("CROSS_CPP=\"$CROSS_CC -E\" && ")

    # Headers path
    conf_body.add("HEADERS_PATH=$HEADERS_ABS/usr/include && ")

    # Configure with explicit cross-tool env vars
    conf_body.add("CC=\"$CROSS_CC\" CPP=\"$CROSS_CPP\" CXX='' ")

    # Add cross-binutils tools
    if binutils_dir:
        for tool in ["LD", "AR", "AS", "NM", "RANLIB", "OBJCOPY", "OBJDUMP", "STRIP"]:
            conf_body.add(
                tool + "=$(PATH=$BINUTILS_ABS/tools/bin:$PATH which " + tool_prefix + tool.lower() + " 2>/dev/null || true) ",
            )

    conf_body.add(
        "../configure " +
        "--prefix=/usr " +
        "--host=" + target_triple + " " +
        "--build=$(../scripts/config.guess) " +
        "--enable-kernel=4.19 " +
        "--with-headers=$HEADERS_PATH " +
        "--disable-nscd " +
        "--disable-werror " +
        "--enable-cet=no " +
        "libc_cv_slibdir=/usr/lib64 " +
        "libc_cv_forced_unwind=yes " +
        "libc_cv_c_cleanup=yes " +
        "libc_cv_pde=yes " +
        "libc_cv_pde_load_address=0x0000000000400000 " +
        "libc_cv_cxx_link_ok=no " +
        "CFLAGS='-O2 -g -fcf-protection=none' " +
        "CXXFLAGS='-O2 -g -fcf-protection=none'",
    )

    conf_script.add(conf_body)
    # Use absolute PATH so it works after cd
    _glibc_path = cmd_args(
        "$PROJECT_ROOT/", compiler_dir, "/tools/bin:",
        delimiter = "",
    )
    if binutils_dir:
        _glibc_path.add(cmd_args("$PROJECT_ROOT/", binutils_dir, "/tools/bin:", delimiter = ""))
    _glibc_path.add("/usr/bin:/bin")
    ctx.actions.run(conf_script, category = "configure", identifier = ctx.attrs.name)

    # Phase 4: compile (need absolute PATH for cross tools)
    built = ctx.actions.declare_output("built", dir = True)
    compile_script = cmd_args("/bin/bash", "-ce")
    compile_body = cmd_args(
        "PROJECT_ROOT=$PWD && ",
        delimiter = "",
    )
    compile_body.add(cmd_args("COMPILER_ABS=$PROJECT_ROOT/", compiler_dir, " && ", delimiter = ""))
    if binutils_dir:
        compile_body.add(cmd_args("BINUTILS_ABS=$PROJECT_ROOT/", binutils_dir, " && ", delimiter = ""))
    compile_body.add("export PATH=$COMPILER_ABS/tools/bin:")
    if binutils_dir:
        compile_body.add("$BINUTILS_ABS/tools/bin:")
    compile_body.add("$PATH && ")
    compile_body.add(cmd_args(
        "cp -a ", configured, "/. ", built.as_output(), "/ && ",
        "cd ", built.as_output(), "/build && ",
        "make -j$(nproc)",
        delimiter = "",
    ))
    compile_script.add(compile_body)
    ctx.actions.run(compile_script, category = "compile", identifier = ctx.attrs.name)

    # Phase 5: install (resolve all paths to absolute before cd)
    installed = ctx.actions.declare_output("installed", dir = True)
    install_script = cmd_args("/bin/bash", "-ce")
    install_body = cmd_args(
        "PROJECT_ROOT=$PWD && ",
        delimiter = "",
    )
    install_body.add(cmd_args("COMPILER_ABS=$PROJECT_ROOT/", compiler_dir, " && ", delimiter = ""))
    if binutils_dir:
        install_body.add(cmd_args("BINUTILS_ABS=$PROJECT_ROOT/", binutils_dir, " && ", delimiter = ""))
    install_body.add("export PATH=$COMPILER_ABS/tools/bin:")
    if binutils_dir:
        install_body.add("$BINUTILS_ABS/tools/bin:")
    install_body.add("$PATH && ")
    install_body.add(cmd_args(
        "BUILD_DIR=$PROJECT_ROOT/", built, "/build && ",
        "INSTALL_DIR=$PROJECT_ROOT/", installed.as_output(), " && ",
        "cd $BUILD_DIR && ",
        "make -j$(nproc) DESTDIR=$INSTALL_DIR install && ",
        # Fix glibc linker scripts to use relative paths
        "for script in $INSTALL_DIR/usr/lib*/libc.so $INSTALL_DIR/usr/lib*/libpthread.so $INSTALL_DIR/usr/lib*/libm.so; do ",
        "if [ -f \"$script\" ] && file \"$script\" | grep -q ASCII; then ",
        "sed -i -e 's|/usr/lib64/||g' -e 's|/usr/lib/||g' -e 's|/lib64/||g' -e 's|/lib/||g' \"$script\"; ",
        "fi; done && ",
        # Create /lib64 symlink
        "mkdir -p $INSTALL_DIR/lib64 && ",
        "ln -sfv ../usr/lib64/ld-linux-x86-64.so.2 $INSTALL_DIR/lib64/ld-linux-x86-64.so.2",
        delimiter = "",
    ))
    install_script.add(install_body)
    ctx.actions.run(install_script, category = "install", identifier = ctx.attrs.name)

    return [DefaultInfo(default_output = installed)]

bootstrap_glibc = rule(
    impl = _bootstrap_glibc_impl,
    attrs = {
        "source": attrs.dep(),
        "compiler": attrs.dep(),
        "binutils": attrs.option(attrs.dep(), default = None),
        "linux_headers": attrs.dep(),
        "target_triple": attrs.string(default = TARGET_TRIPLE),
        "_configure_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:configure_helper"),
        ),
        "_build_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:build_helper"),
        ),
        "_install_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:install_helper"),
        ),
    },
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
    ctx.actions.run(prep_cmd, category = "prepare", identifier = ctx.attrs.name)

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
    ctx.actions.run(conf_cmd, category = "configure", identifier = ctx.attrs.name)

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
    ctx.actions.run(build_cmd, category = "compile", identifier = ctx.attrs.name)

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
    ctx.actions.run(inst_cmd, category = "install", identifier = ctx.attrs.name)

    pkg_info = PackageInfo(
        name = ctx.attrs.name,
        version = ctx.attrs.version,
        prefix = installed,
        include_dirs = [installed.project("usr/include")],
        lib_dirs = [
            installed.project("usr/lib"),
            installed.project("usr/lib64"),
        ],
        bin_dirs = [installed.project("usr/bin")],
        libraries = ctx.attrs.libraries,
        pkg_config_path = installed.project("usr/lib/pkgconfig"),
        cflags = [],
        ldflags = [],
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
        "source": attrs.dep(),
        "stage": attrs.dep(providers = [BootstrapStageInfo]),
        "version": attrs.string(default = ""),
        "configure_args": attrs.list(attrs.string(), default = []),
        "skip_configure": attrs.bool(default = False),
        "build_subdir": attrs.option(attrs.string(), default = None),
        "make_args": attrs.list(attrs.string(), default = []),
        "cc_as_make_arg": attrs.bool(default = False),
        "destdir_var": attrs.string(default = "DESTDIR"),
        "extra_env": attrs.list(attrs.string(), default = []),
        "libraries": attrs.list(attrs.string(), default = []),
        "license": attrs.string(default = "UNKNOWN"),
        "src_uri": attrs.string(default = ""),
        "src_sha256": attrs.string(default = ""),
        "homepage": attrs.option(attrs.string(), default = None),
        "description": attrs.string(default = ""),
        "_configure_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:configure_helper"),
        ),
        "_build_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:build_helper"),
        ),
        "_install_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:install_helper"),
        ),
    },
)
