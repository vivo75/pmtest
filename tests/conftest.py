import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

import corpus

try:
    import yaml
except ImportError:  # pragma: no cover - PyYAML is a documented host prereq
    yaml = None

REPO_ROOT = Path(__file__).resolve().parents[1]
# PM registry: which package manager is under test is decided here, not
# by hardcoded paths. The active entry is selected via PMTEST_PM
# (default: "portuale"); see managers/README.md.
MANAGERS_YAML = REPO_ROOT / "managers" / "managers.yaml"
DEFAULT_PM = "portuale"
VERSIONS_PYTHON_HARNESS = REPO_ROOT / "python" / "versions_harness.py"
ATOM_PYTHON_HARNESS = REPO_ROOT / "python" / "atom_harness.py"
USE_REDUCE_PYTHON_HARNESS = REPO_ROOT / "python" / "use_reduce_harness.py"
REQUIRED_USE_PYTHON_HARNESS = REPO_ROOT / "python" / "required_use_harness.py"
FIXTURES_ROOT = REPO_ROOT / "fixtures"

# Config variables portuale now honours from the process environment
# (real `config.regenerate()`'s `env` USE_ORDER layer -- see
# portage-profile's `ENV_INCREMENTAL_VARS`/`ENV_SCALAR_VARS`). A test
# runner's own environment must not leak into the fixture config, so
# these are stripped process-wide for the whole test session; a test
# that specifically exercises an env override sets the var explicitly.
_ENV_CONFIG_VARS = (
    "USE", "ACCEPT_KEYWORDS", "USE_EXPAND", "USE_EXPAND_UNPREFIXED",
    "USE_EXPAND_IMPLICIT", "USE_EXPAND_HIDDEN", "IUSE_IMPLICIT",
    "ACCEPT_LICENSE", "ACCEPT_PROPERTIES", "ACCEPT_RESTRICT",
    "PKGDIR", "PORTAGE_LOGDIR", "PORTAGE_BINHOST", "PORTAGE_NICENESS",
    "PORTAGE_IONICE_COMMAND", "PORTAGE_SCHEDULING_POLICY",
    "PORTAGE_SCHEDULING_PRIORITY", "PORTAGE_ELOG_SYSTEM", "PORTAGE_ELOG_CLASSES",
    "PORTAGE_ELOG_MAILURI", "FEATURES", "CHOST", "CBUILD", "CTARGET",
    "CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "FFLAGS", "FCFLAGS",
    "MAKEOPTS", "EMERGE_DEFAULT_OPTS", "PORTAGE_RSYNC_EXTRA_OPTS",
    "GENTOO_MIRRORS", "VIDEO_CARDS", "PYTHON_TARGETS", "PYTHON_SINGLE_TARGET",
    "LINGUAS", "L10N", "CPU_FLAGS_X86", "ELIBC", "KERNEL", "USERLAND", "ABI_X86",
)


@pytest.fixture(scope="session", autouse=True)
def _isolate_config_env():
    """Strip any inherited make.conf-style config vars for the session."""
    for name in _ENV_CONFIG_VARS:
        os.environ.pop(name, None)
    yield


_registry_cache = None


def _registry():
    """The `pms:` mapping from managers/managers.yaml, loaded once."""
    global _registry_cache
    if _registry_cache is None:
        if yaml is None:
            pytest.fail("PyYAML is required to read managers/managers.yaml")
        try:
            data = yaml.safe_load(MANAGERS_YAML.read_text())
        except FileNotFoundError:
            pytest.fail(f"PM registry not found: {MANAGERS_YAML}")
        _registry_cache = (data or {}).get("pms") or {}
    return _registry_cache


def _active_pm():
    """(name, entry) of the PM selected via PMTEST_PM."""
    name = os.environ.get("PMTEST_PM", DEFAULT_PM)
    reg = _registry()
    if name not in reg:
        pytest.fail(
            f"PMTEST_PM={name!r} is not in managers/managers.yaml "
            f"(available: {', '.join(sorted(reg)) or 'none'})"
        )
    return name, reg[name] or {}


