#!/bin/bash
# Build a per-filesystem golden image: same bytes as golden.qcow2 (xfs),
# fresh <fs> root. The kernel+initramfs live on the ESP (vfat, copied
# 1:1), so GRUB never touches the root fs; the root keeps the SAME UUID
# (mkfs -U) so grub.cfg needs no edit -- only fstab's fstype field.
# Same-UUID twins must never be attached to one guest together (they
# never are: one variant boots at a time) and are mounted here only by
# explicit /dev paths, never by UUID/LABEL.
#
#   differential-test-bed/vm/make-fs-image.sh ext4|btrfs [--rebuild]
#
# Output: vm/work/golden-<fs>.qcow2 + .sha256 (standalone, no backing).
set -euo pipefail
VM_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$VM_HERE/vm-common.sh"

FS=${1:?ext4|btrfs}
REBUILD=0
[ "${2:-}" = "--rebuild" ] && REBUILD=1
case $FS in
  ext4|btrfs) ;;
  *) echo "fs must be ext4|btrfs (xfs is golden.qcow2 itself)" >&2; exit 2 ;;
esac

SRC=$VM_IMAGE
DST=$VM_WORK/golden-$FS.qcow2
if [ -f "$DST" ] && [ "$REBUILD" != 1 ]; then
  echo ">>> $DST exists (use --rebuild to redo)"
  exit 0
fi

echo ">>> building $DST from $SRC"
rm -f "$DST"
qemu-img create -f qcow2 "$DST" 20G > /dev/null

SRCDEV=$(nbd_dev)
DSTDEV=$(nbd_dev "$SRCDEV")
sudo qemu-nbd --read-only --connect="$SRCDEV" "$SRC"
sudo qemu-nbd --connect="$DSTDEV" "$DST"
cleanup_nbd() {
  sudo umount /mnt/vmfs-src /mnt/vmfs-dst 2>/dev/null || true
  sudo qemu-nbd --disconnect "$SRCDEV" 2>/dev/null || true
  sudo qemu-nbd --disconnect "$DSTDEV" 2>/dev/null || true
}
trap cleanup_nbd EXIT
sleep 2

echo ">>> partitioning $DST (GPT: ESP + root)"
sudo sgdisk -Z -n 1:0:+512M -t 1:EF00 -c 1:gentooefi \
  -n 2:0:0 -t 2:8300 -c 2:gentooroot "$DSTDEV" > /dev/null
sudo partprobe "$DSTDEV"
sleep 2

UUID=$(sudo blkid -s UUID -o value "${SRCDEV}p2")
[ -n "$UUID" ] || { echo "!!! no UUID on source root" >&2; exit 2; }
echo ">>> mkfs.$FS (UUID=$UUID, LABEL=gentooroot)"
case $FS in
  ext4)  sudo mkfs.ext4 -q -U "$UUID" -L gentooroot "${DSTDEV}p2" ;;
  btrfs) sudo mkfs.btrfs -q -U "$UUID" -L gentooroot -f "${DSTDEV}p2" > /dev/null ;;
esac

echo ">>> cloning ESP (dd, preserves serial + content)"
sudo dd if="${SRCDEV}p1" of="${DSTDEV}p1" bs=4M status=none

echo ">>> copying root content"
sudo mkdir -p /mnt/vmfs-src /mnt/vmfs-dst
sudo mount -o ro "${SRCDEV}p2" /mnt/vmfs-src
sudo mount "${DSTDEV}p2" /mnt/vmfs-dst
sudo cp -a --sparse=always /mnt/vmfs-src/. /mnt/vmfs-dst/
echo ">>> fixing fstab fstype (xfs -> $FS, label+mountpoint kept)"
sudo sed -i -E "s|^(\S+\s+/\s+)xfs(\s)|\1${FS}\2|" /mnt/vmfs-dst/etc/fstab
grep -h '^LABEL=gentooroot' /mnt/vmfs-dst/etc/fstab \
  || { echo "!!! fstab root line lost?!"; cat /mnt/vmfs-dst/etc/fstab; exit 2; }
sync
sudo umount /mnt/vmfs-src /mnt/vmfs-dst
trap - EXIT
sudo qemu-nbd --disconnect "$SRCDEV"
sudo qemu-nbd --disconnect "$DSTDEV"

sha256sum "$DST" > "$DST.sha256"
qemu-img info "$DST" | grep -E 'virtual size|disk size'
echo ">>> ready: $DST"
