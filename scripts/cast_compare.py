#!/usr/bin/env python3
"""Compare two asciicast v3 recordings: text, chunking, timing (backlog #443 C2).

Three independent comparisons over the output (`"o"`) event stream:

* text -- the concatenated output after normalisation (temp dirs, PIDs,
  durations); ANSI escapes are kept, so colour differences still count.
* chunking -- the ordered list of output events and their sizes: a
  progress line printed piecemeal vs in one write differs here even when
  the text is identical.
* timing -- per output event the elapsed-time ratio between the two
  casts, flagged above a tolerance (default 5x), ignoring events under
  50 ms. A report only, never a failure.

Exit status is 0 always, except with `--strict-text` when the text
differs (then 1).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_TOLERANCE = 5.0
MIN_EVENT_S = 0.05
DIFF_CONTEXT = 120


@dataclass
class Event:
    t: float  # absolute seconds since the recording start
    kind: str  # "o" output, "i" input, "m" marker, "r" resize, "x" exit
    data: str


@dataclass
class Cast:
    header: dict
    events: list[Event]

    @property
    def text(self) -> str:
        return "".join(e.data for e in self.events if e.kind == "o")


def parse_cast(path: Path) -> Cast:
    """Parse an asciicast v3 file; absolute event times, delta summed."""
    raw = Path(path).read_text().splitlines()
    if not raw:
        raise ValueError(f"{path}: empty file, not an asciicast")
    try:
        header = json.loads(raw[0])
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path}:1: garbled header line: {exc}") from None
    if not isinstance(header, dict) or header.get("version") != 3:
        raise ValueError(f"{path}:1: not an asciicast v3 header: {raw[0][:80]!r}")
    events: list[Event] = []
    t = 0.0
    for lineno, line in enumerate(raw[1:], start=2):
        if not line.strip():
            continue
        try:
            item = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValueError(f"{path}:{lineno}: garbled event line: {exc}") from None
        if not isinstance(item, list) or len(item) != 3:
            raise ValueError(f"{path}:{lineno}: not a [delta, kind, data] event: {line[:80]!r}")
        delta, kind, data = item
        try:
            t += float(delta)
        except (TypeError, ValueError):
            raise ValueError(f"{path}:{lineno}: bad delta {delta!r}") from None
        if not isinstance(kind, str) or not isinstance(data, str):
            raise ValueError(f"{path}:{lineno}: bad kind/data in {line[:80]!r}")
        events.append(Event(t, kind, data))
    if not any(e.kind == "x" for e in events):
        raise ValueError(f"{path}: no 'x' (exit) event; truncated recording?")
    return Cast(header, events)


_TMP_PATH = re.compile(r"/(?:private/)?tmp/[^\s\"'\\]*|/var/tmp/[^\s\"'\\]*")
_PID = re.compile(r"\b[Pp][Ii][Dd]\s*=?\s*\d+")
_DURATION = re.compile(r"\b\d+(?:\.\d+)?\s+seconds?\b")


def normalise(text: str, tmp_roots: tuple[str, ...] = (),
              ignore_lines: tuple[str, ...] = ()) -> str:
    """Strip run-specific noise; ANSI escapes pass through untouched.

    `ignore_lines` are regexes; each matching whole line is dropped (setup
    chatter one side prints about the fixture tree, not about the cell).
    """
    for pattern in ignore_lines:
        text = re.sub(rf"^(?:{pattern})[^\n]*\n", "", text, flags=re.M)
    for root in tmp_roots:
        if root:
            text = text.replace(root, "<TMP>")
    text = _TMP_PATH.sub("<TMP>", text)
    text = _PID.sub("PID <PID>", text)
    text = _DURATION.sub("<DURATION>", text)
    return text


@dataclass
class TimingEntry:
    index: int  # i-th output event in each cast
    dt_a: float
    dt_b: float
    ratio: float
    flagged: bool


@dataclass
class Report:
    text_equal: bool
    first_diff: dict | None  # {"offset", "a", "b"}: context around the split
    chunk_equal: bool
    chunks_a: list[int]
    chunks_b: list[int]
    timings: list[TimingEntry] = field(default_factory=list)
    max_ratio: float = 1.0
    n_flagged: int = 0


def _first_diff(a: str, b: str) -> dict | None:
    if a == b:
        return None
    common = min(len(a), len(b))
    offset = next((i for i in range(common) if a[i] != b[i]), common)
    lo = max(0, offset - DIFF_CONTEXT // 2)
    return {"offset": offset,
            "a": a[lo:offset + DIFF_CONTEXT // 2],
            "b": b[lo:offset + DIFF_CONTEXT // 2]}


def compare(a: Cast, b: Cast, tolerance: float = DEFAULT_TOLERANCE,
            tmp_roots: tuple[str, ...] = (),
            ignore_lines: tuple[str, ...] = ()) -> Report:
    """Text, chunking and timing comparison of two parsed casts."""
    norm_a = normalise(a.text, tmp_roots, ignore_lines)
    norm_b = normalise(b.text, tmp_roots, ignore_lines)
    out_a = [e for e in a.events if e.kind == "o"]
    out_b = [e for e in b.events if e.kind == "o"]
    chunks_a = [len(e.data) for e in out_a]
    chunks_b = [len(e.data) for e in out_b]
    # Timing pairs the i-th output event of each side; when the chunking
    # differs the pairing is positional, which the chunking verdict above
    # already flags -- timing stays a report, never a gate.
    timings: list[TimingEntry] = []
    prev_a = prev_b = 0.0
    for i, (ea, eb) in enumerate(zip(out_a, out_b)):
        dt_a, dt_b = ea.t - prev_a, eb.t - prev_b
        prev_a, prev_b = ea.t, eb.t
        if min(dt_a, dt_b) < MIN_EVENT_S:
            continue
        ratio = max(dt_a, dt_b) / min(dt_a, dt_b)
        timings.append(TimingEntry(i, dt_a, dt_b, ratio, ratio > tolerance))
    flagged = [t for t in timings if t.flagged]
    return Report(
        text_equal=norm_a == norm_b,
        first_diff=_first_diff(norm_a, norm_b),
        chunk_equal=chunks_a == chunks_b,
        chunks_a=chunks_a,
        chunks_b=chunks_b,
        timings=timings,
        max_ratio=max([t.ratio for t in timings] or [1.0]),
        n_flagged=len(flagged),
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("a", help="first cast file")
    parser.add_argument("b", help="second cast file")
    parser.add_argument("--strict-text", action="store_true",
                        help="exit 1 when the normalised text differs")
    parser.add_argument("--tolerance", type=float, default=DEFAULT_TOLERANCE,
                        help="timing ratio above this is flagged (default %(default)s)")
    parser.add_argument("--tmp-root", action="append", default=[],
                        help="extra temp dir to normalise away (repeatable)")
    parser.add_argument("--ignore-line", action="append", default=[],
                        help="regex of whole lines to drop before comparing (repeatable)")
    args = parser.parse_args()
    cast_a = parse_cast(Path(args.a))
    cast_b = parse_cast(Path(args.b))
    report = compare(cast_a, cast_b, tolerance=args.tolerance,
                     tmp_roots=tuple(args.tmp_root),
                     ignore_lines=tuple(args.ignore_line))
    print(f"text: {'equal' if report.text_equal else 'DIFFER'}")
    if report.first_diff is not None:
        print(f"first difference at offset {report.first_diff['offset']}:")
        print(f"  a: {report.first_diff['a']!r}")
        print(f"  b: {report.first_diff['b']!r}")
    n_a, n_b = len(report.chunks_a), len(report.chunks_b)
    print(f"chunking: {'equal' if report.chunk_equal else 'DIFFER'} "
          f"({n_a} vs {n_b} output events)")
    print(f"timing: max ratio {report.max_ratio:.1f}x "
          f"({report.n_flagged} flagged above {args.tolerance}x, "
          f"{len(report.timings)} pairs compared)")
    if args.strict_text and not report.text_equal:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
