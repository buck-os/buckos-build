"""Build rule for the kbuild capture LD_PRELOAD shim.

The shim is a small POSIX C file that interposes execve(3) and
posix_spawn(3) to log every exec made by a child process tree.  We
build it with the host cc because:

  * It runs on the host alongside make/gcc during capture, so it must
    be ABI-compatible with the host glibc — hermetic toolchain output
    won't be loadable by the host's gcc/cc1 binaries.
  * It has no third-party deps; just libc + libdl.
  * Keeping it in `cc -shared` form avoids pulling the autotools/cmake
    machinery into a 180-line build.
"""

def _impl(ctx: AnalysisContext) -> list[Provider]:
    out = ctx.actions.declare_output("libkbuild_trace.so")
    cmd = cmd_args(
        "cc",
        "-O2",
        "-Wall",
        "-Wextra",
        "-Wno-unused-parameter",
        "-fPIC",
        "-shared",
        "-ldl",
        ctx.attrs.src,
        "-o",
        out.as_output(),
    )
    ctx.actions.run(
        cmd,
        category = "kbuild_trace_lib",
        identifier = ctx.attrs.name,
        allow_cache_upload = True,
    )
    return [DefaultInfo(default_output = out)]

kbuild_trace_lib = rule(
    impl = _impl,
    attrs = {
        "src": attrs.source(),
    },
)
