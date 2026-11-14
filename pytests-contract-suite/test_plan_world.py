"""`mrg --plan-world[=update|emptytree]` on the fixture world. Expected behaviour comes from the
charter, not from Portage (`--plan-world` does not exist there): property 5 (a message names what
it did and what it did not do), property 1 (the JSON plan is one the health checker can judge),
and the PMS (`dependencies.tex`: everything is built, so every build-time edge binds)."""

import subprocess

import health_checker as hc


def _plan(mrg_binary, fixture_env, *args):
    return subprocess.run(
        [str(mrg_binary), "--plan-world", *args],
        capture_output=True, text=True, env=fixture_env, check=False,
    )


def test_plan_world_update_says_on_stderr_what_it_did_not_check(mrg_binary, fixture_env):
    """Charter property 5: two stderr lines, the count and the order, then what was not looked
    at and the command that does look; stdout is the rows and nothing else."""
    run = _plan(mrg_binary, fixture_env, "--sort", "depend")
    assert run.returncode == 0, run.stderr
    assert run.stderr == (
        "plan-world: 4 to install, order depend\n"
        "not checked: blockers, REQUIRED_USE, slot conflicts, USE rebuilds; "
        "run 'mrg -puDN @world' for the full plan\n"
    )
    assert run.stdout.splitlines() == [
        "[ebuild  N     ] dev-libs/innernestedsetpkg-1.0:0",
        "[ebuild  N     ] dev-libs/newpkg-1.0:0",
        "[ebuild     U  ] dev-libs/upgradepkg-2.0:0 [1.0]",
        "[ebuild  N     ] dev-libs/withdeps-1.0:0",
    ]


def test_plan_world_with_the_mode_named_is_the_bare_plan(mrg_binary, fixture_env):
    """Owner decision Q1 of plan 02.692: a bare `--plan-world` is `--plan-world=update`."""
    bare = _plan(mrg_binary, fixture_env, "--sort", "depend")
    named = subprocess.run(
        [str(mrg_binary), "--plan-world=update", "--sort", "depend"],
        capture_output=True, text=True, env=fixture_env, check=False,
    )
    assert (named.returncode, named.stdout, named.stderr) == (0, bare.stdout, bare.stderr)


def test_plan_world_emptytree_lists_every_reached_slot_and_names_its_full_plan(mrg_binary, fixture_env):
    """Charter property 5 and the PMS: everything is built, so a kept version is an `R` row, and
    the stderr line names `mrg -pe @world`, with no USE rebuilds left to mention."""
    run = subprocess.run(
        [str(mrg_binary), "--plan-world=emptytree", "--sort", "depend"],
        capture_output=True, text=True, env=fixture_env, check=False,
    )
    assert run.returncode == 0, run.stderr
    rows = run.stdout.splitlines()
    assert "[ebuild   R    ] dev-libs/systempkg-1.0:0" in rows
    assert "[ebuild     U  ] dev-libs/upgradepkg-2.0:0 [1.0]" in rows
    assert all(r.startswith("[ebuild") for r in rows)
    assert run.stderr == (
        f"plan-world: {len(rows)} to install, order depend\n"
        "not checked: blockers, REQUIRED_USE, slot conflicts; "
        "run 'mrg -pe @world' for the full plan\n"
    )


def test_plan_world_unknown_mode_is_a_usage_error_naming_both(mrg_binary, fixture_env):
    """Charter property 5: the message names the two modes that exist."""
    run = subprocess.run([str(mrg_binary), "--plan-world=full"],
                         capture_output=True, text=True, env=fixture_env, check=False)
    assert (run.returncode, run.stdout) == (2, "")
    assert "update" in run.stderr and "emptytree" in run.stderr, run.stderr


def test_plan_world_emptytree_json_is_a_plan_the_checker_loads(mrg_binary, fixture_env):
    """Charter property 1: a kept version is a `reinstall` entry, is not repeated in `kept`, and
    the checker finds nothing wrong that the installed system did not have already."""
    run = subprocess.run(
        [str(mrg_binary), "--plan-world=emptytree", "--json", "--sort", "depend"],
        capture_output=True, text=True, env=fixture_env, check=False)
    doc = hc.parse_json_output(run.stdout)
    assert run.returncode == 0 and doc is not None, run.stdout + run.stderr
    assert len(run.stdout.splitlines()) == 1
    by_package = {e["package"]: e["outcome"] for e in doc["entries"]}
    assert by_package["systempkg"] == "reinstall" and by_package["upgradepkg"] == "upgrade"
    assert "systempkg" not in {k["package"] for k in doc["kept"]}
    assert [e["merge_order"] for e in doc["entries"]] == list(range(len(doc["entries"])))
    vdb = hc.Path(fixture_env["ROOT"]) / "var/db/pkg"
    found = [f for f in hc.check_document(doc, vdb) if f.is_failure and not f.pre_existing]
    assert found == [], found


def test_740_the_plan_takes_the_newest_arm(mrg_binary, fixture_env, tmp_path):
    """Charter property 3 (backlog #740): the fast plan takes the `||` arm whose atoms the
    best visible candidates match, so the compat package is new and the provider upgrades
    instead of staying pinned to the installed sub-slot. A CASES/`emerge` pin is the wrong
    shape: this is the fast plan, not `emerge`."""
    root = tmp_path / "root"
    (root / "var/lib/portage").mkdir(parents=True)
    (root / "var/lib/portage/world").write_text("dev-libs/w740user\ndev-libs/w740sudo\n")
    for pf, slot in (("dev-libs/w740prov-3", "0/3"), ("dev-libs/w740sudo-1", "0")):
        vdb = root / "var/db/pkg" / pf
        vdb.mkdir(parents=True)
        (vdb / "CATEGORY").write_text("dev-libs\n")
        (vdb / "SLOT").write_text(f"{slot}\n")
        (vdb / "EAPI").write_text("8\n")
    env = dict(fixture_env)
    env["ROOT"] = str(root)
    env["PORTAGE_RUNNING_ROOT"] = str(root)
    run = subprocess.run(
        [str(mrg_binary), "--plan-world"],
        capture_output=True, text=True, env=env, check=False,
    )
    assert run.returncode == 0, run.stderr
    assert "[ebuild  N     ] dev-libs/w740compat-3:3" in run.stdout.splitlines(), run.stdout
    assert "[ebuild     U  ] dev-libs/w740prov-4:0 [3]" in run.stdout.splitlines(), run.stdout
