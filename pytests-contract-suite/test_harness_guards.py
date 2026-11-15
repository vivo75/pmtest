"""The harness space guards (backlog #756).

`check-work-space.sh` used to answer "is there room?" with `df -Pk` size only.
On 2026-11-15 a full gate run's basetemp on `/tmp` exhausted that tmpfs's
1 048 576 inodes while 63 G were free, and the suite reported 182 ENOSPC
errors and 2 failures that read as product regressions (the same tree under
`/var/tmp` was green). A complete run needs ~1.8 M inodes (measured: 1 804 465
for 4967 tests), which no 1 M-inode tmpfs can hold.

These pins drive the three scripts through a `df` shim on `PATH` — the
scripts invoke bare `df`, so the shim controls them — and assert **exit code
and message only**: the failure path also prints a real `du` table over the
real mounts, which is host-variable and must not be asserted on.
"""

from __future__ import annotations

import os
import subprocess
import textwrap
from pathlib import Path

import pytest

PMTEST_ROOT = Path(__file__).resolve().parents[1]
PORTUALE_ROOT = PMTEST_ROOT.parent / "portuale"
CHECK = PORTUALE_ROOT / "LLM/tools/check-work-space.sh"
GATE = PORTUALE_ROOT / "LLM/tools/gate.sh"
PARALLEL = PMTEST_ROOT / "scripts/pytest-parallel.sh"

pytestmark = pytest.mark.skipif(
    not CHECK.is_file() or not GATE.is_file(),
    reason="the sibling portuale checkout is not present (pmtest stood alone)",
)