def _resolve_registry_path(raw):
    """A registry path: absolute stays, relative resolves against pmtest root."""
    p = Path(os.path.expandvars(os.path.expanduser(str(raw))))
    return p if p.is_absolute() else REPO_ROOT / p


def _pm_rust_dir(pm):
    """Cargo workspace dir for entries built from source (None if prebuilt)."""
    if pm.get("rust_dir"):
        return _resolve_registry_path(pm["rust_dir"])
    if pm.get("repo"):
        return _resolve_registry_path(pm["repo"]) / "rust"
    return None


def _cargo_build(rust_dir, package):
    subprocess.run(
        ["cargo", "build", "--release", "--package", package],
        cwd=rust_dir,
        check=True,
    )
    return rust_dir / "target" / "release" / package


def _ensure_built(name, pm, package, binary):
    """Return `binary`, building `package` first if needed."""
    if binary.exists():
        return binary
    rust_dir = _pm_rust_dir(pm)
    if rust_dir is None:
        pytest.skip(
            f"PM {name!r}: {binary} not found and the registry entry "
            "has no repo to build it from"
        )
    if shutil.which("cargo") is None:
        pytest.skip(f"PM {name!r}: {binary} not built and cargo not available")
    _cargo_build(rust_dir, package)
    if not binary.exists():
        pytest.fail(f"PM {name!r}: cargo build of {package} produced no {binary}")
    return binary


_HARNESS_PACKAGES = {
    "versions": "versions-harness",
    "atom": "atom-harness",
    "use_reduce": "use-reduce-harness",
    "required_use": "required-use-harness",
}


def _pm_harness(harness):
    """Neutral CLI harness binary of the active PM (skips if it ships none)."""
    name, pm = _active_pm()
    package = _HARNESS_PACKAGES[harness]
    if pm.get(f"{harness}_harness"):
        binary = _resolve_registry_path(pm[f"{harness}_harness"])
    else:
        rust_dir = _pm_rust_dir(pm)
        if rust_dir is None:
            pytest.skip(
                f"PM {name!r} ships no {package} harness "
                "(no repo in registry) -- harness contract not applicable"
            )
        binary = rust_dir / "target" / "release" / package
    return _ensure_built(name, pm, package, binary)


def _pm_applet(kind):
    """emerge/ebuild/mrg entry point of the active PM."""
    name, pm = _active_pm()
    package = pm.get("package", "portuale")
    if pm.get(kind):
        binary = _resolve_registry_path(pm[kind])
    else:
        rust_dir = _pm_rust_dir(pm)
        if rust_dir is None:
            pytest.skip(f"PM {name!r}: no {kind} path and no repo in registry")
        binary = rust_dir / "target" / "release" / package
    return _ensure_built(name, pm, package, binary)


def _applet_symlink(kind, tmp_path_factory):
    """A real `kind` symlink to the active PM's applet, so tests exercise
    the same argv[0]-dispatch path a real installation would use."""
    target = _pm_applet(kind)
    link_dir = tmp_path_factory.mktemp(f"{kind}-symlink")
    link = link_dir / kind
    link.symlink_to(target)
    return link


@pytest.fixture(scope="session")
def versions_harness_rust() -> Path:
    return _pm_harness("versions")


@pytest.fixture(scope="session")
def versions_harness_python() -> list[str]:
    return [sys.executable, str(VERSIONS_PYTHON_HARNESS)]


@pytest.fixture(scope="session")
def atom_harness_rust() -> Path:
    return _pm_harness("atom")


@pytest.fixture(scope="session")
def atom_harness_python() -> list[str]:
    return [sys.executable, str(ATOM_PYTHON_HARNESS)]


@pytest.fixture(scope="session")
def use_reduce_harness_rust() -> Path:
    return _pm_harness("use_reduce")


@pytest.fixture(scope="session")
def use_reduce_harness_python() -> list[str]:
    return [sys.executable, str(USE_REDUCE_PYTHON_HARNESS)]


@pytest.fixture(scope="session")
def required_use_harness_rust() -> Path:
    return _pm_harness("required_use")


