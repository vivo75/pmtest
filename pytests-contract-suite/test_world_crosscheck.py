"""Charter properties 1 and 3: `world-crosscheck.py` sets the fast world plan
(`mrg --plan-world --json`), the check (`mrg --check-world --json`) and the
resolver's @world plan side by side. A difference is information to judge,
not a failure; each output line says which class it is. Inputs here are
hand-written; the expected lines follow from them, not from any program.
"""

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "differential-test-bed/compare/world-crosscheck.py"


def load():
    spec = importlib.util.spec_from_file_location("world_crosscheck", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def entry(cpv, outcome, slot="0"):
    cat, rest = cpv.split("/")
    pn, version = rest.rsplit("-", 1)
    return {"category": cat, "package": pn, "version": version, "slot": slot, "outcome": outcome}


def finding(prop, package, atom):
    return {"property": prop, "package": package, "atom": atom, "reason": "x", "pre_existing": False}


def kinds(lines):
    return [(line.cls, line.kind) for line in lines]


def test_two_plans_that_agree_give_no_line_to_judge():
    resolver = {"entries": [entry("a/b-2", "upgrade"), entry("c/d-1", "already_installed")]}
    fast = {"entries": [entry("a/b-2", "upgrade")], "kept": [entry("c/d-1", "x")], "aborted": None}
    assert load().crosscheck(resolver, fast, []) == []


def test_two_plans_that_differ_say_which_class_each_difference_is():
    resolver = {"entries": [
        entry("a/b-3", "upgrade"), entry("p/q-1", "new"), entry("r/s-1", "reinstall"),
        entry("m/n-1", "already_installed", None), entry("t/u-1", "upgrade", "1")]}
    fast = {"entries": [entry("a/b-2", "upgrade"), entry("x/y-1", "new"), entry("m/n-2", "upgrade"),
                        entry("t/u-1", "upgrade", "2")],
            "kept": [], "aborted": None}
    check = [finding("world-no-match", "@world", ">=a/b-3"),
             finding("world-no-match", "@world", "no/pkg"),
             finding("world-unneeded", "a/b:0", "")]
    got = load().crosscheck(resolver, fast, check)
    assert kinds(got) == [
        ("judge", "world-version-differs"),
        ("judge", "world-invalid-but-planned"),
        ("note", "fast-only"),
        ("note", "fast-only"),
        ("note", "fast-only"),
        ("note", "resolver-only"),
        ("note", "resolver-only"),
        ("note", "resolver-only-reinstall"),
    ]
    text = "\n".join(line.text for line in got)
    assert "a/b:0" in text and "fast=2" in text and "resolver=3" in text
    assert ">=a/b-3" in text and "resolver" in got[1].text
    assert "no/pkg" not in text  # nothing satisfies it: both programs agree
    assert "m/n:0" in text and "keeps" in text  # the resolver keeps m/n installed
    assert "t/u:1" in text and "t/u:2" in text  # slots only one side lists


def test_a_resolver_that_gave_up_on_a_world_the_check_calls_clean_is_said_so():
    fast = {"entries": [], "kept": [], "aborted": None}
    got = load().crosscheck({"entries": [], "aborted": {"reason": "slot conflict"}}, fast, [])
    assert kinds(got) == [("judge", "world-clean-but-resolver-refused")]
    got = load().crosscheck({"entries": [], "slot_conflicts": [{}]}, fast, [])
    assert kinds(got) == [("judge", "world-clean-but-resolver-refused")]


def test_a_fast_plan_stale_binding_the_plan_does_not_repair_is_noted():
    stale = {"consumer": "a/b", "atom": "c/d:0/1=",
             "provider": "c/d-2", "reason": "not satisfied by c/d-2"}
    fast = {"entries": [], "kept": [], "stale-bindings": [stale], "aborted": None}
    got = load().crosscheck({"entries": []}, fast, [])
    assert kinds(got) == [("note", "fast-stale-binding-unrepaired")]
    assert "a/b (c/d:0/1=: not satisfied by c/d-2)" in got[0].text
    bare = {"entries": [], "kept": [], "aborted": None}
    assert load().crosscheck({"entries": []}, bare, []) == []


def test_the_command_line_prints_the_lines_and_exits_zero(tmp_path):
    (tmp_path / "rs.json").write_text(json.dumps({"entries": [entry("a/b-3", "upgrade")]}) + "\n")
    (tmp_path / "fast.json").write_text(json.dumps(
        {"entries": [entry("a/b-2", "upgrade")], "kept": [], "aborted": None}) + "\n")
    (tmp_path / "cw.jsonl").write_text(
        json.dumps(finding("world-no-match", "@world", "a/b")) + "\n"
        + json.dumps({"atoms": 1, "slots": 1, "unsatisfiable": 1, "not_read": 0}) + "\n")
    run = subprocess.run([sys.executable, str(SCRIPT), str(tmp_path / "rs.json"), str(tmp_path / "fast.json"),
                          "--check", str(tmp_path / "cw.jsonl")], capture_output=True, text=True)
    assert run.returncode == 0, run.stderr
    assert "[judge] world-version-differs" in run.stdout
    assert "[judge] world-invalid-but-planned" in run.stdout
    assert "world cross-check:" in run.stdout.splitlines()[-1]
    bad = subprocess.run([sys.executable, str(SCRIPT), str(tmp_path / "nothing"), str(tmp_path / "fast.json")],
                         capture_output=True, text=True)
    assert bad.returncode == 2


def test_the_report_prints_the_cross_check_and_the_fast_plan_does_not_gate(tmp_path):
    """The fast plan is known to be incomplete: its failures are printed, not
    counted in the exit code. The files under `world/` become one section."""
    report = SCRIPT.with_name("health-report.py")
    bad = {"property": "runtime-deps", "package": "a/b-1", "atom": "c/d", "reason": "x", "pre_existing": False}
    run_dir = tmp_path
    (run_dir / "world").mkdir()
    (run_dir / "health.jsonl").write_text(
        json.dumps({"plan": "plans/WORLD_resolver.json", "findings": []}) + "\n"
        + json.dumps({"plan": "plans/FAST_world.json", "findings": [bad]}) + "\n")
    (run_dir / "world/crosscheck-default.txt").write_text(
        "[judge] world-version-differs  a/b:0  fast=1  resolver=2\n"
        "[note] resolver-only  c/d:0  resolver=1 (new)\n"
        "world cross-check: 1 resolver-only, 1 world-version-differs\n")
    (run_dir / "world/check-world.jsonl").write_text(
        '{"atoms":3,"slots":4,"unsatisfiable":0,"not_read":0}\n')
    run = subprocess.run([sys.executable, str(report), str(run_dir / "health.jsonl")],
                         capture_output=True, text=True)
    assert run.returncode == 0, run.stdout + run.stderr
    assert "with failures: 0" in run.stdout
    assert "FAST_world" in run.stdout and "not gating" in run.stdout
    section = run.stdout.split("world cross-check\n", 1)[1]
    assert "crosscheck-default" in section and "[judge] world-version-differs" in section
    assert "check-world: 3 atoms, 4 slots, 0 unsatisfiable\n" in section
