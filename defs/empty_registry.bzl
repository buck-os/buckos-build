"""
Fallback patch registry when the private patches/ directory does not exist.

Users who maintain private patches create patches/registry.bzl to override
this empty default.
"""

PATCH_REGISTRY = {}
