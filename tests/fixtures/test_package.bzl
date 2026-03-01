"""
Minimal test-only rules for building trivial C test fixtures.

Produces PackageInfo so outputs can feed through stamp_package /
ima_sign_package transforms from defs/rules/transforms.bzl.
"""

load("//defs:providers.bzl", "PackageInfo")

def _test_c_binary_impl(ctx):
    """Compile a single C file into an install layout."""
    output = ctx.actions.declare_output("prefix", dir = True)
    src = ctx.attrs.src

    script = ctx.actions.write(
        "build.sh",
        """\
#!/bin/bash
set -e
OUT="$1"; shift
SRC="$1"; shift
mkdir -p "$OUT/usr/bin"
cc "$@" -o "$OUT/usr/bin/{binary}" "$SRC"
""".format(binary = ctx.attrs.binary_name),
        is_executable = True,
    )

    cmd = cmd_args(script, output.as_output(), src)
    cmd.add(ctx.attrs.cflags)

    ctx.actions.run(cmd, category = "test_compile", identifier = ctx.attrs.name)

    return [
        DefaultInfo(default_output = output),
        PackageInfo(
            name = ctx.attrs.pkg_name,
            version = ctx.attrs.version,
            prefix = output,
            libraries = [],
            cflags = [],
            ldflags = [],
            compile_info = None,
            link_info = None,
            path_info = None,
            runtime_deps = None,
            license = "test",
            src_uri = "",
            src_sha256 = "",
            homepage = None,
            supplier = "Organization: BuckOS",
            description = "Test fixture",
            cpe = None,
        ),
    ]

test_c_binary = rule(
    impl = _test_c_binary_impl,
    attrs = {
        "src": attrs.source(),
        "pkg_name": attrs.string(),
        "binary_name": attrs.string(),
        "version": attrs.string(default = "0.1.0"),
        "cflags": attrs.list(attrs.string(), default = []),
    },
)

def _test_c_library_impl(ctx):
    """Compile a single C file into a shared library install layout."""
    output = ctx.actions.declare_output("prefix", dir = True)
    src = ctx.attrs.src

    script = ctx.actions.write(
        "build.sh",
        """\
#!/bin/bash
set -e
OUT="$1"; shift
SRC="$1"; shift
mkdir -p "$OUT/usr/lib64"
cc -shared -fPIC "$@" -o "$OUT/usr/lib64/{lib}" "$SRC"
""".format(lib = ctx.attrs.lib_name),
        is_executable = True,
    )

    cmd = cmd_args(script, output.as_output(), src)
    cmd.add(ctx.attrs.cflags)

    ctx.actions.run(cmd, category = "test_compile", identifier = ctx.attrs.name)

    return [
        DefaultInfo(default_output = output),
        PackageInfo(
            name = ctx.attrs.pkg_name,
            version = ctx.attrs.version,
            prefix = output,
            libraries = [ctx.attrs.lib_name],
            cflags = [],
            ldflags = [],
            compile_info = None,
            link_info = None,
            path_info = None,
            runtime_deps = None,
            license = "test",
            src_uri = "",
            src_sha256 = "",
            homepage = None,
            supplier = "Organization: BuckOS",
            description = "Test fixture",
            cpe = None,
        ),
    ]

test_c_library = rule(
    impl = _test_c_library_impl,
    attrs = {
        "src": attrs.source(),
        "pkg_name": attrs.string(),
        "lib_name": attrs.string(),
        "version": attrs.string(default = "0.1.0"),
        "cflags": attrs.list(attrs.string(), default = []),
    },
)
