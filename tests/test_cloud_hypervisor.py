"""Tests for Cloud Hypervisor: target queries, build smoke, and VM boot.

Tier 1 (unmarked): query-only, no builds, no KVM — always run.
Tier 2 (@pytest.mark.slow): build smoke test.
Tier 3 (@pytest.mark.integration): full stack build + VM boot via KVM.
"""
from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import tempfile

import pytest

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

CH_TARGET = "//packages/linux/emulation/utilities/cloud-hypervisor:cloud-hypervisor"
KERNEL_TARGET = "//packages/linux/kernel/buckos-kernel:buckos-kernel-ch"
INITRAMFS_TARGET = "//packages/linux/system/cloud-hypervisor:ch-initramfs"
KERNEL_CONFIG_TARGET = "//packages/linux/kernel/configs:buckos-ch-guest"

HOST_TC = "-c"
HOST_TC_VAL = "buckos.use_host_toolchain=true"

BOOT_SCRIPT_NAMES = [
    "ch-boot-debug",
    "ch-boot-direct",
    "ch-boot-direct-full",
    "ch-boot-direct-minimal",
    "ch-boot-firmware-pvh",
    "ch-boot-firmware-uefi",
    "ch-boot-virtiofs",
    "ch-boot-virtiofs-full",
]

SYSTEM_IMAGE_NAMES = [
    "ch-minimal-rootfs",
    "ch-base-rootfs",
    "ch-full-rootfs",
    "ch-initramfs",
    "ch-initramfs-virtiofs",
    "ch-minimal-disk",
    "ch-base-disk",
    "ch-full-disk",
    "ch-full-disk-gpt",
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _uquery_attr(buck2, target: str, attr: str, *extra_args: str):
    """Run buck2 uquery --output-attribute and return the attribute value."""
    result = buck2(
        "uquery", target,
        "--output-attribute", attr,
        "--json",
        *extra_args,
        check=True,
    )
    data = json.loads(result.stdout)
    for key, attrs in data.items():
        if key.endswith(target.lstrip("/")) or key == target:
            return attrs.get(attr)
    return None


def _cquery_env(buck2, target: str, *extra_args: str) -> dict[str, str]:
    """Run buck2 cquery and extract the env attribute."""
    result = buck2(
        "cquery", target,
        "--output-attribute", "env",
        "--json",
        HOST_TC, HOST_TC_VAL,
        *extra_args,
        check=True,
    )
    text = result.stdout
    m = re.search(r"\{", text)
    if m:
        data = json.loads(text[m.start():])
        for _key, attrs in data.items():
            return attrs.get("env", {})
    return {}


# ---------------------------------------------------------------------------
# Tier 1: Query tests (no builds, no KVM)
# ---------------------------------------------------------------------------

class TestChTargetsExist:
    """Verify CH-related targets are present in the build graph."""

    def test_ch_binary_target(self, all_targets: list[str]):
        assert any(t.endswith(":cloud-hypervisor") for t in all_targets)

    def test_ch_boot_script_targets(self, all_targets: list[str]):
        boot_targets = [
            t for t in all_targets
            if "cloud-hypervisor-boot:" in t and ":ch-boot-" in t
        ]
        for name in BOOT_SCRIPT_NAMES:
            assert any(name in t for t in boot_targets), (
                f"Missing boot script target: {name}"
            )

    def test_ch_system_image_targets(self, all_targets: list[str]):
        sys_targets = [
            t for t in all_targets
            if "system/cloud-hypervisor:" in t
        ]
        for name in SYSTEM_IMAGE_NAMES:
            assert any(name in t for t in sys_targets), (
                f"Missing system image target: {name}"
            )

    def test_ch_no_network_boot_scripts(self, all_targets: list[str]):
        network_targets = [
            t for t in all_targets
            if "cloud-hypervisor-boot:" in t and "network" in t
        ]
        assert not network_targets, (
            f"Network boot targets should not exist: {network_targets}"
        )

    def test_ch_kernel_config_target(self, all_targets: list[str]):
        assert any(t.endswith(":buckos-ch-guest") for t in all_targets)

    def test_ch_kernel_build_target(self, all_targets: list[str]):
        assert any(t.endswith(":buckos-kernel-ch") for t in all_targets)


class TestChLabels:
    """Verify auto-injected labels on CH target."""

    def test_compile_and_cargo_labels(self, buck2):
        labels = _uquery_attr(buck2, CH_TARGET, "labels") or []
        assert "buckos:compile" in labels
        assert "buckos:build:cargo" in labels


class TestChProvenance:
    """Verify provenance labels on CH target."""

    def test_provenance_labels(self, buck2):
        labels = _uquery_attr(buck2, CH_TARGET, "labels") or []
        assert any(l.startswith("buckos:url:") and len(l) > len("buckos:url:") for l in labels)
        assert any(l.startswith("buckos:sha256:") and len(l) > len("buckos:sha256:") for l in labels)
        assert any(l.startswith("buckos:source:") and len(l) > len("buckos:source:") for l in labels)


class TestChBootScriptsLabeled:
    """Verify boot scripts have buckos:bootscript label."""

    def test_boot_scripts_labeled(self, all_target_labels: dict[str, list[str]]):
        boot_targets = {
            t: labels for t, labels in all_target_labels.items()
            if "cloud-hypervisor-boot:" in t and ":ch-boot-" in t
        }
        assert len(boot_targets) >= 8, f"Expected >=8 boot targets, got {len(boot_targets)}"
        for t, labels in boot_targets.items():
            assert "buckos:bootscript" in labels, f"{t} missing buckos:bootscript"


class TestChSystemImagesLabeled:
    """Verify image targets have buckos:image label."""

    def test_system_images_labeled(self, all_target_labels: dict[str, list[str]]):
        image_names = {"ch-minimal-rootfs", "ch-base-rootfs", "ch-full-rootfs",
                       "ch-initramfs", "ch-initramfs-virtiofs",
                       "ch-minimal-disk", "ch-base-disk", "ch-full-disk", "ch-full-disk-gpt"}
        image_targets = {
            t: labels for t, labels in all_target_labels.items()
            if "system/cloud-hypervisor:" in t
            and any(t.endswith(":" + n) for n in image_names)
        }
        for t, labels in image_targets.items():
            assert "buckos:image" in labels, f"{t} missing buckos:image"


class TestChUseFlags:
    """Verify USE flag resolution for cloud-hypervisor."""

    def test_defaults(self, buck2):
        """Default USE flags are io-uring + kvm."""
        flags = _uquery_attr(buck2, CH_TARGET, "use_flags")
        assert sorted(flags) == ["io-uring", "kvm"]

    def test_override_disable_kvm(self, buck2):
        """Disabling kvm via config-file removes it from resolved flags."""
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".buckconfig", delete=False
        ) as f:
            f.write("[use.cloud-hypervisor]\n  kvm = false\n")
            f.flush()
            flags = _uquery_attr(
                buck2, CH_TARGET, "use_flags",
                "--config-file", f.name,
            )
        assert "kvm" not in flags
        assert "io-uring" in flags

    def test_override_cargo_flags(self, buck2):
        """Disabling kvm removes kvm feature from CARGO_BUILD_FLAGS."""
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".buckconfig", delete=False
        ) as f:
            f.write("[use.cloud-hypervisor]\n  kvm = false\n")
            f.flush()
            env = _cquery_env(
                buck2, CH_TARGET,
                "--config-file", f.name,
            )
        cargo_flags = env.get("CARGO_BUILD_FLAGS", "")
        assert "kvm" not in cargo_flags
        assert "io_uring" in cargo_flags


