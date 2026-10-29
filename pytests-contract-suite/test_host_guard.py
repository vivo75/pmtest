"""Guards against the contract suite changing the host it runs on.

Global updates now run before every emerge: Portage's `run_action`
(`lib/_emerge/actions.py:3933`, 3rdparty/portage 3.0.83) applies
`profiles/updates/*` moves to the target root and to the running root,
then records each updates file's mtime under `mtimedb["updates"]`
(`lib/portage/_global_updates.py:251`) and commits the running root's
mtimedb. As root with `PORTAGE_RUNNING_ROOT=/` (several suite tests set
it on purpose; many build their env from `os.environ`) a suite run
would therefore apply the host's unrecorded updates and rewrite the
host's `/var/cache/edb/mtimedb`. `conftest.py` guards both halves: it
refuses to start as root without `PMTEST_ALLOW_ROOT=1`, and a session
sentinel fingerprints the host `/var/cache/edb/mtimedb` and `/var/db/pkg`
at session start and fails the session if either changed by session end.
These tests pin the pure refusal decision, the fingerprint helper on
scratch paths (via the test-only `PMTEST_HOST_SENTINEL_PATHS` override),
and the sentinel's session-failing behaviour in isolated subprocess
runs of the actual `pytest_sessionstart`/`pytest_sessionfinish` hooks.
"""

import importlib.util
import os
import subprocess
import sys
from pathlib import Path

import pytest

from conftest import diff_host_state, fingerprint_host_state, root_guard_message

SUITE_DIR = Path(__file__).resolve().parent


def _point_sentinel_at(tmp_path, monkeypatch):
    """Redirect the sentinel at scratch paths via its test-only override."""
    mtimedb = tmp_path / "host" / "mtimedb"
    vdb = tmp_path / "host" / "vdb"
    vdb.mkdir(parents=True)
    monkeypatch.setenv(
        "PMTEST_HOST_SENTINEL_PATHS", f"{mtimedb}{os.pathsep}{vdb}"
    )
    return mtimedb, vdb


def test_fingerprint_is_stable_on_an_untouched_tree(tmp_path, monkeypatch):
    """Two fingerprints of an unchanged scratch tree compare equal."""
    mtimedb, _vdb = _point_sentinel_at(tmp_path, monkeypatch)
    mtimedb.write_bytes(b'{"updates": {}}')
    assert fingerprint_host_state() == fingerprint_host_state()


def test_fingerprint_notices_a_touched_mtimedb(tmp_path, monkeypatch):
    """Appending a byte to the watched file changes the fingerprint,
    and the diff names the path and the changed fields."""
    mtimedb, _vdb = _point_sentinel_at(tmp_path, monkeypatch)
    mtimedb.write_bytes(b'{"updates": {}}')
    before = fingerprint_host_state()
    with open(mtimedb, "ab") as handle:
        handle.write(b" ")
    after = fingerprint_host_state()
    assert before != after
    changes = diff_host_state(before, after)
    assert len(changes) == 1
    assert str(mtimedb) in changes[0]
    assert "size" in changes[0]
    assert "sha256" in changes[0]


def test_fingerprint_tolerates_a_missing_mtimedb(tmp_path, monkeypatch):
    """A missing watched file is a valid state (stable while absent),
    and its later appearance reads as a missing -> present change."""
    mtimedb, _vdb = _point_sentinel_at(tmp_path, monkeypatch)
    before = fingerprint_host_state()
    assert before["mtimedb"]["exists"] is False
    assert fingerprint_host_state() == before
    mtimedb.write_bytes(b"{}")
    after = fingerprint_host_state()
    assert after["mtimedb"]["exists"] is True
    changes = diff_host_state(before, after)
    assert len(changes) == 1
    assert "missing" in changes[0]


def test_fingerprint_notices_a_vdb_mtime_change(tmp_path, monkeypatch):
    """Creating an entry under the watched vdb dir (what a move or
    slotmove does to `/var/db/pkg`) changes its recorded mtime."""
    _mtimedb, vdb = _point_sentinel_at(tmp_path, monkeypatch)
    # A coarse-mtime tmpfs can hand the new entry the same nanosecond value
    # the empty directory carried; pin "before" to an old time so mkdir's
    # timestamp is unambiguous.
    os.utime(vdb, ns=(1_000_000_000, 1_000_000_000))
    before = fingerprint_host_state()
    (vdb / "cat-pkg-1.0").mkdir()
    after = fingerprint_host_state()
    assert before != after
    changes = diff_host_state(before, after)
    assert any("mtime_ns" in line for line in changes)


