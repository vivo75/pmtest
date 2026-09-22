# Mutation testing — `cargo-mutants` on `portage-repo` (backlog #52 §10)

Tool: `cargo-mutants` v27.1.0 (`cargo install cargo-mutants --locked`),
`--in-place` (the default sandbox copy breaks the crate's tests, which
resolve fixtures relative to the manifest: the unmutated baseline fails
with 233 failures and no mutant is tested). Cadence per the plan:
nightly/weekly, not per-commit.

```sh
export PATH="$HOME/.cargo/bin:$PATH"
cargo mutants -p portage-repo --file portage-repo/src/resolver_trace.rs --in-place --timeout 300
cargo mutants -p portage-repo --file portage-repo/src/solver_bridge.rs --in-place --timeout 300
```

| module | mutants | caught | missed | unviable | wall clock |
|---|---|---|---|---|---|
| `resolver_trace.rs` (361 lines) | 35 | 0 | **35** | 0 | 4 min |
| `solver_bridge.rs` (1625 lines) | 86 | 44 | **26** | 16 | 7 min |
| `merge_order.rs` (3199) | 456 | — | — | — | not run (≈40 min) |
| `lib.rs` (34407) | 2207 | — | — | — | not run (≈3 h) |

`resolver_trace.rs` is the `PORTUALE_MO_SEL`/trace instrumentation
module: 35/35 survivors simply means no unit test asserts its internal
detail (its "tests" are the L0 `MO_ORDER` traces and
`TEST/scripts/mo-trace/`). Expected, not a gap.

## Surviving mutants in `solver_bridge.rs` (26) and their triage

All 26 sit in the `--solver=pubgrub` / `--solver=resolvo` bridge:

- `graph_result_from_order` outcome/ordering mapping (lines 430, 440,
  467, 665, 711, 732) and `newest_installed` (390): 13 survivors from
  guards/`==`/`>`/`&&` flips.
- `BridgeRepo::versions_for` / `desired_use` (824, 864),
  `resolve_pubgrub` (933), `resolve_resolvo` (1042): 5 survivors.
- `cp_exists` (124), `LazyRepo::build` (201), `target_slot` (770, 771):
  8 survivors.

