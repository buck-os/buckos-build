"""
Minimal test-only rules for building trivial C test fixtures.

Produces PackageInfo so outputs can feed through stamp_package /
ima_sign_package transforms from defs/rules/transforms.bzl.
"""

load("//defs:providers.bzl", "BuildToolchainInfo", "PackageInfo")
load("//defs:toolchain_helpers.bzl", "TOOLCHAIN_ATTRS")

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
# Absolutize relative buck-out paths in CC so GCC specs %R produces
# correct absolute interpreter paths in the binary.
_CC=""
for _w in $CC; do
    case "$_w" in
        --sysroot=buck-out*|-specs=buck-out*)
            _f="${{_w%%=*}}="
            _p="${{_w#*=}}"
            _CC="$_CC ${{_f}}$(pwd)/$_p"
            ;;
        *) _CC="$_CC $_w" ;;
    esac
done
CC=$_CC
$CC "$@" -o "$OUT/usr/bin/{binary}" "$SRC"
""".format(binary = ctx.attrs.binary_name),
        is_executable = True,
    )

    tc = ctx.attrs._toolchain[BuildToolchainInfo]
    cmd = cmd_args(script, output.as_output(), src)
    cmd.add(ctx.attrs.cflags)

    env = {"CC": cmd_args(tc.cc.args, delimiter = " ")}
    if tc.host_bin_dir:
        env["PATH"] = tc.host_bin_dir

    ctx.actions.run(cmd, category = "test_compile", identifier = ctx.attrs.name, env = env)

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
    } | TOOLCHAIN_ATTRS,
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
# Absolutize relative buck-out paths in CC (see test_c_binary).
_CC=""
for _w in $CC; do
    case "$_w" in
        --sysroot=buck-out*|-specs=buck-out*)
            _f="${{_w%%=*}}="
            _p="${{_w#*=}}"
            _CC="$_CC ${{_f}}$(pwd)/$_p"
            ;;
        *) _CC="$_CC $_w" ;;
    esac
done
CC=$_CC
$CC -shared -fPIC "$@" -o "$OUT/usr/lib64/{lib}" "$SRC"
""".format(lib = ctx.attrs.lib_name),
        is_executable = True,
    )

    tc = ctx.attrs._toolchain[BuildToolchainInfo]
    cmd = cmd_args(script, output.as_output(), src)
    cmd.add(ctx.attrs.cflags)

    env = {"CC": cmd_args(tc.cc.args, delimiter = " ")}
    if tc.host_bin_dir:
        env["PATH"] = tc.host_bin_dir

    ctx.actions.run(cmd, category = "test_compile", identifier = ctx.attrs.name, env = env)

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
    } | TOOLCHAIN_ATTRS,
)
