"""Tests for .buckconfig-based USE flag resolution across all build systems.

Verifies the resolution order:
  1. Package use_defaults
  2. Global [use] section
  3. Per-package [use.PKGNAME] section

Also verifies:
  - use_dep() conditional dependency resolution
  - use_configure_args() → EXTRA_ECONF (autotools)
  - use_cmake_options() → CMAKE_EXTRA_ARGS (cmake)
  - use_meson_options() → MESON_EXTRA_ARGS (meson)
  - use_cargo_args() → CARGO_BUILD_FLAGS (cargo)
  - use_go_build_args() → GO_BUILD_FLAGS (go)
  - provenance/slsa read from [use] section
  - [use_expand] section parsing

Uses buck2 uquery/cquery/audit (no builds, no gcc).
"""
from __future__ import annotations

import json
import re
import tempfile

import pytest

TARGET = "//tests/fixtures/use-flags:test-use-flags"
CMAKE_TARGET = "//tests/fixtures/use-flags:test-cmake-use"
MESON_TARGET = "//tests/fixtures/use-flags:test-meson-use"
CARGO_TARGET = "//tests/fixtures/use-flags:test-cargo-use"
GO_TARGET = "//tests/fixtures/use-flags:test-go-use"

HOST_TC = "-c"
HOST_TC_VAL = "buckos.use_host_toolchain=true"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _uquery_use_flags(buck2, target: str = TARGET, *extra_args: str) -> list[str]:
    """Run buck2 uquery and extract the use_flags attribute."""
    result = buck2(
        "uquery",
        target,
        "--output-attribute", "use_flags",
        "--json",
        *extra_args,
        check=True,
    )
    data = json.loads(result.stdout)
    for key, attrs in data.items():
        if key.endswith(target.lstrip("/")) or key == target:
            return sorted(attrs.get("use_flags", []))
    return []


def _uquery_with_config_file(buck2, ini_content: str, target: str = TARGET) -> list[str]:
    """Write a temp buckconfig file and query with --config-file."""
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".buckconfig", delete=False
    ) as f:
        f.write(ini_content)
        f.flush()
        return _uquery_use_flags(buck2, target, "--config-file", f.name)


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


def _cquery_deps(buck2, target: str, *extra_args: str) -> list[str]:
    """Run buck2 cquery deps() and return the target list."""
    result = buck2(
        "cquery", f"deps({target})",
        "--json",
        HOST_TC, HOST_TC_VAL,
        *extra_args,
        check=True,
    )
    text = result.stdout
    m = re.search(r"\[", text)
    if m:
        return json.loads(text[m.start():])
    return []


# ---------------------------------------------------------------------------
# Smoke test
# ---------------------------------------------------------------------------

def test_target_count(buck2):
    """Smoke test: the migration must not break target parsing."""
    result = buck2("targets", "//...", timeout=300)
    targets = [l for l in result.stdout.splitlines() if l.strip()]
    assert len(targets) > 7000, (
        f"Expected >7000 targets, got {len(targets)}"
    )


# ---------------------------------------------------------------------------
# USE flag resolution layers (autotools fixture)
# ---------------------------------------------------------------------------

class TestUseDefaults:
    """Layer 1: package use_defaults with no buckconfig overrides."""

    def test_defaults_only(self, buck2):
        """With all [use] flags unset, only use_defaults should be active."""
        flags = _uquery_use_flags(
            buck2, TARGET,
            "--config", "use.ssl=",
            "--config", "use.ipv6=",
            "--config", "use.threads=",
            "--config", "use.unicode=",
        )
        assert "ssl" in flags


class TestGlobalEnable:
    """Layer 2: global [use] section enables a flag."""

    def test_global_enable_zstd(self, buck2):
        """[use] zstd = true should add zstd to effective flags."""
        flags = _uquery_use_flags(
            buck2, TARGET,
            "--config", "use.zstd=true",
        )
        assert "zstd" in flags

    def test_global_enable_debug(self, buck2):
        """[use] debug = true should add debug."""
        flags = _uquery_use_flags(
            buck2, TARGET,
            "--config", "use.debug=true",
        )
        assert "debug" in flags


class TestGlobalDisable:
    """Layer 2: global [use] section disables a flag from use_defaults."""

    def test_global_disable_ssl(self, buck2):
        """[use] ssl = false should remove ssl despite use_defaults."""
        flags = _uquery_use_flags(
            buck2, TARGET,
            "--config", "use.ssl=false",
        )
        assert "ssl" not in flags


