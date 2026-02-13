#!/bin/bash
# Generate BuckOS Live System Init Scripts
# This script creates all the configuration files needed for the live environment

set -e

OUT="$1"

if [ -z "$OUT" ]; then
    echo "Usage: $0 <output_directory>"
    exit 1
fi

mkdir -p "$OUT/etc/init.d"
mkdir -p "$OUT/etc/rc.d"
mkdir -p "$OUT/sbin"
# Removed: mkdir -p "$OUT/etc/sddm.conf.d" (using plasma-login-manager)
mkdir -p "$OUT/etc/xdg/autostart"
mkdir -p "$OUT/usr/share/applications"
mkdir -p "$OUT/etc/systemd/system/getty@tty1.service.d"
mkdir -p "$OUT/etc/systemd/system/multi-user.target.wants"

# Create inittab for busybox init (live environment)
cat > "$OUT/etc/inittab" << 'INITTAB'
# /etc/inittab - BuckOS Live System Configuration
# System initialization
::sysinit:/etc/init.d/rcS

# Start getty on console
tty1::respawn:/sbin/getty 38400 tty1
tty2::respawn:/sbin/getty 38400 tty2

# Start display manager (for graphical session)
::once:/etc/init.d/display-manager start

# What to do when restarting the init process
::restart:/sbin/init

# What to do before rebooting
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
::shutdown:/sbin/swapoff -a
INITTAB

# Create rcS startup script for live system
cat > "$OUT/etc/init.d/rcS" << 'RCS'
#!/bin/sh
# BuckOS Live System - System initialization script

# Set PATH first - essential for finding commands
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

echo "BuckOS Live System - Booting..."

# Mount essential filesystems (skip if already mounted by initramfs)
mountpoint -q /proc  || mount -t proc proc /proc 2>/dev/null || true
mountpoint -q /sys   || mount -t sysfs sysfs /sys 2>/dev/null || true
mountpoint -q /dev   || mount -t devtmpfs devtmpfs /dev 2>/dev/null || mount -t tmpfs tmpfs /dev

# Create essential device nodes if devtmpfs failed
if [ ! -c /dev/null ]; then
    mknod -m 666 /dev/null c 1 3
    mknod -m 666 /dev/zero c 1 5
    mknod -m 666 /dev/random c 1 8
    mknod -m 666 /dev/urandom c 1 9
    mknod -m 600 /dev/console c 5 1
    mknod -m 666 /dev/tty c 5 0
    mknod -m 666 /dev/tty1 c 4 1
    mknod -m 666 /dev/tty2 c 4 2
    mknod -m 660 /dev/ttyS0 c 4 64
fi

# Mount /dev/pts for pseudo-terminals (skip if already mounted)
mkdir -p /dev/pts /dev/shm
mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts 2>/dev/null || true
mountpoint -q /dev/shm || mount -t tmpfs tmpfs /dev/shm 2>/dev/null || true

# Mount /run and /tmp (skip if already mounted)
mountpoint -q /run || mount -t tmpfs tmpfs /run 2>/dev/null || true
mountpoint -q /tmp || mount -t tmpfs tmpfs /tmp 2>/dev/null || true

# Set hostname
hostname buckos-live

# Configure loopback
ip link set lo up 2>/dev/null || ifconfig lo up 2>/dev/null

# Load kernel modules for hardware support
modprobe -a i915 amdgpu nouveau radeon 2>/dev/null || true
modprobe -a virtio virtio_pci virtio_blk virtio_net 2>/dev/null || true
modprobe -a usbhid hid-generic 2>/dev/null || true
modprobe -a overlay squashfs loop 2>/dev/null || true

# Start udev or eudev for device management
if [ -x /sbin/udevd ]; then
    /sbin/udevd --daemon
    udevadm trigger
    udevadm settle
elif [ -x /usr/lib/systemd/systemd-udevd ]; then
    /usr/lib/systemd/systemd-udevd --daemon
    udevadm trigger
    udevadm settle
