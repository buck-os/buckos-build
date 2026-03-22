# Local Buck2 modifier configuration for BuckOS
#
# This file is the tracked default. The buckos installer or CLI generates
# config/local_modifiers.bzl (gitignored) with your actual USE flag choices.
#
# To configure USE flags:
#   buckos use +wayland +ssl -gtk        # Toggle global flags
#   buckos use profile desktop           # Apply a profile
#   buckos use package vim +python       # Per-package override
#
# Or copy this file to config/local_modifiers.bzl and edit manually.
# Available constraints are defined in //use/constraints/

LOCAL_MODIFIERS = [
]
