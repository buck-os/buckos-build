"""
extract_source rule: extract source archives.

Extraction-only — downloading is handled by the prelude's http_file rule
or by export_file for vendored archives.  The package() macro creates both
targets automatically.

The two-target split (http_file -> extract_source) preserves http_file's
native benefits: content-addressed CAS lookup by sha256, deferred
execution, and RE-native download handling.
"""

def _extract_source_impl(ctx):
    # Get the archive from the source dep
    archive = ctx.attrs.source[DefaultInfo].default_outputs[0]

    output = ctx.actions.declare_output("src", dir = True)

    cmd = cmd_args(ctx.attrs._extract_tool[RunInfo])
    cmd.add("--archive", archive)
    cmd.add("--output", output.as_output())
    cmd.add("--strip-components", str(ctx.attrs.strip_components))
    if ctx.attrs.format:
        cmd.add("--format", ctx.attrs.format)

    ctx.actions.run(cmd, category = "extract", identifier = ctx.attrs.name)

    return [DefaultInfo(default_output = output)]

extract_source = rule(
    impl = _extract_source_impl,
    attrs = {
        "source": attrs.dep(),
        "strip_components": attrs.int(default = 1),
        "format": attrs.option(attrs.string(), default = None),
        "_extract_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:extract"),
        ),
    },
)
