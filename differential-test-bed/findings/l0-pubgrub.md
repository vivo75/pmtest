# L0 pubgrub parity (`--solver=pubgrub`, backlog #34)

Modes `-pv -pvu -pvuD -pvuDN -pve`, 117 probes, `--getbinpkg=n --usepkg=n`,
graded with `resolve-compare.py --count-categories missing,extra,version,action,exit`.

| step | -pv | -pvu | -pvuD | -pvuDN | -pve |
|---|---|---|---|---|---|
| S0 start (m/e/x) | 203/1679/34 | 9/1698/34 | 82/1698/34 | 2516/137/34 | 26078/137/16 |
| S5e, raw | 0/0/26 | 0/0/26 | 0/0/26 | 0/0/26 | 2/0/26 |
| S5e, after allowlist | 0 | 0 | 0 | 0 | 0 |

Allowlisted (layer `l0-pubgrub`, `owner: portuale-bug`): exit-code differences in
13 probes (#363 autounmask USE gate, #364 masked dependency, #365 REQUIRED_USE) and
`virtual/pager` under `-pve` (#366, order-blind `||` preference).
Evidence: portuale `LLM/evidence/2026-10-15-34-s5/` (`modes-e.md`, `triage.md`).

Final run (Z, after the S6 refactor, 2026-10-15): runs `l0-20261015T155330Z` … `l0-20261015T164057Z`, all five modes 0/0/0/0/0 after allowlist; default-solver run `l0-20261015T170422Z` 0/448/0/0/0, unchanged since S0.

## 2026-10-16 — #367 S4: pubgrub `-pvuD` / `-pve` bed runs

The first note on this date said the bed could not run (no image). That was
wrong: `localhost/test-portuale:latest` exists. Both modes were run on the
branch `backlog/359-default-solver-update` (portuale `fb4648d5`, so after #367,
#361, #362, #359 and #360), 117 probes each, `--getbinpkg=n --usepkg=n`:

| mode | run | missing/extra/version/action/exit (unexplained) |
|---|---|---|
| -pvuD | `l0-20261016T185128Z` | 0/0/0/0/0 |
| -pve | `l0-20261016T190945Z` | 0/0/0/0/0 |

Same as the 2026-10-15 final run. Default solver `-pv` (same branch, full run
with multi-graph and invariants, `l0-20261016T184032Z`): set categories 0, 31
unexplained rows (14 order, 9 advice, 6 error, 2 truncated), in line with the
historical default-mode residue of about 32 (15 order); 120 invariant probes,
0 violations.
