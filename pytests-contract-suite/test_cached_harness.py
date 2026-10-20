"""The answer cache in front of the Python reference harnesses (backlog #448).

Everything here uses a fake harness and a fake Portage checkout in tmp_path:
these tests check the cache's own rules (key, replay, invalidation, env
switches), not any Portage answer.
"""

import importlib.util
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
_SPEC = importlib.util.spec_from_file_location(
    "cached_harness", REPO_ROOT / "python-harness" / "cached_harness.py"
)
cached = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(cached)

FAKE_HARNESS = '''\
import os, sys
with open(os.path.join(os.environ["FAKE_COUNTER_DIR"], "runs"), "a") as f:
    f.write("x")
if sys.argv[1:2] == ["batch"]:
    data = sys.stdin.read()
    sys.stdout.write("batch:" + data.upper())
else:
    sys.stdout.write("argv:" + repr(sys.argv[1:]) + "\\n")
    sys.stderr.write("err-line\\n")
if "fail" in sys.argv[1:]:
    sys.exit(3)
'''


def _git(cwd, *args):
    subprocess.run(
        ["git", "-C", str(cwd), "-c", "user.name=t", "-c", "user.email=t@t", *args],
        check=True, capture_output=True,
    )


@pytest.fixture
def env(tmp_path, monkeypatch):
    harness_dir = tmp_path / "harness"
    harness_dir.mkdir()
    (harness_dir / "fake_harness.py").write_text(FAKE_HARNESS)
    counter = tmp_path / "counter"
    counter.mkdir()
    monkeypatch.setenv("FAKE_COUNTER_DIR", str(counter))
    monkeypatch.delenv("PMTEST_PORTAGE_CACHE", raising=False)
    monkeypatch.delenv("PMTEST_REFRESH_PORTAGE", raising=False)

    checkout = tmp_path / "portage"
    (checkout / "lib" / "portage").mkdir(parents=True)
    (checkout / "lib" / "portage" / "__init__.py").write_text("# v1\n")
    _git(checkout, "init", "-q")
    _git(checkout, "add", "-A")
    _git(checkout, "commit", "-q", "-m", "pin one")

    class Env:
        pass

    e = Env()
    e.harness_dir = harness_dir
    e.answers_dir = tmp_path / "answers"
    e.checkout = checkout
    e.counter = counter
    return e


def _run(env, argv, stdin=b""):
    return cached.answer(
        "fake", argv, stdin,
        harness_dir=str(env.harness_dir),
        answers_dir=str(env.answers_dir),
        checkout=str(env.checkout),
    )


def _runs(env):
    path = env.counter / "runs"
    return len(path.read_text()) if path.exists() else 0


def test_hit_replays_rc_stdout_stderr_without_running(env):
    first = _run(env, ["parse", "a/b"])
    second = _run(env, ["parse", "a/b"])
    assert first == second
    assert first[0] == 0
    assert b"argv:" in first[1]
    assert first[2] == b"err-line\n"
    assert _runs(env) == 1


def test_batch_stdin_is_part_of_the_key(env):
    out1 = _run(env, ["batch"], b"one\n")
    out2 = _run(env, ["batch"], b"two\n")
    assert out1[1] == b"batch:ONE\n"
    assert out2[1] == b"batch:TWO\n"
    assert _runs(env) == 2
    assert _run(env, ["batch"], b"one\n") == out1
    assert _runs(env) == 2


def test_changed_harness_sha_misses(env):
    _run(env, ["parse"])
    harness = env.harness_dir / "fake_harness.py"
    harness.write_text(FAKE_HARNESS + "\n# changed\n")
    _run(env, ["parse"])
    assert _runs(env) == 2


def test_changed_portage_pin_misses(env):
    _run(env, ["parse"])
    (env.checkout / "lib" / "portage" / "__init__.py").write_text("# v2\n")
    _git(env.checkout, "add", "-A")
    _git(env.checkout, "commit", "-q", "-m", "pin two")
    _run(env, ["parse"])
    assert _runs(env) == 2
    lines = (env.answers_dir / "fake.jsonl").read_text().splitlines()
    assert len(lines) == 2


def test_dirty_checkout_runs_live_and_records_nothing(env):
    (env.checkout / "lib" / "portage" / "__init__.py").write_text("# dirty\n")
    _run(env, ["parse"])
    _run(env, ["parse"])
    assert _runs(env) == 2
    assert not (env.answers_dir / "fake.jsonl").exists()


def test_cache_off_bypasses_read_and_write(env, monkeypatch):
    _run(env, ["parse"])  # records one answer
    monkeypatch.setenv("PMTEST_PORTAGE_CACHE", "off")
    _run(env, ["parse"])
    assert _runs(env) == 2
    assert len((env.answers_dir / "fake.jsonl").read_text().splitlines()) == 1


def test_refresh_ignores_hit_and_appends_new_line(env, monkeypatch):
    _run(env, ["parse"])
    monkeypatch.setenv("PMTEST_REFRESH_PORTAGE", "1")
    _run(env, ["parse"])
    assert _runs(env) == 2
    lines = (env.answers_dir / "fake.jsonl").read_text().splitlines()
    assert len(lines) == 2
    monkeypatch.delenv("PMTEST_REFRESH_PORTAGE")
    _run(env, ["parse"])
    assert _runs(env) == 2  # the last line for the key is what hits now


def test_nonzero_exit_replays_identically(env):
    first = _run(env, ["parse", "fail"])
    second = _run(env, ["parse", "fail"])
    assert first == second
    assert first[0] == 3
    assert _runs(env) == 1


def test_damaged_line_is_skipped(env):
    _run(env, ["parse"])
    store = env.answers_dir / "fake.jsonl"
    with open(store, "a") as f:
        f.write('{"key": "torn')
    assert _run(env, ["parse"])[0] == 0
    assert _runs(env) == 1


def test_unknown_harness_is_an_error(env):
    with pytest.raises(SystemExit):
        cached.answer("nope", ["parse"], b"",
                      harness_dir=str(env.harness_dir),
                      answers_dir=str(env.answers_dir),
                      checkout=str(env.checkout))