fi

# Configure network (DHCP)
for iface in eth0 enp0s3 ens3; do
    if [ -e "/sys/class/net/$iface" ]; then
        ip link set "$iface" up 2>/dev/null
        dhcpcd "$iface" 2>/dev/null &
        break
    fi
done

# Create live user home
mkdir -p /home/live/Desktop
chown -R 1000:1000 /home/live 2>/dev/null || true

echo "System initialization complete."
echo "Starting graphical environment..."
RCS
chmod +x "$OUT/etc/init.d/rcS"

# Create display manager init script
cat > "$OUT/etc/init.d/display-manager" << 'DM'
#!/bin/sh
# Display manager control script
case "$1" in
    start)
        # Try SDDM first (KDE default), then fallback to simpler options
        if [ -x /usr/bin/sddm ]; then
            exec /usr/bin/sddm
        elif [ -x /usr/bin/startplasma-wayland ]; then
            su - live -c "XDG_SESSION_TYPE=wayland exec /usr/bin/startplasma-wayland"
        elif [ -x /usr/bin/sway ]; then
            su - live -c "exec /usr/bin/sway"
        elif [ -x /usr/bin/startx ]; then
            su - live -c "exec startx"
        else
            echo "No display manager or compositor found!"
            echo "Starting console shell..."
            exec /bin/sh
        fi
        ;;
    stop)
        killall sddm startplasma-wayland sway 2>/dev/null
        ;;
    *)
        echo "Usage: $0 {start|stop}"
        exit 1
        ;;
esac
DM
chmod +x "$OUT/etc/init.d/display-manager"

# Create fstab for live system
# Keep it minimal - systemd handles /proc, /sys, /dev, /run automatically
# Don't add /tmp here; let systemd's tmp.mount handle it or mask it
cat > "$OUT/etc/fstab" << 'FSTAB'
# /etc/fstab - BuckOS Live System
# Root is an overlay filesystem mounted by initramfs.
# systemd handles /proc, /sys, /dev, /run automatically.
FSTAB

# NOTE: /etc/passwd, /etc/group, /etc/shadow are now managed by the
# live-users-gen genrule in packages/linux/system/BUCK
# This ensures proper group memberships for the live user

# Create os-release
cat > "$OUT/etc/os-release" << 'OSRELEASE'
NAME="BuckOS Linux"
VERSION="0.1 Live"
ID=buckos
ID_LIKE=gentoo
PRETTY_NAME="BuckOS Linux 0.1 Live"
HOME_URL="https://github.com/buck-os/buckos-build"
VARIANT="Live"
VARIANT_ID=live
OSRELEASE

# Create hostname
echo "buckos-live" > "$OUT/etc/hostname"

# Create hosts
cat > "$OUT/etc/hosts" << 'HOSTS'
127.0.0.1   localhost buckos-live
::1         localhost ip6-localhost ip6-loopback
HOSTS

# Locale configuration is now provided by baselayout package

# Create profile
cat > "$OUT/etc/profile" << 'PROFILE'
# /etc/profile - BuckOS Live System
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PS1='\[\033[01;32m\]live@buckos-live\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
export TERM=linux

# Wayland preferences (XDG_RUNTIME_DIR is set by pam_systemd)
export XDG_SESSION_TYPE=wayland
export QT_QPA_PLATFORM=wayland
export GDK_BACKEND=wayland
PROFILE

# Create issue (login banner)
# Note: Backslashes are doubled because getty interprets escape sequences
cat > "$OUT/etc/issue" << 'ISSUE'

  ____             _     ___  ____    _     _
 | __ ) _   _  ___| | __/ _ \\/ ___|  | |   (_)_   _____
 |  _ \\| | | |/ __| |/ / | | \\___ \\  | |   | \\ \\ / / _ \\
 | |_) | |_| | (__|   <| |_| |___) | | |___| |\\ V /  __/
 |____/ \\__,_|\\___|_|\\_\\\\___/|____/  |_____|_| \\_/ \\___|

 Welcome to BuckOS Linux Live System!

 To install BuckOS to your hard drive, run the installer:
   - Click the "Install BuckOS" icon on the desktop
   - Or run: sudo buckos-installer

 Kernel \r on \m

