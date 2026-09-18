import getpass
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

# --- tmp/disk hygiene ----------------------------------------------------
#
# This has to run BEFORE `import corpus`: corpus.py snapshots the process
# environment at its own import time (`_HOST_ENV`) to tell "just inherited
# from the host" apart from "this call's own env" -- import it after
# $TMPDIR is set here, or that snapshot is the pre-override environment
# and $TMPDIR itself gets misclassified as case-specific, breaking every
# corpus lookup that goes through `fixture_env()`'s `dict(os.environ)`.
#
# A merge test chowns paths to root (this container has passwordless sudo,
# and real installed-file ownership is part of what is being tested), so
# once a session ends, pytest's own tmp cleanup -- which runs unprivileged
# -- cannot remove them: it renames the undeletable tree to `garbage-<uuid>`
# and leaves it forever. Those pile up run after run, and on a tmpfs /tmp
# (RAM-backed, a FIXED inode count independent of disk size) that is what
# actually exhausts inodes -- not test volume by itself (2026-09-15
# finding, see the memory note).
#
# Setting $TMPDIR is NOT enough to fix this: pytest's output-capture
# manager creates its own fd-swap tempfiles to capture conftest.py's own
# import (so a print/error during conftest loading is captured too), and
# doing so calls `tempfile.gettempdir()` -- which caches the OLD value --
# *before* this module's code ever runs. The only reliable hook is
# `config.option.basetemp`, which `TempPathFactory` reads directly and
# which bypasses `tempfile` entirely (this is exactly what `--basetemp`
# does from the command line).
#
# Three defenses, cheapest/most-targeted first:
#   1. reclaim what pytest itself could not, before this session's
#      basetemp is (re)created (needs sudo; best-effort without it --
#      never blocks a run, just leaves the old problem in place).
#   2. default that basetemp onto real disk, not tmpfs (`/var/tmp`, not
#      `/tmp`) -- real disk isn't RAM- and isn't capped at a fixed inode
#      count the way this host's tmpfs is. A fixed, reused path (no
#      `pytest-N` numbering) means there is only ever one directory to
#      reclaim, not an unbounded family of them.
#   3. a preflight space/inode check, so a filesystem that is genuinely
#      too full fails once, clearly, up front -- not as a cascade of
#      unrelated-looking OSErrors well into the run.
#
# `$PMTEST_TMPDIR` overrides the base directory; an explicit `--basetemp`
# on the command line is always respected instead (this suite manages its
# own default, never someone else's explicit choice). `$TMPDIR` is also
# defaulted the same way, as a courtesy to anything that still creates
# its own tempfiles directly (this repo's host-side shell scripts, a
# future test) -- harmless, since it plays no part in the basetemp fix
# above.
_TMP_BASE = os.environ.get("PMTEST_TMPDIR") or os.environ.get("TMPDIR") or "/var/tmp/pmtest"
os.environ.setdefault("TMPDIR", _TMP_BASE)
_BASETEMP = Path(_TMP_BASE) / "pytest-basetemp"

import corpus  # noqa: E402  (see the ordering note above)

# Preflight thresholds (env-overridable -- "tune to what this machine
# actually has", not a number picked once and forgotten): a full
# contract-suite run's own tmp usage is on the order of 10-100k inodes
# and a few hundred MB in the steady state (post-reclaim); these leave
# comfortable headroom above that without being so tight that ordinary
# variance trips the warning.
_MIN_FREE_INODES_WARN = int(os.environ.get("PMTEST_MIN_FREE_INODES_WARN", 200_000))
_MIN_FREE_INODES_FAIL = int(os.environ.get("PMTEST_MIN_FREE_INODES", 20_000))
_MIN_FREE_BYTES_WARN = int(os.environ.get("PMTEST_MIN_FREE_BYTES_WARN", 2 * 1024**3))
_MIN_FREE_BYTES_FAIL = int(os.environ.get("PMTEST_MIN_FREE_BYTES", 200 * 1024**2))


def _sudo_rm_rf(path: Path) -> bool:
    """Best-effort privileged removal. `sudo -n` (non-interactive): never
    hang a run waiting on a password, and never require sudo to exist."""
    result = subprocess.run(
        ["sudo", "-n", "rm", "-rf", str(path)], capture_output=True, text=True
    )
    return result.returncode == 0 and not path.exists()


def _reclaim_portuale_bin_overlays(base: Path) -> None:
    """Every `emerge`/`ebuild` invocation makes its own PATH overlay at
    `$TMPDIR/portuale-bin.<pid>` (`ebuild_phases.rs::bin_dir()`) and never
    removes it -- a real, per-process leak in the PM under test, not an
    artifact of this harness. It hid inside the general churn of the
    default `/tmp`; relocating TMPDIR made it the majority of what a full
    run leaves behind (~1000 tiny dirs for two runs of this suite alone).
    Unprivileged (portuale itself runs as this user in these tests, no
    chown involved) -- swept here anyway since nothing else ever will."""
    for stale in base.glob("portuale-bin.*"):
        shutil.rmtree(stale, ignore_errors=True)


