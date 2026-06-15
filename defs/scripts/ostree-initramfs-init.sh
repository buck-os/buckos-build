#!/usr/bin/busybox sh
# BuckOS ostree initramfs init (SPEC-006 P3).
#
# Runs as /init in a dynamic-capable initramfs (glibc + ostree + busybox, with
# a real ld.so.cache from ldconfig).  Mounts the physical sysroot, lets
# ostree-prepare-root set up the booted deployment (read-only /usr + 3-way
# merged /etc + /var bind), then switch_roots into it.  ostree-prepare-root is
# a dynamic binary, which is why the initramfs is built from a real rootfs
# slice rather than a hand-assembled /lib64.
#
# Commands go through busybox explicitly so we don't depend on applet symlinks.
BB=/usr/bin/busybox
msg() { $BB echo "[ostree-initramfs] $*"; }

$BB mount -t proc proc /proc 2>/dev/null
$BB mount -t sysfs sysfs /sys 2>/dev/null
$BB mount -t devtmpfs devtmpfs /dev 2>/dev/null
$BB mkdir -p /run /sysroot
$BB mount -t tmpfs tmpfs /run 2>/dev/null
$BB mount --make-rprivate / 2>/dev/null

# Physical root device from the kernel cmdline (root=...), default /dev/vda.
rootdev=/dev/vda
for arg in $($BB cat /proc/cmdline 2>/dev/null); do
    case "$arg" in
        root=*) rootdev=${arg#root=} ;;
    esac
done

msg "mounting sysroot $rootdev"
if ! $BB mount -o rw "$rootdev" /sysroot; then
    msg "failed to mount $rootdev; dropping to shell"
    exec $BB sh
fi

msg "preparing ostree deployment (ostree-prepare-root)"
if /usr/lib/ostree/ostree-prepare-root /sysroot; then
    msg "deployment ready; switch_root into it"
    exec $BB switch_root /sysroot /sbin/init
fi

msg "ostree-prepare-root failed; dropping to shell"
exec $BB sh
