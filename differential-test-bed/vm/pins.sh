#!/bin/bash
# Pins for the VM test-bed image (differential-test-bed/vm/).
# Source, don't execute. Re-pin alongside create-container.bash's own
# LAST_COMMIT block and the L0_PORTAGE_PIN default in run/l0-resolver.sh.

# Official Gentoo disk image this bed is built on (spike/REPORT.md).
# The timestamp is a first-class pin like DATESTART: re-validate
# (L0 + L1, container and VM) on every bump.
IMAGE_TS=20260913T163055Z
DI_BASE_URL=https://distfiles.gentoo.org/releases/amd64/autobuilds/${IMAGE_TS}
DI_FILE=di-amd64-cloudinit-${IMAGE_TS}.qcow2
# sha256 of the image (from the clearsigned .sha256 file, verified
# against the Gentoo releng key at download time).
DI_SHA256=e6f3b41e5a9cb626fd1b75ccdccee992f6f7e8935e051da37fcb853124b0120a

# In-guest repo pins: same commits the container bed tests against.
declare -a VM_REPOS=( gentoo buildovl )
declare -A VM_LAST_COMMIT=(
  [gentoo]="11c58b7af1df0fbc3e9f2560a82c4355231967a6"
  [buildovl]="3b1df68114f4c486520864338b1b6a42efcaec7e"
)
VM_REPOS_SHALLOW_SINCE=2026-08-23T15:30:57Z
VM_REPO_URL_gentoo=https://github.com/gentoo-mirror/gentoo.git
VM_REPO_URL_buildovl=https://github.com/vivo75/buildovl.git

# The portage version portuale mirrors (baked into the golden image;
# in-container.sh still honours L0_SKIP_PORTAGE_UPGRADE per run).
VM_PORTAGE_PIN=3.0.82.2

# Throwaway VM shape (slice 2 runs one domain per PM; L3 pairs run two).
VM_VCPUS=4
VM_MEMORY_MB=8192
VM_NET=default
VM_SSH_USER=root
# Public key installed as guest root's authorized_keys (test-only NAT).
VM_SSH_PUBKEY=${VM_SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}
