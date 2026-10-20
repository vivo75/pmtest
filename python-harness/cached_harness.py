#!/usr/bin/env python3
"""Answer cache in front of the Python reference harnesses (backlog #448).

Usage:
    cached_harness.py <harness_name> [args...]

`<harness_name>` is one of atom, versions, use_reduce, required_use: the
script runs `python-harness/<harness_name>_harness.py` with the same argv
and returns its (returncode, stdout, stderr). A recorded answer is replayed
without starting Portage at all, so a hit costs a few milliseconds.

Cache key = sha256 over the Portage pin, the harness file's sha256, the
wrapper's (`_pinned_portage.py`) sha256, the argv, and the stdin bytes
(stdin is only read in `batch` mode, the one mode that consumes it). The
pin is `git rev-parse HEAD` of the Portage checkout, or the sha256 of its
`lib/portage/__init__.py` when that is not a git checkout. A checkout with
local changes to tracked files has no usable pin, so it runs live.

Store: `python-harness/answers/<harness_name>.jsonl`, append-only, one
JSON object per line; the last line for a key wins. Read ONLY the stdlib
here: importing portage on a hit would defeat the point.

Environment:
    PMTEST_PORTAGE_CACHE=off   bypass the cache entirely (no read, no write)
    PMTEST_REFRESH_PORTAGE=1   ignore hits, run live, append the new answer

Portuale's own answers are never cached: this script only wraps the
reference (Portage) side.
"""

import hashlib
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from _pinned_portage import checkout_dir  # noqa: E402  (stdlib-only module)

ANSWERS_DIR = os.path.join(HERE, "answers")
ENV_CACHE = "PMTEST_PORTAGE_CACHE"
ENV_REFRESH = "PMTEST_REFRESH_PORTAGE"


def _sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def _sha256_file(path):
    with open(path, "rb") as f:
        return _sha256_bytes(f.read())


def portage_pin(checkout):
    """The identity of the Portage checkout, or None when it is unknown or
    dirty (the caller then runs live: a stale hit is worse than none)."""
    if not os.path.isfile(os.path.join(checkout, "lib", "portage", "__init__.py")):
        return None
    try:
        top = subprocess.run(
            ["git", "-C", checkout, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=10,
        )
        head = subprocess.run(
            ["git", "-C", checkout, "rev-parse", "HEAD"],
            capture_output=True, text=True, timeout=10,
        )
        if top.returncode == 0 and head.returncode == 0:
            # Guard: a non-repo checkout inside another repo would report
            # the outer HEAD.
            if os.path.realpath(top.stdout.strip()) != os.path.realpath(checkout):
                raise OSError("checkout is not its own git repository")
            dirty = subprocess.run(
                ["git", "-C", checkout, "status", "--porcelain",
                 "--untracked-files=no"],
                capture_output=True, text=True, timeout=30,
            )
            if dirty.returncode != 0 or dirty.stdout.strip():
                return None
            return "git:" + head.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    init = os.path.join(checkout, "lib", "portage", "__init__.py")
    try:
        return "file:" + _sha256_file(init)
    except OSError:
        return None


def cache_key(name, pin, harness_sha, wrapper_sha, argv, stdin_bytes):
    payload = json.dumps(
        {
            "harness": name,
            "portage": pin,
            "harness_sha": harness_sha,
            "wrapper_sha": wrapper_sha,
            "argv": list(argv),
            "stdin_sha": _sha256_bytes(stdin_bytes),
        },
        sort_keys=True,
    )
    return _sha256_bytes(payload.encode("utf-8"))


def load_answers(path):
    """key -> record; the last line for a key wins, damaged lines are skipped
    (a torn write from a killed run must not poison the whole file)."""
    answers = {}
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
    except FileNotFoundError:
        return answers
    for line in lines:
        try:
            record = json.loads(line)
            answers[record["key"]] = record
        except (ValueError, KeyError, TypeError):
            continue
    return answers


def append_answer(path, record):
    """One O_APPEND write per record, so concurrent runs cannot interleave."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    data = (json.dumps(record) + "\n").encode("utf-8")
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        while data:
            written = os.write(fd, data)
            data = data[written:]
    finally:
        os.close(fd)


def run_live(harness_path, argv, stdin_bytes, batch):
    """Run the real harness; returns (rc, stdout_bytes, stderr_bytes)."""
    proc = subprocess.run(
        [sys.executable, harness_path, *argv],
        input=stdin_bytes if batch else None,
        capture_output=True,
    )
    return proc.returncode, proc.stdout, proc.stderr


def answer(name, argv, stdin_bytes, *, harness_dir=HERE, answers_dir=ANSWERS_DIR,
           checkout=None):
    """(rc, stdout_bytes, stderr_bytes) for `<name>_harness.py argv`, from the
    cache when a valid record exists, otherwise live (and recorded)."""
    harness_path = os.path.join(harness_dir, f"{name}_harness.py")
    if not os.path.isfile(harness_path):
        raise SystemExit(f"cached_harness: no harness named {name!r} "
                         f"({harness_path} missing)")
    batch = bool(argv) and argv[0] == "batch"
    cache_off = os.environ.get(ENV_CACHE, "") == "off"
    if cache_off:
        return run_live(harness_path, argv, stdin_bytes, batch)

    pin = portage_pin(checkout if checkout is not None else checkout_dir())
    if pin is None:
        return run_live(harness_path, argv, stdin_bytes, batch)

    key = cache_key(
        name, pin,
        _sha256_file(harness_path),
        _sha256_file(os.path.join(HERE, "_pinned_portage.py")),
        argv, stdin_bytes,
    )
    store = os.path.join(answers_dir, f"{name}.jsonl")
    if os.environ.get(ENV_REFRESH, "") != "1":
        hit = load_answers(store).get(key)
        if hit is not None:
            return (hit["rc"], hit["stdout"].encode("utf-8", "surrogateescape"),
                    hit["stderr"].encode("utf-8", "surrogateescape"))

    rc, out, err = run_live(harness_path, argv, stdin_bytes, batch)
    append_answer(store, {
        "key": key,
        "portage": pin,
        "argv": list(argv),
        "rc": rc,
        "stdout": out.decode("utf-8", "surrogateescape"),
        "stderr": err.decode("utf-8", "surrogateescape"),
    })
    return rc, out, err


def main(argv):
    if not argv:
        print("usage: cached_harness.py <harness_name> [args...]", file=sys.stderr)
        return 2
    name, rest = argv[0], argv[1:]
    stdin_bytes = sys.stdin.buffer.read() if rest and rest[0] == "batch" else b""
    rc, out, err = answer(name, rest, stdin_bytes)
    sys.stdout.buffer.write(out)
    sys.stdout.buffer.flush()
    sys.stderr.buffer.write(err)
    sys.stderr.buffer.flush()
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
