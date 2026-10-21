#!/usr/bin/env python3
"""Reproducible `@world`-shaped resolver benchmark (backlog #461).

Generates the input with gen_world_shaped.py (or reuses it after a
fingerprint check), runs `PORTUALE_PROFILE=1 <pm> emerge -puDN @world`
three times, and prints the median phase timers -- the same method as
`portuale:LLM/evidence/2026-10-21-world-profile/README.md`, but over a
generated fixture tree + pinned VDB instead of live host state, so the
numbers are reproducible on any machine with no network access.

The binary is resolved -- and rebuilt -- through managers/managers.yaml
exactly like the contract suite's, never from a hardcoded path
(USAGE.AGENTS.md F3); the JSON carries the registry entry, resolved
version and cargo profile next to the numbers (USAGE.AGENTS.md point 4).

Example:
    python3 bench/world_shaped_benchmark.py
    python3 bench/world_shaped_benchmark.py --runs 5 --json out.json
    python3 bench/world_shaped_benchmark.py --verify-only
"""

import argparse
import hashlib
import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "managers"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import registry  # noqa: E402
import gen_world_shaped as gen  # noqa: E402

DEFAULT_OUT = Path("/var/tmp/pmtest-world-bench")
ARGV = ["emerge", "-puDN", "@world"]


def check_fingerprint(out):
    """Recomputes the tree digest and compares it with fingerprint.json."""
    fp_path = Path(out) / "fingerprint.json"
    if not fp_path.exists():
        return False, "no fingerprint.json -- regenerate"
    recorded = json.loads(fp_path.read_text())
    if recorded.get("generator") != gen.GENERATOR_VERSION:
        return False, (f"generator v{recorded.get('generator')} != "
                       f"v{gen.GENERATOR_VERSION} -- regenerate")
    current = gen.fingerprint(out, recorded.get("params", {}))
    if current["tree_digest"] != recorded.get("tree_digest"):
        rec_files, cur_files = recorded.get("files", {}), current["files"]
        missing = sorted(set(rec_files) - set(cur_files))
        extra = sorted(set(cur_files) - set(rec_files))
        changed = sorted(k for k in set(rec_files) & set(cur_files)
                         if rec_files[k] != cur_files[k])
        detail = (f"missing={missing[:5]} extra={extra[:5]} "
                  f"changed={changed[:5]}")
        return False, f"tree digest mismatch -- regenerate ({detail})"
    return True, (f"tree {recorded['tree_digest'][:16]}... "
                  f"({recorded['file_count']} files)")


def clean_runtime_state(out):
    """Wipes regenerable runtime state so every run starts identical.

    A run writes its binhost cache under `var/cache/edb/`; leaving it
    would make run N+1 a cache-hit workload while run 1 re-reads the
    index. `tmp/` is the runner's TMPDIR (normally untouched by a
    pretend run, wiped for hygiene all the same).
    """
    import shutil
    out = Path(out)
    for sub in ("var/cache", "tmp"):
        d = out / sub
        if d.is_symlink() or d.is_file():
            d.unlink()
        elif d.is_dir():
            shutil.rmtree(d)
        d.mkdir(parents=True, exist_ok=True)


def run_once(binary, env, out):
    clean_runtime_state(out)
    start = time.perf_counter()
    proc = subprocess.run([str(binary), *ARGV], env=env, capture_output=True,
                          text=True, check=False)
    return proc, time.perf_counter() - start
def run_env(out):
    env = dict(os.environ)
    env["PORTAGE_CONFIGROOT"] = str(out)
    env["ROOT"] = str(out)
    env["PORTAGE_RUNNING_ROOT"] = str(out)
    env["DISTDIR"] = str(Path(out) / "distfiles")
    env["TMPDIR"] = str(Path(out) / "tmp")
    env["PORTUALE_PROFILE"] = "1"
    # The benchmark pins its binhost set: the generated file:// index only.
    # A host PORTAGE_BINHOST would add a real third binhost (network + new
    # remote candidates = a different workload, cf. the #455 evidence §Binhost).
    env.pop("PORTAGE_BINHOST", None)
    return env