# ---------------------------------------------------------------------------
# Tier 2: Build smoke test
# ---------------------------------------------------------------------------

@pytest.mark.slow
@pytest.mark.timeout(900)
def test_ch_binary_builds(ch_binary):
    """CH binary builds successfully via buck2."""
    assert ch_binary.exists(), f"CH binary not found at {ch_binary}"


@pytest.mark.slow
@pytest.mark.timeout(900)
def test_ch_boot_script_has_resolved_paths(buck2, repo_root):
    """Build ch-boot-direct-minimal and verify generated script has real paths."""
    target = "//packages/linux/boot/cloud-hypervisor-boot:ch-boot-direct-minimal"
    result = buck2(
        "build", "--show-output",
        HOST_TC, HOST_TC_VAL,
        target,
        timeout=900,
    )

    script_path = None
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line or line.startswith("["):
            continue
        parts = line.split(None, 1)
        if len(parts) == 2 and "ch-boot-direct-minimal" in parts[0]:
            script_path = repo_root / parts[1]

    assert script_path and script_path.exists(), (
        f"Boot script not found in build output: {result.stdout}"
    )
    content = script_path.read_text()
    assert "<build artifact" not in content, (
        "Script contains unresolved artifact references"
    )
    assert "KERNEL_DIR=" in content, "Script missing KERNEL_DIR variable"

    m = re.search(r'KERNEL_DIR="([^"]*)"', content)
    assert m, "Cannot find KERNEL_DIR assignment"
    kernel_dir = m.group(1)
    assert kernel_dir, "KERNEL_DIR is empty"
    assert "PLACEHOLDER" not in kernel_dir, (
        "KERNEL_DIR contains unresolved placeholder"
    )


