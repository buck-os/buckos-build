"""QEMU IMA enforcement tests.

Boot a minimal custom kernel with IMA support in QEMU and verify:
- Signed binaries execute under IMA enforcement
- Unsigned binaries are rejected (EACCES) under IMA enforcement
- Unsigned binaries execute when IMA is off
"""
from __future__ import annotations

import gzip
import io
import os
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path

import pytest

KEYS_DIR = Path(__file__).resolve().parent.parent / "defs" / "keys"


# ---------------------------------------------------------------------------
# Skip conditions
# ---------------------------------------------------------------------------

def _check_tool(name: str) -> str | None:
    return shutil.which(name)


def _check_kvm() -> bool:
    return os.access("/dev/kvm", os.R_OK | os.W_OK)


needs_qemu = pytest.mark.skipif(
    not _check_tool("qemu-system-x86_64"),
    reason="qemu-system-x86_64 not on PATH",
)
needs_kvm = pytest.mark.skipif(
    not _check_kvm(),
    reason="/dev/kvm not accessible",
)
needs_evmctl = pytest.mark.skipif(
    not _check_tool("evmctl"),
    reason="evmctl not on PATH",
)
needs_e2fs = pytest.mark.skipif(
    not (_check_tool("mke2fs") and _check_tool("debugfs")),
    reason="mke2fs/debugfs not on PATH",
)


# ---------------------------------------------------------------------------
# buck2 build helper
# ---------------------------------------------------------------------------

def _buck2_build(repo_root: Path, target: str, timeout: int = 600) -> Path:
    """Build a target and return the output path."""
    buck2_path = shutil.which("buck2")
    if buck2_path is None:
        pytest.skip("buck2 not found on PATH")

    iso_name = "ima-" + uuid.uuid4().hex[:12]
    result = subprocess.run(
        ["buck2", "--isolation-dir", iso_name,
         "build", "--show-full-output",
         "-c", "buckos.use_host_toolchain=true",
         target],
        cwd=repo_root, capture_output=True, text=True, timeout=timeout,
    )
    assert result.returncode == 0, (
        f"buck2 build failed for {target}:\n{result.stderr}"
    )
    for line in result.stdout.strip().splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2:
            return Path(parts[1])
    pytest.fail(f"Could not parse output path from: {result.stdout}")


# ---------------------------------------------------------------------------
# cpio newc archive builder (pure Python)
# ---------------------------------------------------------------------------

def _cpio_header(
    ino: int, mode: int, uid: int, gid: int, nlink: int,
    mtime: int, filesize: int, devmajor: int, devminor: int,
    rdevmajor: int, rdevminor: int, namesize: int,
) -> bytes:
    """Build a cpio newc (070701) header."""
    return (
        f"070701"
        f"{ino:08X}"
        f"{mode:08X}"
        f"{uid:08X}"
        f"{gid:08X}"
        f"{nlink:08X}"
        f"{mtime:08X}"
        f"{filesize:08X}"
        f"{devmajor:08X}"
        f"{devminor:08X}"
        f"{rdevmajor:08X}"
        f"{rdevminor:08X}"
        f"{namesize:08X}"
        f"{0:08X}"  # check
    ).encode("ascii")


def _cpio_entry(name: str, data: bytes, mode: int, ino: int, nlink: int = 1) -> bytes:
    """Single cpio newc entry (header + name + padding + data + padding)."""
    namesize = len(name) + 1  # includes trailing NUL
    hdr = _cpio_header(
        ino=ino, mode=mode, uid=0, gid=0, nlink=nlink,
        mtime=0, filesize=len(data), devmajor=0, devminor=0,
        rdevmajor=0, rdevminor=0, namesize=namesize,
    )
    buf = io.BytesIO()
    buf.write(hdr)
    buf.write(name.encode("ascii") + b"\x00")
    # pad to 4-byte boundary after header + name
    pos = len(hdr) + namesize
    if pos % 4:
        buf.write(b"\x00" * (4 - pos % 4))
    buf.write(data)
    # pad data to 4-byte boundary
    if len(data) % 4:
        buf.write(b"\x00" * (4 - len(data) % 4))
    return buf.getvalue()


def _cpio_dir(name: str, ino: int) -> bytes:
    """Directory entry in cpio newc."""
    return _cpio_entry(name, b"", mode=0o40755, ino=ino, nlink=2)


def _cpio_trailer() -> bytes:
    return _cpio_entry("TRAILER!!!", b"", mode=0, ino=0)


