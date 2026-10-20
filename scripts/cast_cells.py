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

# Long cells (backlog #452 K1): real merges of fixture packages, one argv
# list per recording; the resume cell records twice in the same stage.
LONG_CELLS: list[tuple[str, list]] = [
    ("long-keep-going",
     [["--keep-going", "dev-libs/schedbad", "dev-libs/schedok"]]),
    ("long-stop",
     [["dev-libs/schedbad", "dev-libs/schedok"]]),
    ("long-with-dependent",
     [["--keep-going", "dev-libs/schedbaddep", "dev-libs/schedok"]]),
    ("long-clean-multi",
     [["dev-libs/schedparent"]]),
    ("long-resume",
     [["dev-libs/schedbad", "dev-libs/schedok"], ["--resume"]]),
    # K4: a run is (argv, [(prompt regex, reply)]); the reply is typed into a pty.
    ("long-ask-no",
     [(["--ask", "dev-libs/schedok"], [(r"\[Yes/No\]", "n")])]),
    ("long-ask-yes",
     [(["--ask", "dev-libs/schedok"], [(r"\[Yes/No\]", "y")])]),
]

# Merges must not touch the host: scratch PORTAGE_TMPDIR/PKGDIR plus the
# fixture manifest gap (no Manifest ships, so strict always fails the
# fetch) and every sandbox dropped, per the plan's probe.
LONG_FEATURES = "-strict -sandbox -usersandbox -network-sandbox -ipc-sandbox -pid-sandbox"


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


def run_long_cells(out: Path, link: Path, cap_bytes: int) -> list[str]:
    """Record LONG_CELLS under both PMs; return report.md lines (K1/K2/K3).

    Each PM gets a fresh stage plus scratch PORTAGE_TMPDIR/PKGDIR under
    /var/tmp; argv is prefixed with `sudo --preserve-env` (root-owned
    build files, wiped with `sudo rm -rf` after). rc differences are
    reported, never raised. Comparison runs on capped casts (K2),
    landmarks on the originals (K3).
    """
    lines = ["", "## long cells (real merges)", "",
             f"capped at {cap_bytes} output bytes per cast (0 = off); "
             "rc differences are findings, never failures.", ""]
    base = Path(tempfile.mkdtemp(prefix="cast-long-", dir="/var/tmp"))
    try:
        for cell, runs in LONG_CELLS:
            casts: dict[str, list[tuple[Path, int]]] = {}
            for pm, argv0 in (("portage", str(PORTAGE_EMERGE)), ("portuale", str(link))):
                stage = stage_fixtures(base / f"stage-{cell}-{pm}")
                scratch = base / f"scratch-{cell}-{pm}"
                tmpdir, pkgdir = scratch / "tmp", scratch / "pkg"
                tmpdir.mkdir(parents=True)
                pkgdir.mkdir(parents=True)
                env = fixture_env(stage)
                env["PORTAGE_TMPDIR"] = str(tmpdir)
                env["PKGDIR"] = str(pkgdir)
                env["FEATURES"] = LONG_FEATURES
                casts[pm] = []
                for n, run in enumerate(runs, start=1):
                    run_args, answers = run if isinstance(run, tuple) else (run, None)
                    suffix = f".{n}" if len(runs) > 1 else ""
                    cast_path = out / f"{cell}{suffix}.{pm}.cast"
                    argv = ["sudo", "--preserve-env", argv0, "--color=n", *run_args]
                    if answers:
                        _, rc = cast_record.record_with_answers(argv, cast_path, answers, env=env)
                    else:
                        _, rc = cast_record.record(argv, cast_path, env=env)
                    casts[pm].append((cast_path, rc))
                # Builds ran as root: drop the stage, don't pile up in /var/tmp.
                subprocess.run(["sudo", "rm", "-rf", str(stage), str(scratch)])
            for n, run in enumerate(runs, start=1):
                run_args = run[0] if isinstance(run, tuple) else run
                name = f"{cell}.{n}" if len(runs) > 1 else cell
                ca = cast_compare.parse_cast(casts["portage"][n - 1][0])
                cb = cast_compare.parse_cast(casts["portuale"][n - 1][0])
                rc_a, rc_b = casts["portage"][n - 1][1], casts["portuale"][n - 1][1]
                capped_a, info_a = cast_compare.cap_cast(ca, cap_bytes)
                capped_b, info_b = cast_compare.cap_cast(cb, cap_bytes)
                report = cast_compare.compare(capped_a, capped_b,
                                                ignore_lines=SETUP_NOISE)
                times_a = cast_compare.landmark_times(ca)
                times_b = cast_compare.landmark_times(cb)
                print(f"{name}: rc {rc_a}/{rc_b} "
                      f"text={'=' if report.text_equal else '!'} "
                      f"chunks={'=' if report.chunk_equal else '!'} "
                      f"max-ratio={report.max_ratio:.1f}x")
                lines.append(f"### {name}")
                lines.append(f"`emerge {' '.join(run_args)}` — "
                             f"rc portage/portuale: {rc_a}/{rc_b}")
                lines.append(f"compare (capped): text "
                             f"{'equal' if report.text_equal else 'DIFFER'}, chunking "
                             f"{'equal' if report.chunk_equal else 'DIFFER'}, "
                             f"max-ratio {report.max_ratio:.1f}x "
                             f"({report.n_flagged} flagged)")
                for pm, info in (("portage", info_a), ("portuale", info_b)):
                    lines.append(f"sizes ({pm}): {info['original_bytes']} → "
                                 f"{info['capped_bytes']} bytes "
                                 f"({info['dropped_events']} events capped)")
                lines += ["", "| landmark | portage (s) | portuale (s) |",
                          "| --- | --- | --- |"]
                for label, _ in cast_compare.LANDMARKS:
                    col_a = f"{times_a[label]:.1f}" if times_a[label] is not None else ""
                    col_b = f"{times_b[label]:.1f}" if times_b[label] is not None else ""
                    lines.append(f"| `{label}` | {col_a} | {col_b} |")
                lines.append("")
    finally:
        subprocess.run(["sudo", "rm", "-rf", str(base)])
    return lines


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="/var/tmp/casts",
                        help="directory for the casts and report.md (default %(default)s)")
    parser.add_argument("--color", action="store_true",
                        help="leave colour on (default NOCOLOR=true so the text compares)")
    parser.add_argument("--cells", choices=("pretend", "long", "all"), default="pretend",
                        help="which cells to run (default %(default)s)")
    parser.add_argument("--cap-bytes", type=int, default=cast_compare.DEFAULT_CAP_BYTES,
                        help="cap long-cell output at this many bytes per cast, 0 disables "
                        "(default %(default)s)")
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

    cases = load_cases() if args.cells in ("pretend", "all") else []
    rows = []
    if args.cells in ("pretend", "all"):
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
    if args.cells in ("long", "all"):
        with tempfile.TemporaryDirectory(prefix="cast-cells-") as tmp:
            link = Path(tmp) / "emerge"
            link.symlink_to(portuale)
            lines += run_long_cells(out, link, args.cap_bytes)
    (out / "report.md").write_text("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