Triage (the plan's own order): §1/§5/§6/§7 all fail to reach these —
the contract suite drives the default resolver, the fixture oracle and
L0 do too, and upstream has no pubgrub/resolvo tests to translate. That
is consistent with backlogs #33 (resolvo cycle linearization) and #34
(pubgrub over-merge), which already record both backends as
non-functional on real targets. **Conclusion: the survivors are a real
test gap in a deliberately parked Tier-4 area, not an accident of
coverage — the follow-up is a Tier-4 slice that wires the backends to
real targets and adds bridge-level unit tests for the mapping
functions, at which point these mutants become the acceptance list.**
No bespoke unit test was written now: it would pin mapping behaviour the
parked backends do not yet guarantee end-to-end.

The default resolver's own survivors (if any) are in
`merge_order.rs`/`lib.rs`, which were not run inside this session's
budget; `cargo mutants -p portage-repo --file portage-repo/src/merge_order.rs
--in-place` is the next useful run (~40 min).

## `merge_order.rs` (3199 lines) — run 2026-09-22 (backlog #52 S3, Phase 4)

`cargo mutants -p portage-repo --file portage-repo/src/merge_order.rs
--in-place --timeout 300`: **555 mutants, 272 caught / 233 missed / 31
unviable / 19 timeouts, ~3h wall** (the plan's "≈40 min" was 4× low;
TIMEOUTs at 300 s each dominate). Baseline `cargo test -p
portage-repo`: 442 passed in 0.33 s — the run is valid, and the
`--in-place` tree was restored clean by cargo-mutants on exit
(verified: `git status` clean apart from this file). Raw log:
`/tmp/mutants-merge-order2.log` (first attempt killed at 60 min/118
verdicts, `/tmp/mutants-merge-order.log`).

Triage buckets (every missed mutant classified; timeouts kept apart —
each hangs the suite past 300 s, so they are behavior-changing, not
silent survivors):

- **trace-only / unreachable: 16.** `debug_dump_graph` (8: gate
  flips, guard true/false, `with ()` — env-gated inside, stderr only),
  `debug_dump_graph_only` + `debug_dump_cycle` (`with ()`),
  `mo_sel_enabled` (3) + `mo_sel_cpv` (2) (the `PORTUALE_MO_SEL`
  trace harness — same accepted shape as `resolver_trace.rs` 35/35),
  plus 1 `select_nodes` mutant inside a `mo_sel_enabled()` block
  (`delete !` at :3053: stderr-only flag). Accepted, not chased.
- **equivalent: 2.** `frontier_enabled -> false` — the
  `PORTAGE_SERIALIZE_FRONTIER_DISABLE` fallback is behavior-neutral by
  design (`disabled_path_matches_direct_scans` pins the equivalence at
  the frontier level); no test toggles the env var, so the mutant is
  unobservable either way. `mo_iter += 1` → `*=` at :2828 — the
  counter runs live but its only consumer is the `MO_SEL` stderr line,
  which no test asserts.
- **real unit-test gaps: 215 (38.7%)** — one line per cluster below.
  Stop-rule verdict: under the plan's 40% bar, so cluster items are
  filed (#144–#146) rather than stopping. The misses concentrate where
  the file's 18 `mod tests` fns never go: no direct test calls
  `select_nodes`, `add_installed_dependency_closure`, `key_priority`,
  `dep_edges_from_metadata`, `seed_toolchain_asap`, `schedule_graph`,
  `deep_system_deps`, `installed_candidates_by_cp` or `rank_best`
  (verified by grep); that coverage lives in the contract suite + L0
  mo-trace, which this run does not execute.

Real-gap clusters (missed / timeouts):

- `select_nodes` main loop: 32 missed + 4 timeouts (:2831–:3053
  `&&`/`||`/`!`/`>` flips in asap/leaf/batch selection;
  `replace > with ==/</>=` at :2919). No direct unit test. → #144.
- `schedule_graph` driver: 5 missed + 2 timeouts (:3379, :3387,
  :3428). → #144.
- `seed_toolchain_asap`: 7 missed (:2196–:2220 virtual-match
  `==`/`&&`/`!` flips; `@world` reinstall seeding is L0-only). → #144.
- `deep_system_deps`: 2 missed (:2120). → #144.
- `serialize_merge_order` filter/sort arms: 6 missed (:3327 `<`
  family, :3329 `+=` family; 7 caught elsewhere). → #144.
- `--tree` simulation arms: `tree_schedule_stuck` 4 (:2652–:2663),
  `tree_note_selection` 3 (:2697–:2698), `tree_solved_replacements`
  3 + 1 RET (:2749–:2751; 2 caught). → #144.
- cycle tie-breaks: `find_smallest_cycle` 5 + 1 RET + 3 RET-timeouts
  (:2288, :2318 `<` family), `harvest_cycle` 3 + 1 RET + 1 timeout
  (:2355–:2356), `elementary_cycles` 3 (:2472 `<` family; 4 caught),
  `shortest_path` 1 timeout. → #144.
- `suppressed_alt_edges` 2 (`&=`→`|=` at :1726–:1727; 6 caught),
  `gather_deps` 1 + 1 RET + 1 RET-timeout (:2259), `Digraph`
  primitives (`child_nodes` 2 + 2 RET at :528,
  `add_edge` 1 at :555, `has_parents` 1 RET). → #144.
- `add_installed_dependency_closure`: 24 + whole-body `with ()` at
  :1120 + 1 timeout (:1144–:1354 `&&`/`||`/`==`/`!`/`<` flips; the
  noop surviving means no unit test observes the closure at all). → #145.
- installed-satisfaction inputs: `installed_candidates_by_cp` 13 RET
  (every return replacement incl. empty map at :1014 — the vdb-backed
  map is unit-invisible), `edge_satisfied_with` 4 + 1 RET (:980–:986),
  `dep_edge_satisfied_by_installed` 2 RET, `outcome_version` 3 RET
  (:864 None/""/"xyzzy" — feeds the :1509/:1603 ordering
  comparisons). → #145.
- dep-key mapping: `key_priority` 5 (whole RDEPEND|IDEPEND and PDEPEND
  arms deletable; runtime/runtime_post/optional fields deletable),
  `dep_edges_from_metadata` 5 (all four key arms + :305 `==` flip;
  2 caught). → #146.
- ignore-priority ladder: `n_ignore_*`/`s_ignore_*` RET pairs
  (~14: every predicate replaceable by constant true/false) +
  in-body flips (~10: :343–:407) + `PriorityRange::ig` 1 RET. The
  whole `SATISFIED`/`NORMAL` ladder is unit-invisible. → #146.
- dep-target ranking: `rank_best` 6 (match arms :1600–:1601, `!` at
  :1593, `>` family at :1605; 0 caught), `select_dep_target` 5
  (:1465–:1519; 12 caught). → #146.
- `split_disjunctive` branch bookkeeping: 17 (`||`/`(`/`)` arm
  deletions, depth/group/branch counter arithmetic, `==` flips at
  :154–:190; 4 caught). → #146.
- `build_digraph` fallback arms: 13 (required_by-fallback priority
  field deletions + `:1981`/`:2006`/`:2032`/`:2043` condition flips;
  11 caught on the forward-walk arms). → #146.
- `frontier_enabled -> true`: 1 (fallback path untested at unit
  level). `DepPriority::fmt` whole-body (`with Ok(Default::default())`
  at :3118 — the ladder's Display is never printed by a test). → #146.
- `SerializeFrontier::build` 3 timeouts, `leaves_via` 2 RET-timeouts:
  hang the suite (frontier-construction loops). → inspected in #144.

No tests were added in this slice, per the plan: the mutants above
are the acceptance list for #144–#146.
