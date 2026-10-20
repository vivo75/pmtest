"""Unit tests for scripts/cast_record.py + scripts/cast_compare.py (backlog #443 C4).

Synthetic casts are built in tmp_path; only the smoke test touches the
real asciinema binary (skipped when it is missing).

Grounding: the asciicast v3 layout (header JSON line, then
`[delta, "o"|"x", data]` lines with deltas relative to the previous
event) is per https://docs.asciinema.org/manual/asciicast/v3/ and was
verified against `asciinema 3.2.0` on this host (plan 06.443 S0).
"""

import importlib.util
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"


def _load(name: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod  # dataclasses resolves annotations via sys.modules
    spec.loader.exec_module(mod)
    return mod


cast_compare = _load("cast_compare")
cast_record = _load("cast_record")

NEEDS_ASCIINEMA = pytest.mark.skipif(
    shutil.which("asciinema") is None, reason="asciinema not installed")


def write_cast(path: Path, chunks: list[tuple[float, str]], rc: int = 0) -> Path:
    """Minimal v3 cast: header + one "o" event per chunk + the "x" event."""
    header = {"version": 3, "term": {"cols": 120, "rows": 40}, "timestamp": 1700000000}
    lines = [json.dumps(header)]
    lines += [json.dumps([dt, "o", text]) for dt, text in chunks]
    lines.append(json.dumps([0.0, "x", str(rc)]))
    path.write_text("\n".join(lines) + "\n")
    return path


def test_identical_casts_compare_equal(tmp_path):
    a = write_cast(tmp_path / "a.cast", [(0.1, "foo\r\n"), (0.2, "bar\r\n")])
    b = write_cast(tmp_path / "b.cast", [(0.1, "foo\r\n"), (0.2, "bar\r\n")])
    report = cast_compare.compare(cast_compare.parse_cast(a), cast_compare.parse_cast(b))
    assert report.text_equal
    assert report.first_diff is None
    assert report.chunk_equal
    assert report.n_flagged == 0
    assert report.max_ratio == pytest.approx(1.0)


def test_text_difference_reported(tmp_path):
    a = write_cast(tmp_path / "a.cast", [(0.1, "foo\r\n")])
    b = write_cast(tmp_path / "b.cast", [(0.1, "bar\r\n")])
    report = cast_compare.compare(cast_compare.parse_cast(a), cast_compare.parse_cast(b))
    assert not report.text_equal
    assert report.first_diff is not None
    assert report.first_diff["offset"] == 0  # "foo" vs "bar"
    assert "foo" in report.first_diff["a"]
    assert "bar" in report.first_diff["b"]


def test_same_text_different_chunking(tmp_path):
    a = write_cast(tmp_path / "a.cast", [(0.1, "ab"), (0.1, "cd\r\n")])
    b = write_cast(tmp_path / "b.cast", [(0.2, "abcd\r\n")])
    report = cast_compare.compare(cast_compare.parse_cast(a), cast_compare.parse_cast(b))
    assert report.text_equal
    assert not report.chunk_equal
    assert report.chunks_a == [2, 4]
    assert report.chunks_b == [6]


def test_timing_difference_only_reported(tmp_path):
    a = write_cast(tmp_path / "a.cast", [(0.1, "same\r\n")])
    b = write_cast(tmp_path / "b.cast", [(1.0, "same\r\n")])
    report = cast_compare.compare(cast_compare.parse_cast(a), cast_compare.parse_cast(b))
    assert report.text_equal
    assert report.chunk_equal
    assert report.n_flagged == 1
    assert report.max_ratio == pytest.approx(10.0)


def test_timing_within_tolerance_not_flagged(tmp_path):
    a = write_cast(tmp_path / "a.cast", [(0.1, "same\r\n")])
    b = write_cast(tmp_path / "b.cast", [(0.2, "same\r\n")])
    report = cast_compare.compare(cast_compare.parse_cast(a), cast_compare.parse_cast(b))
    assert report.text_equal
    assert report.n_flagged == 0


def test_normalise_strips_tmp_pid_duration_keeps_escapes():
    raw = ("\x1b[32mok\x1b[0m /tmp/cast-cells-xyz/out 12.3 seconds "
           "pid 98765 /var/tmp/pmtest/pytest-1/x")
    out = cast_compare.normalise(raw, tmp_roots=("/tmp/cast-cells-xyz",))
    assert "\x1b[32mok\x1b[0m" in out  # escapes untouched
    assert "/tmp/cast-cells-xyz" not in out
    assert "98765" not in out
    assert "12.3 seconds" not in out
    assert "<TMP>" in out


def test_truncated_cast_raises(tmp_path):
    truncated = tmp_path / "t.cast"
    truncated.write_text(json.dumps({"version": 3}) + "\n"
                         + json.dumps([0.1, "o", "hi"]) + "\n")
    with pytest.raises(ValueError, match="no 'x'"):
        cast_compare.parse_cast(truncated)


def test_garbled_cast_raises(tmp_path):
    garbled = tmp_path / "g.cast"
    garbled.write_text(json.dumps({"version": 3}) + "\n{not json\n")
    with pytest.raises(ValueError, match="garbled"):
        cast_compare.parse_cast(garbled)


def test_strict_text_cli_exit_code(tmp_path):
    a = write_cast(tmp_path / "a.cast", [(0.1, "foo\r\n")])
    b = write_cast(tmp_path / "b.cast", [(0.1, "bar\r\n")])
    same = write_cast(tmp_path / "s.cast", [(0.1, "foo\r\n")])
    ok = subprocess.run([sys.executable, str(SCRIPTS / "cast_compare.py"),
                         str(a), str(same)], capture_output=True, text=True)
    assert ok.returncode == 0
    strict = subprocess.run([sys.executable, str(SCRIPTS / "cast_compare.py"),
                             str(a), str(b), "--strict-text"],
                            capture_output=True, text=True)
    assert strict.returncode == 1
    lax = subprocess.run([sys.executable, str(SCRIPTS / "cast_compare.py"),
                          str(a), str(b)], capture_output=True, text=True)
    assert lax.returncode == 0


@NEEDS_ASCIINEMA
def test_record_printf_smoke(tmp_path):
    cast_path, rc = cast_record.record(["printf", "a\nb\n"], tmp_path / "smoke.cast")
    assert rc == 0
    cast = cast_compare.parse_cast(cast_path)
    assert "a" in cast.text and "b" in cast.text


def test_ignore_lines_drops_only_matching_lines(tmp_path):
    """Setup chatter on one side must not make an otherwise equal cell differ,
    and a line that does not match the pattern must still count."""
    a = write_cast(tmp_path / "a.cast", [(0.0, "!!! noise 1\r\nrow\r\n")])
    b = write_cast(tmp_path / "b.cast", [(0.0, "row\r\n")])
    ca, cb = cast_compare.parse_cast(a), cast_compare.parse_cast(b)
    assert not cast_compare.compare(ca, cb).text_equal
    assert cast_compare.compare(ca, cb, ignore_lines=("!!! noise",)).text_equal
    c = write_cast(tmp_path / "c.cast", [(0.0, "!!! noise 1\r\nother\r\n")])
    assert not cast_compare.compare(
        cast_compare.parse_cast(c), cb, ignore_lines=("!!! noise",)).text_equal


def _big_cast(tmp_path, name="big.cast", n=10, size=1000):
    """n output events of `size` bytes each: 10000 bytes total."""
    return write_cast(tmp_path / name,
                      [(0.1, f"{i:04d}".ljust(size, "x")) for i in range(n)])


def test_cap_respects_budget(tmp_path):
    """Over-budget output collapses to head + marker + tail (backlog #452 K2)."""
    cast = cast_compare.parse_cast(_big_cast(tmp_path))
    capped, info = cast_compare.cap_cast(cast, 4000)
    out = [e.data for e in capped.events if e.kind == "o"]
    assert sum(map(len, out)) <= 4000
    assert info["original_bytes"] == 10000
    assert info["capped_bytes"] == sum(map(len, out))
    assert info["dropped_bytes"] == 10000 - info["capped_bytes"]
    assert info["dropped_events"] > 0
    markers = [e for e in capped.events if e.kind == "m"]
    assert len(markers) == 1
    assert f"{info['dropped_bytes']} bytes" in markers[0].data
    assert f"{info['dropped_events']} events" in markers[0].data


def test_cap_keeps_head_and_tail(tmp_path):
    cast = cast_compare.parse_cast(_big_cast(tmp_path))
    capped, _ = cast_compare.cap_cast(cast, 4000)
    out = [e.data for e in capped.events if e.kind == "o"]
    assert out[0].startswith("0000")  # head: first event kept
    assert out[-1].startswith("0009")  # tail: last event kept
    assert not any(d.startswith("0005") for d in out)  # middle dropped


def test_cap_off_when_zero(tmp_path):
    """budget=0 disables capping: identical events, no marker (backlog #452 K2)."""
    path = _big_cast(tmp_path)
    cast = cast_compare.parse_cast(path)
    capped, info = cast_compare.cap_cast(cast, 0)
    assert [e.data for e in capped.events] == [e.data for e in cast.events]
    assert not [e for e in capped.events if e.kind == "m"]
    assert info["dropped_events"] == 0


def test_cap_under_budget_unchanged(tmp_path):
    cast = cast_compare.parse_cast(_big_cast(tmp_path))
    capped, info = cast_compare.cap_cast(cast, 10000)
    assert [e.data for e in capped.events] == [e.data for e in cast.events]
    assert info["capped_bytes"] == info["original_bytes"] == 10000


def test_capped_casts_compare(tmp_path):
    """compare() works on capped casts: same content still equal (backlog #452 K2)."""
    a = cast_compare.parse_cast(_big_cast(tmp_path, "a.cast"))
    b = cast_compare.parse_cast(_big_cast(tmp_path, "b.cast"))
    ca, _ = cast_compare.cap_cast(a, 4000)
    cb, _ = cast_compare.cap_cast(b, 4000)
    report = cast_compare.compare(ca, cb)
    assert report.text_equal
    assert report.chunk_equal


def test_landmarks_found_in_order(tmp_path):
    """Each landmark reports its event's seconds-since-start (backlog #452 K3)."""
    chunks = [(1.0, ">>> Emerging (1 of 2) dev-libs/schedok\r\n"),
              (2.0, "noise\r\n"),
              (3.0, ">>> Install schedok into /root\r\n"),
              (4.0, ">>> Completed\r\n")]
    cast = cast_compare.parse_cast(write_cast(tmp_path / "lm.cast", chunks))
    times = cast_compare.landmark_times(cast)
    assert times[">>> Emerging"] == pytest.approx(1.0)
    assert times[">>> Install"] == pytest.approx(1.0 + 2.0 + 3.0)
    assert times[">>> Completed"] == pytest.approx(1.0 + 2.0 + 3.0 + 4.0)
    assert times[">>> Emerging"] < times[">>> Install"] < times[">>> Completed"]
    assert times["Failed to emerge"] is None
    assert times["*** Resuming"] is None
    assert times["failed-to-build summary"] is None


def test_landmarks_split_write_still_match(tmp_path):
    """A landmark split across two writes matches at the second event's time."""
    chunks = [(1.0, ">>> Emerg"), (2.0, "ing dev-libs/schedok\r\n")]
    cast = cast_compare.parse_cast(write_cast(tmp_path / "sp.cast", chunks))
    assert cast_compare.landmark_times(cast)[">>> Emerging"] == pytest.approx(3.0)


def test_landmarks_absent_is_none(tmp_path):
    cast = cast_compare.parse_cast(
        write_cast(tmp_path / "plain.cast", [(0.5, "just some output\r\n")]))
    assert all(v is None for v in cast_compare.landmark_times(cast).values())


def test_landmark_failure_summary(tmp_path):
    chunks = [(1.0, "*** Resuming merge...\r\n"),
              (1.0, "Failed to emerge dev-libs/schedbad\r\n"),
              (1.0, " * The following 1 package has failed to build\r\n")]
    times = cast_compare.landmark_times(
        cast_compare.parse_cast(write_cast(tmp_path / "fail.cast", chunks)))
    assert times["*** Resuming"] == pytest.approx(1.0)
    assert times["Failed to emerge"] == pytest.approx(2.0)
    assert times["failed-to-build summary"] == pytest.approx(3.0)


@NEEDS_ASCIINEMA
def test_record_with_answers_types_the_reply_at_the_prompt(tmp_path):
    """K4 (#452): the reply reaches the child's stdin and shows in the cast."""
    rec = _load("cast_record")
    cast = tmp_path / "ask.cast"
    _, rc = rec.record_with_answers(
        ["sh", "-c", "printf 'Q? '; read x; echo got-$x; exit 3"],
        cast, [(r"Q\? ", "hi")], timeout=20)
    assert rc == 3
    assert "got-hi" in _load("cast_compare").parse_cast(cast).text


@NEEDS_ASCIINEMA
def test_record_with_answers_times_out_when_the_prompt_never_comes(tmp_path):
    rec = _load("cast_record")
    with pytest.raises(TimeoutError):
        rec.record_with_answers(["sh", "-c", "sleep 30"], tmp_path / "t.cast",
                                [(r"never", "x")], timeout=2)
