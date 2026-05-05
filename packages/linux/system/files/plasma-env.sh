#!/bin/bash
# Source this script to set up Plasma environment variables for debugging
# Usage: source ~/plasma-env.sh
#        plasmashell   # or any other KDE app

export XDG_RUNTIME_DIR=/run/user/1000
export XDG_SESSION_TYPE=wayland
export XDG_DATA_DIRS=/usr/share:/usr/local/share
export XDG_CONFIG_DIRS=/etc/xdg
export XDG_CONFIG_HOME=$HOME/.config
export XDG_DATA_HOME=$HOME/.local/share
export XDG_CACHE_HOME=$HOME/.cache
export XDG_CURRENT_DESKTOP=KDE
export KDE_FULL_SESSION=true
export KDE_SESSION_VERSION=6

export QT_QPA_PLATFORM=wayland
export QT_PLUGIN_PATH=/usr/lib64/plugins:/usr/plugins
export QML_IMPORT_PATH=/usr/lib64/qml:/usr/qml
export QML2_IMPORT_PATH=/usr/lib64/qml:/usr/qml

export LIBSEAT_BACKEND=logind
export HOME=/home/live

# Try to get WAYLAND_DISPLAY from running kwin
if [ -z "$WAYLAND_DISPLAY" ]; then
    export WAYLAND_DISPLAY=$(ls $XDG_RUNTIME_DIR/wayland-* 2>/dev/null | head -1 | xargs basename 2>/dev/null)
fi

# Try to get DBUS_SESSION_BUS_ADDRESS from running session
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    if [ -S "$XDG_RUNTIME_DIR/bus" ]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    else
        PID=$(pgrep -f "kwin_wayland" | head -1)
        if [ -n "$PID" ]; then
            export DBUS_SESSION_BUS_ADDRESS=$(cat /proc/$PID/environ 2>/dev/null | tr '\0' '\n' | grep DBUS_SESSION_BUS_ADDRESS | cut -d= -f2-)
        fi
    fi
fi

echo "Environment set up:"
echo "  WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
echo "  DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS"
echo "  XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
echo ""
echo "You can now run: plasmashell, dolphin, konsole, etc."
