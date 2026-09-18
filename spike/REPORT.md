# Spike report: official Gentoo qcow2 as VM test-bed base (2026-09-18)

## Verdict: GO on `di-amd64-cloudinit`

The official cloud-init image boots under libvirt+KVM with SSH fully
scriptable. The from-scratch OS build is dropped; slice 1 becomes
"download → verify → customize → snapshot".

## Image identity (verified)

- File: `di-amd64-cloudinit-20260913T163055Z.qcow2` (1 200 160 768 bytes)
- sha256 `e6f3b41e…0120a` matches the clearsigned `.sha256` file.
- PGP: Good signature from `Gentoo Linux Release Engineering
  (Automated Weekly Release Key) <releng@gentoo.org>`, key
  `534E4209AB49EEE1C19D96162C44695DB9F6043D` (subkey
  `BB572E0E2D182910`, fetched from hkps://keys.gentoo.org).
  Trust is TOFU (no WoT path checked) — same level as the stage3 flow.
- Local pristine copy: `spike/di-amd64-cloudinit.qcow2` (do not modify).

## Boot requirements (gotchas found)

1. **Non-secboot OVMF.** `virt-install --boot uefi` picks
   `OVMF_CODE_4M.secboot.qcow2` → guest freezes with ~0 CPU (stuck
   pre-GRUB, no serial output). Explicit loader
   `OVMF_CODE_4M.qcow2` + `OVMF_VARS_4M.qcow2` (matches firmware
   descriptor `50-edk2-ovmf-4m-qcow2-x64-nosb.json`) boots.
   (`secure='no'` as XML attribute is rejected by libvirt — omit the
   attribute entirely.)
2. **No network by default.** `/etc/systemd/network/` is empty, so
   systemd-networkd (enabled) configures nothing → no DHCP, no SSH,
   silent guest. Fix at customize time: one `.network` file with
   `DHCP=yes` (offline via nbd, or cloud-init `bootcmd`).
3. **sshd present but disabled; git absent; repos empty.**
   All fixed at customize time (offline nbd write, no guest agent
   needed): enable sshd unit, root `authorized_keys`, hostname,
   then `emerge dev-vcs/git` + repo clone on first boot with network.
4. **cloud-init works** (NoCloud seed ISO, label `cidata`, SATA cdrom):
   `DataSourceNoCloud` detected, hostname + root key applied.
   Offline nbd customization works too — belt and braces; prefer nbd
   for static content (deterministic), seed ISO for per-run identity.

## Guest fact sheet

| Item | Value |
|---|---|
| Kernel | 6.18.48, `console=ttyS0 console=tty0` on cmdline |
| Init | systemd 261 |
| Root fs | **XFS** (`gentooroot` label), ESP vfat, GPT, 20 GB virtual disk |
| Profile | `default/linux/amd64/23.0/no-multilib/systemd` (dangling until repos cloned) |
| Portage | 3.0.81.3 (bed PIN is 3.0.82.2 → upgrade at customize or per run) |
| Python | 3.14.7 |
| Tools | gcc/make/curl/rsync/eselect/cloud-init present; **git missing** |
| net | systemd-networkd enabled, no `.network` files shipped |
| sshd | binary present, unit disabled by default |
| @world seed | pwgen, sudo, unzip, gnupg, nano, … (gnupg present → gpg tests feasible) |
| Cold boot → SSH | **21 s** (systemd-analyze: 19.2 s); 4 vCPU / 8 GB |
| Host backends | KVM `/dev/kvm`, libvirt `default` NAT (DHCP works), OVMF present, `xorriso` builds seed ISOs |

## Consequences for the plan

- Slice 1 = `vm/make-image.sh`: download+verify (pinned timestamp
  alongside `LAST_COMMIT`/`DATESTART`), seed-ISO generator, offline nbd
  customize (network/sshd/key/hostname), first-boot customize (git,
  repos at pins, portage PIN, overlay, make.conf), golden snapshot.
- No-multilib + weekly-refresh caveats stand: VM runs get their own
  baseline; image timestamp becomes a pin; re-validate on bump.
- Filesystem matrix: official image is XFS. ext4/btrfs variants need
  re-partition+mkfs at customize time (same content, fresh fs) —
  feasible, deferred to the matrix slice.
- Serial console stayed silent even with `console=ttyS0` on the cmdline
  (never needed: SSH worked). If guest debugging is ever needed,
  attach a virtio VGA and use `screendump`.
- Left on host (scratch, git-ignored): `/var/lib/libvirt/images/
  porttest-spike.qcow2` (customized working copy). Spike domain
  undefined; NVRAM removed.