class TestPerPackageOverride:
    """Layer 3: [use.PKGNAME] overrides global [use].

    Per-package sections have dots in section names ([use.test-use-flags])
    which can't be expressed via --config key=val. We use --config-file.
    """

    def test_per_package_enable(self, buck2):
        """[use] ssl = false + [use.test-use-flags] ssl = true -> ssl enabled."""
        flags = _uquery_with_config_file(buck2, "\n".join([
            "[use]",
            "  ssl = false",
            "[use.test-use-flags]",
            "  ssl = true",
        ]))
        assert "ssl" in flags

    def test_per_package_disable(self, buck2):
        """[use] ssl = true + [use.test-use-flags] ssl = false -> ssl disabled."""
        flags = _uquery_with_config_file(buck2, "\n".join([
            "[use]",
            "  ssl = true",
            "[use.test-use-flags]",
            "  ssl = false",
        ]))
        assert "ssl" not in flags


class TestUnsetPassthrough:
    """Unset keys in [use.PKGNAME] fall through to global [use]."""

    def test_unset_falls_through(self, buck2):
        """[use] zstd = true, no [use.test-use-flags] zstd -> zstd enabled."""
        flags = _uquery_use_flags(
            buck2, TARGET,
            "--config", "use.zstd=true",
        )
        assert "zstd" in flags


# ---------------------------------------------------------------------------
# use_dep() — conditional dependency resolution
# ---------------------------------------------------------------------------

class TestUseDep:
    """use_dep() adds/removes deps based on enabled USE flags."""

    def test_ssl_enabled_includes_openssl(self, buck2):
        """With ssl default, openssl should be in deps."""
        deps = _cquery_deps(buck2, TARGET)
        assert any("openssl" in d for d in deps)

    def test_ssl_disabled_excludes_openssl(self, buck2):
        """Disabling ssl should remove openssl from deps."""
        deps = _cquery_deps(buck2, TARGET, "-c", "use.ssl=false")
        assert not any("openssl" in d for d in deps)

    def test_zstd_enabled_includes_zstd(self, buck2):
        """Enabling zstd should add zstd dep."""
        deps = _cquery_deps(buck2, TARGET, "-c", "use.zstd=true")
        assert any("zstd" in d for d in deps)

    def test_zstd_disabled_excludes_zstd(self, buck2):
        """With zstd off (default), zstd dep should not be present."""
        deps = _cquery_deps(buck2, TARGET)
        assert not any("/zstd:" in d for d in deps)


# ---------------------------------------------------------------------------
# use_configure_args() — autotools EXTRA_ECONF
# ---------------------------------------------------------------------------

class TestUseConfigureArgs:
    """use_configure_args() emits EXTRA_ECONF for autotools_package."""

    def test_default_configure_args(self, buck2):
        """Default (ssl on, zstd/debug off) → --with-ssl --without-zstd --disable-debug."""
        env = _cquery_env(buck2, TARGET)
        econf = env.get("EXTRA_ECONF", "")
        assert "--with-ssl" in econf
        assert "--without-zstd" in econf
        assert "--disable-debug" in econf

    def test_enable_all(self, buck2):
        """All flags on → --with-ssl --with-zstd --enable-debug."""
        env = _cquery_env(buck2, TARGET,
                          "-c", "use.zstd=true", "-c", "use.debug=true")
        econf = env.get("EXTRA_ECONF", "")
        assert "--with-ssl" in econf
        assert "--with-zstd" in econf
        assert "--enable-debug" in econf
        assert "--without" not in econf
        assert "--disable" not in econf

    def test_disable_all(self, buck2):
        """All flags off → --without-ssl --without-zstd --disable-debug."""
        env = _cquery_env(buck2, TARGET, "-c", "use.ssl=false")
        econf = env.get("EXTRA_ECONF", "")
        assert "--without-ssl" in econf
        assert "--without-zstd" in econf
        assert "--disable-debug" in econf


# ---------------------------------------------------------------------------
# use_cmake_options() — CMAKE_EXTRA_ARGS
# ---------------------------------------------------------------------------

