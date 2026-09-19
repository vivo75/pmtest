# VM findings (slice 2 baseline, 2026-09-18)

L0-on-VM vs L0-on-container, same atom list, same pins, same PM build
(portuale 84cefdf). Reports:
`differential-test-bed/logs/l0-vm-20260918T173822Z/`,
`differential-test-bed/logs/l0-20260918T175422Z/`.

- Container: 100/120 clean, parity 0.833, 34 unexplained.
- VM: 76/120 clean, parity 0.633, 125 unexplained, 0 invariant
  violations (container run has 2 libbsd-tree ones — profile-dependent
  rendering, both directions teach something).

The gap is guest-state-driven, not plumbing: same repos/profile
family/python-major, but the weekly official image ships a NEWER
installed set than the pinned stage3 container (e.g. expat-2.8.4 vs
2.8.3, python 3.14.7 vs 3.14.6, different @system closure). Both PMs
see the same guest (fair); real adapts to the installed set where
portuale does not. Adjudication belongs to the portuale owner (no
unilateral blessing); candidates:

1. **expat installed-version reuse** — FILED as
   `l0-vm-installed-expat` (backend: vm, exact ebuild-row match;
   owner portuale-bug). Single filing with (2).
2. **python:3.14 slot resolution** — FILED as
   `l0-vm-installed-python-slot` (backend: vm, this probe only;
   owner portuale-bug). Same installed-visibility root cause.
3. **@system merge-order cluster** (`real virtual/editor vs portuale
   virtual/libc`): OPEN, needs full-list order verdict.

## L1 (slice 4)

- Smoke (`l1-smoke.txt`, 5 pkgs) and porttest set (10 pkgs, setuid /
  hardlinks / symlinks / keepdir / dodoc / INSTALL_MASK / phases /
  splitdebug / unicode): GREEN on VM, 0 hard findings.
  Reports: `logs/l1-vm-20260918T193129Z/`, `logs/l1-vm-20260918T193316Z/`.
- Full set (`l1-merge.txt`): INVALID run (`MERGE_RC=2` — portuale
  built htop from source), root-caused to a genuine PM gap, not plumbing:
  1. The stock cloud image ships
     `/etc/portage/package.use/releng/no-filecaps` (`*/* -filecaps`,
     "caps are not useful" on auto-login images).
  2. Real honors it (htop binpkg built/merged with `-filecaps`);
     portuale ignores the fragment (computes `filecaps` from IUSE
     default) → binpkg USE mismatch → source rebuild.
  3. Proof of causality: same probe in the container bed (no releng
     fragment there) has both PMs agree on `filecaps` ON.
   So portuale does not read `package.use/` directory fragments (or at
   least extensionless ones) — backend-independent bug class, exposed
   by VM stock content. Per owner decision (2026-09-19): known and
   already in progress upstream — IGNORED, no new filing, no bed
   workaround. L1/L2 full sets stay invalid/blocked pending the PM fix.

## L3 (slice 6)

- Smoke (`l3-smoke.txt`) GREEN incl. clean control pair
  (`logs/l3-vm-20260918T225222Z/`): candidate 12 explained (VDB
  REPO_REVISIONS/env entries), 0 unexplained; control 0/0.
- 6 systemd coredumps (`core.build-and-merge.*`) appeared in one
  portuale guest run (merge rc=0 regardless). The PM binary under test is
  a dirty-tree dev build — per owner decision (2026-09-19): retest on a
  clean tree first (PENDING, see below), no filing yet. Not diff signal
  either way (pruned).

## L2 (slice 5)

- Porttest track (`l1-porttest.txt`, strict): GREEN
  (`logs/l2-vm-20260918T203434Z/`) after adjudicating one single-cause
  class (below); cross-install + control clean.
- `REPO_REVISIONS` (filed, suppressed; suppression CONFIRMED per
  owner decision 2026-09-19): portuale hardcodes
  `PORTAGE_REPO_REVISIONS="{}"` ("until portuale tracks a repo
  revision", `emerge_build.rs`); real fills SHAs via git
  `retrieve_head` whenever git exists. Suppressed in
  `l2-portuale-builder-vm.sh` `KNOWN_FINDINGS` as
  `l2-vm-repo-revisions[-env]` plus yaml VDB entries
  (`l2-vm-repo-revisions-vdb[-env]`, `l3-vm-repo-revisions-vdb[-env]`);
  delete all when portuale tracks revisions. The VM golden has git
  (repo clones need it), the container image has none — so real writes
  `{}` on containers (pair matches, bed green) and SHAs on VMs. The
  full 1308-line `environment.bz2` diff is that ONE line.
