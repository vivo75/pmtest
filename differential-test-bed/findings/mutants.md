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

## #161 closeout (2026-09-26, branch `backlog/161-librs-backtracker-driver-tests`)

S1–S6r, all test-only in `rust/portage-repo/src/lib.rs` (`mod tests`;
+4386 lines, 53 `run_pass_*` legs plus S1–S5 legs for the other five
functions; no product byte, no pmtest counterpart — standalone
commits). Scratch-`ResolveCtx` harness in the Phase 8 S2 style
(`CtxOpts161`/`ctx_161`/`run_161`, fixture-tree + scratch-repo legs).

`run_pass` scope accounting (P7b inventory: 140 missed): S6a–S6o legs
killed 48 (final full-scope `in run_pass$` re-run: 92 missed), then
S6p killed 5 (23532:80, 23535:33, 23563:60, 23566:37, 23608:78 —
genuine-Binary `with_bdeps` + `--buildpkgonly` legs, each verified
lethal by hand-application), S6q killed 6 (23103:51, 23103:62,
23563:33, 23563:63, 23608:51, 23608:81 — edge/oldbest asserts, each
verified lethal), S6r killed 1 (22634, Reinstall-revisit reuse leg),
and 2 more hand-verified lethal outside the scope runs (23823 pumask,
23831 autounmask-mask commutator — scope-stale binaries reported them
missed; touch-guarded hand-application failed as required). Total:
62 killed, 78 classified survivors below. S1–S5 (other functions):
slot-op scan/probe/bind/eliminate/entries (19 caught + 1 proven
equivalent 14855:29), `params_equal`/`Backtracker` (57 caught + 1
timeout `Backtracker::get`), `build_residual_slot_conflicts` (23
caught + 1 unviable 18072), `collect_feedback` (14 caught),
`direct_solve_slot_conflicts` + `slot_conflict_mask_choices` (19
caught + 4 proven equivalent 18449x3/18462). The `Backtracker::get ->
Some(default)` timeout (20574:9) stands: inspect, don't pin around.

Survivor buckets (line numbers are `portage-repo/src/lib.rs` at
`5bb7c875`; every row below was hand-applied and observed surviving
except where noted):

- Trace-only, no `PassResult` surface (3): 21364:25, 21492:29
  (`resolver_debug() && first_pass` stderr gates); 21661:16
  (`parent_atoms` dedup — unreachable in practice: `visited_atoms`
  precludes pushing the same row twice).
- Autounmask path, gate never opens in-harness (20): the parent-flip
  block 21687:26, 21739:23, 21813:48, 21835:44, 21879:50/37/61,
  21880:21, 21883:54/41/65, the suggestion gate 22357:17, and the
  flip-fold overlay block 22854:47, 22892:62/49/73, 22893:33,
  22896:66/53/77. All need `NoVisibleCandidate` +
  `autounmask_suggest_use` (harness `BacktrackParams::default()` leaves
  it false) + masked/forced-USE conditional-parent shapes. Recipe for
  a follow-up: suggest_use params + mask fixtures + NVC probe.
- Downgrade shapes absent from fixtures (2): 22057:13
  (`resolved_version` Downgrade arm, missing-dep feedback),
  22633:17 (`existing_version` Downgrade arm, slot revisit). No
  newer-installed fixture exists; display/output contract pins cover
  the rendering.
- Binary-selection skew/divergence (20): respect-use gate
  22534:17, 22535:17, 22536:17/20, 22541:71/44/84
  (gate-shadowed: the finder closure never runs with the gate shut;
  needs newuse/binary + USE-divergent binary/ebuild pair) and the
  equiv-ebuild filter 22567:41/33/17/44, 22569:30, 22570:25,
  22571:25, 22577:50, 22580:40, 22582:31, 22585:37, 22586:37 (needs a
  version-skewed binary/tree shape: tree ebuild at another version so
  the retain actually drops). 22582:26 additionally needs the
  `use_ebuild_visibility` process global + `--useoldpkg-atoms`
  (global-gated; harness carries neither).
