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

### Phase 8 (2026-09-23, backlog #146/#145/#144) — the unit tests, before/after

Branch `backlog/144-146-merge-order-tests`. Clusters re-run from
`rust/` with `cargo mutants --in-place --file
portage-repo/src/merge_order.rs --timeout 300 --re '<cluster regex>'`;
the after-runs use `--iterate` (only the previously-missed mutants are
re-tested; previously-caught/unviable are carried over). The file had
grown from 3199 to 4324 lines since the 2026-09-22 run, so the
`--list` inventory — not the old line numbers — was the target list.

| cluster | mutants | before caught/missed | after caught/missed | unviable | timeout |
|---|---|---|---|---|---|
| #146 dep-key/priority | 168 | 83 / 79 | **156 / 6** | 6 | 0 |
| #145 installed/vdb | 62 | 14 / 46 | **59 / 1** | 1 | 1 |
| #144 scheduler loop | 258 | 178 / 41 (one run, post-test) | **201 / 17** | 21 | 19 |

The #144 cluster's "before" is the 2026-09-22 triage above plus the
current `--list` inventory: the file had grown ~1100 lines, so the
inventory was the target list, and the cluster was run once on the
post-test tree (`--timeout 60`), then three `--iterate --timeout 20`
passes over its missed/timeout sets (the 15
`SerializeFrontier::add_edge` mutants are excluded — the pre-existing
`frontier_add_edge_only_grows_survival` pins them and they are not in
#144's list).

**#146 survivors (all equivalent).**

- `split_disjunctive` :175/:176 (`&&`→`||` in the nested-branch guard) —
  the mutated condition can only differ when a `(` deeper than
  `aod+1` is reached with `branch_group_depth` still `None`;
  well-nested structured-reduce output always sets it at `aod+1` first.
  Unreachable through `dep_edges_from_metadata`; the direct-token pin
  covers the reachable branch.
- `frontier_enabled -> true|false` — the leaf frontier is a pure
  performance layer; `frontier_matches_direct_scans_*` and
  `disabled_path_matches_direct_scans` pin both arms to identical leaf
  sets and order, so forcing either arm is behavior-neutral by design.
- `build_digraph` :2012 (`||`→`&&` in the uninstall reverse-edge loop)
  — `g.children[owner]` can never hold the removal node at that point
  (the forward walk's `match_candidates` drops every `Uninstall`
  target), so the `any(...)` term is constantly false and the condition
  reduces to `i == j`; `required_by` never names the removal's own cp
  either.
- `build_digraph` :2025 (delete the `satisfied` field from the reverse
  edge's priority) — the literal sets `satisfied: false`, which is
  already `DepPriority::default()`'s value.

**#145 survivors.**

- `2025:29` (delete `satisfied` from the reverse edge) — equivalent, as
  under #146.
- `1283:12` (delete `!` from `if !present.insert(key) { return; }`) —
  **caught by timeout**: the flipped guard pushes an unbounded stream of
  duplicate synthetic entries (each duplicate is re-queued), so the
  closure loop never terminates; no bounded test can observe it, and it
  is recorded rather than pinned around (batch §4 Phase 8).
- `1155:21` (`&&`→`||` in the `if let Some(a) = atom && …` let-chain) —
  **unviable**: let-chains do not accept `||`, so the mutant does not
  compile.

**#144 fix pass (reviewer counterexamples, 2026-09-23).** The first
classification called 12 survivors equivalent; a fresh-context review
produced concrete inputs where they change the selection. Five new
tests cover them —
`select_nodes_prefers_a_leaf_whose_parent_is_an_asap_node` (the
asap-parent preference: 6 mutants),
`select_nodes_promotes_only_an_unsatisfied_pdep_child` (the PDEPEND
promotion predicate) and `select_nodes_pins_the_normal_range_cycle_pass`,
`select_nodes_escalates_to_the_satisfied_range_before_the_roots` (the
range-escalation guard; `select_nodes_pins_the_single_leaf_shortcut` and
`select_nodes_defers_the_root_selection_when_asap_is_pending` were
covered by the asap-preference test) — 11 caught and one
(`2946:50`) recorded caught by timeout. The #145 survivor `1164:88`
(`<`→`<=` in `pick_installed`) was also misclassified: `1.0` and
`1.0-r0` compare equal (a missing revision is 0), so the mutant can
replace the first vercmp-equal version; now caught by
`add_installed_dependency_closure_keeps_the_first_of_vercmp_equal_versions`.

**#144 survivors (17 missed + 19 timeouts, all classified).**

The 17 missed (every one behavior-neutral under the shapes the resolver
can produce):

- `2025:29` (delete the explicit `satisfied: false` field) —
  equivalent: `false` is `DepPriority::default()`'s value.
- `2478:54` (`<`→`<=` in `elementary_cycles`' min-length update) —
  equivalent: `<=` only re-assigns `min_len` to an equal value.
- `2830:17` (`mo_iter += 1`→`*=`) and `3055:21` (delete `!` in the
  `retlist_merges` count) — trace-only: both feed only the
  `PORTUALE_MO_SEL` stderr line.
- `2921:48`, `2921:61` ×3 (the `--debug` cycle-dump gate) and `3156:5`
  (whole-body `debug_dump_cycle`) — trace-only: stderr dumps under
  `--debug`.
- `2938:41` (`sub.len() > 1`→`>= 1`) — equivalent: a one-node `sub`
  harvests to the same node the `collect()` branch would take.
- `2973:37` (`||`→`&&` in the promotion's already-queued guard) —
  equivalent: the extra duplicate `asap` entry is pruned by
  `asap.retain(alive)`.
- `3325:18`/`3325:67` ×4, `3327:16` ×2 (the leftover weave-back's
  bounds/sort arms) — equivalent: `select_nodes` schedules every real
  entry, so `leftover` is always empty and the block's body never runs.

The 19 timeouts, by family (a bounded test cannot observe a hang — the
test hangs too; recorded *caught by timeout*, not pinned around):

- `SerializeFrontier::build` 688:23/688:28 ×2 — the `m &= m - 1`
  lowest-bit-clear (and its `+`/`/` variants) no longer clears bits, so
  the survival-count loop never terminates.
- `leaves_via -> vec![0]|vec![1]` — a bogus non-empty leaf list leaves
  the scheduler removing nothing; `while any alive` never ends.
- `gather_deps -> Some(empty)` / `find_smallest_cycle -> Some((empty|…, None))` ×4
  — an empty cycle closure selects nothing, so the loop makes no
  progress.
- `harvest_cycle -> vec![]` / `2352:11 delete !` — an empty harvest (or
  the skipped `while !remaining.is_empty()` loop) selects nothing.
- `elementary_cycles::shortest_path 2449:43` (`&&`→`||`) — already-seen
  nodes are re-enqueued, so the BFS frontier grows without bound.
- `select_nodes 2946:35`, `2946:50`, `3015:16`, `3024:31`, `3089:16` —
  guard flips that re-enter a no-progress iteration (2946:35/2946:50
  with `asap` non-empty) or skip/repeat a removal; the `alive` set
  stops shrinking.
- `schedule_graph 3422:28` / `3431:12` — the prune loop's `removed`
  flag/guard flips make it iterate forever.

New `mod tests` functions (all in `merge_order.rs`): the #146 family
(`key_priority`, `dep_edges_from_metadata` keys/priorities/blockers/
slot-operators/disjunctions, `split_disjunctive` bookkeeping,
`ignore_*` truth tables, `ignore_name`, `PriorityRange` rungs,
`rank_best`, `select_dep_target` narrowing/elimination, `build_digraph`
self-edges/blockers/top-atom narrowing/inline-vs-deferred/uninstall
reverse edges/`required_by` fallback), the #145 family
(`outcome_version`, `edge_satisfied_with`, `installed_candidates_by_cp`
over the fixture vdb, `dep_edge_satisfied_by_installed`,
`add_installed_dependency_closure` over runtime scratch vdbs including
the injected-libc strip and the vercmp-equal pick), and the #144 family
(`Digraph` primitives, `deep_system_deps`, `seed_toolchain_asap`,
`gather_deps`, `find_smallest_cycle`, `harvest_cycle`, `cycle_report`,
`tree_schedule_stuck`, `tree_note_selection`, `select_nodes` (greedy
batch, runtime-cycle harvest, satisfied-range escalation, PDEPEND
promotion, asap-parent preference, range-escalation guard),
`serialize_merge_order`, `schedule_graph`, `tree_solved_replacements`,
`suppressed_alt_edges`). No fixture was added and no product byte
changed.

## `portage-repo/src/lib.rs` — run 2026-09-25 (backlog #52 P7b, batch `batch-2026-09-24.md`)

Launch: `cargo mutants --in-place --file portage-repo/src/lib.rs`
(branch `backlog/52-librs-mutants` both repos, portuale rev `a790a058`,
clean tree before and after — only `mutants.out/` remained, removed;
per-row data kept in the portuale workspace
`.superpowers/sdd/batch-2026-09-24/p7b/`). Mutant count at launch
**2729** (was 2207 in the plan; growth from Phase 13 + #153/#155, as
predicted). Unmutated baseline green. Serial run, ~7 h wall clock.

Result: **2729 tested: 1588 caught / 940 missed / 197 unviable / 4
timeouts.** `lib.rs` holds 422 `#[test]`s, but the 132
survivor-carrying functions have ~zero direct unit references — the
same shape Phase 8 found in `merge_order.rs`: coverage lives in the
black-box contract suite, which the mutation run does not execute.
Timeouts (inspect, don't pin around): `delete ! in
topological_removal_order` (7627:12, loop-divergence suspect, same
family as Phase 8's `schedule_graph` hangs), `Backtracker::get ->
Some(default)` (20574:9, default params likely re-enter backtracking
forever), and two `alnum_sort_key` arithmetic rows (8543/8544, slow,
not necessarily hung).

Clusters (one backlog item each; each item's implementation classifies
equivalent/trace-only rows the way Phase 8's review pass did — no
tests written in this phase):

| Item | Area | Missed | Representative functions |
|---|---|---|---|
| #161 | slot-conflict/backtracker driver | ~233 | `run_pass` (140), `direct_solve_slot_conflicts`, `build_residual_slot_conflicts`, `collect_feedback`, `Backtracker::feedback`, `slot_operator_rebuild_*` (+1 timeout) |
| #162 | pure selection predicates | ~102 | `promote_tied_alternative`, `alternative_downgrade_demoted`, `params_equal`, `disjunction_preference`, `clean_selection`, `complete_graph_auto_enable`, `check_if_latest_atom_form`, `bare_cp` |
| #163 | result/display assembly | ~88 | `resolve_pretend` (42), `assemble_result` (32), `use_unsat_parent_row`, `abort_outcome`, `refresh_entry_use_display` |
| #164 | masking/visibility stack | ~63 | `autounmask_dep_chain`, `parse_license_tree`, `mask/license/keyword_masked_only`, `visible_tree_matches`, `required_use/masked_dep_chain` |
| #165 | graph inputs (walk/installed/vdb, merge-order, blockers, use) | ~122 | `installed_reverse_dependents`, `vdb_fingerprint`, `find_repos_impl`, `enqueue_dependencies`, `topological_removal_order` (+1 timeout), `prune_cleanlist`, `resolve_blockers`, `file_blocker_conflicts`, `collect_unwalked_installed_blockers`, `parent_use_state` |
| #166 | circular/instance-use solution residue | ~120 | `circular_dep_solutions` (17), `synthesize_surviving_conflict_entries`, `rebuilt_binary_changed`, `strip_revision`, `filter_usepkg_exclude_include`, `direct_solve_instance_use/arg_mode` |

Plus ~212 whole-function-body rows with no function attribution,
spread file-wide (heaviest: 82 in lines 0–1999, the top-of-file
config/error/slot helpers) — each item's implementation reviews its
area's share. Bucket hypothesis for
all six: real unit-test gaps (black-box-covered, unit-invisible),
with whole-body noops on small pure functions the likely-equivalent
tail. O12-style stop not applicable (campaign phase, not a parity
run); no stop fired — six clusters is the handful the plan asks for.