ISSUE

# Note: SDDM config removed - using plasma-login-manager instead

# Create XDG autostart for installer notification
cat > "$OUT/etc/xdg/autostart/buckos-installer-notify.desktop" << 'AUTOSTART'
[Desktop Entry]
Type=Application
Name=BuckOS Installer Notification
Exec=notify-send -i system-software-install "Welcome to BuckOS Live" "Click the 'Install BuckOS' icon on your desktop to install BuckOS to your computer."
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
AUTOSTART

# Create desktop entry for installer
cat > "$OUT/usr/share/applications/buckos-installer.desktop" << 'DESKTOPENTRY'
[Desktop Entry]
Type=Application
Name=Install BuckOS
GenericName=System Installer
Comment=Install BuckOS to your computer
Exec=sudo /usr/bin/buckos-installer
Icon=system-software-install
Terminal=false
Categories=System;
Keywords=install;installer;setup;system;
StartupNotify=true
X-KDE-StartupNotify=true
DESKTOPENTRY

# Note: sway-init is now in //packages/linux/system/init/sway-init:sway-init
# Note: /sbin/init symlink is created by the init system package (systemd or sway-init)

# =============================================================================
# Systemd configuration for live boot (when systemd is PID 1)
# =============================================================================

# Getty autologin on tty1 - auto-login as live user for live session
cat > "$OUT/etc/systemd/system/getty@tty1.service.d/autologin.conf" << 'GETTYCONF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin live --noclear %I $TERM
Type=idle
GETTYCONF

# Seatd service for session management (needed by sway/wlroots)
cat > "$OUT/etc/systemd/system/seatd.service" << 'SEATD'
[Unit]
Description=Seat management daemon
Documentation=man:seatd(1)

[Service]
Type=simple
ExecStart=/usr/bin/seatd -g seat
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
SEATD

# Enable seatd at boot
# NOTE: Disabled for KDE - KDE uses systemd-logind for seat management
# Uncomment for sway-based live systems that need seatd
# ln -sf ../seatd.service "$OUT/etc/systemd/system/multi-user.target.wants/seatd.service"

# Create root's profile to auto-start sway on tty1
mkdir -p "$OUT/root"
cat > "$OUT/root/.bash_profile" << 'ROOTPROFILE'
# Auto-start Sway on tty1 in live session
if [ "$(tty)" = "/dev/tty1" ] && [ -z "$WAYLAND_DISPLAY" ]; then
    export XDG_RUNTIME_DIR=/run/user/0
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 0700 "$XDG_RUNTIME_DIR"
    export XDG_SESSION_TYPE=wayland
    export QT_QPA_PLATFORM=wayland
    export GDK_BACKEND=wayland

    echo ""
    echo "======================================"
    echo "  Welcome to BuckOS Live"
    echo "======================================"
    echo ""

    if [ -e /dev/dri/card0 ]; then
        echo "Starting Sway Wayland compositor..."
        exec sway
    else
        echo "No display detected (no /dev/dri/card0)"
        echo "Dropping to shell. Type 'sway' to try manually."
    fi
fi
ROOTPROFILE

# Disable systemd-firstboot (live system is pre-configured)
# Create the machine-id so firstboot doesn't trigger (locale.conf already created above)
mkdir -p "$OUT/etc"
echo "buckos-live" > "$OUT/etc/machine-id"
echo "UTC" > "$OUT/etc/timezone"
ln -sf /usr/share/zoneinfo/UTC "$OUT/etc/localtime" 2>/dev/null || true

