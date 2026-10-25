"""Backlog #564 self-test: the suite's repos.conf filter.

Portage merges the installed system repos.conf
(`/usr/share/portage/config/repos.conf`, declaring the host `gentoo`
repo) with every run's config-root one
(`repository/config.py::load_repository_config`), so the suite hides the
host file behind a per-invocation mount-namespace bind
(`repos_filter.sh`, wired in through conftest's applet launchers). These
tests prove the host `gentoo` is invisible inside the filter, the
privilege gate behaves as unfiltered, concurrent invocations do not see
each other's mounts, and the bypass runs the real binary directly.
"""

import concurrent.futures
import os
import subprocess
from pathlib import Path

import pytest

FILTER_SH = Path(__file__).parent / "repos_filter.sh"
HOST_REPOS_CONF = Path("/usr/share/portage/config/repos.conf")


def _src() -> str:
    try:
        return os.environ["PMTEST_REPOS_FILTER_SRC"]
    except KeyError:
        pytest.fail("PMTEST_REPOS_FILTER_SRC is not set (run under the suite)")


def _filtered(*argv: str, extra_env: dict | None = None) -> subprocess.CompletedProcess:
    """Run `argv[0]` filtered with argv[0] `argv[1]` (the helper's
    `<real-binary> <argv0>` calling convention)."""
    env = dict(os.environ, PMTEST_REPOS_FILTER_SRC=_src())
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        [str(FILTER_SH), *argv], capture_output=True, text=True, env=env, check=False
    )


def test_filter_hides_the_host_system_repos_conf():
    """Inside the filter the installed-system path reads the fixture
    file (comments only), not the host's `[gentoo]` declaration."""
    src_text = Path(_src()).read_text()
    assert "[gentoo]" not in src_text
    result = _filtered("/bin/cat", "/bin/cat", str(HOST_REPOS_CONF))
    assert result.returncode == 0, result.stderr
    assert result.stdout == src_text
    assert "[gentoo]" not in result.stdout
    assert HOST_REPOS_CONF.read_text() != src_text, (
        "the host file itself must be untouched"
    )


def _portage_gid() -> int | None:
    """The host's `portage` gid, or `None` where no such group exists."""
    try:
        return int(
            subprocess.run(
                ["getent", "group", "portage"],
                capture_output=True,
                text=True,
                check=False,
            ).stdout.split(":")[2]
        )
    except (IndexError, ValueError):
        return None


def test_filter_preserves_the_real_uid_and_file_ownership(tmp_path):
    """The nested user namespace restores the real uid, so the privilege
    gate and created-file ownership behave as unfiltered."""
    result = _filtered("/usr/bin/id", "/usr/bin/id", "-u")
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == str(os.getuid())
    marker = tmp_path / "owned"
    result = _filtered("/usr/bin/touch", "/usr/bin/touch", str(marker))
    assert result.returncode == 0, result.stderr
    assert marker.stat().st_uid == os.getuid()


def test_filter_maps_the_portage_group_so_chgrp_succeeds(tmp_path):
    """Ebuild phases `chgrp` to the portage group (Portage's own helpers
    do): the inner primary gid maps there, so the call succeeds silently
    exactly like outside -- no `EINVAL` line polluting exact-output pins.
    The mapping is outer-current-gid -> portage-gid, so host-side files
    keep the caller's group (asserted here too); only the in-namespace
    view carries `portage`. Skipped where the host has no portage group
    -- there the unfiltered `chgrp` fails identically, so parity holds."""
    portage_gid = _portage_gid()
    if portage_gid is None:
        pytest.skip("no portage group on this host")
    result = _filtered("/usr/bin/id", "/usr/bin/id", "-g")
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == str(portage_gid)
    marker = tmp_path / "grouped"
    marker.touch()
    result = _filtered(
        "/usr/bin/chgrp", "/usr/bin/chgrp", "portage", str(marker)
    )
    assert result.returncode == 0, result.stderr
    assert marker.stat().st_gid == os.getgid(), (
        "host-side the file keeps the caller's group"
    )
    result = _filtered(
        "/usr/bin/stat",
        "/usr/bin/stat",
        "-c",
        "%u %g",
        str(marker),
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == f"{os.getuid()} {portage_gid}", (
        "in-namespace the file carries the portage gid"
    )


def test_filter_mounts_are_per_invocation_and_concurrent():
    """Four concurrent filtered reads all see the fixture file while the
    host keeps reading its own -- the bind lives in a private mount
    namespace per invocation (backlog #564 concurrency note)."""
    src_text = Path(_src()).read_text()
    host_text = HOST_REPOS_CONF.read_text()

    def read_filtered(_: int) -> str:
        result = _filtered("/bin/cat", "/bin/cat", str(HOST_REPOS_CONF))
        assert result.returncode == 0, result.stderr
        return result.stdout

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as workers:
        seen = list(workers.map(read_filtered, range(4)))
    assert seen == [src_text] * 4
    assert HOST_REPOS_CONF.read_text() == host_text


def test_filtered_emerge_sees_no_host_gentoo(emerge_binary, fixture_env):
    """Product-level proof: the filtered `emerge --info` lists the
    fixture repos only, with no `gentoo` entry from the host file."""
    result = subprocess.run(
        [str(emerge_binary), "--info"],
        capture_output=True,
        text=True,
        env=fixture_env,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    repos_block = result.stdout.split("Repositories:")[1].split("Binary ")[0]
    assert "\ngentoo\n" not in f"\n{repos_block}\n"


def test_filter_bypass_runs_the_real_binary_directly():
    """`PMTEST_REPOS_FILTER=off` execs the binary with no namespaces --
    the escape hatch the sudo/real-root tests use."""
    result = _filtered(
        "/bin/cat",
        "/bin/cat",
        str(HOST_REPOS_CONF),
        extra_env={"PMTEST_REPOS_FILTER": "off"},
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout == HOST_REPOS_CONF.read_text()


def test_filter_preserves_a_fake_pwd(tmp_path):
    """POSIX shells reset `$PWD` at startup when it names a nonexistent
    dir; the Python launcher carries the real value through and the
    helper restores it at every exec point, so title-style consumers see
    the fake dir (and the carrier never leaks into the child env)."""
    marker = tmp_path / "pwd.txt"
    launcher = tmp_path / "pwdprobe"
    launcher.write_text(
        "#!/usr/bin/python3\n"
        "import os, sys\n"
        f"REAL = '/usr/bin/env'\n"
        f"HELPER = {str(FILTER_SH)!r}\n"
        "env = dict(os.environ)\n"
        'env.setdefault("PWD", os.getcwd())\n'
        'env["_PMTEST_SAVED_PWD"] = env["PWD"]\n'
        "os.execve(HELPER, [HELPER, REAL, sys.argv[0], *sys.argv[1:]], env)\n"
    )
    launcher.chmod(0o755)
    env = dict(
        os.environ,
        PMTEST_REPOS_FILTER_SRC=_src(),
        PWD="/fake/dir/for/title",
    )
    result = subprocess.run(
        [str(launcher)], capture_output=True, text=True, env=env, check=False
    )
    assert result.returncode == 0, result.stderr
    assert "\nPWD=/fake/dir/for/title\n" in f"\n{result.stdout}\n"
    assert "_PMTEST_SAVED_PWD" not in result.stdout
