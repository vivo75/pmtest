# #326 Z close-out run (2026-10-09): nopy / noportage builds vs real Portage

Spec: portuale `docs/02.326-no-portage-runtime.opus.md` §Z. Bed entry:
`run/z326-closeout.sh`. Portuale branch `backlog/326`; the product-side
evidence is portuale `docs/evidence/2026-10-09-326-z.md`. Every bed run
exported `GENTOO_MIRRORS="http://10.48.0.229:8080"` (the local
distfiles proxy). `NOPY_JOBS=16` / `Z326_JOBS=16` everywhere
(`MAKEOPTS=-j16`).

## Rerun after #330 / #331 / #332 (2026-10-09, supersedes "Final results")

Run `z326-20261009T153412Z`, portuale branch `backlog/330-332` with all
three residue fixes in the tree (#331 `787a4b14`, then #330 and #332,
committed after this run as `890eaeaa` and `06b15067`). Legs: (a)
`nopy-20261009T153413Z`, (b) `nopy-20261009T153540Z`.

| cell | result | before |
|---|---|---|
| leg (a) / leg (b) runners | ok / ok | ok / ok |
| audit (a) / (b) | PASS / PASS | PASS / PASS |
| diff (a), strict | green, 0 hard | 1 unexplained (`MY_PATCHES`, #330) |
| gpkg (a) | 0/8 pairs hard | 4/8 (`PT_HELPER_DOINS` #332, + `MY_PATCHES`) |
| diff (b), strict | 51 hard, all glibc: 39 `.a` archives, 12 getconf debuglink paths, and their 34 `CONTENTS` rows | 70 (the same families, plus bash `MY_PATCHES`) |
| gpkg (b) | bash ok; glibc hard (`.a` + getconf only) | 2/2 hard |
| [gate] | green (`l1-20261009T155717Z`) | green |
| [gate] reinstall | green (`l1-20261009T162842Z`) | green |
| l31b | green (`l31b-20261009T163026Z`) | green |

What remains is the build nondeterminism already explained below:
- glibc's static archives differ between two real-Portage builds too;
- the getconf `.gnu_debuglink` names a different member of one hardlink
  group (the #261 race).

The overall rc=1 comes only from those rows. No allowlist entry was
added. New residue: #333 (the local merge's `CONFIG_PROTECT` comes from
the process env, not the resolved config).

## Final results (supersede the history sections further down)

The first pass (sections below, from "Leg (a) [nopy] — BLOCKED")
ran on portuale `d0558538` and found the leg (a) doins blocker. The
blocker was then fixed in portuale, and so was a second bug the
unblocked leg exposed:
1. `PORTAGE_ACTUAL_DISTDIR` was not exported to the phases. Real
   `config.environ()` (`config.py:3403-3409`) exports it, and
   `ebuild-helpers/doins:80-82` passes `--distdir` only when it is set.
   Without `--distdir`, real `doins.py` dereferences absolute symlinks
   too: the new oracle cases `fixtures/helpers/doins/dangling-abs-kept`
   and `dangling-abs-nodistdir` show both behaviours, generated from
   real `doins`. The native doins was right; its environment was
   wrong.
2. A `--buildpkg` source merge recorded no vdb `BINPKGMD5`. Real
   `_record_binpkg_info` (`EbuildBuild.py:502-523`) writes it.

| cell | run | result |
|---|---|---|
| leg (a) | `nopy-20261009T125339Z` (final binary `f546b5c1`) | 0/0/0 |
| leg (b) | `nopy-20261009T114839Z` (binary `394f8a2a`: fix 1 only; fix 2 cannot show here, step 2 re-merges both from gpkg) | 0/0/0 |
| audit (a) / (b) | same | PASS / PASS (64 build-system python calls, all glibc's) |
| diff (a) | `z326-20261009T125338Z` | 1 unexplained: bash `MY_PATCHES` (portuale #330) |
| diff (b) | `z326-20261009T114714Z`; again 70, same families, against a fresh reference in `z326-20261009T125338Z` | 70 unexplained: glibc `.a` (CONTENT + CONTENTS echoes), getconf hardlink debuglink race, bash `MY_PATCHES` |
| gpkg (a) | `z326-20261009T125338Z` | 4/8 hard, `environment.bz2` only: `PT_HELPER_DOINS` (portuale #332), + `MY_PATCHES` on bash |
| gpkg (b) | `z326-20261009T114714Z` | 2/2 hard: bash `MY_PATCHES`; glibc `.a` + getconf race |
| [gate] | `l1-20261009T121021Z` | 0 hard / 0 unexplained |
| [gate] reinstall | `l1-20261009T124329Z` | 0 / 0, merged_count 2 |
| l31b | `l31b-20261009T124514Z` | 0 / 0, install-bin assertions hold |

New residue families, read from the rows:
- **`PT_HELPER_DOINS="1"` only in real's gpkg environments** of
  helper-docompress, helper-package, bash and eix. Each is built
  after `porttest/helper-doins`, which installs
  `/etc/env.d/99pt-helper-doins`. Real re-reads `profile.env` for
  every package task (`Scheduler._allocate_config` → `config.reload()`,
  `Scheduler.py:1899-1913`, `config.py:2691-2699`). portuale reads it
  once per run. Filed as portuale #332. The merge order is identical
  on both sides, so ordering is not the cause.
- **getconf `SIZE`/`CONTENT` rows** belong to the allowlisted
  `#261-hardlink-debug-race` family, but hit the stripped binaries
  themselves, which the allowlist entry does not cover. The
  `.gnu_debuglink` names a different member of the same hardlink
  group: real `POSIX_V7_LP64_OFF64.debug`, portuale
  `POSIX_V6_LP64_OFF64.debug`, in the leg (b) gpkgs. A different name
  length gives the 30992-vs-31000 sizes. No allowlist entry was added.
- **glibc `.a`**: unchanged from the first pass, proven real-vs-real
  (family 1 below).

Bed changes after the first pass:
- `compare/z326-audit.py`: the dispatcher's own argv
  (`portuale __helper python <script>`) matched `INTERP_RE`'s bare
  `python` token, so the one sampled `filter-bash-environment.py` call
  of leg (a) was reported as a violation. Dispatcher lines are now
  recognised first. Leg (a) re-graded PASS with `dispatcher calls
  observed: 1`, and leg (b) is unchanged.
- The mixed-binary incident: a portuale `cargo build` during run
  `z326-20261009T112535Z` replaced the bind-mounted binary while
  glibc's postinst ran (`portageq-wrapper: line 8:
  /usr/local/bin/portuale (deleted)`). That run was stopped and
  discarded, and the product side was filed as portuale #331. Never
  rebuild `rust/target/release` during a bed run.

## New / changed bed files (all under `differential-test-bed/`)

- `atomlists/z326-nopy.txt` (new): leg (a) list — `app-portage/eix`,
  `app-shells/bash`, `porttest/helper-{unpack,doins,docompress,package}`.
- `run/nopy-build.sh`: `--reinstall` (guest `--reinstall-atoms`, needed
  for atoms already installed at the resolved version); `NOPY_JOBS`
  (guest `MAKEOPTS`); `NOPY_SNAPSHOT=1` (restricted merge snapshot,
  consume.sh shape, via `layers/z326/merged-snapshot-lib.sh`);
  `NOPY_AUDIT=1` (census + ps sampler + temp transcripts);
  `FEATURES="buildpkg -sign noclean"` on the build steps (noclean keeps
  `/var/tmp/portage` for audit/artifacts); harness-env hygiene (NOPY_*
  consumed into shell-locals then unset so they cannot leak into saved
  phase envs); `PORTAGE_RUNNING_ROOT=/` export (parity with consume.sh).
- `layers/z326/merged-snapshot-lib.sh` (new, shared):
  `z326_snapshot_merged_set` (merged-cpvs as union of fresh installs +
  atom matches, paths.txt, `compare/snapshot.sh`).
- `layers/z326/ref-build-merge-snapshot.sh` (new): reference side in the
  normal image — real Portage from-source `--buildpkg` (gpkg),
  `--usepkgonly` re-merge, xpak rebuild + re-merge (mirrors the nopy
  guest step for step, same FEATURES), then the shared snapshot;
  binpkgs persist via `PKGDIR=/pkgs`.
- `compare/z326-audit.py` (new): the phase-env audit (design below).
- `run/z326-closeout.sh` (new): orchestrates legs/audits/ref/diff/gpkg/
  gate/l31b; `--skip-*`, `--leg-a-dir/--leg-b-dir`, `--jobs`.
- README: Z section + layout (this run).

Checks: `bash -n` clean on all four scripts; shellcheck `-S warning`
clean except one pre-existing `SC2034 PM_BARE` in `nopy-build.sh`
(consumed dynamically by `run/lib.sh:pm_mounts`, predates this task).

## Leg (a) [nopy] — BLOCKED by a portuale doins bug (first pass; fixed, see above)

Run `logs/nopy-20261009T093709Z` (`--variant nopy --reinstall`,
6 atoms): **step1 rc=1, step2 SKIP, step3 SKIP.** Runner rc=0 (a
failing build is a result, not a runner error). eix deps
(`app-shells/push-3.4`, `app-shells/quoter-4.2`) and
`porttest/helper-unpack` built fine; the run dies in (4 of 8):

```
>>> Emerging (4 of 8) porttest/helper-doins-1.0::porttest
>>> Building package for porttest/helper-doins-1.0...
FileNotFoundError: [Errno 2] No such file or directory: b'/var/tmp/portage/porttest/helper-doins-1.0/work/doins-src/payload/abs-link'
 * ERROR: porttest/helper-doins-1.0::porttest failed (install phase):
 *   doins failed
```

Reading: the ebuild installs an ABSOLUTE symlink
(`ln -s /usr/share/porttest/helper-doins/plain.txt payload/abs-link`)
whose target does not exist until the package itself is installed
(it dangles at build time). Real Portage (`ref a-nopy`, rc=0, same
list) handles it. Portuale's native doins appears to stat/resolve
through the link instead of copying the link node (real `doins.py`
copies it). The S6 oracle tree has an absolute symlink too, but
non-dangling, so this case slipped through. NOT fixed (brief
forbids product changes); filed here as the leg-(a) blocker.

Consequence: no complete portuale-side tree for the nopy list, so no
tree diff for (c)-nopy. The 3 completed binpkgs (push, quoter,
helper-unpack) still pair for gpkg_diff (below).

## Leg (b) [noportage] — GREEN

- First: `logs/nopy-20261009T093737Z` (glibc + bash, `--reinstall`):
  step1/step2/step3 rc=0, 113 ps samples, snapshot 4005 paths,
  2 merged packages. (Superseded as the diff input only by the
  hygiene rerun; its artifacts anchor the forensics below.)
- Final (harness-hygiene): `logs/nopy-20261009T101059Z`: step1/2/3
  rc=0, 112 ps samples, 2 merged packages.

## Phase-env audit — design and results

Design (`compare/z326-audit.py`, rule from the plan): a Portage-helper
call is a python invocation whose script is under `$PORTAGE_BIN_PATH`,
imports `portage`, or is `-c` naming the portage *module*; anything
else is a build-system call. The live phase env is observable through
none of the persisted channels (saved `temp/environment` is the
post-filter dump with `PORTAGE_*` stripped by design; portuale leaves
`__source_all_bashrcs` unimplemented, so no bashrc hook can observe
it; successful helpers are silent) — hence three indirect legs:

1. census (`artifacts/audit-env.txt`): helper scripts exist ONLY
   inside the dispatcher (no `.py`, no checkout, no
   `/usr/lib/portage`); nopy must provide no python at all.
2. live `ps` sampler across all steps: `portuale __helper <name>`
   lines are dispatcher invocations caught in the act.
3. log scan (step logs + per-package temp transcripts): every python
   invocation classified; any `no native helper` 127 is a violation
   (transition table empty at this HEAD, so the dispatcher can never
   exec a real interpreter).

PASS verdict: census matches the variant, all three step rcs 0, zero
violations.

- Leg (a) (`nopy-20261009T093709Z`): steps 1/SKIP/SKIP; census clean
  (no python provider, no portage package); 1 ps sample; 0
  build-system calls; 0 ipc-127; 0 violations → **FAIL on
  incompleteness only** (the doins blocker above). No helper ever
  reached a real interpreter (none exists).
- Leg (b) (`nopy-20261009T101059Z`): steps 0/0/0; census python3
  present (expected), portage package absent (incl. negative
  `import portage` probe); 112 ps samples; **75 build-system python
  calls, all glibc's own** (`../scripts/gen-as-const.py` under
  `/usr/bin/python3.14`, `checking for python3...`, `PYTHON_COMPAT`
  iteration); 0 ipc-127; **0 violations → PASS**.
- Audit self-tests during development: fixed two classifier bugs
  before grading (a `/var/tmp/portage` path tripping the `-c`
  rule — now module-only; a `dist-info` mistaken for the portage
  package — now dir-or-import).

## Leg (c) reference + comparison

Reference runs (normal image, `logs/_z326-pkgcache-{nopy,noportage}`):
`z326-20261009T095604Z` (superseded: pre-step3 ref guest) and
`z326-20261009T101059Z` (final; ref builds do gpkg + usepkgonly +
xpak like the legs). All ref steps rc=0. Strict modes throughout,
existing `known-divergences.yaml` only (no entries added).

### (c)-nopy: no tree diff (leg (a) blocked); gpkg 3/3 pairs hard on metadata only

Per-PF newest pairs, `--mode strict` (`z326-20261009T101059Z/gpkg-a-nopy.txt`):
`push-3.4`, `quoter-4.2`, `helper-unpack-1.0` — **image paths,
modes, payloads IDENTICAL** on all three; the only hard rows are
`metadata/environment.bz2` (here: the superseded pre-hygiene
`NOPY_*` leak on the portuale side + `PORTAGE_RUNNING_ROOT` only on
the ref side — both fixed after this leg ran; payloads unaffected)
and informational `outer-name` BUILD_IDs. Verbatim rows, e.g.:

```
HARD push-3.4 (rc=1)
    [outer-name] prefix differs: push-3.4-2 vs push-3.4-1
    [metadata] metadata/environment.bz2 differs: a='\n\n\n\n            SANDBOX_READ+=":${potential_location}";\n            eqawarn "QA Notice: \'aclocal\' called by ${FUNCNAME[1' b='\n\n\n\n            SANDBOX_READ+=":${potential_location}";\n            eqawarn "QA Notice: \'aclocal\' called by ${FUNCNAME[1'
    gpkg-diff: mode=strict hard=1 soft=1
```

(quoter, helper-unpack identical in shape.)

### (c)-noportage: tree diff 40 hard / 0 explained / 40 unexplained; gpkg 2/2 hard

`z326-20261009T101059Z/diff-b-noportage.txt`: CONTENT 13, CONTENTS 26
(their md5 echoes), VDB 1; mtime-only 3857 (non-fatal); payload 0.
`gpkg-b-noportage.txt`: bash hard=1 (environment.bz2 only — payload
identical), glibc hard=25 (environment.bz2 + getconf hardlink-name
variants + `.a` payloads).

Triaged into four families (all recorded unexplained; none silenced):

1. **glibc `.a` archive bytes differ (13 CONTENT + 26 CONTENTS)** —
   independent-build archive nondeterminism (member order/timestamps
   under `-j16`), proven real-vs-real: ref run1 vs run2 digests
   differ with the same PM, e.g. `usr/lib64/libc.a` ref CONTENTS
   md5 `f47184b08c8b3d0fcd05286d031f9be8` (run `095604Z`) vs
   `c8571f94092317f0098b52fecd57e280` (run `101059Z`); image sha
   `6163bf4fc6a7` vs `cea2a4a…`. Merges are faithful on both sides
   (merged sha == own image sha: ref `cea2a4a…`, M1 portuale merge
   of its own binpkgs reproduces image bytes exactly).
2. **getconf hardlink-name variants** (build-id symlinks +
   `only in a/b` debug names, e.g. `POSIX_V6_ILP32_OFFBIG` vs
   `XBS5_ILP32_OFFBIG` under the same build-id) — same nondeterminism
   family as allowlisted `#261-hardlink-debug-race`, but the racing
   paths differ every run (run `095604Z` even had 16 explained rows
   of it incl. a transient `[MISSING] /usr/lib/debug/.build-id/0c`,
   all gone the next run). Unexplained by the letter; same cause by
   evidence (`/usr/bin/getconf` image bytes shuffle across runs:
   run1 `13bc082c… vs 510152ba…`, run2 `510152ba… vs 53910a7f…` —
   note run2's ref side == run1's portuale side).
3. **bash binary one-off (superseded run only)**: portuale's step3
   xpak build produced `/bin/bash`
   `7ff785e8695e…`/`bash.debug -8B` vs four `3cb21306418f…`
   builds (portuale step1, portuale gpkg rebuild, portuale xpak
   rebuild, real ×3). Same-size binary ⇒ link-order lottery
   striking once, not format-dependent (xpak rebuild gives `3cb2`).
   Notably the divergent build was still self-consistent
   (xpak image == merged bytes). No bash rows in the final pass.
4. **VDB `environment` residuals** — fully diffed, harness/counter
   cosmetics only (bash pair, 3 lines): `BUILD_ID="3"` (persistent-
   cache counter, ref side); `MY_PATCHES` paths `/distfiles/…`
   (portuale uses DISTDIR directly) vs
   `/var/tmp/portage/…/distdir/…` (real links into per-package
   distdir) — same files, different staging paths; plus a stray
   real-side `declare -- f`. The earlier `FEATURES`/`NOPY_*`/
   `BINPKG_FORMAT`-last-touch rows were harness bugs, fixed
   (FEATURES parity + env hygiene + ref xpak step3) before the final
   pass.

## [gate] — GREEN twice

- `logs/l1-20261009T103312Z` (plain): 0 hard / 0 explained /
  0 unexplained (merged_count 0 — set already installed).
- `logs/l1-20261009T110437Z` (`L1_SKIP_BUILD=1
  L1_CONSUME_REINSTALL=1`): 0/0/0, merged_count 2 (glibc+bash
  re-merged over the live system).

## S8 (l31b) — GREEN

`logs/l31b-20261009T110623Z` (`L31B_SKIP_BUILD=1`, pkgcache current):
diff rc=0 (no allowlist), install-bin assertions HOLD (first pass
exactly one `install-bin 0`, client
`/usr/local/bin/portuale-5a8f43be0186b97f` sha = server, mode 0755;
re-run zero lines, same inode/mtime).

## Harness bugs found and fixed during this run (bed-only)

- ref/nopy FEATURES mismatch (`filecaps -cgroup…` only on ref) →
  byte-identical FEATURES on both guests now.
- `NOPY_*`/`Z326_*`/`L1_SKIP_PORTAGE_UPGRADE` leaking into saved
  phase envs → consume-and-unset hygiene in both guests;
  `PORTAGE_RUNNING_ROOT` asymmetry fixed.
- ref had no xpak step3 → BINPKG_FORMAT last-touch asymmetry;
  added.
- `timeout` cannot exec the `podman_run_pm` function → argv array in
  `z326-closeout.sh`.
- guest referenced unforwarded `$VARIANT` (fatal under `set -u`,
  killed a smoke run after step1) → `NOPY_VARIANT` forwarding.
- audit requires all three step rcs (a crashed guest otherwise
  "passes" step1).

## Residues / follow-ups for the portuale team (not done here)

- helper-doins dangling-absolute-symlink `FileNotFoundError` (leg (a)
  blocker) — FIXED in portuale (`PORTAGE_ACTUAL_DISTDIR`); D4 cases
  `dangling-abs-{kept,nodistdir}` added.
- bash one-off build bytes (7ff7) — single lottery sample; a rebuild
  matrix (or `ar`/link-order determinism work) could apportion it.
- `MY_PATCHES`/distdir staging difference — filed as portuale #330
  (real `_prepare_fake_distdir`).
- V-std for the final portuale tree: see portuale
  `docs/evidence/2026-10-09-326-z.md`.

## Run-dir index

- final pass: `z326-20261009T114714Z` (legs, ref/diff b, gate, l31b),
  `z326-20261009T125338Z` (leg a after the BINPKGMD5 fix);
  discarded: `z326-20261009T112535Z` (mixed binary)

- legs: `nopy-20261009T093709Z` (a, blocked), `nopy-20261009T093737Z`
  (b, green, superseded-input), `nopy-20261009T101059Z` (b, green, final)
- z326: `z326-20261009T094757Z` (superseded), `z326-20261009T095604Z`
  (superseded), `z326-20261009T101059Z` (final)
- gate: `l1-20261009T103312Z`, `l1-20261009T110437Z`
- l31b: `l31b-20261009T110623Z`
- ref pkgcaches: `logs/_z326-pkgcache-{nopy,noportage}`
- (pre-existing unrelated runs `nopy-20261009T014047Z/042205Z/060631Z`
  and smoke `093133Z/093204Z/093426Z/093445Z/095558Z` left untouched)
