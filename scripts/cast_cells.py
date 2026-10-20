#!/usr/bin/env python3
"""Record pretend cells under both PMs and compare the casts (backlog #443 C3).

Eight rows from `test_emerge_pretend_contract.py::CASES` (imported by path,
never run under pytest), chosen for varied output -- plain merge list,
blocker, masked abort, autounmask suggestion, --tree, --verbose USE flags,
upgrade, conflict -- each recorded under real Portage (`/usr/sbin/emerge`)
and portuale (the multicall binary symlinked as `emerge`, the same
argv[0]-dispatch the contract suite exercises). Writes
`<out>/<cell>.{portage,portuale}.cast` plus one `report.md`.
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import re
import shutil
import sys
import subprocess
import tempfile
from pathlib import Path

PMTEST_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PMTEST_ROOT / "scripts"))
sys.path.insert(0, str(PMTEST_ROOT / "managers"))

import cast_compare
import cast_record
import registry

# (cell name, CASES description verbatim). The description is the lookup
# key: a rename in the contract suite fails loudly here, not silently.
CELLS = [
    ("plain-new", "new install"),
    ("blocker",
     "blocker: strong (!!) blocker vs an installed package no walk pulls in is satisfied (rc 0, Portage `b`)"),
    ("masked-abort", "only ~keyword, not visible"),
    ("autounmask",
     "--autounmask: keyword-masked target resolves + prints the changes block once enabled"),
    ("tree",
     "merge order threads through --tree too (roots re-derived from required_by)"),
    ("verbose-use", "-pv: cpv decorated with ::repo"),
    ("upgrade", "--update: upgrade available"),
    ("triangle-conflict",
     "the needer/othermod triangle reports the installed-instance conflict (#57, #62: rc 1 like Portage)"),
]

PORTAGE_EMERGE = Path("/usr/sbin/emerge")


def load_cases() -> list:
    """CASES without running pytest: import the contract module by path."""
    mod_path = PMTEST_ROOT / "pytests-contract-suite" / "test_emerge_pretend_contract.py"
    sys.path.insert(0, str(mod_path.parent))  # the module does `import corpus`
    spec = importlib.util.spec_from_file_location("pretend_contract_cases", mod_path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["pretend_contract_cases"] = mod
    spec.loader.exec_module(mod)
    return mod.CASES


def find_case(cases: list, description: str) -> tuple[list[str], int]:
    for desc, args, expected_rc in cases:
        if desc == description:
            return list(args), expected_rc
    raise LookupError(f"no CASES row named {description!r}; the contract suite renamed it?")


def fixture_env(root: Path, color: bool = False) -> dict[str, str]:
    """Fixture ROOT the contract suite grades against, plus CLEAN_DELAY=0.

    Determinism pins from the bed's abort-capture.sh: fixed hash seed,
    locale and timezone so dict/set order and dates don't leak host state.
    """
    fixtures = PMTEST_ROOT / "fixtures"
    env = dict(os.environ)
    env["PORTAGE_CONFIGROOT"] = str(root)
    env["ROOT"] = str(root)
    env["PORTAGE_RUNNING_ROOT"] = str(root)
    env["DISTDIR"] = str(fixtures / "distfiles")
    env["CLEAN_DELAY"] = "0"
    env["PYTHONHASHSEED"] = "0"
    env["LC_ALL"] = "C.UTF-8"
    env["TZ"] = "UTC"
    env.pop("NO_COLOR", None)
    if not color:
        env["NOCOLOR"] = "true"
    return env


# Portage-only chatter about the fixture overlays' layout.conf, not the cell.
SETUP_NOISE = (r"!!! Repository '[^']*' is missing masters attribute",
               r"!!! Set 'masters = [^']*' in this file")

_LOCATION = re.compile(r"^location = (?![/\$])", re.M)


def stage_fixtures(dest: Path) -> Path:
    """Pristine scratch copy of fixtures with absolute repos.conf locations.

    Real Portage rejects the committed tree's relative `location =` entries
    and its global-updates pass mutates `var/db` under ROOT, so each PM
    gets its own disposable copy (the bed's abort-capture.sh stages the
    same way; the committed tree is never touched).
    """
    root = dest / "fixtures"
    shutil.copytree(PMTEST_ROOT / "fixtures", root, symlinks=True,
                    ignore=shutil.ignore_patterns("abort-captures"))
    repos_conf = root / "etc" / "portage" / "repos.conf" / "repos.conf"
    repos_conf.write_text(_LOCATION.sub(f"location = {root}/", repos_conf.read_text()))
    return root


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="/var/tmp/casts",
                        help="directory for the casts and report.md (default %(default)s)")
    parser.add_argument("--color", action="store_true",
                        help="leave colour on (default NOCOLOR=true so the text compares)")
    args = parser.parse_args()
    out = Path(args.out)
    if str(out).startswith("/dev/shm"):
        parser.error("refusing to write into /dev/shm")
    out.mkdir(parents=True, exist_ok=True)

    if not PORTAGE_EMERGE.is_file():
        raise SystemExit(f"reference PM missing: {PORTAGE_EMERGE} not found")
    # Declared path, no build: the release binary is already built.
    portuale = registry.declared_applet("emerge", name="portuale")
    if not portuale.is_file():
        raise SystemExit(f"portuale binary missing: {portuale} not found")

    cases = load_cases()
    rows = []
    with tempfile.TemporaryDirectory(prefix="cast-cells-") as tmp:
        # Multicall dispatch: portuale behaves as emerge iff argv[0] is emerge.
        link = Path(tmp) / "emerge"
        link.symlink_to(portuale)
        for cell, description in CELLS:
            cell_args, _ = find_case(cases, description)
            stages = {}
            results = {}
            for pm, argv0 in (("portage", str(PORTAGE_EMERGE)), ("portuale", str(link))):
                # One pristine stage per PM: a global-updates pass under one
                # must not move what the other resolves.
                stage = stage_fixtures(Path(tmp) / f"stage-{cell}-{pm}")
                stages[pm] = stage
                cast_path = out / f"{cell}.{pm}.cast"
                env = fixture_env(stage, color=args.color)
                # NOCOLOR does not decolour Portage under ROOT != / (its `/`
                # config is built from a filtered environment), so pass the
                # option to both. Portage's global-updates lines come from the
                # staged fixtures' updates file and are filtered by SETUP_NOISE.
                colour_arg = [] if args.color else ["--color=n"]
                _, rc = cast_record.record([argv0, *colour_arg, *cell_args], cast_path, env=env)
                results[pm] = (cast_path, rc)
            report = cast_compare.compare(
                cast_compare.parse_cast(results["portage"][0]),
                cast_compare.parse_cast(results["portuale"][0]),
                ignore_lines=SETUP_NOISE,
                tmp_roots=(str(stages["portage"]), str(stages["portuale"]), tmp),
            )
            rows.append((cell, " ".join(cell_args), results["portage"][1],
                         results["portuale"][1], report))
            print(f"{cell}: rc {results['portage'][1]}/{results['portuale'][1]} "
                  f"text={'=' if report.text_equal else '!'} "
                  f"chunks={'=' if report.chunk_equal else '!'} "
                  f"max-ratio={report.max_ratio:.1f}x")
            # Drop the stages: 16 cells x 25M must not pile up in tmp.
            for pm in ("portage", "portuale"):
                shutil.rmtree(Path(tmp) / f"stage-{cell}-{pm}", ignore_errors=True)

    lines = ["# cast cells report", "",
             "| cell | argv | rc portage | rc portuale | text equal | chunking equal | max timing ratio |",
             "| --- | --- | --- | --- | --- | --- | --- |"]
    for cell, argv, rc_a, rc_b, report in rows:
        lines.append(
            f"| {cell} | `emerge {argv}` | {rc_a} | {rc_b} | "
            f"{'yes' if report.text_equal else 'no'} | "
            f"{'yes' if report.chunk_equal else 'no'} | "
            f"{report.max_ratio:.1f}x ({report.n_flagged} flagged) |")
    (out / "report.md").write_text("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