def build_initramfs(init_path: Path, cert_der_path: Path) -> bytes:
    """Build a gzipped cpio newc initramfs with /init and /etc/keys/x509_ima.der."""
    init_data = init_path.read_bytes()
    cert_data = cert_der_path.read_bytes()

    ino = 1
    entries = io.BytesIO()

    entries.write(_cpio_dir(".", ino)); ino += 1
    for d in ("dev", "etc", "etc/keys", "mnt", "proc", "sys"):
        entries.write(_cpio_dir(d, ino)); ino += 1
    entries.write(_cpio_entry("etc/keys/x509_ima.der", cert_data, mode=0o100644, ino=ino)); ino += 1
    entries.write(_cpio_entry("init", init_data, mode=0o100755, ino=ino)); ino += 1
    entries.write(_cpio_trailer())

    raw = entries.getvalue()
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as gz:
        gz.write(raw)
    return buf.getvalue()


# ---------------------------------------------------------------------------
# ext4 image builder (mke2fs + debugfs, no root required)
# ---------------------------------------------------------------------------

def build_ext4_image(
    binary_path: Path,
    tmp_dir: Path,
    signed: bool = False,
    key_path: Path | None = None,
) -> Path:
    """Create a small ext4 image with /ima-test, optionally IMA-signed."""
    work = Path(tempfile.mkdtemp(dir=tmp_dir))
    img = work / "disk.img"

    # Create empty ext4 image
    empty_dir = work / "empty"
    empty_dir.mkdir()
    subprocess.run(
        ["mke2fs", "-t", "ext4", "-d", str(empty_dir), str(img), "8M"],
        check=True, capture_output=True,
    )

    # Build debugfs batch script
    batch = work / "debugfs.cmds"
    cmds = [
        f"write {binary_path} /ima-test",
        "set_inode_field /ima-test mode 0100755",
    ]

    if signed:
        assert key_path is not None
        # evmctl ima_sign --sigfile writes .sig file but also tries (and fails)
        # to set the xattr without root — ignore the exit code, just verify
        # the .sig file was created
        local_bin = work / "ima-test"
        shutil.copy2(binary_path, local_bin)
        subprocess.run(
            ["evmctl", "ima_sign", "--sigfile", "--key", str(key_path),
             str(local_bin)],
            capture_output=True,
        )
        sig_file = Path(str(local_bin) + ".sig")
        assert sig_file.exists(), f"evmctl did not create {sig_file}"
        cmds.append(f"ea_set /ima-test security.ima -f {sig_file}")

    batch.write_text("\n".join(cmds) + "\n")

    subprocess.run(
        ["debugfs", "-w", "-f", str(batch), str(img)],
        check=True, capture_output=True,
    )
    return img


# ---------------------------------------------------------------------------
# QEMU runner
# ---------------------------------------------------------------------------

def run_qemu(
    kernel: Path,
    initramfs_data: bytes,
    disk: Path,
    cmdline_extra: str,
    tmp_dir: Path,
    timeout: int = 30,
) -> str:
    """Boot QEMU with the given kernel/initramfs/disk and return serial output."""
    work = Path(tempfile.mkdtemp(dir=tmp_dir))
    initrd = work / "initramfs.cpio.gz"
    initrd.write_bytes(initramfs_data)

    cmd = [
        "qemu-system-x86_64",
        "-kernel", str(kernel),
        "-initrd", str(initrd),
        "-drive", f"file={disk},format=raw,if=virtio,readonly=on",
        "-append", f"console=ttyS0 panic=-1 {cmdline_extra}",
        "-nographic",
        "-no-reboot", "-m", "256M",
        "-enable-kvm", "-cpu", "host",
    ]
    result = subprocess.run(
        cmd, capture_output=True, text=True, timeout=timeout,
    )
    return result.stdout + result.stderr


# ---------------------------------------------------------------------------
# Session-scoped fixtures — buck2 builds artifacts, caches in buck-out
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def ima_tmp_dir(tmp_path_factory) -> Path:
    """Shared temp dir for per-test ephemeral artifacts (disk images, initramfs)."""
    return tmp_path_factory.mktemp("ima-qemu")


