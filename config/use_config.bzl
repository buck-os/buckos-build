# Generated USE flag configuration
# This file defines the global USE flags and hardware configuration
# Global USE flags for the installation
INSTALL_USE_FLAGS = [
    # Basic system features
    "ssl",
    "ipv6",
    "threads",
    "unicode",
    # Disable optional features by default
    "-X",
    "-gtk",
    "-qt5",
    "-pulseaudio",
]
# Per-package USE flag overrides
# Format: {"package_name": {"enabled": [...], "disabled": [...]}}
INSTALL_PACKAGE_USE = {}
# Video card drivers to enable
# Options: nvidia, amd, intel, vesa, fbdev, nouveau, radeon, vmware, virtualbox, qxl
INSTALL_VIDEO_CARDS = [
    "fbdev",
    "vesa",
]
# Input device drivers to enable
# Options: evdev, libinput, synaptics, wacom, joystick, keyboard, mouse
INSTALL_INPUT_DEVICES = [
    "evdev",
    "libinput",
]