- Slot-op unrebuildable (6): 22656:41, 22657:21, 22658:21, 22659:21,
  22701:35, 22706:29 (bare-`:=` + `built_equals_*`: needs an
  installed-bound instance that cannot rebuild — excluded/vdb
  interplay the scratch vdb cannot express).
- Use-dep collision revisit (4): 22757:24, 22758:77, 22762:57,
  22786:24 (needs a resolved_slots revisit whose existing version's
  USE fails the second atom's `[use]` deps — per-version-USE-divergent
  fixtures).
- #57 direction-2 (1): 22935:37 (`installed_sub` find — needs the
  installed+merge same-slot collision; #57's oracle cells pin it
  end-to-end).
- Proven equivalent (1): 23100:43 (New guard `new_slot -> true`:
  `New` + `!new_slot` implies no installed refs at all, so the guard
  arm yields `[]` either way).
- Download recipe (1): 23280:29 (`candidate_source == Ebuild` for
  `download_files` — unobservable with SRC_URI-less scratch ebuilds;
  needs SRC_URI in the package writer + a non-empty-bytes assert).
- REQUIRED_USE message nuances (2): 23392:25 (`Ok(Some(r))` arm —
  needs a violation whose reduced form differs from normalized;
  orrequseprefer-shaped), 23399:33 (`!repo.is_empty()` guard — needs
  an empty-repo candidate in a violation).
- Reinstall display nuance (1): 23472:17 (`reinst_flags` arm —
  force-show vs changed-marker rendering identical in every
  newuse shape; display contract pins cover it).
- AI+merge coexistence (2): 23900:17, 23903:17 (`mergebound_cp_slots`
  arms — the retain's drop arm never fires: no shape across 50+
  legs co-emits an `AlreadyInstalled` entry with a merge-bound
  same-cp slot; unreachable-in-practice).
- Direct-solve removal (13): 23965:25, 23981:41, 24039:36,
  24045:55/49, 24077:42, 24078:53, 24079:33/48, 24084:58,
  24085:64/52/75 (everything downstream of a non-empty
  `solved.removed`: keeper repoint (vdb vs tree), keeper blocker
  collection + dedup. No `run_pass` leg produces a solved removal;
  `direct_solve_slot_conflicts` itself is pinned at unit level by S5).
