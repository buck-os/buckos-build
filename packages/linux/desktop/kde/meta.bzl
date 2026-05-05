"""
KDE meta-package lists.

Replaces filegroup meta-targets which fail on duplicate artifact names.
Use these lists inline in deps or rootfs packages attributes.
"""

# KDE Frameworks (all KF6 framework packages)
KF_FRAMEWORKS = [
    "//packages/linux/desktop/kde:kcoreaddons",
    "//packages/linux/desktop/kde:ki18n",
    "//packages/linux/desktop/kde:kconfig",
    "//packages/linux/desktop/kde:kcodecs",
    "//packages/linux/desktop/kde:kguiaddons",
    "//packages/linux/desktop/kde:kwidgetsaddons",
    "//packages/linux/desktop/kde:kitemviews",
    "//packages/linux/desktop/kde:kiconthemes",
    "//packages/linux/desktop/kde:kcompletion",
    "//packages/linux/desktop/kde:kwindowsystem",
    "//packages/linux/desktop/kde:kcrash",
    "//packages/linux/desktop/kde:kdbusaddons",
    "//packages/linux/desktop/kde:kauth",
    "//packages/linux/desktop/kde:kjobwidgets",
    "//packages/linux/desktop/kde:kservice",
    "//packages/linux/desktop/kde:knotifications",
    "//packages/linux/desktop/kde:kio",
    "//packages/linux/desktop/kde:ktextwidgets",
    "//packages/linux/desktop/kde:kxmlgui",
    "//packages/linux/desktop/kde:kbookmarks",
    "//packages/linux/desktop/kde:solid",
    "//packages/linux/desktop/kde:sonnet",
    "//packages/linux/desktop/kde:karchive",
    "//packages/linux/desktop/kde:attica",
    "//packages/linux/desktop/kde:kpackage",
    "//packages/linux/desktop/kde:knewstuff",
    "//packages/linux/desktop/kde:kconfigwidgets",
    "//packages/linux/desktop/kde:kitemmodels",
    "//packages/linux/desktop/kde:kirigami",
    # Additional frameworks needed by KDE apps
    "//packages/linux/desktop/kde:kcolorscheme",
    "//packages/linux/desktop/kde:breeze-icons",
    "//packages/linux/desktop/kde:kidletime",
    "//packages/linux/desktop/kde:kglobalaccel",
    "//packages/linux/desktop/kde:ksvg",
    "//packages/linux/desktop/kde:krunner",
    "//packages/linux/desktop/kde:knotifyconfig",
    "//packages/linux/desktop/kde:kdoctools",
    "//packages/linux/desktop/kde:kcmutils",
    "//packages/linux/desktop/kde:kparts",
    "//packages/linux/desktop/kde:kpty",
    "//packages/linux/desktop/kde:syntax-highlighting",
    "//packages/linux/desktop/kde:ktexteditor",
    # Additional frameworks needed by plasma-workspace/desktop
    "//packages/linux/desktop/kde:kded",
    "//packages/linux/desktop/kde:kdeclarative",
    "//packages/linux/desktop/kde:kstatusnotifieritem",
    "//packages/linux/desktop/kde:kwallet",
    "//packages/linux/desktop/kde:kunitconversion",
    "//packages/linux/desktop/kde:prison",
    "//packages/linux/desktop/kde:kquickcharts",
]

# KDE Plasma desktop (for rootfs packages list)
KDE_PLASMA = [
    # Core Plasma components
    "//packages/linux/desktop/kde:plasma-desktop",
    "//packages/linux/desktop/kde:plasma-workspace",
    "//packages/linux/desktop/kde:kwin",
    # KDE Apps (essential for usable desktop)
    "//packages/linux/desktop/kde/apps:konsole",
    "//packages/linux/desktop/kde/apps:dolphin",
    "//packages/linux/desktop/kde/apps:kate",
    # KDE Frameworks (QML modules required for Plasma)
    "//packages/linux/desktop/kde:kservice",
    "//packages/linux/desktop/kde:kirigami",
    "//packages/linux/desktop/kde:kcmutils",
    "//packages/linux/desktop/kde:kdeclarative",
    "//packages/linux/desktop/kde:kitemmodels",
    "//packages/linux/desktop/kde:ksvg",
    "//packages/linux/desktop/kde:krunner",
    "//packages/linux/desktop/kde:kpackage",
    "//packages/linux/desktop/kde:plasma-activities",
    "//packages/linux/desktop/kde:kactivitymanagerd",
    "//packages/linux/desktop/kde:breeze",
    "//packages/linux/desktop/kde:breeze-icons",
    "//packages/linux/desktop/kde:kiconthemes",
    # KDE/Graphics libraries (explicit dependencies for Plasma shell)
    "//packages/linux/desktop/kde:libplasma",
    "//packages/linux/desktop/kde:plasma5support",
    "//packages/linux/desktop/kde:kdecoration2",
    "//packages/linux/desktop/kde:kwayland",
    "//packages/linux/desktop/kde:kscreenlocker",
    "//packages/linux/desktop/kde:kglobalacceld",
    "//packages/linux/desktop/kde:layer-shell-qt",
    "//packages/linux/desktop/kde:kquickcharts",
    "//packages/linux/desktop/kde:kholidays",
    "//packages/linux/desktop/kde:kirigami-addons",
    "//packages/linux/desktop/kde:milou",
    # Graphics stack
    "//packages/linux/graphics/rendering/wayland:wayland",
    "//packages/linux/desktop/mesa:mesa",
    "//packages/linux/graphics/libepoxy:libepoxy",
    "//packages/linux/system/libs/graphics/lcms2:lcms2",
    "//packages/linux/graphics/xorg/libxcvt:libxcvt",
    "//packages/linux/graphics/utilities/libdisplay-info:libdisplay-info",
    "//packages/linux/graphics/xorg/xcb-util-cursor:xcb-util-cursor",
    "//packages/linux/graphics/xorg/xcb-util-image:xcb-util-image",
    "//packages/linux/graphics/xorg/xcb-util-renderutil:xcb-util-renderutil",
    # Audio support
    "//packages/linux/audio/daemons/pipewire:pipewire",
    "//packages/linux/system/libs/audio/alsa-lib:alsa-lib",
]