@pytest.mark.parametrize(
    ("euid", "env", "refused"),
    [
        (0, {}, True),
        (0, {"PMTEST_ALLOW_ROOT": "0"}, True),
        (0, {"PMTEST_ALLOW_ROOT": ""}, True),
        (0, {"PMTEST_ALLOW_ROOT": "yes"}, True),
        (0, {"PMTEST_ALLOW_ROOT": "1"}, False),
        (1000, {}, False),
        (1000, {"PMTEST_ALLOW_ROOT": "1"}, False),
    ],
)
def test_root_guard_message_decision_table(euid, env, refused):
    """Only root without `PMTEST_ALLOW_ROOT=1` is refused, and the
    refusal names the override and the host path at stake."""
    message = root_guard_message(euid, env)
    if not refused:
        assert message is None
    else:
        assert message is not None
        assert "PMTEST_ALLOW_ROOT=1" in message
        assert "/var/cache/edb/mtimedb" in message


def test_root_guard_reads_the_process_environment_by_default(monkeypatch):
    """With no explicit env mapping the decision follows the process environment:
    `PMTEST_ALLOW_ROOT=1` lets root through, its absence refuses."""
    monkeypatch.setenv("PMTEST_ALLOW_ROOT", "1")
    assert root_guard_message(0) is None
    monkeypatch.delenv("PMTEST_ALLOW_ROOT")
    assert root_guard_message(0) is not None


_SCRATCH_CONFTEST_TEMPLATE = """\
import importlib.util
import sys

sys.path.insert(0, "%%SUITE_DIR%%")
spec = importlib.util.spec_from_file_location(
    "pmtest_host_guard_real_conftest", "%%REAL_CONFTEST%%"
)
_real = importlib.util.module_from_spec(spec)
sys.modules["pmtest_host_guard_real_conftest"] = _real
spec.loader.exec_module(_real)


def pytest_sessionstart(session):
    _real.pytest_sessionstart(session)


def pytest_sessionfinish(session, exitstatus):
    _real.pytest_sessionfinish(session, exitstatus)
"""


def _run_scratch_session(tmp_path, test_body):
    """Run an isolated pytest session wired to the suite's own conftest hooks.

    The scratch dir carries a `conftest.py` that loads the suite's actual
    `conftest.py` from its file path (under an alias, so the scratch
    `conftest` module itself never collides with it) and delegates the
    session hooks to it; `PMTEST_HOST_SENTINEL_PATHS` points the
    sentinel at scratch paths. Returns the completed process.
    """
    scratch = tmp_path / "scratch-session"
    scratch.mkdir()
    mtimedb = scratch / "host-mtimedb"
    mtimedb.write_bytes(b'{"updates": {}}')
    vdb = scratch / "host-vdb"
    vdb.mkdir()
    conftest_text = _SCRATCH_CONFTEST_TEMPLATE.replace(
        "%%SUITE_DIR%%", str(SUITE_DIR)
    ).replace("%%REAL_CONFTEST%%", str(SUITE_DIR / "conftest.py"))
    (scratch / "conftest.py").write_text(conftest_text)
    (scratch / "test_scratch.py").write_text(
        test_body.replace("%%MTIMEDB%%", str(mtimedb))
    )
    env = dict(os.environ)
    env["PMTEST_HOST_SENTINEL_PATHS"] = f"{mtimedb}{os.pathsep}{vdb}"
    env["PMTEST_TMPDIR"] = str(scratch / "tmp")
    return subprocess.run(
        [sys.executable, "-m", "pytest", str(scratch), "-q", "-p", "no:cacheprovider"],
        capture_output=True,
        text=True,
        env=env,
        check=False,
        timeout=240,
    )


def test_sentinel_fails_a_session_that_touches_the_watched_paths(tmp_path):
    """A session whose test appends to the watched file exits non-zero
    with a message naming the change -- this is the proof that
    `pytest_sessionfinish` setting `session.exitstatus` really changes
    the process exit code."""
    result = _run_scratch_session(
        tmp_path,
        'from pathlib import Path\n'
        '\n'
        '\n'
        'def test_touch_the_watched_file():\n'
        '    watched = Path("%%MTIMEDB%%")\n'
        '    watched.write_bytes(watched.read_bytes() + b" ")\n',
    )
    assert result.returncode != 0
    combined = result.stdout + result.stderr
    assert "host sentinel" in combined
    assert "host-mtimedb" in combined


def test_sentinel_passes_a_session_that_leaves_them_alone(tmp_path):
    """The same wiring with a no-op test exits 0, so the failure above
    comes from the touch and not from the harness itself."""
    result = _run_scratch_session(
        tmp_path,
        'def test_leaves_the_watched_paths_alone():\n    pass\n',
    )
    assert result.returncode == 0, result.stdout + result.stderr