# Mask systemd services that don't work / aren't needed on a live overlay root
mkdir -p "$OUT/etc/systemd/system"

for svc in \
    systemd-firstboot.service \
    systemd-remount-fs.service \
    tmp.mount \
    sys-kernel-debug.mount \
    sys-kernel-tracing.mount \
    sys-kernel-debug-tracing.mount \
    sys-kernel-config.mount \
    sys-fs-fuse-connections.mount \
    dev-hugepages.mount \
    systemd-udev-load-credentials.service \
    systemd-machine-id-commit.service \
    systemd-random-seed.service \
    systemd-boot-random-seed.service \
    systemd-update-done.service \
    systemd-sysusers.service \
    systemd-pcrphase-initrd.service \
    systemd-pcrphase-sysinit.service \
    systemd-pcrphase.service \
    systemd-pcrmachine.service \
    systemd-pcrfs-root.service \
    systemd-binfmt.service \
    systemd-boot-update.service \
    systemd-homed.service \
    systemd-hwdb-update.service \
    ldconfig.service \
; do
    ln -sf /dev/null "$OUT/etc/systemd/system/$svc"
done

# =============================================================================
# Systemd service enablement for live boot
# =============================================================================

# Set graphical.target as default (needed for display manager)
ln -sf /usr/lib/systemd/system/graphical.target "$OUT/etc/systemd/system/default.target"

# Note: plasma-login-manager is enabled in live-systemd-config-gen instead of SDDM

# Enable dbus and logind (required by most desktop services and session management)
mkdir -p "$OUT/etc/systemd/system/multi-user.target.wants"
ln -sf /usr/lib/systemd/system/dbus.service "$OUT/etc/systemd/system/multi-user.target.wants/dbus.service" 2>/dev/null || true
ln -sf /usr/lib/systemd/system/systemd-logind.service "$OUT/etc/systemd/system/multi-user.target.wants/systemd-logind.service" 2>/dev/null || true

# =============================================================================
# Fix common boot issues
# =============================================================================

# Create sulogin symlink - systemd expects /usr/bin/sulogin but shadow installs to /sbin/sulogin
mkdir -p "$OUT/usr/bin"
if [ ! -e "$OUT/usr/bin/sulogin" ]; then
    ln -sf /sbin/sulogin "$OUT/usr/bin/sulogin"
fi