class TestUseCmakeOptions:
    """use_cmake_options() emits CMAKE_EXTRA_ARGS for cmake_package."""

    def test_default_cmake_args(self, buck2):
        """Default (ssl on) → -DWITH_SSL=ON -DWITH_ZSTD=OFF -DENABLE_DEBUG=OFF."""
        env = _cquery_env(buck2, CMAKE_TARGET)
        args = env.get("CMAKE_EXTRA_ARGS", "")
        assert "-DWITH_SSL=ON" in args
        assert "-DWITH_ZSTD=OFF" in args
        assert "-DENABLE_DEBUG=OFF" in args

    def test_enable_all_cmake(self, buck2):
        """All on → all =ON."""
        env = _cquery_env(buck2, CMAKE_TARGET,
                          "-c", "use.zstd=true", "-c", "use.debug=true")
        args = env.get("CMAKE_EXTRA_ARGS", "")
        assert "-DWITH_SSL=ON" in args
        assert "-DWITH_ZSTD=ON" in args
        assert "-DENABLE_DEBUG=ON" in args

    def test_disable_ssl_cmake(self, buck2):
        """ssl off → -DWITH_SSL=OFF."""
        env = _cquery_env(buck2, CMAKE_TARGET, "-c", "use.ssl=false")
        args = env.get("CMAKE_EXTRA_ARGS", "")
        assert "-DWITH_SSL=OFF" in args

    def test_cmake_deps_follow_flags(self, buck2):
        """cmake use_deps resolves same as autotools."""
        deps = _cquery_deps(buck2, CMAKE_TARGET)
        assert any("openssl" in d for d in deps)
        deps_off = _cquery_deps(buck2, CMAKE_TARGET, "-c", "use.ssl=false")
        assert not any("openssl" in d for d in deps_off)


# ---------------------------------------------------------------------------
# use_meson_options() — MESON_EXTRA_ARGS
# ---------------------------------------------------------------------------

class TestUseMesonOptions:
    """use_meson_options() emits MESON_EXTRA_ARGS for meson_package."""

    def test_default_meson_args(self, buck2):
        """Default (ssl on) → -Dssl=enabled -Dzstd=disabled -Ddebug=disabled."""
        env = _cquery_env(buck2, MESON_TARGET)
        args = env.get("MESON_EXTRA_ARGS", "")
        assert "-Dssl=enabled" in args
        assert "-Dzstd=disabled" in args
        assert "-Ddebug=disabled" in args

    def test_enable_all_meson(self, buck2):
        """All on → all =enabled."""
        env = _cquery_env(buck2, MESON_TARGET,
                          "-c", "use.zstd=true", "-c", "use.debug=true")
        args = env.get("MESON_EXTRA_ARGS", "")
        assert "-Dssl=enabled" in args
        assert "-Dzstd=enabled" in args
        assert "-Ddebug=enabled" in args

    def test_disable_ssl_meson(self, buck2):
        """ssl off → -Dssl=disabled."""
        env = _cquery_env(buck2, MESON_TARGET, "-c", "use.ssl=false")
        args = env.get("MESON_EXTRA_ARGS", "")
        assert "-Dssl=disabled" in args

    def test_meson_deps_follow_flags(self, buck2):
        """meson use_deps resolves same as autotools."""
        deps = _cquery_deps(buck2, MESON_TARGET)
        assert any("openssl" in d for d in deps)
        deps_off = _cquery_deps(buck2, MESON_TARGET, "-c", "use.ssl=false")
        assert not any("openssl" in d for d in deps_off)


# ---------------------------------------------------------------------------
# use_cargo_args() — CARGO_BUILD_FLAGS
# ---------------------------------------------------------------------------

class TestUseCargoArgs:
    """use_cargo_args() emits CARGO_BUILD_FLAGS for cargo_package."""

    def test_default_cargo_flags(self, buck2):
        """Default (ssl on) → --features=openssl-tls."""
        env = _cquery_env(buck2, CARGO_TARGET)
        flags = env.get("CARGO_BUILD_FLAGS", "")
        assert "openssl-tls" in flags

    def test_enable_multiple_cargo(self, buck2):
        """ssl + zstd → --features=openssl-tls,zstd-compression."""
        env = _cquery_env(buck2, CARGO_TARGET, "-c", "use.zstd=true")
        flags = env.get("CARGO_BUILD_FLAGS", "")
        assert "openssl-tls" in flags
        assert "zstd-compression" in flags

    def test_no_flags_cargo(self, buck2):
        """No features enabled → --no-default-features only."""
        env = _cquery_env(buck2, CARGO_TARGET, "-c", "use.ssl=false")
        flags = env.get("CARGO_BUILD_FLAGS", "")
        assert "--no-default-features" in flags
        assert "openssl-tls" not in flags

    def test_cargo_deps_follow_flags(self, buck2):
        """cargo use_deps resolves same as autotools."""
        deps = _cquery_deps(buck2, CARGO_TARGET)
        assert any("openssl" in d for d in deps)
        deps_off = _cquery_deps(buck2, CARGO_TARGET, "-c", "use.ssl=false")
        assert not any("openssl" in d for d in deps_off)


