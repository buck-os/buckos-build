"""
USE_EXPAND variables for BuckOs.

Reads multi-value feature sets from .buckconfig [use_expand]:

    [use_expand]
      video_cards = amdgpu,radeonsi,intel
      input_devices = evdev,libinput

Access at analysis time:

    load("//defs:use_expand.bzl", "get_use_expand")
    cards = get_use_expand("video_cards")   # ["amdgpu", "radeonsi", "intel"]
"""

def get_use_expand(var_name, default = ""):
    """Read a USE_EXPAND variable from .buckconfig [use_expand].

    Args:
        var_name: Variable name (e.g. "video_cards", "input_devices")
        default: Default comma-separated string if unset

    Returns:
        List of enabled values (empty list if unset/empty)
    """
    raw = read_config("use_expand", var_name, default)
    if not raw:
        return []
    return [v.strip() for v in raw.split(",") if v.strip()]