# Create ld.so.conf so ldconfig can find libraries
cat > "$OUT/etc/ld.so.conf" << 'LDCONF'
/usr/lib64
/usr/lib
/lib64
/lib
include /etc/ld.so.conf.d/*.conf
LDCONF
mkdir -p "$OUT/etc/ld.so.conf.d"

# =============================================================================
# PAM configuration (required by systemd-logind and login services)
# =============================================================================
mkdir -p "$OUT/etc/pam.d"

cat > "$OUT/etc/pam.d/system-auth" << 'PAMAUTH'
auth      sufficient  pam_unix.so try_first_pass nullok
auth      required    pam_deny.so
account   required    pam_unix.so
password  sufficient  pam_unix.so try_first_pass nullok sha512 shadow
password  required    pam_deny.so
session   required    pam_unix.so
PAMAUTH

cat > "$OUT/etc/pam.d/system-login" << 'PAMLOGIN'
auth      include   system-auth
account   include   system-auth
password  include   system-auth
session   include   system-auth
session   optional  pam_systemd.so
PAMLOGIN

cat > "$OUT/etc/pam.d/login" << 'PAMLOGINF'
auth      include   system-login
account   include   system-login
password  include   system-login
session   include   system-login
PAMLOGINF

# SDDM PAM configs are now provided by the SDDM package itself
# No need to create them here

cat > "$OUT/etc/pam.d/system-local-login" << 'PAMLOCALLOGIN'
auth      include   system-login
account   include   system-login
password  include   system-login
session   include   system-login
PAMLOCALLOGIN

cat > "$OUT/etc/pam.d/systemd-user" << 'PAMSYSTEMDUSER'
# PAM configuration for systemd user instance (user@.service)
# NOTE: pam_systemd should NOT be here - it's for login sessions only
# The user systemd instance is started BY pam_systemd during login
account  required pam_unix.so
session  required pam_unix.so
PAMSYSTEMDUSER

cat > "$OUT/etc/pam.d/other" << 'PAMOTHER'
auth      required  pam_deny.so
account   required  pam_deny.so
password  required  pam_deny.so
session   required  pam_deny.so
PAMOTHER

# =============================================================================
# D-Bus system bus configuration
# =============================================================================
mkdir -p "$OUT/etc/dbus-1"
mkdir -p "$OUT/var/lib/dbus"

# Generate machine D-Bus UUID (needed by dbus-daemon)
if [ ! -f "$OUT/var/lib/dbus/machine-id" ]; then
    cp "$OUT/etc/machine-id" "$OUT/var/lib/dbus/machine-id" 2>/dev/null || \
        echo "buckoslive" > "$OUT/var/lib/dbus/machine-id"
fi

# Ensure dbus system.conf exists (should come from dbus package, but ensure it)
if [ ! -f "$OUT/etc/dbus-1/system.conf" ] && [ ! -f "$OUT/usr/share/dbus-1/system.conf" ]; then
    cat > "$OUT/etc/dbus-1/system.conf" << 'DBUSCONF'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>system</type>
  <listen>unix:path=/run/dbus/system_bus_socket</listen>
  <auth>EXTERNAL</auth>
  <includedir>/etc/dbus-1/system.d</includedir>
  <includedir>/usr/share/dbus-1/system.d</includedir>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
    <allow user="*"/>
  </policy>
</busconfig>
DBUSCONF
fi

# Create dbus run directory
mkdir -p "$OUT/run/dbus"

# Note: D-Bus policy for session creation is now in live-dbus-policy-gen Buck genrule

# =============================================================================
# Runtime directories and udev/logind setup
# =============================================================================
# Note: utmp/wtmp/btmp and polkit rules are now created by Buck genrules

# Create essential runtime directories that systemd services need
mkdir -p "$OUT/run/udev"
mkdir -p "$OUT/run/systemd/sessions"
mkdir -p "$OUT/run/systemd/users"
mkdir -p "$OUT/var/lib/systemd/linger"
mkdir -p "$OUT/var/lib/systemd/backlight"
mkdir -p "$OUT/var/lib/systemd/rfkill"

# Ensure udev directories exist
mkdir -p "$OUT/etc/udev/rules.d"
mkdir -p "$OUT/etc/udev/hwdb.d"
mkdir -p "$OUT/usr/lib/udev/rules.d"

# Create empty hwdb.bin if it doesn't exist (prevents udev hwdb errors)
touch "$OUT/etc/udev/hwdb.bin"

# Create udev configuration
cat > "$OUT/etc/udev/udev.conf" << 'UDEVCONF'
# udev configuration for live system
udev_log=err
UDEVCONF

# Create a no-op vconsole-setup service override to prevent udev errors
# We don't have the kbd package (setfont/loadkeys), but udev still triggers vconsole-setup
# Instead of masking it (which causes "failed with exit code 1"), create a dummy service that succeeds
mkdir -p "$OUT/etc/systemd/system/systemd-vconsole-setup.service.d"
cat > "$OUT/etc/systemd/system/systemd-vconsole-setup.service.d/override.conf" << 'VCONSOLEOVERRIDE'
[Unit]
# Live system doesn't need vconsole setup (kbd package not installed)
# Kernel console defaults work fine

[Service]
# Replace the service command with a no-op that succeeds
ExecStart=
ExecStart=/bin/true
VCONSOLEOVERRIDE

# Ensure logind directories exist
mkdir -p "$OUT/var/lib/systemd/linger"
mkdir -p "$OUT/etc/systemd/logind.conf.d"

# Configure logind for live session (no lid switch, no power key actions)
cat > "$OUT/etc/systemd/logind.conf.d/live.conf" << 'LOGINDCONF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
KillUserProcesses=no
LOGINDCONF

# Create tmpfiles.d config to set up runtime directories at boot
mkdir -p "$OUT/etc/tmpfiles.d"
cat > "$OUT/etc/tmpfiles.d/live-system.conf" << 'TMPFILES'
# Live system runtime directories
d /run/udev 0755 root root -
d /run/dbus 0755 root root -
d /run/systemd 0755 root root -
d /run/systemd/sessions 0755 root root -
d /run/systemd/users 0755 root root -
d /run/user 0755 root root -
# Note: /tmp is handled by systemd's /usr/lib/tmpfiles.d/tmp.conf

# systemd-logind state directories
d /var/lib/systemd 0755 root root -
d /var/lib/systemd/linger 0755 root root -
d /var/lib/systemd/backlight 0755 root root -
d /var/lib/systemd/rfkill 0755 root root -

# Login tracking files
d /var/log 0755 root root -
f /run/utmp 0664 root utmp -
f /var/log/wtmp 0664 root utmp -
f /var/log/btmp 0600 root utmp -
f /var/log/lastlog 0664 root utmp -

# X11 socket directory (needed for X server)
d /tmp/.X11-unix 1777 root root -

# Note: /run/user/1000 is created automatically by systemd-logind on user login
TMPFILES

# Ensure cgroups v2 unified hierarchy works
mkdir -p "$OUT/etc/systemd/system.conf.d"
cat > "$OUT/etc/systemd/system.conf.d/live.conf" << 'SYSTEMCONF'
[Manager]
# Use cgroups v2 unified hierarchy
DefaultCPUAccounting=yes
DefaultMemoryAccounting=yes
DefaultTasksAccounting=yes
# Reduce boot timeout for live system
DefaultTimeoutStartSec=30s
DefaultTimeoutStopSec=15s
SYSTEMCONF

# Note: default.target is set to graphical.target earlier in this script (for KDE/SDDM)
# Don't override it here

# Enable getty on tty1 explicitly
mkdir -p "$OUT/etc/systemd/system/getty.target.wants"
ln -sf /usr/lib/systemd/system/getty@.service "$OUT/etc/systemd/system/getty.target.wants/getty@tty1.service"

# Enable serial console for aarch64 (QEMU uses ttyAMA0)
ln -sf /usr/lib/systemd/system/serial-getty@.service "$OUT/etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service"

# Create autologin override for serial console too
mkdir -p "$OUT/etc/systemd/system/serial-getty@ttyAMA0.service.d"
cat > "$OUT/etc/systemd/system/serial-getty@ttyAMA0.service.d/autologin.conf" << 'SERIALCONF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I 115200 linux
Type=idle
SERIALCONF

# Create /sbin/ldconfig symlink (systemd expects /sbin/ldconfig but glibc installs to /usr/sbin)
mkdir -p "$OUT/sbin"
ln -sf ../usr/sbin/ldconfig "$OUT/sbin/ldconfig"

# Create empty ld.so.cache so ldconfig.service is skipped on live boot
# (avoids startup delay and potential issues with read-only squashfs)
touch "$OUT/etc/ld.so.cache"

# Create /etc/securetty to allow root login on console and serial ports
# Required by pam_securetty.so which is used by login PAM config
cat > "$OUT/etc/securetty" << 'SECURETTY'
# Console terminals
console
tty1
tty2
tty3
tty4
tty5
tty6
# Serial terminals (for QEMU and real hardware)
ttyS0
ttyS1
ttyAMA0
ttyAMA1
hvc0
SECURETTY

# Note: PAM configs (system-auth, login) are now in the pam package

echo "Live init scripts generated successfully in $OUT"