# ---------------------------------------------------------------------------
# use_go_build_args() — GO_BUILD_FLAGS
# ---------------------------------------------------------------------------

class TestUseGoBuildArgs:
    """use_go_build_args() emits GO_BUILD_FLAGS for go_package."""

    def test_default_go_flags(self, buck2):
        """Default (ssl on) → -tags=with_ssl."""
        env = _cquery_env(buck2, GO_TARGET)
        flags = env.get("GO_BUILD_FLAGS", "")
        assert "with_ssl" in flags

    def test_enable_multiple_go(self, buck2):
        """ssl + zstd → -tags=with_ssl,with_zstd."""
        env = _cquery_env(buck2, GO_TARGET, "-c", "use.zstd=true")
        flags = env.get("GO_BUILD_FLAGS", "")
        assert "with_ssl" in flags
        assert "with_zstd" in flags

    def test_no_flags_go(self, buck2):
        """No flags → no GO_BUILD_FLAGS env var."""
        env = _cquery_env(buck2, GO_TARGET, "-c", "use.ssl=false")
        assert "GO_BUILD_FLAGS" not in env

    def test_go_deps_follow_flags(self, buck2):
        """go use_deps resolves same as autotools."""
        deps = _cquery_deps(buck2, GO_TARGET)
        assert any("openssl" in d for d in deps)
        deps_off = _cquery_deps(buck2, GO_TARGET, "-c", "use.ssl=false")
        assert not any("openssl" in d for d in deps_off)


# ---------------------------------------------------------------------------
# provenance/slsa via [use] section
# ---------------------------------------------------------------------------

class TestProvenanceSlsaConfig:
    """provenance and slsa are read from [use] section in .buckconfig."""

    def test_provenance_readable(self, buck2):
        """buck2 audit config returns [use] provenance."""
        result = buck2("audit", "config", "use.provenance", check=True)
        assert "provenance" in result.stdout

    def test_slsa_readable(self, buck2):
        """buck2 audit config returns [use] slsa."""
        result = buck2("audit", "config", "use.slsa", check=True)
        assert "slsa" in result.stdout

    def test_provenance_override(self, buck2):
        """--config use.provenance=true overrides default."""
        result = buck2(
            "audit", "config", "use.provenance",
            "--config", "use.provenance=true",
            check=True,
        )
        assert "true" in result.stdout.lower()

    def test_slsa_override(self, buck2):
        """--config use.slsa=true overrides default."""
        result = buck2(
            "audit", "config", "use.slsa",
            "--config", "use.slsa=true",
            check=True,
        )
        assert "true" in result.stdout.lower()


# ---------------------------------------------------------------------------
# USE_EXPAND
# ---------------------------------------------------------------------------

class TestUseExpand:
    """[use_expand] section provides comma-separated multi-value variables."""

    def test_video_cards_readable(self, buck2):
        """buck2 audit config returns [use_expand] video_cards."""
        result = buck2(
            "audit", "config", "use_expand.video_cards",
            check=True,
        )
        assert "video_cards" in result.stdout
        assert "fbdev" in result.stdout
        assert "vesa" in result.stdout

    def test_input_devices_readable(self, buck2):
        """buck2 audit config returns [use_expand] input_devices."""
        result = buck2(
            "audit", "config", "use_expand.input_devices",
            check=True,
        )
        assert "input_devices" in result.stdout
        assert "evdev" in result.stdout
        assert "libinput" in result.stdout

    def test_use_expand_override(self, buck2):
        """--config can override [use_expand] values."""
        result = buck2(
            "audit", "config", "use_expand.video_cards",
            "--config", "use_expand.video_cards=amdgpu,radeonsi",
            check=True,
        )
        assert "amdgpu" in result.stdout
        assert "radeonsi" in result.stdout

    def test_use_expand_empty(self, buck2):
        """Empty [use_expand] value is valid."""
        result = buck2(
            "audit", "config", "use_expand.video_cards",
            "--config", "use_expand.video_cards=",
            check=True,
        )
        # Should not contain the default values
        assert "fbdev" not in result.stdout