@pytest.fixture(scope="session")
def ima_cert_der(ima_tmp_dir: Path) -> Path:
    """DER-encoded certificate for initramfs."""
    pem = KEYS_DIR / "ima-test.x509"
    if not pem.exists():
        pytest.skip("IMA test cert not found")
    der = ima_tmp_dir / "ima-test.der"
    subprocess.run(
        ["openssl", "x509", "-in", str(pem),
         "-outform", "DER", "-out", str(der)],
        check=True, capture_output=True,
    )
    return der


@pytest.fixture(scope="session")
def ima_key() -> Path:
    p = KEYS_DIR / "ima-test.priv"
    if not p.exists():
        pytest.skip("IMA test private key not found")
    return p


@pytest.fixture(scope="session")
def ima_test_binary(repo_root: Path) -> Path:
    """Static test binary built by buck2."""
    return _buck2_build(repo_root, "//tests/fixtures/ima-test:ima-test-binary")


@pytest.fixture(scope="session")
def ima_init_binary(repo_root: Path) -> Path:
    """Static init binary built by buck2."""
    return _buck2_build(repo_root, "//tests/fixtures/ima-test:ima-init")


@pytest.fixture(scope="session")
def ima_kernel(repo_root: Path) -> Path:
    """Minimal IMA kernel built by buck2."""
    return _buck2_build(
        repo_root, "//tests/fixtures/ima-test:ima-kernel", timeout=900,
    )


# ---------------------------------------------------------------------------
# Session cleanup — kill test buck2 daemons
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session", autouse=True)
def _cleanup_ima_isolation_dirs(repo_root: Path):
    """Kill ima-* test daemons after all tests."""
    yield
    buck_out = repo_root / "buck-out"
    if buck_out.exists():
        for d in buck_out.iterdir():
            if d.is_dir() and d.name.startswith("ima-"):
                subprocess.run(
                    ["buck2", "--isolation-dir", d.name, "kill"],
                    cwd=repo_root, capture_output=True, timeout=30,
                )
                shutil.rmtree(d, ignore_errors=True)


# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

@pytest.mark.slow
@needs_qemu
@needs_kvm
@needs_evmctl
@needs_e2fs
class TestImaQemu:
    """IMA enforcement end-to-end tests via QEMU."""

    def test_enforced_signed_binary_runs(
        self, ima_kernel, ima_test_binary, ima_init_binary,
        ima_cert_der, ima_key, ima_tmp_dir,
    ):
        """IMA enforce + signed binary -> exec succeeds."""
        disk = build_ext4_image(
            ima_test_binary, ima_tmp_dir, signed=True, key_path=ima_key,
        )
        initramfs = build_initramfs(ima_init_binary, ima_cert_der)
        output = run_qemu(
            ima_kernel, initramfs, disk,
            "ima_appraise=enforce ima_test_mode=enforce_signed",
            ima_tmp_dir,
        )
        assert "IMA-TEST-PASS" in output, f"Binary did not run:\n{output}"
        assert "IMA-RESULT:PASS" in output, f"Init reported failure:\n{output}"

    def test_enforced_unsigned_binary_rejected(
        self, ima_kernel, ima_test_binary, ima_init_binary,
        ima_cert_der, ima_tmp_dir,
    ):
        """IMA enforce + unsigned binary -> EACCES."""
        disk = build_ext4_image(ima_test_binary, ima_tmp_dir, signed=False)
        initramfs = build_initramfs(ima_init_binary, ima_cert_der)
        output = run_qemu(
            ima_kernel, initramfs, disk,
            "ima_appraise=enforce ima_test_mode=enforce_unsigned",
            ima_tmp_dir,
        )
        assert "IMA-TEST-PASS" not in output, (
            f"Unsigned binary should not have run:\n{output}"
        )
        assert "IMA-RESULT:PASS" in output, (
            f"Init should report EACCES as expected:\n{output}"
        )

    def test_disabled_unsigned_binary_runs(
        self, ima_kernel, ima_test_binary, ima_init_binary,
        ima_cert_der, ima_tmp_dir,
    ):
        """IMA off + unsigned binary -> exec succeeds."""
        disk = build_ext4_image(ima_test_binary, ima_tmp_dir, signed=False)
        initramfs = build_initramfs(ima_init_binary, ima_cert_der)
        output = run_qemu(
            ima_kernel, initramfs, disk,
            "ima_appraise=off ima_test_mode=noima",
            ima_tmp_dir,
        )
        assert "IMA-TEST-PASS" in output, f"Binary did not run:\n{output}"
        assert "IMA-RESULT:PASS" in output, f"Init reported failure:\n{output}"
