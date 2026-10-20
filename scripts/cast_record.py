#!/usr/bin/env python3
"""Record an argv under `asciinema rec --headless` at a fixed tty size (backlog #443 C1).

Runs the given argv in a headless asciinema session (120x40, `-q`), with
the caller's environment passed through, and returns the cast path plus
the exit code read back from the cast's own `"x"` event. asciinema's own
exit status is 0 even when the recorded command fails, so the cast is the
source of truth for the exit code.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
from pathlib import Path

COLS = 120
ROWS = 40


def record(argv: list[str], out: Path, env: dict[str, str] | None = None) -> tuple[Path, int]:
    """Record argv to out; return (cast path, exit code from the "x" event)."""
    asciinema = shutil.which("asciinema")
    if asciinema is None:
        raise FileNotFoundError("asciinema not found on PATH; cannot record")
    out = Path(out)
    # One shell-quoted string: asciinema -c takes a single command line.
    cmd = shlex.join(str(a) for a in argv)
    subprocess.run(
        [asciinema, "rec", "--headless", "--overwrite", "-q",
         "--window-size", f"{COLS}x{ROWS}", "-c", cmd, str(out)],
        env=env if env is not None else os.environ,
        check=True,
    )
    return out, exit_code(out)


def exit_code(path: Path) -> int:
    """Exit code from the last "x" event of a v3 cast."""
    code = None
    for lineno, line in enumerate(Path(path).read_text().splitlines()[1:], start=2):
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValueError(f"{path}:{lineno}: garbled event line: {exc}") from None
        if not isinstance(event, list) or len(event) != 3:
            raise ValueError(f"{path}:{lineno}: not a [delta, kind, data] event: {line[:80]!r}")
        if event[1] == "x":
            code = int(event[2])
    if code is None:
        raise ValueError(f"{path}: no 'x' (exit) event; truncated recording?")
    return code


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("out", help="cast file to write")
    parser.add_argument("argv", nargs=argparse.REMAINDER,
                        help="command to record (prefix with -- to separate)")
    args = parser.parse_args()
    cmd = args.argv[1:] if args.argv[:1] == ["--"] else args.argv
    if not cmd:
        parser.error("no command to record")
    path, rc = record(cmd, Path(args.out))
    print(f"{path}: exit {rc}")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
