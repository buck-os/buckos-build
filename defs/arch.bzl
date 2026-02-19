# Architecture Configuration Module for BuckOS
#
# Provides architecture-specific configuration values and helper functions
# for cross-compilation and multi-arch support.

# Architecture configuration mappings
ARCH_CONFIGS = {
    "x86_64": {
        "target_triplet": "x86_64-buckos-linux-gnu",
        "kernel_arch": "x86",
        "kernel_image": "arch/x86/boot/bzImage",
        "ld_linux": "ld-linux-x86-64.so.2",
        "lib_suffix": "64",  # lib64 on x86_64
        "qemu_machine": "q35",
        "qemu_cpu": "qemu64",
        "march": "x86-64",
    },
    "aarch64": {
        "target_triplet": "aarch64-buckos-linux-gnu",
        "kernel_arch": "arm64",
        "kernel_image": "arch/arm64/boot/Image",
        "ld_linux": "ld-linux-aarch64.so.1",
        "lib_suffix": "",  # lib on aarch64
        "qemu_machine": "virt",
        "qemu_cpu": "cortex-a72",
        "march": "armv8-a",
    },
}

# Default architecture
DEFAULT_ARCH = "x86_64"

def get_arch_config(arch):
    """Get architecture configuration dictionary.

    Args:
        arch: Architecture name ("x86_64" or "aarch64")

    Returns:
        Dictionary with architecture-specific values
    """
    if arch not in ARCH_CONFIGS:
        fail("Unknown architecture: {}. Supported: {}".format(arch, ARCH_CONFIGS.keys()))
    return ARCH_CONFIGS[arch]

def get_target_triplet(arch):
    """Get the target triplet for an architecture.

    Args:
        arch: Architecture name ("x86_64" or "aarch64")

    Returns:
        Target triplet string (e.g., "x86_64-buckos-linux-gnu")
    """
    return get_arch_config(arch)["target_triplet"]

def get_kernel_arch(arch):
    """Get the kernel ARCH value for an architecture.

    Args:
        arch: Architecture name ("x86_64" or "aarch64")

    Returns:
        Kernel ARCH value (e.g., "x86" or "arm64")
    """
    return get_arch_config(arch)["kernel_arch"]

def get_kernel_image_path(arch):
    """Get the kernel image path for an architecture.

    Args:
        arch: Architecture name ("x86_64" or "aarch64")

    Returns:
        Kernel image path (e.g., "arch/x86/boot/bzImage")
    """
    return get_arch_config(arch)["kernel_image"]

def arch_select(x86_64_value, aarch64_value):
    """Create a select() statement for architecture-specific values.

    Args:
        x86_64_value: Value to use for x86_64
        aarch64_value: Value to use for aarch64

    Returns:
        A select() expression
    """
    return select({
        "root//platforms:is_x86_64": x86_64_value,
        "root//platforms:is_aarch64": aarch64_value,
    })

def get_cross_compile_prefix(host_arch, target_arch):
    """Get the cross-compilation prefix when building for a different architecture.

    Args:
        host_arch: Host architecture
        target_arch: Target architecture

    Returns:
        Cross-compile prefix (e.g., "aarch64-buckos-linux-gnu-") or empty string if native
    """
    if host_arch == target_arch:
        return ""
    return get_target_triplet(target_arch) + "-"

def get_qemu_args(arch):
    """Get QEMU machine and CPU arguments for an architecture.

    Args:
        arch: Architecture name

    Returns:
        Dictionary with qemu_machine and qemu_cpu
    """
    config = get_arch_config(arch)
    return {
        "machine": config["qemu_machine"],
        "cpu": config["qemu_cpu"],
    }
