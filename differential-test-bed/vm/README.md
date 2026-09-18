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

## Rebuild

```sh
differential-test-bed/vm/make-image.sh --rebuild
```

Per-run overlays (`qemu-img create -b golden`) + L0-on-VM come with
slice 2 (`vm-lib.sh`, `run/l0-resolver-vm.sh`).