@pytest.fixture(scope="session")
def required_use_harness_python() -> list[str]:
    return [sys.executable, str(REQUIRED_USE_PYTHON_HARNESS)]


@pytest.fixture(scope="session")
def portuale_binary() -> Path:
    """The active PM's own product binary (multicall dispatch target).

    Historically the portuale multicall binary; now resolved through the
    registry: an explicit `binary` key wins, else the `emerge` applet
    path (the same binary for multicall PMs), else a cargo build."""
    _, pm = _active_pm()
    if pm.get("binary"):
        binary = _resolve_registry_path(pm["binary"])
        if binary.exists():
            return binary
    return _pm_applet("emerge")


@pytest.fixture(scope="session")
def emerge_binary(tmp_path_factory: pytest.TempPathFactory) -> Path:
    return _applet_symlink("emerge", tmp_path_factory)


@pytest.fixture(scope="session")
def ebuild_binary(tmp_path_factory: pytest.TempPathFactory) -> Path:
    return _applet_symlink("ebuild", tmp_path_factory)


@pytest.fixture(scope="session")
def mrg_binary(tmp_path_factory: pytest.TempPathFactory) -> Path:
    return _applet_symlink("mrg", tmp_path_factory)


@pytest.fixture(autouse=True)
def _corpus_context(request: pytest.FixtureRequest, tmp_path_factory: pytest.TempPathFactory):
    """Tell `corpus.py` which test is running (entries are keyed by node
    id) and where pytest's base temp is (normalised to `<TMP>`)."""
    corpus.set_basetemp(str(tmp_path_factory.getbasetemp()))
    token = corpus.current_nodeid.set(request.node.nodeid)
    yield
    corpus.current_nodeid.reset(token)


def pytest_terminal_summary(terminalreporter, exitstatus, config):
    corpus.write_blessed()
    if corpus.drifted:
        terminalreporter.section("corpus drift (flagged for review)")
        for line in corpus.drifted:
            terminalreporter.line(line)
        terminalreporter.line(
            "Rust output differs from the harvested Rust==Python-reference agreement "
            "(tests/corpus.py). Review, then re-run with PORTUALE_CORPUS_BLESS=1 "
            "to accept."
        )


@pytest.fixture(autouse=True)
def _no_clean_delay(monkeypatch: pytest.MonkeyPatch) -> None:
    """Real `emerge -C`/`--depclean`/`--prune` run a `CLEAN_DELAY`-second
    countdown (default 5) before removing anything. Pin it to 0 for the
    whole suite so removal tests don't each sleep -- real portage's own
    test infra does the same."""
    monkeypatch.setenv("CLEAN_DELAY", "0")


@pytest.fixture
def fixtures_root() -> Path:
    """fixtures/, for tests that copy a committed fixture file
    (e.g. a real `.tbz2`/`.gpkg.tar`) into an ad-hoc tree."""
    return FIXTURES_ROOT


@pytest.fixture
def fixture_env() -> dict[str, str]:
    """PORTAGE_CONFIGROOT/ROOT pointed at fixtures, the synthetic
    repo+vdb tree the emerge --pretend contract is tested against.
    DISTDIR points at the committed fixtures/distfiles/ so the
    `f`/`F` fetch-restrict bracket column has a deterministic on-disk
    state to check against.

    PORTAGE_RUNNING_ROOT is pinned to the same fixture ROOT: portuale
    now routes BDEPEND/IDEPEND against the running root whenever it
    differs from the target ROOT (real EAPI-7+ portage does this
    unconditionally -- see running_root_from_env's doc comment), so
    without this pin every fixture-ROOT test would consult the real
    host's /var/db/pkg and lose determinism. A test that specifically
    exercises a cross-root build overrides PORTAGE_RUNNING_ROOT itself."""
    env = dict(os.environ)
    env["PORTAGE_CONFIGROOT"] = str(FIXTURES_ROOT)
    env["ROOT"] = str(FIXTURES_ROOT)
    env["PORTAGE_RUNNING_ROOT"] = str(FIXTURES_ROOT)
    env["DISTDIR"] = str(FIXTURES_ROOT / "distfiles")
    return env
