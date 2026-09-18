#!/bin/bash
# Build the VM golden image: official Gentoo disk image + the bed's
# constants (repos at pins, portage PIN, porttest overlay, make.conf),
# snapshotted for per-run overlays (slice 2 boots overlays, never this).
#
#   differential-test-bed/vm/make-image.sh [--rebuild] [--skip-firstboot]
#
# Run as a NORMAL user (libvirt group): sudo is used internally only
# for nbd/mount. Running the whole script under sudo breaks SSH auth
# (the seeded key's private half lives in the user's ~/.ssh).
#
# --rebuild: redo even a finished golden. --skip-firstboot: stop after
# the offline nbd customize (debug). Work dir: vm/work/ (git-ignored).
set -euo pipefail
VM_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$VM_HERE/vm-common.sh"

REBUILD=0
SKIP_FIRSTBOOT=0
for a in "$@"; do
  case $a in
    --rebuild) REBUILD=1 ;;
    --skip-firstboot) SKIP_FIRSTBOOT=1 ;;
    *) echo "usage: $0 [--rebuild] [--skip-firstboot]" >&2; exit 2 ;;
  esac
done

BASE=$VM_WORK/base-$DI_FILE
GOLDEN=$VM_IMAGE
BUILD_LOG=$VM_WORK/build-$(date -u +%Y%m%dT%H%M%SZ).log
mkdir -p "$VM_WORK"
exec > >(tee "$BUILD_LOG") 2>&1
echo ">>> log: $BUILD_LOG"

[ -f "$VM_SSH_PUBKEY" ] || { echo "!!! no ssh pubkey: $VM_SSH_PUBKEY (VM_SSH_PUBKEY)" >&2; exit 2; }

cleanup_build() {  # best-effort teardown of the build domain (golden kept)
  vm_down porttest-build 2>/dev/null || true
}

# --- 1. download + verify ----------------------------------------------
if [ ! -f "$BASE" ]; then
  echo ">>> downloading $DI_FILE"
  curl -sS -o "$BASE" "$DI_BASE_URL/$DI_FILE"
  curl -sS -o "$BASE.sha256" "$DI_BASE_URL/$DI_FILE.sha256"
  gpg --keyserver hkps://keys.gentoo.org --recv-keys \
    534E4209AB49EEE1C19D96162C44695DB9F6043D 2>&1 | tail -n 1 || true
  gpg --verify "$BASE.sha256" || { echo "!!! signature FAILED" >&2; exit 2; }
fi
echo "$DI_SHA256  $BASE" | sha256sum -c - \
  || { echo "!!! base hash mismatch (pins.sh DI_SHA256 stale?)" >&2; exit 2; }
echo ">>> base verified: $BASE"

# --- 2. golden overlay ---------------------------------------------------
if [ -f "$GOLDEN" ] && [ "$REBUILD" != 1 ]; then
  echo ">>> golden exists (use --rebuild to redo): $GOLDEN"
  exit 0
fi
rm -f "$GOLDEN"
qemu-img create -F qcow2 -b "$BASE" -f qcow2 "$GOLDEN"
echo ">>> golden overlay created"

# --- 3. offline nbd customize -------------------------------------------
echo ">>> offline customize (network, sshd, root key)"
DEV=$(nbd_dev)
sudo qemu-nbd --connect="$DEV" "$GOLDEN"
trap 'sudo qemu-nbd --disconnect "$DEV" 2>/dev/null || true' EXIT
sleep 2
MNT=$(mktemp -d)
sudo mount "${DEV}p2" "$MNT"
sudo tee "$MNT/etc/systemd/network/20-wired.network" > /dev/null <<'EOF'
[Match]
Name=en* eth*
[Network]
DHCP=yes
EOF
sudo mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
sudo ln -sf /usr/lib/systemd/system/sshd.service \
  "$MNT/etc/systemd/system/multi-user.target.wants/sshd.service"
sudo mkdir -p "$MNT/root/.ssh"
sudo cp "$VM_SSH_PUBKEY" "$MNT/root/.ssh/authorized_keys"
sudo chmod 700 "$MNT/root/.ssh"
sudo chmod 600 "$MNT/root/.ssh/authorized_keys"
echo 'porttest-build' | sudo tee "$MNT/etc/hostname" > /dev/null
# Unlock the root *account* while keeping password login impossible (`*`):
# stock images ship `!*`, and sshd accepts the key but PAM kills the
# session right after auth (spike/REPORT.md). Cloud images do the same.
sudo sed -i 's/^root:!\*:/root:*:/' "$MNT/etc/shadow"
sudo umount "$MNT"
rmdir "$MNT"
sudo qemu-nbd --disconnect "$DEV"
trap - EXIT
echo ">>> offline customize done"
[ "$SKIP_FIRSTBOOT" = 1 ] && { echo ">>> stopping (--skip-firstboot)"; exit 0; }

# --- 4. boot build domain -------------------------------------------------
echo ">>> booting build domain"
"$VM_HERE/make-seed-iso.sh" porttest-build "$VM_SSH_PUBKEY" "$VM_WORK/build-seed.iso"
vm_define porttest-build "$GOLDEN" "$VM_WORK/build-seed.iso"
trap cleanup_build EXIT
# NOTE: virt-install --import already boots the domain; no virsh start.
IP=$(wait_for_ssh porttest-build 60)
echo ">>> build guest at $IP"

# --- 5. first-boot customize ----------------------------------------------
echo ">>> staging porttest overlay source"
vm_ssh "$IP" "rm -rf /tmp/porttest-overlay && mkdir -p /tmp/porttest-overlay"
scp $(ssh_opts) -r "$VM_TEST_DIR/images/overlay/porttest/." \
  "${VM_SSH_USER}@${IP}:/tmp/porttest-overlay/"
echo ">>> running firstboot-customize.sh"
scp $(ssh_opts) "$VM_HERE/firstboot-customize.sh" "${VM_SSH_USER}@${IP}:/tmp/"
vm_ssh "$IP" "VM_PORTAGE_PIN=$VM_PORTAGE_PIN \
  VM_REPOS_SHALLOW_SINCE=$VM_REPOS_SHALLOW_SINCE \
  VM_LAST_COMMIT_gentoo=${VM_LAST_COMMIT[gentoo]} \
  VM_LAST_COMMIT_buildovl=${VM_LAST_COMMIT[buildovl]} \
  VM_REPO_URL_gentoo=$VM_REPO_URL_gentoo \
  VM_REPO_URL_buildovl=$VM_REPO_URL_buildovl \
  PORTTEST_OVERLAY_DIR=/tmp/porttest-overlay \
  bash /tmp/firstboot-customize.sh"

# --- 6. seal the golden ----------------------------------------------------
echo ">>> sealing golden"
vm_ssh "$IP" "rm -rf /tmp/porttest-overlay /tmp/firstboot-customize.sh && shutdown -h now" || true
for _ in $(seq 1 30); do
  virsh --connect qemu:///system domstate porttest-build 2>/dev/null | grep -q 'shut off' && break
  sleep 10
done
trap - EXIT
cleanup_build
vm_claim "$GOLDEN"
qemu-img snapshot -c golden "$GOLDEN"
sha256sum "$GOLDEN" > "$GOLDEN.sha256"
qemu-img info "$GOLDEN" | grep -E 'virtual size|disk size|backing file'
qemu-img snapshot -l "$GOLDEN"
echo ">>> golden ready: $GOLDEN"