# ---------------------------------------------------------------------------
# Tier 3: Runtime integration test
# ---------------------------------------------------------------------------

@pytest.mark.integration
@pytest.mark.timeout(1800)
def test_ch_boots_vm(buck2, repo_root):
    """Build CH + kernel + initramfs, boot a VM, verify serial output."""
    # Fail (not skip) if KVM is unavailable
    assert os.access("/dev/kvm", os.R_OK | os.W_OK), (
        "/dev/kvm not accessible — KVM required for CH integration test"
    )

    # Build all three artifacts
    result = buck2(
        "build", "--show-output",
        HOST_TC, HOST_TC_VAL,
        CH_TARGET,
        KERNEL_TARGET,
        INITRAMFS_TARGET,
        timeout=1800,
    )

    # Parse --show-output lines: "target path"
    artifacts = {}
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line or line.startswith("["):
            continue
        parts = line.split(None, 1)
        if len(parts) == 2:
            artifacts[parts[0]] = parts[1]

    # Resolve artifact paths
    ch_path = None
    kernel_path = None
    initramfs_path = None

    for target, path in artifacts.items():
        if ":cloud-hypervisor" in target and ":cloud-hypervisor-" not in target:
            ch_path = repo_root / path
        elif ":buckos-kernel-ch" in target:
            kernel_path = repo_root / path
        elif ":ch-initramfs" in target and "virtiofs" not in target and "xz" not in target:
            initramfs_path = repo_root / path

    assert ch_path and ch_path.exists(), f"CH binary not found in build output: {artifacts}"
    assert kernel_path, f"Kernel not found in build output: {artifacts}"
    assert initramfs_path, f"Initramfs not found in build output: {artifacts}"

    # Find cloud-hypervisor binary (output may be a package directory)
    if ch_path.is_dir():
        candidates = list(ch_path.glob("**/cloud-hypervisor"))
        assert candidates, f"No cloud-hypervisor binary found under {ch_path}"
        ch_bin = candidates[0]
    else:
        ch_bin = ch_path
    os.chmod(ch_bin, 0o755)

    # Find vmlinuz within kernel build output (may be a directory)
    if kernel_path.is_dir():
        candidates = list(kernel_path.glob("**/vmlinuz*")) + list(kernel_path.glob("**/bzImage"))
        assert candidates, f"No vmlinuz/bzImage found under {kernel_path}"
        kernel_bin = candidates[0]
    else:
        kernel_bin = kernel_path

    # Find initramfs cpio (may be a directory)
    if initramfs_path.is_dir():
        candidates = list(initramfs_path.glob("**/*.cpio.gz")) + list(initramfs_path.glob("**/initramfs*"))
        assert candidates, f"No initramfs cpio found under {initramfs_path}"
        initramfs_bin = candidates[0]
    else:
        initramfs_bin = initramfs_path

    # Size the VM generously but within CH limits
    import multiprocessing
    host_cpus = min(multiprocessing.cpu_count(), 16)
    host_mem_kb = 0
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("MemTotal:"):
                host_mem_kb = int(line.split()[1])
                break
    vm_mem_mb = min(max(256, int(host_mem_kb * 0.9 / 1024)), 4096)

    # Boot the VM
    cmd = [
        str(ch_bin),
        "--kernel", str(kernel_bin),
        "--initramfs", str(initramfs_bin),
        "--cmdline", "console=ttyS0 init=/init panic=-1",
        "--cpus", f"boot={host_cpus}",
        "--memory", f"size={vm_mem_mb}M",
        "--serial", "tty",
        "--console", "off",
    ]

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    output = ""
    # Use a kernel message — userspace tty output doesn't reach CH serial
    boot_string = "Run /init as init process"
    try:
        # Read stdout line by line with a timeout
        import selectors
        sel = selectors.DefaultSelector()
        sel.register(proc.stdout, selectors.EVENT_READ)

        deadline = 60  # seconds
        import time
        start = time.monotonic()

        while time.monotonic() - start < deadline:
            events = sel.select(timeout=max(0.1, deadline - (time.monotonic() - start)))
            for key, _ in events:
                line = key.fileobj.readline()
                if not line:
                    # Process exited
                    break
                output += line
                if boot_string in line:
                    # Success — VM booted
                    break
            if boot_string in output:
                break
            if proc.poll() is not None:
                break

        sel.close()
    finally:
        if proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()

    stderr = proc.stderr.read() if proc.stderr else ""
    assert boot_string in output, (
        f"Boot string not found in VM output.\n"
        f"Expected: {boot_string}\n"
        f"Got (last 2000 chars):\n{output[-2000:]}\n"
        f"Stderr (last 500 chars):\n{stderr[-500:]}"
    )
