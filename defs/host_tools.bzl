"""Default host tool exec_dep attrs for package rules.

Each build-system rule declares its required host tools as hidden
attrs.default_only(attrs.exec_dep(...)) — same pattern as _configure_tool,
_build_tool, _install_tool.  Shared attr dicts here avoid duplication.

host_tool_path_args() extracts --path-prepend flags from _host_* attrs
for Python helpers to assemble PATH from per-rule exec_deps.
"""

load("//defs:providers.bzl", "PackageInfo")

# Core POSIX tools needed by virtually every build
_CORE_TOOL_ATTRS = {
    "_host_coreutils": attrs.default_only(
        attrs.exec_dep(default = "//packages/core/coreutils:coreutils"),
    ),
    "_host_bash": attrs.default_only(
        attrs.exec_dep(default = "//packages/core/bash:bash"),
    ),
    "_host_sed": attrs.default_only(
        attrs.exec_dep(default = "//packages/core/sed:sed"),
    ),
    "_host_grep": attrs.default_only(
        attrs.exec_dep(default = "//packages/core/grep:grep"),
    ),
    "_host_gawk": attrs.default_only(
        attrs.exec_dep(default = "//packages/core/gawk:gawk"),
    ),
    "_host_findutils": attrs.default_only(
        attrs.exec_dep(default = "//packages/core/findutils:findutils"),
    ),
    "_host_diffutils": attrs.default_only(
        attrs.exec_dep(default = "//packages/core/diffutils:diffutils"),
    ),
    "_host_make": attrs.default_only(
        attrs.exec_dep(default = "//packages/core/make:make"),
    ),
    "_host_patch": attrs.default_only(
        attrs.exec_dep(default = "//packages/core/patch:patch"),
    ),
    "_host_gzip": attrs.default_only(
        attrs.exec_dep(default = "//packages/core/gzip:gzip"),
    ),
    "_host_tar": attrs.default_only(
        attrs.exec_dep(default = "//packages/core/tar:tar"),
    ),
}

# Autotools builds: core + autotools chain
AUTOTOOLS_HOST_TOOL_ATTRS = dict(_CORE_TOOL_ATTRS)
AUTOTOOLS_HOST_TOOL_ATTRS.update({
    "_host_perl": attrs.default_only(
        attrs.exec_dep(default = "//packages/languages/perl:perl"),
    ),
    "_host_m4": attrs.default_only(
        attrs.exec_dep(default = "//packages/core/m4:m4"),
    ),
    "_host_texinfo": attrs.default_only(
        attrs.exec_dep(default = "//packages/core/texinfo:texinfo"),
    ),
})

CMAKE_HOST_TOOL_ATTRS = dict(_CORE_TOOL_ATTRS)
CMAKE_HOST_TOOL_ATTRS.update({
    "_host_cmake": attrs.default_only(
        attrs.exec_dep(default = "//packages/core/cmake:cmake"),
    ),
})

MESON_HOST_TOOL_ATTRS = dict(_CORE_TOOL_ATTRS)
MESON_HOST_TOOL_ATTRS.update({
    "_host_python": attrs.default_only(
        attrs.exec_dep(default = "//packages/languages/python:python"),
    ),
    "_host_ninja": attrs.default_only(
        attrs.exec_dep(default = "//packages/core/ninja:ninja"),
    ),
})

CARGO_HOST_TOOL_ATTRS = dict(_CORE_TOOL_ATTRS)

GO_HOST_TOOL_ATTRS = dict(_CORE_TOOL_ATTRS)

PYTHON_HOST_TOOL_ATTRS = dict(_CORE_TOOL_ATTRS)

MOZBUILD_HOST_TOOL_ATTRS = dict(_CORE_TOOL_ATTRS)
MOZBUILD_HOST_TOOL_ATTRS.update({
    "_host_python": attrs.default_only(
        attrs.exec_dep(default = "//packages/languages/python:python"),
    ),
    "_host_m4": attrs.default_only(
        attrs.exec_dep(default = "//packages/core/m4:m4"),
    ),
})

BINARY_HOST_TOOL_ATTRS = dict(_CORE_TOOL_ATTRS)

def host_tool_path_args(ctx):
    """Extract --path-prepend args from _host_* exec_dep attrs.

    Iterates ctx.attrs looking for _host_* prefixed deps, extracts
    PackageInfo.prefix or DefaultInfo output, returns --path-prepend
    cmd_args list for Python helpers.
    """
    args = []
    for attr_name in dir(ctx.attrs):
        if not attr_name.startswith("_host_"):
            continue
        dep = getattr(ctx.attrs, attr_name)
        if dep == None:
            continue
        if PackageInfo in dep:
            prefix = dep[PackageInfo].prefix
        else:
            prefix = dep[DefaultInfo].default_outputs[0]
        args.append(cmd_args("--path-prepend", cmd_args(prefix, format = "{}/usr/bin")))
        args.append(cmd_args("--path-prepend", cmd_args(prefix, format = "{}/usr/sbin")))
    return args
