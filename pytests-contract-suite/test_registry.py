"""`managers/registry.py` unit tests: the `$PMTEST_PROFILE` cargo knob (R8).

These are pure registry tests -- no cargo build, no network, no PM binary
ever runs. `_cargo_build` is exercised through a stubbed `subprocess.run`
so the argv it *would* run is asserted without invoking cargo.
"""

import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "managers"))
import registry  # noqa: E402  (pmtest root is not a package)


@pytest.fixture(autouse=True)
def _portuale_and_no_profile(monkeypatch):
    """Pin the entry and start every case from `PMTEST_PROFILE` unset."""
    monkeypatch.setenv("PMTEST_PM", "portuale")
    monkeypatch.delenv("PMTEST_PROFILE", raising=False)


def _record_cargo_build(monkeypatch):
    """Stub `subprocess.run`; return the list it records argv into."""
    calls = []

    def fake_run(argv, **kwargs):
        calls.append(argv)
        return None

    monkeypatch.setattr(registry.subprocess, "run", fake_run)
    return calls


# --- the profile value itself -------------------------------------------


def test_unset_profile_defaults_to_release(monkeypatch):
    monkeypatch.delenv("PMTEST_PROFILE", raising=False)
    assert registry.cargo_profile() == "release"


def test_empty_profile_defaults_to_release(monkeypatch):
    monkeypatch.setenv("PMTEST_PROFILE", "")
    assert registry.cargo_profile() == "release"


def test_zero_is_not_a_default_alias(monkeypatch):
    """Only unset/empty means default; `"0"` is a non-empty invalid value."""
    monkeypatch.setenv("PMTEST_PROFILE", "0")
    with pytest.raises(registry.RegistryError):
        registry.cargo_profile()


def test_invalid_profile_names_value_and_both_profiles(monkeypatch):
    monkeypatch.setenv("PMTEST_PROFILE", "bogus")
    with pytest.raises(registry.RegistryError) as excinfo:
        registry.cargo_profile()
    message = str(excinfo.value)
    assert "bogus" in message
    assert "debug" in message
    assert "release" in message


# --- declared_applet paths ------------------------------------------------


def test_default_applet_path_is_target_release(monkeypatch):
    monkeypatch.delenv("PMTEST_PROFILE", raising=False)
    path = str(registry.declared_applet("emerge"))
    assert "/target/release/portuale" in path


def test_debug_applet_path_is_target_debug(monkeypatch):
    monkeypatch.setenv("PMTEST_PROFILE", "debug")
    path = str(registry.declared_applet("emerge"))
    assert "/target/debug/portuale" in path
    assert "/target/release/" not in path


def test_explicit_release_applet_path_is_target_release(monkeypatch):
    monkeypatch.setenv("PMTEST_PROFILE", "release")
    path = str(registry.declared_applet("emerge"))
    assert "/target/release/portuale" in path


def test_harness_computed_path_is_profile_aware(monkeypatch):
    """The harness fallback path follows the profile too (no cargo run:
    `_provide` is stubbed, so the binary is never built or stat'd)."""
    monkeypatch.setenv("PMTEST_PROFILE", "debug")
    seen = {}

    def fake_provide(name, pm, package, binary, build=True):
        seen["binary"] = binary
        seen["package"] = package
        return binary

    monkeypatch.setattr(registry, "_provide", fake_provide)
    registry.harness("versions")
    assert seen["package"] == "versions-harness"
    assert str(seen["binary"]).endswith("/target/debug/versions-harness")


# --- cargo build flag -----------------------------------------------------


def test_release_build_passes_release_flag(monkeypatch):
    monkeypatch.delenv("PMTEST_PROFILE", raising=False)
    calls = _record_cargo_build(monkeypatch)
    registry._cargo_build(Path("/does/not/matter"), "portuale")
    assert calls == [["cargo", "build", "--release", "--package", "portuale"]]


def test_explicit_release_build_passes_release_flag(monkeypatch):
    monkeypatch.setenv("PMTEST_PROFILE", "release")
    calls = _record_cargo_build(monkeypatch)
    registry._cargo_build(Path("/does/not/matter"), "portuale")
    assert calls == [["cargo", "build", "--release", "--package", "portuale"]]


def test_debug_build_omits_release_flag(monkeypatch):
    monkeypatch.setenv("PMTEST_PROFILE", "debug")
    calls = _record_cargo_build(monkeypatch)
    registry._cargo_build(Path("/does/not/matter"), "portuale")
    assert calls == [["cargo", "build", "--package", "portuale"]]
    assert "--release" not in calls[0]


# --- yaml-declared path rewriting ----------------------------------------


def test_yaml_target_path_rewritten_under_debug(monkeypatch):
    monkeypatch.setenv("PMTEST_PROFILE", "debug")
    resolved = str(registry.resolve_path("../portuale/rust/target/release/portuale"))
    assert "/target/debug/portuale" in resolved
    assert "target/release" not in resolved


def test_yaml_target_path_unchanged_by_default(monkeypatch):
    monkeypatch.delenv("PMTEST_PROFILE", raising=False)
    resolved = str(registry.resolve_path("../portuale/rust/target/release/portuale"))
    assert resolved.endswith("/portuale/rust/target/release/portuale")


def test_yaml_debug_path_rewritten_under_release(monkeypatch):
    """The pin is a placeholder: either segment follows the active profile."""
    monkeypatch.setenv("PMTEST_PROFILE", "release")
    resolved = str(registry.resolve_path("../portuale/rust/target/debug/portuale"))
    assert "/target/release/portuale" in resolved


def test_non_cargo_path_is_left_untouched(monkeypatch):
    monkeypatch.setenv("PMTEST_PROFILE", "debug")
    assert str(registry.resolve_path("/usr/sbin/emerge")) == "/usr/sbin/emerge"


def test_similar_segments_are_not_rewritten(monkeypatch):
    """Only a whole `target/<profile>` path segment matches."""
    monkeypatch.setenv("PMTEST_PROFILE", "debug")
    for raw in ("/opt/mytarget/release/foo", "/opt/target/release-notes/foo"):
        assert str(registry.resolve_path(raw)) == raw