@pytest.hookimpl(tryfirst=True)
def pytest_configure(config):
    """Point pytest's own `tmp_path`/`tmp_path_factory` machinery at a
    single, reused, real-disk directory (see the module docstring above
    for why this has to happen here, via `config.option.basetemp`,
    rather than via `$TMPDIR`), reclaiming it from any previous session
    first; then fail fast on a filesystem that is already too full to
    run on at all.

    `tryfirst=True` + module-level registration order isn't a guarantee
    pytest documents, so this doesn't *rely* on running before
    `_pytest.tmpdir`'s own `pytest_configure` -- if our sudo reclaim
    can't fully clear `_BASETEMP` (no sudo, or something still holds a
    lock on it), this falls back to leaving `config.option.basetemp`
    alone entirely, i.e. pytest's own default `/tmp` numbered-dir
    behaviour, rather than risking a hard crash from a half-wiped fixed
    path with no retry."""
    if config.option.basetemp is None:
        _TMP_BASE_PATH = Path(_TMP_BASE)
        _TMP_BASE_PATH.mkdir(parents=True, exist_ok=True)
        _reclaim_portuale_bin_overlays(_TMP_BASE_PATH)
        if not _BASETEMP.exists() or _sudo_rm_rf(_BASETEMP):
            config.option.basetemp = str(_BASETEMP)
        else:
            print(
                f"[pmtest] could not reclaim {_BASETEMP} (no sudo?) -- "
                "falling back to pytest's own default tmp location",
                file=sys.stderr,
            )

    try:
        st = os.statvfs(_TMP_BASE)
    except OSError:
        return
    free_inodes = st.f_favail
    free_bytes = st.f_bavail * st.f_frsize
    if free_inodes < _MIN_FREE_INODES_FAIL or free_bytes < _MIN_FREE_BYTES_FAIL:
        raise pytest.UsageError(
            f"{_TMP_BASE}: only {free_inodes:,} free inodes / "
            f"{free_bytes / 1024**2:,.0f} MiB free -- too low to run the suite. "
            f"Free space there, or point PMTEST_TMPDIR at a filesystem with more "
            f"headroom (see USAGE.AGENTS.md, \"Spazio /tmp\")."
        )
    if free_inodes < _MIN_FREE_INODES_WARN or free_bytes < _MIN_FREE_BYTES_WARN:
        print(
            f"[pmtest] warning: {_TMP_BASE} is getting low -- "
            f"{free_inodes:,} free inodes / {free_bytes / 1024**2:,.0f} MiB free",
            file=sys.stderr,
        )


REPO_ROOT = Path(__file__).resolve().parents[1]
# PM registry: which package manager is under test is decided there, not
# by hardcoded paths. The active entry is selected via PMTEST_PM
# (default: "portuale"); see managers/README.md.
sys.path.insert(0, str(REPO_ROOT / "managers"))
import registry  # noqa: E402  (pmtest root is not a package)

VERSIONS_PYTHON_HARNESS = REPO_ROOT / "python-harness" / "versions_harness.py"
ATOM_PYTHON_HARNESS = REPO_ROOT / "python-harness" / "atom_harness.py"
USE_REDUCE_PYTHON_HARNESS = REPO_ROOT / "python-harness" / "use_reduce_harness.py"
REQUIRED_USE_PYTHON_HARNESS = REPO_ROOT / "python-harness" / "required_use_harness.py"
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


# Markers, not a full inventory: enough to catch a tree that is there
# but is not the fixture tree (an empty clone, a half-finished checkout).
_FIXTURE_MARKERS = (
    "repo/profiles/make.defaults",
    "repo/metadata/md5-cache",
    "etc/portage/make.conf",
    "var/db/pkg",
)


@pytest.fixture(scope="session", autouse=True)
def _require_fixture_tree():
    """Fail the session, once and with the reason, on a missing or wrong
    fixture tree.

    Every case in this suite reads `fixtures/`; without this the whole
    run turns into a pile of unrelated file-not-found failures. The same
    tree is what the PM's own Rust tests read, through a `fixtures`
    symlink in its checkout."""
    if not FIXTURES_ROOT.is_dir():
        pytest.fail(f"fixture tree missing: {FIXTURES_ROOT}")
    missing = [m for m in _FIXTURE_MARKERS if not (FIXTURES_ROOT / m).exists()]
    if missing:
        pytest.fail(
            f"fixture tree at {FIXTURES_ROOT} is missing {', '.join(missing)}: "
            "it exists, but it is not the fixture tree this suite grades against"
        )


@pytest.fixture(scope="session", autouse=True)
def _isolate_config_env():
    """Strip any inherited make.conf-style config vars for the session."""
    for name in _ENV_CONFIG_VARS:
        os.environ.pop(name, None)
    yield


def _resolved(what, kind):
    """`registry.<what>(kind)`, with registry errors in pytest's idiom.

    A `NotProvided` is the entry saying it cannot offer this binary at
    all (a prebuilt reference PM has no neutral harness): that is a skip,
    with the reason the registry gave. Anything else is a real
    misconfiguration and fails the run.
    """
    try:
        return getattr(registry, what)(kind) if kind else getattr(registry, what)()
    except registry.NotProvided as exc:
        pytest.skip(str(exc))
    except registry.RegistryError as exc:
        pytest.fail(str(exc))


def _pm_harness(harness):
    """Neutral CLI harness binary of the active PM (skips if it ships none)."""
    return _resolved("harness", harness)


def _pm_applet(kind):
    """emerge/ebuild/mrg entry point of the active PM."""
    return _resolved("applet", kind)


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
    return _resolved("product_binary", None)


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
            "(pytests-contract-suite/corpus.py). Review, then re-run with PORTUALE_CORPUS_BLESS=1 "
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