def _shim(tmp_path: Path, *, bytes_pct: int, inodes_total: int, inodes_free: int) -> Path:
    """A `df` that answers both shapes the scripts use."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(parents=True)
    script = bin_dir / "df"
    script.write_text(
        textwrap.dedent(
            f"""\
            #!/bin/sh
            case " $* " in
              *" -Pi "*|*" -i "*)
                printf 'Filesystem Inodes IUsed IFree IUse%% Mounted on\\n'
                printf 'shim %s 1 %s 1%% /shim\\n' "${{SHIM_INODES_TOTAL}}" "${{SHIM_INODES_FREE}}"
                ;;
              *)
                printf 'Filesystem 1K-blocks Used Available Capacity Mounted on\\n'
                printf 'shim 100 1 %s 1%% /shim\\n' "${{SHIM_BYTES_FREE}}"
                ;;
            esac
            """
        )
    )
    script.chmod(0o755)
    return bin_dir


def _env(bin_dir: Path, **extra: str) -> dict[str, str]:
    env = dict(os.environ)
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    env.update(extra)
    return env


def _run(argv: list[str], env: dict[str, str]) -> subprocess.CompletedProcess:
    return subprocess.run(argv, capture_output=True, text=True, env=env, timeout=120)


# --- check-work-space.sh -------------------------------------------------


def test_bytes_low_and_inodes_fine_still_fails_on_space(tmp_path):
    bin_dir = _shim(tmp_path, bytes_pct=0, inodes_total=10_000_000, inodes_free=9_000_000)
    env = _env(bin_dir, SHIM_BYTES_FREE="1", SHIM_INODES_TOTAL="10000000",
               SHIM_INODES_FREE="9000000")
    out = _run(["sh", str(CHECK)], env)
    assert out.returncode == 1
    assert "not enough free space" in out.stdout
    assert "LOW" in out.stdout


def test_inodes_low_and_bytes_fine_fails_on_inodes(tmp_path):
    # 150 free inodes is below the 200 000 sanity floor; space is plentiful.
    env = _env(
        _shim(tmp_path, bytes_pct=99, inodes_total=1000, inodes_free=150),
        SHIM_BYTES_FREE="99", SHIM_INODES_TOTAL="1000", SHIM_INODES_FREE="150",
    )
    out = _run(["sh", str(CHECK)], env)
    assert out.returncode == 1
    assert "inodes" in out.stdout
    assert "not enough free space" in out.stdout


def test_both_plenty_is_ok_and_prints_both_tables(tmp_path):
    env = _env(
        _shim(tmp_path, bytes_pct=99, inodes_total=10_000_000, inodes_free=9_000_000),
        SHIM_BYTES_FREE="99", SHIM_INODES_TOTAL="10000000", SHIM_INODES_FREE="9000000",
    )
    out = _run(["sh", str(CHECK)], env)
    assert out.returncode == 0
    assert "inodes (sanity floor" in out.stdout
    assert "LOW" not in out.stdout


def test_a_zero_inode_filesystem_is_warned_about_not_refused(tmp_path):
    """btrfs and zfs report 0 inodes in total (#762): nothing to size, so the
    inode check is skipped with a WARN line rather than refusing the run."""
    env = _env(
        _shim(tmp_path, bytes_pct=99, inodes_total=0, inodes_free=0),
        SHIM_BYTES_FREE="99", SHIM_INODES_TOTAL="0", SHIM_INODES_FREE="0",
    )
    out = _run(["sh", str(CHECK)], env)
    assert out.returncode == 0, out.stderr
    assert "WARN" in out.stdout
    assert "division by zero" not in out.stderr
    assert "error token" not in out.stderr

    guard = _run(["sh", str(CHECK), "--require-inodes", str(tmp_path)], env)
    assert guard.returncode == 0, guard.stderr
    assert "WARN" in guard.stderr

    both = _run(["sh", str(CHECK), "--basetemp", str(tmp_path)], env)
    assert both.returncode == 0, both.stderr
    assert "WARN" in both.stderr


def test_basetemp_mode_checks_space_and_inodes_in_one_call(tmp_path):
    short = _env(
        _shim(tmp_path, bytes_pct=99, inodes_total=1_048_576, inodes_free=959_944),
        SHIM_BYTES_FREE="99", SHIM_INODES_TOTAL="1048576", SHIM_INODES_FREE="959944",
    )
    out = _run(["sh", str(CHECK), "--basetemp", str(tmp_path / "bt")], short)
    assert out.returncode == 1
    assert "free inodes" in out.stderr
    assert "inodes (sanity floor" in out.stdout, "the space tables ride along"


def test_require_inodes_refuses_a_short_filesystem(tmp_path):
    env = _env(
        _shim(tmp_path, bytes_pct=99, inodes_total=1_048_576, inodes_free=959_944),
        SHIM_BYTES_FREE="99", SHIM_INODES_TOTAL="1048576", SHIM_INODES_FREE="959944",
    )
    target = tmp_path / "not-created-yet" / "basetemp"
    out = _run(["sh", str(CHECK), "--require-inodes", str(target)], env)
    assert out.returncode == 1
    assert "free inodes" in out.stderr
    assert not target.exists(), "the check must not create the path it judges"


def test_require_inodes_accepts_a_big_filesystem_and_the_override(tmp_path):
    env = _env(
        _shim(tmp_path, bytes_pct=99, inodes_total=10_737_418_240, inodes_free=10_733_796_674),
        SHIM_BYTES_FREE="99",
        SHIM_INODES_TOTAL="10737418240",
        SHIM_INODES_FREE="10733796674",
    )
    ok = _run(["sh", str(CHECK), "--require-inodes", str(tmp_path)], env)
    assert ok.returncode == 0

    short = _env(
        _shim(tmp_path / "short", bytes_pct=99, inodes_total=1_048_576, inodes_free=959_944),
        SHIM_BYTES_FREE="99", SHIM_INODES_TOTAL="1048576", SHIM_INODES_FREE="959944",
    )
    refused = _run(["sh", str(CHECK), "--require-inodes", str(tmp_path / "short")], short)
    assert refused.returncode == 1
    overridden = _run(
        ["sh", str(CHECK), "--require-inodes", str(tmp_path / "short")],
        dict(short, PMTEST_MIN_BASETEMP_INODES="100"),
    )
    assert overridden.returncode == 0, overridden.stderr


@pytest.mark.parametrize("bad", ["-5", "0", "abc", "1e6", " "])
def test_a_malformed_inode_override_is_refused_not_ignored(tmp_path, bad):
    """A knob that silently ignores a bad value is a bypass: `-5` compares
    false and lets the run through, `abc` errors inside `[ ]` without
    tripping `set -e`. Both entry points must fail closed."""
    env = _env(
        _shim(tmp_path, bytes_pct=99, inodes_total=1_048_576, inodes_free=959_944),
        SHIM_BYTES_FREE="99", SHIM_INODES_TOTAL="1048576", SHIM_INODES_FREE="959944",
        PMTEST_MIN_BASETEMP_INODES=bad,
    )
    checker = _run(["sh", str(CHECK), "--require-inodes", str(tmp_path)], env)
    assert checker.returncode == 2, checker
    assert "positive integer" in checker.stderr or "greater than 0" in checker.stderr

    parallel = _run(
        ["bash", str(PARALLEL), f"--basetemp={tmp_path / 'bt'}", "-q", "-k", "nothing"],
        env,
    )
    assert parallel.returncode == 2, parallel
    assert "PMTEST_MIN_BASETEMP_INODES" in parallel.stderr


# --- the two entry points ------------------------------------------------


def test_pytest_parallel_refuses_a_short_basetemp_before_deleting_it(tmp_path):
    bin_dir = _shim(tmp_path, bytes_pct=99, inodes_total=1_048_576, inodes_free=959_944)
    env = _env(bin_dir, SHIM_BYTES_FREE="99", SHIM_INODES_TOTAL="1048576",
               SHIM_INODES_FREE="959944")
    basetemp = tmp_path / "keep-me"
    basetemp.mkdir()
    (basetemp / "sentinel").write_text("must survive a refusal")
    out = _run(
        ["bash", str(PARALLEL), f"--basetemp={basetemp}", "-q", "-k", "nothing"],
        env,
    )
    assert out.returncode == 2
    assert "free inodes" in out.stderr
    assert (basetemp / "sentinel").exists(), "a refusal must not delete the basetemp"


def test_gate_refuses_a_short_out_and_removes_only_what_it_created(tmp_path):
    bin_dir = _shim(tmp_path, bytes_pct=99, inodes_total=1_048_576, inodes_free=959_944)
    env = _env(bin_dir, SHIM_BYTES_FREE="99", SHIM_INODES_TOTAL="1048576",
               SHIM_INODES_FREE="959944")
    fresh = tmp_path / "fresh-out"
    out = _run(["sh", str(GATE), str(fresh)], env)
    assert out.returncode == 2
    assert "free inodes" in out.stdout + out.stderr
    assert not fresh.exists(), "gate.sh must remove the directory it created"

    keep = tmp_path / "caller-out"
    keep.mkdir()
    (keep / "mine").write_text("x")
    out2 = _run(["sh", str(GATE), str(keep)], env)
    assert out2.returncode == 2
    assert (keep / "mine").exists(), "a caller's directory is never deleted"


def test_pytest_parallel_warns_and_runs_on_a_zero_inode_filesystem(tmp_path):
    """The 0-inode case (#762) through the entry point, and the proof that it
    delegates to portuale's checker (its table is on the output)."""
    venv = tmp_path / "venv"
    (venv / "bin").mkdir(parents=True)
    stub = venv / "bin/python"
    stub.write_text("#!/bin/sh\nexit 0\n")
    stub.chmod(0o755)
    env = _env(
        _shim(tmp_path, bytes_pct=99, inodes_total=0, inodes_free=0),
        SHIM_BYTES_FREE="99", SHIM_INODES_TOTAL="0", SHIM_INODES_FREE="0",
        PMTEST_XDIST_VENV=str(venv),
    )
    out = _run(["bash", str(PARALLEL), f"--basetemp={tmp_path / 'bt'}"], env)
    assert out.returncode == 0, out
    assert "WARN" in out.stdout + out.stderr
    assert "sanity floor" in out.stdout + out.stderr


def _fake_gate_root(tmp_path: Path, checker_body: str) -> Path:
    """A throwaway repo root holding a copy of gate.sh and a stub checker, so
    an unfixed gate can only ever delete this directory."""
    root = tmp_path / "portuale"
    (root / "LLM/tools").mkdir(parents=True)
    (root / "LLM/tools/gate.sh").write_text(GATE.read_text())
    stub = root / "LLM/tools/check-work-space.sh"
    stub.write_text(checker_body)
    (root / "sentinel").write_text("must survive")
    return root


def test_gate_refuses_an_empty_out_argument_first(tmp_path):
    """`gate.sh ""` resolved OUT to the repo root and could rm -rf it (#762)."""
    root = _fake_gate_root(tmp_path, "#!/bin/sh\nexit 1\n")
    out = _run(["sh", str(root / "LLM/tools/gate.sh"), ""], dict(os.environ))
    assert out.returncode == 2, out
    assert "argument is empty" in out.stderr, out
    assert (root / "sentinel").exists(), "the root must survive an empty argument"


def test_gate_calls_the_space_checker_once(tmp_path):
    root = _fake_gate_root(
        tmp_path, '#!/bin/sh\necho "$*" >>"$(dirname "$0")/calls"\nexit 1\n'
    )
    out = _run(["sh", str(root / "LLM/tools/gate.sh"), str(tmp_path / "out")], dict(os.environ))
    assert out.returncode == 2, out
    calls = (root / "LLM/tools/calls").read_text().splitlines()
    assert len(calls) == 1 and calls[0].startswith("--basetemp "), calls
    assert GATE.read_text().count("check-work-space.sh") == 1
