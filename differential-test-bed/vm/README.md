# VM test bed (`differential-test-bed/vm/`)

Dual-backend companion to the container bed: same layers, same
comparators, but throwaway **VMs** (libvirt+KVM) instead of throwaway
containers — full boot, real kernel namespaces, per-run filesystem
choice. See `spike/REPORT.md` for why the official Gentoo cloud-init
qcow2 is the base (and its gotchas), `../USAGE.AGENTS.md` for run rules.

## Layout

- `pins.sh` — all pins (image timestamp, repo SHAs, portage PIN, VM
  shape, SSH key). Sourced; re-pin with the container bed's pins.
- `make-seed-iso.sh` — NoCloud seed ISO (hostname + root key).
- `vm-common.sh` — host helpers: domain define/boot (`vm_define`,
  non-secboot OVMF — secboot freezes the guest), `wait_for_ssh`
  (MAC-based DHCP lookup), `vm_ssh` (fixed flags incl. explicit
  `-i`), `vm_down` + `vm_claim` (libvirt chowns attached disks to
  qemu:qemu; reclaim before rewriting), `nbd_dev`.
- `firstboot-customize.sh` — runs INSIDE the guest: webrsync bootstrap
  (empty repos invalidate the profile, blocking every emerge incl. the
  git install), git, repos at pins, portage PIN, porttest overlay,
  make.conf/repos.conf (same content as `create-container.bash`),
  fingerprint, then `truncate machine-id` so per-run overlays
  re-identify on first boot.
- `make-image.sh` — builds `vm/work/golden.qcow2` (overlay on the
  verified official base): download+verify → offline nbd customize
  (network, sshd, root key, **root unlock** `!*`→`*` — locked root
  authenticates but PAM kills the session) → boot → firstboot →
  clean shutdown → internal `golden` snapshot + sha256.
- `work/` — git-ignored scratch (base, golden, run overlays, seeds,
  build logs). Run everything as a NORMAL user (sudo is used inside
  only for nbd/mount); whole-script sudo breaks SSH auth.

## Runs (slice 2)

- `vm-lib.sh` — per-run lifecycle, sourced after `run/lib.sh`:
  `vm_run_boot` (fresh overlay → seed → boot → IP), `vm_push_pm`
  (single `$PM_EMERGE` binary + applet symlinks — never the whole
  build dir), `vm_push_test` (`layers/` + `atomlists/` + `compare/`
  → `/TEST`), `vm_push`/`vm_pull`/`vm_pull_prefix` (consume.sh
  writes `$OUT.*` prefixes, mirroring the container layout),
  `vm_share_pm`/`vm_mount_pm`/`vm_unshare` (PM checkout via
  virtiofs hotplug at its build-time path — 9p cannot be hotplugged;
  domains carry shared-memory backing for it), `vm_teardown`
  (also kills the per-run virtiofsd).
- `run/l0-resolver-vm.sh [atomlist]` — same probes/env/grading as
  `run/l0-resolver.sh`; reports are `l0-vm-*` (container `l0-*`
  untouched). Smoke list: `atomlists/l0-vm-smoke.txt`
  (`L0_SKIP_MULTI=1 L0_SKIP_INVARIANTS=1` for iteration).

## L1 on VMs (slice 4)

- `run/l1-merge-from-binpkg-vm.sh [atomlist]` — build once with
  Portage (binpkgs pulled to host `_l1-pkgcache-vm`, backend-private
  for provenance), consume per PM on fresh overlays (pkgcache pushed
  to guest `/pkgs`), host-side normalize + `diff.py --fs`.
  `L1_REBUILD`/`L1_SKIP_BUILD`/`L1_JOBS` as the container script;
  reports `l1-vm-*`. Smoke (`l1-smoke.txt`) and porttest set GREEN;
  full set currently invalid by a genuine PM gap (see FINDINGS.md,
  `package.use` fragments) — the bed's first bug found, not a
  plumbing failure.
- Trap discipline: every run script traps teardown, and the trap
  handler must end `true` — a `[ -n ... ] && ...` guard ending false
  overrides a green exit code.
- Baseline rule: the VM guest is a NEWER installed set than the
  pinned container (weekly official image), so VM parity numbers are
  NOT comparable to container ones probe-for-probe — compare finding
  *sets* per backend, adjudicate separately. See `vm/FINDINGS.md`
  (slice-2 baseline: expat/python installed-reuse class).

## Filesystem matrix (slice 3)

- Goldens: `vm/work/golden.qcow2` (xfs, the official layout),
  `golden-ext4.qcow2`, `golden-btrfs.qcow2` — same bytes, fresh fs.
  Built by `vm/make-fs-image.sh ext4|btrfs`: fresh GPT, ESP dd-copied
  (kernel+initramfs live there, GRUB never reads root), root mkfs with
  the SAME UUID (grub.cfg untouched) + `cp -a`, only fstab's fstype
  changes. Same-UUID twins must never share a guest (never happens)
  and are mounted only by explicit /dev paths.
- `VM_FS=xfs|ext4|btrfs` (default xfs) selects the backing in
  `vm_golden()`; `run/l0-resolver-vm.sh` validates it, prints it,
  and grades with `resolve-compare.py --fs`.
- `fs:` allowlist qualifier (string or list; absent = all fs) in
  `compare/known-divergences.yaml`, honored by `resolve-compare.py`
  and `diff.py` (`--fs NAME`); self-test `compare/test-allowlist-fs.py`.
  Runs without `--fs` match nothing fs-qualified.
- Provenance: guest `fingerprint.tsv` carries an `fs` line
  (`stat -f /`; ext4 shows as ext2/ext3), `l0-report.json` summary
  carries `"fs"`.
- Baseline (2026-09-18): smoke ×3 fs identical shape; full ext4 ==
  full xfs finding multiset (76/120 clean) → L0 resolver is
  fs-independent on this corpus. fs-specific findings, if any, will
  surface on merge paths (L1-on-VM).

## Rebuild

```sh
differential-test-bed/vm/make-image.sh --rebuild
```

Per-run overlays (`qemu-img create -b golden`) + L0-on-VM come with
slice 2 (`vm-lib.sh`, `run/l0-resolver-vm.sh`).
