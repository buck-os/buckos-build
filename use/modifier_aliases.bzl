"""Modifier alias struct for buck2 -m CLI shorthand.

Maps short names to constraint_value targets or profile lists.
Struct attribute names become CLI aliases: `buck2 build ... -m minimal`

Profile aliases expand to a list of constraint_value targets.
Individual flag aliases map to a single constraint_value target.
"""

load("//use/profiles:defs.bzl",
     "DESKTOP_FLAGS",
     "DEVELOPER_FLAGS",
     "HARDENED_FLAGS",
     "MINIMAL_FLAGS",
     "SERVER_FLAGS",
)

BUCKOS_ALIASES = struct(
    # ── Profile aliases (expand to lists) ────────────────────────
    minimal = MINIMAL_FLAGS,
    server = SERVER_FLAGS,
    desktop = DESKTOP_FLAGS,
    developer = DEVELOPER_FLAGS,
    hardened = HARDENED_FLAGS,

    # ── Common individual flag aliases ───────────────────────────
    # Security
    ssl_on = "//use/constraints:ssl-on",
    ssl_off = "//use/constraints:ssl-off",
    hardened_on = "//use/constraints:hardened-on",
    hardened_off = "//use/constraints:hardened-off",
    pie_on = "//use/constraints:pie-on",
    ssp_on = "//use/constraints:ssp-on",
    seccomp_on = "//use/constraints:seccomp-on",
    selinux_on = "//use/constraints:selinux-on",

    # Debug / development
    debug_on = "//use/constraints:debug-on",
    debug_off = "//use/constraints:debug-off",
    doc_on = "//use/constraints:doc-on",
    doc_off = "//use/constraints:doc-off",
    test_on = "//use/constraints:test-on",
    test_off = "//use/constraints:test-off",

    # Display
    X_on = "//use/constraints:X-on",
    X_off = "//use/constraints:X-off",
    wayland_on = "//use/constraints:wayland-on",
    wayland_off = "//use/constraints:wayland-off",
    opengl_on = "//use/constraints:opengl-on",
    vulkan_on = "//use/constraints:vulkan-on",
    gtk_on = "//use/constraints:gtk-on",
    gtk_off = "//use/constraints:gtk-off",
    qt5_on = "//use/constraints:qt5-on",
    qt6_on = "//use/constraints:qt6-on",

    # Network
    ipv6_on = "//use/constraints:ipv6-on",
    http2_on = "//use/constraints:http2-on",
    http2_off = "//use/constraints:http2-off",

    # Compression
    zlib_on = "//use/constraints:zlib-on",
    zstd_on = "//use/constraints:zstd-on",
    brotli_on = "//use/constraints:brotli-on",

    # System
    systemd_on = "//use/constraints:systemd-on",
    systemd_off = "//use/constraints:systemd-off",
    dbus_on = "//use/constraints:dbus-on",
    dbus_off = "//use/constraints:dbus-off",
    pam_on = "//use/constraints:pam-on",

    # Build options
    static_on = "//use/constraints:static-on",
    static_off = "//use/constraints:static-off",
    strip_on = "//use/constraints:strip-on",
    strip_off = "//use/constraints:strip-off",

    # Languages
    python_on = "//use/constraints:python-on",
    python_off = "//use/constraints:python-off",
    perl_on = "//use/constraints:perl-on",
    perl_off = "//use/constraints:perl-off",

    # Audio
    pulseaudio_on = "//use/constraints:pulseaudio-on",
    pipewire_on = "//use/constraints:pipewire-on",
    alsa_on = "//use/constraints:alsa-on",

    # Text / internationalization
    unicode_on = "//use/constraints:unicode-on",
    nls_on = "//use/constraints:nls-on",
    icu_on = "//use/constraints:icu-on",
)