- Replacement-wait (2): 24157:27/13 (`needs_tree_sim` — needs a
  blocker satisfied by `Replacement`; #68/#72 shapes, contract-pinned).

Method notes for the next cluster items (#162–#166): `cargo mutants
-- <regex>` scope runs go stale fast on this file — always `touch`
the file first (mtime-stale binaries report false misses; 23823/23831
above), clear `rust/mutants.out` between runs, and restore with
`git checkout --` (never from a `/tmp` backup older than the latest
slice — S6p was once clobbered exactly that way). A leg that
"passes" without proving its key property (S6p's first `with_bdeps`
leg walked an ebuild, not a binary — caught only by instrumenting
`candidate_source` at the gate) is worse than none: instrument the
gate before trusting a green leg. `cargo fmt --check` (edition 2024
via `cargo fmt`; a bare `rustfmt` without `--edition` silently uses
2015 and reports clean) was already red at S1 (`e99e24f5`, 8 hunks)
and drifted to ~70 by S6r — normalize with one `cargo fmt` at each
item's closeout, never inside a test slice.

## #162 closeout (2026-09-26, branch `backlog/162-librs-selection-predicates`)

S1–S7, all test-only in `rust/portage-repo/src/lib.rs` (new
`mod tests_162`, +~1400 lines, 46 tests; zero product bytes, no
pmtest counterpart — standalone commits). Direct predicate-result
legs in the #161 scratch-repo style (`repo_pkgs_162` /
`install_162` / `entry_162` / `cand_162` / `qatom_162` helpers, one
temp root per leg, `testrepo` scratch repos + scratch vdbs).

S0 scope (`cargo mutants -p portage-repo --file
portage-repo/src/lib.rs --in-place --timeout 300 -F
'(bare_cp|clean_selection|alternative_downgrade_demoted|disjunction_preference|promote_tied_alternative|check_if_latest_atom_form|complete_graph_auto_enable|params_equal)'`,
142 mutants: 118 in-body + 18 whole-body rows + 6 out-of-scope
strays): **70 missed / 70 caught / 2 unviable**. Per-function missed
at S0: `bare_cp` 6, `check_if_latest_atom_form` 6,
`clean_selection` 10 (9 in-body + `-> vec![]`),
`complete_graph_auto_enable` 8, `disjunction_preference` 10,
`promote_tied_alternative` 15 (14 in-body + `-> 0`),
`alternative_downgrade_demoted` 15 (14 in-body + `-> false`).
`params_equal` 0 missed: all 31 rows already caught by #161 S2's
`backtrack_params_equal_compares_every_accumulator`, so no S8 was
needed. The 6 strays (`BacktrackParams::initial` field deletions +
`parse_updates_content` guards mentioning `bare_cp`) were all
S0-caught by existing legs.

Closeout re-run (same command, `touch` first, on the S7 tree):
**2 missed / 138 caught / 2 unviable**. Per-function missed after:
`bare_cp` 1, `clean_selection` 1, everything else 0 — 68 killed
across S1–S7 (S1 5, S2 9, S3 8, S4 6, S5 10, S6 15, S7 15).

Survivor buckets (line numbers are `portage-repo/src/lib.rs` at
`cbc40620`; every row below was hand-applied and observed
surviving):

- Proven equivalent (2): 272:9 (`||` -> `&&` in `bare_cp`'s version
  arm — `portage-dep` `parse_atom_uncached` sets `version` exactly
  when the `op` group is present and rejects the ambiguous
  trailing-version form, so `version.is_some() <=> operator != None`
  on every parseable atom while unparseable inputs return `None`
  either way through `?`); 8379:69 (`&&` -> `||` in
  `clean_selection`'s atom/cp guard — `match_from_list` requires cp
  equality, so a non-empty match implies the guard).
- Unviable (2, tool-reported, no test possible): 8369:5
  (`clean_selection -> vec![Default::default()]` —
  `PruneNodepsCp` has no `Default`); 11584:19 (`&&` -> `||` in
  `promote_tied_alternative`'s `if let ... && let ...` — the RHS
  names a binding the LHS never introduces, does not compile).

Corrections to slice commit messages (no rebase, following this
file's own #161 review-pass precedent): S1 (`22e2891a`) claims all
six `||` -> `&&` flips killed — 272:9 above is the exception
(equivalent, not killed; the leg kills the other five). S2
(`30335e8d`) says "Kills 8" but lists, and kills, 9 (the
whole-body `vec![]`, three `< 2` flips, the cross-slot best flip,
both atom/cp `==` flips, the `&&` -> `||` and the `!is_empty`
deletion — the tenth S0 row is the equivalent 8379:69).

No `cargo fmt` closeout commit: every slice kept `cargo fmt --check`
(edition 2024) green as it landed, so the closeout `cargo fmt`
was a no-op. Host quirks for #163–#166: `cargo fmt`/`clippy` go
through rustup proxy shims here — prefix
`RUSTUP_TOOLCHAIN=stable-x86_64-unknown-linux-gnu` (same 1.98.1
compiler); and a re-run that reports only two early misses while
`caught.txt` keeps growing is fine (stdout shows misses only).

## #164 closeout (2026-09-26, branch `backlog/164-librs-masking`)

S1–S6, all test-only in `rust/portage-repo/src/lib.rs` (one new `mod
tests_164` block, 33 legs; no product byte, no pmtest counterpart —
standalone commits). Direct legs observing each predicate's own result:
hand-built `Candidate`s over a nonexistent repo location (no md5-cache
entry means `invalid_use_conditional_reasons` is empty), `Binary`
candidates carrying their own `binary_use`/`binary_deps` (no repo
staging at all), hand-built `GraphEntry` vecs, and a scratch-repo
writer with per-version KEYWORDS/LICENSE/SLOT for
`visible_tree_matches`.

Scope accounting (S0 on current `main`: `cargo mutants -p portage-repo
--file portage-repo/src/lib.rs --in-place --timeout 300 --re
'<nine cluster-4 names>'`, serial in-place — `--in-place` rejects
`--jobs` in v27.1.0, so `-j 4` became serial; 133 mutants, 18 min):

| Function | S0 missed | After | Killed by |
|---|---|---|---|
| `parse_license_tree` | 11 | 0 | S1 exact error positions (`pos + N` on every arm, incl. position 0) |
| `keyword_masked_only` | 7 | 0 | S2 true/false + per-gate + mask/unmask + invalid legs |
| `mask_masked_only` | 9 | 0 | S2, same shape |
| `license_masked_only` | 7 | 0 | S2 + USE-conditional leg |
| `use_masked_only` | 4 | 0 | S2 binary baked-USE legs |
| `visible_tree_matches` | 9 | 0 | S3 scratch-repo legs (visible set, `!`/`=` constraints, LICENSE verdict) |
| `masked_dep_chain` (+3 nested fns) | 9 | 0 | S4 decoy-pinned chain/installed/arg-lines legs |
| `required_use_dep_chain` | 4 | 0 | S5 parent/argument/decoy/empty legs |
| `autounmask_dep_chain` | 13 | 1 | S6 chain/upgrade/installed/self-loop legs; 1 proven equivalent (below) |

Closeout re-run of the S0 command (touch first): **133 tested: 1
missed / 130 caught / 2 unviable** (was 73 / 58 / 2). Real grounding
for every mask/license verdict leg: `_getmaskingstatus`
(`3rdparty/portage/lib/portage/package/ebuild/getmaskingstatus.py:43`,
one `_MaskReason` per failing category — the "X alone" semantics),
`LicenseManager.getMissingLicenses`/`_getMaskedLicenses`
(`_config/LicenseManager.py:169,211`), `_pkg_visibility_check`
(`depgraph.py:7562`), `_get_dep_chain_as_comment` (`depgraph.py:6457`),
`_show_unsatisfied_dep` (`depgraph.py:6471`).

Survivor buckets (line numbers are `portage-repo/src/lib.rs` at
`4eaf0d02`):

- Proven equivalent (1): `autounmask_dep_chain` 19302:31 (`match guard
  *next != cur -> true`). The only divergence shape is a self-loop
  (`required_by.first() == cur`): the mutant advances onto itself and
  re-breaks on the `visited` set with the identical chain (the node is
  always pushed first — every non-NVC/Uninstall outcome carries a
  version; no-parent means the guard never evaluates; a longer cycle
  has no self-edge). Hand-applied and observed surviving the full
  644-test suite; pinned by the new self-loop leg.
- Pre-existing unviable (2, unchanged from S0): `parse_license_tree`
  `Ok(vec![Default::default()])` and
  `masked_dep_chain::select_entry` `Some(Box::leak(Default))` — neither
  target type implements `Default`, so neither compiles.

No product divergence found: every mask/license verdict the legs pin
matches real's reason-accumulation semantics above. Two test-design
traps hit while writing legs (both fixed before committing, kept here
so the next item doesn't re-learn them): (1) `test_config` accepts no
license by default, so MIT-licensed scratch packages read as
license-masked — accept `*` when the KEYWORDS verdict is the subject;
(2) an operator-less versioned constraint (`!dev-libs/pkg-1.0`) is
rejected as PMS-ambiguous by portage-dep (mirroring real
`Atom.__init__`), making the constraint vacuous — use `!=...`.

Scope-filter notes for the next items: `--re` also matches 4
`BacktrackParams::initial` field-deletion mutants on EVERY filter
(including a nonsense one — unconditional companions, caught
throughout, unrelated to this cluster); and a `$`-anchored `--re`
silently drops whole-body replacements (their names end in `[]`/
`true`, not the function name) — S1–S3 ran gate-level rows anchored
and whole-body rows fell through to this closeout run; S4–S6 ran
unanchored. Prefer unanchored function-name scopes. `cargo fmt
--check` stayed green at every slice commit here (the tree was clean
at S0, so each slice hand-matched rustfmt instead of a closeout
`cargo fmt` — no style commit needed); `cargo clippy --release
--all-targets` zero warnings; `cargo test --release -p portage-repo`
644 passed (611 + 33 new).

## #163 closeout (2026-09-26, branch `backlog/163-librs-display`)

S1–S5, all test-only in `rust/portage-repo/src/lib.rs` (new
`mod tests_163`, +~3900 lines, 81 tests; zero product bytes, no
pmtest counterpart — standalone commits). Direct result-structure
legs in the #161/#162 scratch-repo style (`repo_pkgs_163` /
`write_pkg_163` / `install_163` / `resolve_163` + `RpOpts163` /
`ctx_163` / `pass_163` helpers, one temp root per leg).

S0 scope (`cargo mutants -p portage-repo --file
portage-repo/src/lib.rs --in-place --timeout 300 -F
'(resolve_pretend|assemble_result|use_unsat_parent_row|abort_outcome|refresh_entry_use_display)'`,
180 mutants): **76 missed / 91 caught / 13 unviable**. Per-function
missed at S0: `refresh_entry_use_display` 4 (of 9 rows),
`use_unsat_parent_row` 6 (of 13), `resolve_pretend` 29 (of 96),
`abort_outcome` 5 (of 14), `assemble_result` 32 (of 43). The 5
strays (4 `BacktrackParams::initial` field deletions, all caught;
1 `resolve_pretend_graph` whole-body row, unviable) needed nothing.

Closeout re-run (same command, `touch` first, on the S5 tree):
**2 missed / 165 caught / 13 unviable**. Per-function missed
after: `resolve_pretend` 2, everything else 0 — 74 killed across
S1–S5 (S1 5, S2 6, S3 4, S4 27, S5 32), every one hand-verified
lethal by mutant application (focused `cargo test -p portage-repo
--lib tests_163` run per mutant, restored with `git checkout --`).

Survivor buckets (line numbers are the S0-run lines in
`portage-repo/src/lib.rs` — the appended `tests_163` block shifts
nothing before it; every row below was hand-applied and observed
surviving):

- Proven equivalent (1): 13097:33 (`&&` -> `||` in the
  `_equiv_ebuild_visible` outer gate). The gate's body is a no-op
  in exactly the shapes where the gate flips: with no binaries the
  retain runs over an empty vec, and under `--usepkgonly` the
  ebuild-visibility probe sees ebuilds only (binaries join the pool
  after the block) while `some_ebuild_matches_atom` is false and
  `uev` is false, so the inner retain never runs. Full `tests_163`
  suite green under the mutant.
- Unreachable (1): 13406:27 guard-`true` (`Some(use_deps) if true`).
  Only `Some([])` could observe it, and `portage-dep`
  `parse_use_deps` returns `None` for empty brackets (`foo[]` is
  invalid, same as real) while `parse_atom` propagates that `None`
  — so the arm is entered exactly when real enters it.
- Unviable (13, tool-reported, no test possible): the four
  whole-body `Default::default()` rows (`resolve_pretend`,
  `abort_outcome`, `assemble_result`, `resolve_pretend_graph` —
  none of those types implement `Default`), the six `&&` -> `||`
  flips on `let`-chain arms (13328/13329/13330, 13499,
  13541:9/13542:9/13543:9 — the `||` branch leaves the `let`
  binding unbound), 10419:9 (`||` names an unintroduced binding),
  and 25068:13 (same `let`-chain shape).

Corrections to slice work (no rebases, following this file's own
#161 review-pass precedent): the S4 `lonely` and `changed-deps`
legs were redesigned mid-slice (masked ebuild / slot-skewed binary)
after hand-application showed the `_equiv_ebuild_visible` filter
drops any binary with no ebuild at its version regardless of the
respect-use/changed-deps verdict; the S4 pin leg was redesigned
(masked tree) after the downstream `matched`-filter was found to
repair the `satisfies_extra_constraints` break; the S4 rebuilt
`rebuilt` arm was restructured (top-level selective under
`--update`) after the `--emptytree` arm was found to mask the
disjunction mutant; a new best-path trigger test covers the
best-version disjunction arms the `avoid_update` shortcut masks;
the S5 dedup leg was redesigned (different-atom record) after the
coalescing block was found to repair exact duplicates; the S1
18968:52 kill lands through the installed leg too (`.find()`
shadowing), not just the ghost leg.

Method notes for #164–#166 (in addition to #161's): never edit or
commit `lib.rs` while your own `--in-place` run is active — it
restores the file to its startup snapshot after every mutant and
silently wipes uncommitted work (S1 was lost exactly this way;
`git checkout --` restores are only safe past a commit). Amend
(`git commit --amend`) rather than stacking fixups when a
hand-application round trips a leg redesign. Process-global
setters (`set_useoldpkg_atoms`) need a dedicated cp plus a single
set/reset pair in one test, or parallel legs observe each other's
windows (here: `dev-libs/opkg`). The slot-operator vdb-scan token
is `:slot/sub=` with no trailing colon (`dev-libs/prov:0/0=`
parses; `:0/0:=` does not).

No `cargo fmt` closeout commit: every slice kept `cargo fmt
--check` green as it landed (one mid-S4 `cargo fmt` over own hunks
only), and the closeout check is clean. Closeout gates:
`cargo clippy --release --all-targets` zero warnings;
`cargo test --release -p portage-repo` 738 passed / 0 failed.

## #165 closeout (2026-09-27, branch `backlog/165-librs-graph-inputs`)

S1–S9 + S6b, all test-only in `rust/portage-repo/src/lib.rs` (new
`mod tests_165`, +~2000 lines, 47 tests; zero product bytes, no pmtest
counterpart — standalone commits). Scratch-vdb / scratch-repo legs in
the Phase 8 S2 style (`dir_165` / `install_165` / `write_pkg_165` /
`repo_165` / `entry_165` helpers, one temp root per leg, `testrepo`
scratch repos + scratch vdbs). Every test observes the function's own
return value (returned vectors, the vdb fingerprint, filed conflicts,
queued atoms) — no end-to-end contract reproduction.

S0 scope (`cargo mutants -p portage-repo --file
portage-repo/src/lib.rs --in-place --timeout 300 -F
'(installed_reverse_dependents|vdb_fingerprint|find_repos_impl|enqueue_dependencies|topological_removal_order|prune_cleanlist|resolve_blockers|file_blocker_conflicts|collect_unwalked_installed_blockers|parent_use_state)'`,
255 mutants): **153 caught / 88 missed / 1 timeout / 13 unviable**.
Per-function missed at S0: `installed_reverse_dependents` 13 (3
whole-body + 10 in-body), `vdb_fingerprint` 10 + `mtime_nanos` 2,
`find_repos_impl` 6, `parent_use_state` 4, `topological_removal_order`
20 + 1 timeout, `prune_cleanlist` 6, `file_blocker_conflicts` 7,
`collect_unwalked_installed_blockers` 6, `resolve_blockers` 8,
`enqueue_dependencies` 6. Unviable (13, tool-reported, no test
possible): `find_repos_impl` whole-body `Ok(vec![Default])`
(`RepoConfig` has no `Default`), the `&&` -> `||` let-chain (the
`text` binding goes unbound), `any(|k| k)` (`&bool` where `bool` is
needed); `parent_use_state` `Some(Default::default())` (no `Default`
on the tuple); two `topological_removal_order` whole-body
`vec![Default::default()]` rows (`InstalledPackage` has no `Default`);
`prune_cleanlist` `DepcleanResult::default()` (no `Default`);
`file_blocker_conflicts` deleted `Uninstall` match arm (does not
compile); `collect_unwalked` `&&` -> `||` (the `dep_atom` binding goes
unbound); `resolve_blockers` `vec![Default::default()]`;
`enqueue_dependencies` three `&&` -> `||` rows (each puts an `Option`
in a `||` scrutinee position — type errors).

Kills per slice (representative rows verified lethal by
hand-application; the closeout re-run below is authoritative):
S1 (`installed_reverse_dependents`) 12: whole-body x3, both `&&` ->
`||` self-skip widenings, all three `==` -> `!=` self-skip flips, the
blocker `!=` -> `==` flip, both cp-guard flips that admit a matchable
atom, the match `delete !`.
S2 (`vdb_fingerprint`) 5: whole-body `-> 0` / `-> 1`, nested
`mtime_nanos` `-> 0` / `-> 1`, final `^` -> `&`. (The rotation `+` ->
`-` and `count` `+=` -> `-=` rows were already S0-caught, panicking in
pre-existing vdb legs; the S2 sensitivity leg pins them too.)
S3 (`find_repos_impl`) 4: default-priority `==` -> `!=`, the
`volatile` `||` -> `&&` flip, both heuristic `!` deletions.
S4 (`parent_use_state`) 4: owner-lookup `&&` -> `||`, deleted
`Upgrade` / `Downgrade` / `Reinstall` arms.
S5 (`topological_removal_order`) 14: all three priority-arm deletions
+ the PDEPEND `-3` -> `3` flip, the `slot_op_built` `&&` -> `||`
narrowing (via a sub-slot-less `:=` atom), the first `||` -> `&&`
narrowing (which admits the self-edge), the `indeg` `+=` / `/=` rows,
three `delete -` scan levels, the cycle-break `&&` -> `||`, the
`!done` filter deletion. (The two viable whole-body rows and the `n <
2` `>` flip were already S0-caught by the pre-existing order legs.)
S6+S6b (`prune_cleanlist`) 4: the `>=` multi widening, the args outer
`&&` -> `||`, the kept `&&` -> `||`, and (S6b) the guard `-> false`
flip via 9.0/10.0 versions that disagree between lexicographic and
version order (this host's tmpfs readdir is sorted, so last-scanned is
always the version max with plain versions — probed directly).
S7 (`resolve_blockers`) 7: deleted `Downgrade` / `Reinstall` arms,
all four graphed-USE lookup mutants, the same-cp fallback `&&` ->
`||`.
S8 (`file_blocker_conflicts` 7 + `collect_unwalked` 6) 13: every
S0-missed row in both functions.
S9 (`enqueue_dependencies`) 6: every S0-missed row (each of the six
verified lethal individually).
Total killed: 69. Closeout re-run (same command, `touch` first):
**222 caught / 19 missed / 13 unviable / 1 timeout** (255 tested in
28m), i.e. per-function missed before→after: `find_repos_impl` 6→2,
`parent_use_state` 4→0, `installed_reverse_dependents` 13→1,
`vdb_fingerprint`+`mtime_nanos` 12→7, `topological_removal_order`
20+1 timeout→6+1 timeout, `prune_cleanlist` 6→2,
`file_blocker_conflicts` 7→0, `collect_unwalked` 6→0,
`resolve_blockers` 8→1, `enqueue_dependencies` 6→0.

The binding timeout (7627:12 `delete !` on `if !ready.is_empty()`):
the mutant inverts the ready-batch branch, so any iteration with an
empty ready set sorts nothing, emits nothing, and `continue`s without
progress — an infinite loop on every cyclic input (the pre-existing
two-cycle legs hang; the scoped run spends the full 300s on it). It is
not pinned around: the new chain-DAG leg terminates on the mutant and
fails in 0.00s (verified), because a DAG never takes the empty-ready
branch. The tool still reports `timeout` (the pre-existing cycle legs
hang), so the row stands as timeout with a demonstrated fast kill —
the same inspect-don't-pin treatment as #161's `Backtracker::get`.

Survivor buckets (19; every row hand-applied and observed surviving;
line numbers are `portage-repo/src/lib.rs` on the item branch):
- Proven equivalent (10): `installed_reverse_dependents` 6454:55
(`||` -> `&&`: a wrongly admitted atom always fails the cp match, so
the filed set never changes); `topological_removal_order` 7637:39
(the -1 scan level can never pop a matchable edge — priorities are
-4..-2 or 0, and anything eligible at -1 was already eligible at -2),
7570:56 / 7572:39 / 7573:21 (the -1 priority: only a sub-slot `:=`
atom takes it, and no `:slot/sub` candidate string ever matches one,
so the edge never forms), 7572:52 (the RDEPEND condition `&&` ->
`||`: promoting every RDEPEND edge -2 -> -1 moves the whole -2 bucket
to the empty -1 bucket, preserving every pop), 7578:62 (the second
`||` -> `&&`: `&&` binds tighter, so the `i == j` arm still
short-circuits and skips; cross-cp admissions always fail the cp
match); `prune_cleanlist` 8137:61 / 8161:58 (the inner `&&` -> `||`
widenings: the outer full match still requires cp equality);
`resolve_blockers` 16930:49 (`installed_match` `&&` -> `||`: an
entry-sourced match always self-matches on slot+version and an
installed-sourced match always self-matches, so only a twin-entry
pathological shape could diverge).
- Contract-preserving hash-mixing (7, all `vdb_fingerprint`): `^=` ->
`|=` / `&=`, rotation `+` -> `*`, `%` -> `/` / `+`, `count` `+=` ->
`*=`, final `^` -> `|`. Each keeps the fingerprint's
stability-and-sensitivity contract (deterministic per tree, changes on
structural change), so no deterministic oracle distinguishes them.
- Trace-only (2, `find_repos_impl` 1394:16/20): the section-mismatch
`eprintln` gate — no return-value effect.

Corrections to slice commit messages (no rebase, per the #161 review
precedent): S1 (`8479aaf0`) claims 11 killed + 2 equivalent — actually
12 killed (the category `==` -> `!=` flip is lethal) + 1 equivalent
(only the `||` -> `&&` narrowing). S5 (`208d9ef1`) claims the `-=`
-> `/=` row equivalent — actually killed (divide-assign never decrements
`indeg`; the chain then pops in cycle-break order) — and predates the
re-run, so it omits the second `||` -> `&&` narrowing and the RDEPEND
condition widening, both re-run-confirmed survivors with the proofs
above. S6 (`c9f7a614`) claims three equivalents including the kept
`&&` -> `||` — actually that row is killed by the kept-parents leg (a
reachable-but-unmatched package with a walk edge files a third row);
S6b (`e6cc3156`) killed the guard `-> false` the S6 legs missed. S7's
merge-bound-match leg docstring first claimed the `installed_match`
widening kill (amended in-commit once hand-application showed that row
equivalent).

No `cargo fmt` closeout commit: every slice kept `cargo fmt --check`
(edition 2024) green as it landed, so the closeout `cargo fmt` was a
no-op — same as #162. Method notes followed throughout: `touch`
before each scoped run, `rust/mutants.out` cleared between runs,
restore with `git checkout --` (never from a backup), gate
instrumented before trusting (the `:0=` slot-operator leg was verified
to actually match before trusting its kills).

Review follow-up (2026-09-27, portuale `test: address #165 review
nits`): the `resolve_blockers` 16930:49 `installed_match` `&&` ->
`||` row listed above as proven equivalent is killable, not
equivalent. The diverging shape is the merge-bound twin: installed
`target-1.0:0` beside merge-bound `target-1.0:1` (matched, so
`merge_bound_match` is true and every other `installed_match` use
short-circuits) plus a second same-slot entry `target-2.0:1`, which
lets the mutant's widened `installed_match` take the replaced-in-slot
arm and misfile the row as slot `Replacement` (an unsolvable
uninstall with no `satisfied_by` on the original). New leg
`resolve_blockers_requires_slot_and_version_for_an_installed_match`
fails on the hand-applied mutant and passes on the original; the
scoped tool re-run (`--in-place --timeout 300 -F '16930:49'`, 5
tested including the 4 S0-caught `BacktrackParams::initial` strays)
reports it `CaughtMutant`. This supersedes the S7-docstring correction
above (the row is killed after all). Tallies move to: S7 8 kills,
total killed 70, `resolve_blockers` missed 8→0, closeout 223 caught /
18 missed / 13 unviable / 1 timeout (projected from the scoped
re-run; no full re-run), equivalent bucket 9. Same commit also fixes
the `tests_165` module docstring's real-source paths
(`lib/_emerge/depgraph.py:8891 _validate_blockers`;
`lib/_emerge/actions.py` `UnmergeDepPriority` /
`ignore_priority_range` ~:1709), makes the volatile second-repo leg
skip loudly (`eprintln!` + no `second` repo) where the host has no
root-owned system dir, and removes the untracked `rust/mutants.out/`.
