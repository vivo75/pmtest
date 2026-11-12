"""#706: `mrg --future-options=name,other=value` switches on behaviour that is not a plain
option yet. Expected behaviour comes from the charter (property 1: every package that stays
installed has its dependencies; property 3: the same input gives the same plan; property 5:
messages help), not from Portage: `--check-world` and these options do not exist there."""

import subprocess

import pytest


def _mrg(mrg_binary, fixture_env, tmp_path, args, world, env_extra=None):
    root = tmp_path / "root"
    (root / "var/lib/portage").mkdir(parents=True)
    (root / "var/lib/portage/world").write_text("".join(a + "\n" for a in world))
    env = dict(fixture_env)
    env["ROOT"] = str(root)
    env["PORTAGE_RUNNING_ROOT"] = str(root)
    env.update(env_extra or {})
    return subprocess.run(
        [str(mrg_binary), "--check-world", *args],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )


def test_706_unique_is_off_by_default_and_on_with_the_option(mrg_binary, fixture_env, tmp_path):
    """A slot with two satisfying versions is fine, until `check-world-unique` asks for one."""
    off = _mrg(mrg_binary, fixture_env, tmp_path, [], ["dev-libs/w701dup"])
    assert off.returncode == 0, off.stdout
    on = _mrg(
        mrg_binary,
        fixture_env,
        tmp_path / "on",
        ["--future-options=check-world-unique"],
        ["dev-libs/w701dup"],
    )
    assert on.returncode == 1, on.stdout
    assert "INVALID dev-libs/w701dup:0" in on.stdout


def test_706_unneeded_slots_are_listed_only_with_the_option(mrg_binary, fixture_env, tmp_path):
    """`check-world-unneeded` names the slot another slot serves; the exit code stays 0."""
    off = _mrg(mrg_binary, fixture_env, tmp_path, [], ["dev-libs/w701two"])
    assert off.returncode == 0 and "UNNEEDED" not in off.stdout, off.stdout
    on = _mrg(
        mrg_binary,
        fixture_env,
        tmp_path / "on",
        ["--future-options=check-world-unneeded"],
        ["dev-libs/w701two"],
    )
    assert on.returncode == 0, on.stdout
    assert "UNNEEDED dev-libs/w701two:1" in on.stdout


@pytest.mark.parametrize("threads", ["1", "2", "8"])
def test_706_the_thread_count_does_not_change_the_answer(
    mrg_binary, fixture_env, tmp_path, threads
):
    """Property 3: the same world gives the same report on 1, 2 and 8 threads."""
    world = ["dev-libs/w701ver", "dev-libs/w701two", "dev-libs/w701dup"]
    ref = _mrg(
        mrg_binary, fixture_env, tmp_path / "ref",
        ["--future-options=check-world-unique,check-world-threads=1"], world,
    )
    got = _mrg(
        mrg_binary, fixture_env, tmp_path / "got",
        [f"--future-options=check-world-unique,check-world-threads={threads}"], world,
    )
    assert "package slots" in ref.stdout, ref.stdout
    assert (got.returncode, got.stdout) == (ref.returncode, ref.stdout)


def test_706_an_unknown_name_is_refused_with_the_nearest(mrg_binary, fixture_env, tmp_path):
    got = _mrg(
        mrg_binary, fixture_env, tmp_path, ["--future-options=check-world-uniqe"], []
    )
    assert got.returncode == 2
    assert "unknown future option" in got.stderr
    assert "closest: check-world-unique" in got.stderr, got.stderr


def test_706_the_environment_sets_an_option_and_the_flag_overrides_it(
    mrg_binary, fixture_env, tmp_path
):
    """The command line wins over `PORTUALE_FUTURE_OPTIONS` (make.conf is pinned in the Rust
    test, which owns a writable copy of the config tree)."""
    env = {"PORTUALE_FUTURE_OPTIONS": "check-world-unique"}
    via_env = _mrg(mrg_binary, fixture_env, tmp_path, [], ["dev-libs/w701dup"], env)
    assert via_env.returncode == 1, via_env.stdout
    flag_off = _mrg(
        mrg_binary,
        fixture_env,
        tmp_path / "off",
        ["--future-options=check-world-unique=false"],
        ["dev-libs/w701dup"],
        env,
    )
    assert flag_off.returncode == 0, flag_off.stdout


def test_706_help_names_every_option_with_its_stage(mrg_binary, fixture_env):
    out = subprocess.run(
        [str(mrg_binary), "--help"], capture_output=True, text=True, env=fixture_env, check=False
    ).stdout
    for name in ("check-world-unique", "check-world-threads", "check-world-unneeded", "plan-world-newuse"):
        assert name in out
    assert "alpha since" in out