def parse_profile_spans(stderr):
    spans = {}
    for line in stderr.splitlines():
        if line.startswith("[profile] ") and ": " in line:
            name, secs = line[len("[profile] "):].rsplit(": ", 1)
            try:
                spans.setdefault(name.strip(), []).append(float(secs))
            except ValueError:
                pass
    # Repeated spans (run_pass xN, collect_pass_blockers xN) sum per run.
    return {name: sum(vals) for name, vals in spans.items()}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--seed", type=int, default=gen.DEFAULTS["seed"])
    ap.add_argument("--skip-build", action="store_true",
                    help="assume the release binary is already built "
                         "(sets PMTEST_NO_BUILD=1)")
    ap.add_argument("--regenerate", action="store_true",
                    help="regenerate the input even if the fingerprint holds")
    ap.add_argument("--verify-only", action="store_true",
                    help="only check the fingerprint, then exit")
    ap.add_argument("--json", type=Path, help="write results as JSON")
    ap.add_argument("--warmup", type=int, default=1,
                    help="unmeasured runs before the timed ones (page-cache "
                         "warmup; default 1)")
    for key, default in gen.DEFAULTS.items():
        if key == "seed":
            continue
        ap.add_argument(f"--{key.replace('_', '-')}", type=int, default=None,
                        help=f"(default: {default})")
    args = ap.parse_args()

    params = dict(gen.DEFAULTS)
    params["seed"] = args.seed
    for key in gen.DEFAULTS:
        if key != "seed" and getattr(args, key) is not None:
            params[key] = getattr(args, key)

    if args.skip_build:
        os.environ["PMTEST_NO_BUILD"] = "1"

    ok, msg = check_fingerprint(args.out)
    if args.verify_only:
        print(f"fingerprint: {'OK' if ok else 'STALE'} ({msg})")
        return 0 if ok else 1
    if not ok or args.regenerate:
        print(f"(re)generating {args.out}: {msg}")
        fp = gen.generate(args.out, params)
        print(f"generated {fp['file_count']} files, {fp['total_bytes']} bytes, "
              f"tree {fp['tree_digest'][:16]}...")
        ok, msg = check_fingerprint(args.out)
        assert ok, f"freshly generated input fails its own check: {msg}"
    else:
        recorded = json.loads((args.out / "fingerprint.json").read_text())
        if recorded.get("params") != params:
            print(f"params differ from recorded input; regenerating "
                  f"(recorded seed={recorded.get('params', {}).get('seed')})")
            fp = gen.generate(args.out, params)
            print(f"generated {fp['file_count']} files, tree "
                  f"{fp['tree_digest'][:16]}...")
            ok, msg = check_fingerprint(args.out)
            assert ok, f"freshly generated input fails its own check: {msg}"
        else:
            print(f"input fingerprint OK: {msg}")

    try:
        binary = registry.applet("emerge", build=True)
    except registry.RegistryError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    pm_name, _ = registry.active_pm()
    print(f"binary: {binary} (PM {pm_name} "
          f"{registry.pm_version(pm_name)} {registry.cargo_profile()})")

    env = run_env(args.out)
    for w in range(args.warmup):
        proc, elapsed = run_once(binary, env, args.out)
        print(f"warmup {w + 1}: rc={proc.returncode} wall={elapsed:.3f}s "
              f"(unmeasured)")
        if proc.returncode != 0:
            print(f"FAIL: warmup run exited {proc.returncode}; tail of stderr:")
            print("\n".join(proc.stderr.splitlines()[-15:]))
            return 1
    stdouts, walls, per_run = [], [], []
    for n in range(args.runs):
        proc, elapsed = run_once(binary, env, args.out)
        walls.append(elapsed)
        stdouts.append(proc.stdout)
        per_run.append(parse_profile_spans(proc.stderr))
        print(f"run {n + 1}: rc={proc.returncode} wall={walls[-1]:.3f}s "
              f"stdout_sha={hashlib.sha256(proc.stdout.encode()).hexdigest()[:16]}...")
        if proc.returncode != 0:
            print(f"FAIL: run {n + 1} exited {proc.returncode}; tail of stderr:")
            print("\n".join(proc.stderr.splitlines()[-15:]))
            return 1

    hashes = {hashlib.sha256(s.encode()).hexdigest() for s in stdouts}
    if len(hashes) != 1:
        print("FAIL: stdout differs across runs -- the input is not a stable "
              "benchmark workload", file=sys.stderr)
        return 1
    print(f"stdout byte-identical across {args.runs} runs "
          f"(sha256 {hashes.pop()[:16]}...)")

    names = sorted({name for run in per_run for name in run})
    medians = {name: statistics.median(run.get(name, 0.0) for run in per_run)
               for name in names}
    wall_median = statistics.median(walls)

    width = max([len("span")] + [len(n) for n in names])
    header = f"{'span':<{width}}" + "".join(f"{f'run {i + 1}':>10}" for i in range(args.runs)) + f"{'median':>10}"
    print(f"\n{header}")
    for name in names:
        row = f"{name:<{width}}" + "".join(f"{run.get(name, 0.0):>10.3f}" for run in per_run) + f"{medians[name]:>10.3f}"
        print(row)
    print(f"{'wall':<{width}}" + "".join(f"{w:>10.3f}" for w in walls) + f"{wall_median:>10.3f}")

    if args.json:
        recorded = json.loads((args.out / "fingerprint.json").read_text())
        args.json.write_text(json.dumps({
            "pm": pm_name,
            "pm_version": registry.pm_version(pm_name),
            "profile": registry.cargo_profile(),
            "dataset": "world-shaped",
            "argv": ARGV,
            "runs": args.runs,
            "tree_digest": recorded["tree_digest"],
            "generator": gen.GENERATOR_VERSION,
            "params": params,
            "stdout_sha256": hashlib.sha256(stdouts[0].encode()).hexdigest(),
            "spans": {n: [r.get(n, 0.0) for r in per_run] for n in names},
            "span_medians": medians,
            "walls": walls,
            "wall_median": wall_median,
        }, indent=2) + "\n")
        print(f"\nwrote {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
