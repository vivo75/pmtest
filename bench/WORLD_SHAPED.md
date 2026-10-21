# `@world`-shaped resolver benchmark (backlog #461)

A reproducible, network-free benchmark input for resolver optimisation
work (#441 S1): a deterministic generator plus a runner that checks the
input fingerprint, runs `PORTUALE_PROFILE=1 ... emerge -puDN @world`
three times, and prints median phase timers.

- Generator: `bench/gen_world_shaped.py` (seeded, `--seed 461` default).
- Runner: `bench/world_shaped_benchmark.py` (fingerprint check + 3 runs
  + medians table, `--json` for the numbers).
- Method note and the host-scale numbers this replaces:
  `portuale:LLM/evidence/2026-10-21-world-profile/README.md`.
- Evidence of a run: `portuale:LLM/evidence/2026-10-21-f461/`.

## Why a generated input

The frozen #455 benchmark pins live-host VDB/config state by content
hash: reproducible only on that machine, and every run re-downloads two
binhost indexes (~9.8 s of network-fixed cost). This benchmark instead
generates its whole root at run time under `/var/tmp` (default
`/var/tmp/pmtest-world-bench`, ~80 MB): a synthetic repo `benchmain`
(~1200 ebuilds), a pinned VDB (~4000 installed packages), a ~300-atom
world file, and a hermetic `file://` binhost index. Nothing is
committed; regeneration from the same seed is byte-identical (the
fingerprint check enforces it).

## Workload shape (defaults)

| family | default count | exercises |
|---|---|---|
| deep RDEPEND chains (18 levels + 10-leaf fan-out, update 1→2) | 20 chains | deep walk, multi-pass revisits |
| diamonds (a→b,c→d, all updating) + fan-out | 100 | shared-leaf resolution |
| shared leaf pool (2 leaf-deps each, never in world) | 120 | non-world reachability |
| dual-slot pkgs + consumers on both `:slot` atoms | 40 | slot-atom selection |
| satisfied-block replacements (`!=cpv-ver` on the replaced version) | 8 | `collect_pass_blockers` (host gtk-doc shape) |
| USE newuse (`wfeat` on in profile, off in VDB) + leaves | 60 + 60 | `reinstall_flags_for_use_change`, `vdb_aux_get` |
| `\|\|` disjunctions + leaves | 20 + 40 | `dep_zapdeps` bins |
| plain new installs | 60 | `N` rows |
| @system members (profile `packages`, `*` lines) | 8 | the `@system` arm |
| installed-only ballast (no ebuild, not in world) | 3000 | per-pass VDB scans at host scale |

Every repo package also ships a matching entry in the `file://`
binhost `Packages` index, and the generated make.conf carries the
host's own defaults
(`EMERGE_DEFAULT_OPTS="--usepkg=n --getbinpkg=y --binpkg-respect-use=y"`),
so the binary-candidate pool (`collect_binary_candidates`,
`binary_deps_changed` -- the #455 S1 targets) is exercised hermetically.
The runner argv is byte-identical to the #455 evidence:
`emerge -puDN @world`.

## Use

```sh
python3 bench/world_shaped_benchmark.py                # generate + check + 3 runs
python3 bench/world_shaped_benchmark.py --runs 5 --json out.json
python3 bench/world_shaped_benchmark.py --verify-only  # fingerprint only
python3 bench/world_shaped_benchmark.py --regenerate   # force regeneration
```

One unmeasured warmup run precedes the timed runs (page-cache
warmup); `var/cache/` (the run's regenerable binhost cache) is wiped
before every run, so all runs are cache-cold and identical. Repeated
spans (`run_pass`, `collect_pass_blockers`) are summed per run; the
table prints per-run values plus the median. stdout must be
byte-identical across runs or the runner fails.

The runner refuses to run when the fingerprint is stale (regenerates),
fails when stdout differs across runs (an unstable workload is not a
benchmark), and fails on a nonzero exit. Every published number cites
the registry PM entry, resolved version and cargo profile (the `--json`
output carries all three plus the tree digest).

## Deliberate cuts vs the host benchmark

- No network: the ~9.8 s `refresh_binhost_indexes` cost is out of scope
  (local `file://` re-read, milliseconds). This benchmark measures the
  resolver proper (`resolve_once` and below).
- Absolute times are smaller than the host's 30.4 s `resolve_once`: the
  input is shaped, not sized, like `@world`. Compare *relative* numbers
  (before/after an optimisation on the same input), never against the
  host table.
- Portuale-only: no Portage oracle runs here (perf infra, not a parity
  cell). The shapes it borrows (satisfied blocks, slot atoms, newuse)
  are grounded in the oracles cited by #68/#361/#69.
