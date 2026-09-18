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

1. **expat installed-version reuse** (systematic, ~30 probes):
   `[extra] ebuild dev-libs/expat-2.8.3 present for portuale, absent
   for real` — guest has 2.8.4 installed, real treats it as satisfied,
   portuale plans 2.8.3. Absent on containers (2.8.3 installed there).
2. **python:3.14 slot resolution against installed** (`dev-lang_python_3.14`):
   real rc=0 (Total 1), portuale rc=1 `there are no ebuilds to satisfy
   "dev-lang/python:3.14"` — same shape as (1): installed 3.14.7
   invisible to portuale.
3. **@system merge-order cluster** (smoke run): `real virtual/editor
   vs portuale virtual/libc` at #8 — different @system input sets
   (nomultilib vs multilib); needs the full-list order verdict before
   calling it.

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
  by VM stock content. For the owner; no blessing here.
