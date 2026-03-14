"""buckos_test macro: hermetic sh_test wrapper.

Wraps sh_test so every test runs through the host-tools environment
wrapper.  With a seed toolchain, the wrapper prepends host-tools/bin
to PATH — tests find make, file, cc, etc. from the seed without
host-installed packages.  Without a seed, the wrapper is a passthrough.

Usage:
    load("//defs/rules:buckos_test.bzl", "buckos_test")

    buckos_test(
        name = "test-foo",
        test = "test_foo.py",
        labels = ["unit"],
    )
"""

def buckos_test(name, test, deps = [], env = {}, **kwargs):
    """sh_test that runs through the hermetic host-tools wrapper."""
    native.sh_test(
        name = name,
        test = ":host-tools-env",
        deps = deps,
        env = dict(env, **{
            "_BUCKOS_TEST": native.package_name() + "/" + test,
        }),
        **kwargs,
    )
