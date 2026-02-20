"""
Monorepo integration helpers for BuckOS.

When buckos is used as a cell in a monorepo, the monorepo root registers
one cell and adds buckos's execution platforms.

Typical monorepo .buckconfig:

    [cells]
      root = .
      buckos = third-party/buckos

    [build]
      execution_platforms = //exec:platforms, buckos//tc/exec:platforms

    [parser]
      target_platform_detector_spec = \\
        target:root//...->root//platforms:default \\
        target:buckos//...->buckos//platforms:linux-x86_64

Only one cell registration needed — use/ and tc/ are regular directories,
not subcells.
"""

def buckos_execution_platforms():
    """Returns buckos execution platform targets for monorepo registration.

    Usage in monorepo root .buckconfig:
        [build]
        execution_platforms = //exec:platforms, buckos//tc/exec:platforms
    """
    return [
        "buckos//tc/exec:host",
        "buckos//tc/exec:cross",
        "buckos//tc/exec:prebuilt",
    ]

def buckos_cell_config():
    """Documents required .buckconfig entries for monorepo integration.

    Only one cell registration needed — use/ and tc/ are regular directories,
    not subcells.
    """
    return {
        "cells": {
            "buckos": "<path-to-buckos>",
        },
        "buckos/.buckconfig.local": {
            "cells": {
                "prelude": "<relative-path-to-monorepo-prelude>",
            },
        },
    }

def buckos_toolchain_config_settings():
    """Returns the config_setting targets for tc.mode selection.

    Useful for rules that need to select() on the toolchain mode:

        select({
            "//tc/exec:mode-host": [...],
            "//tc/exec:mode-cross": [...],
            "DEFAULT": [...],
        })
    """
    return {
        "host": "//tc/exec:mode-host",
        "cross": "//tc/exec:mode-cross",
        "bootstrap": "//tc/exec:mode-bootstrap",
        "prebuilt": "//tc/exec:mode-prebuilt",
    }
