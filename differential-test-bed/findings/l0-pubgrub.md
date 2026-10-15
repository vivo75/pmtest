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
