#!/bin/bash
# Per-run VM lifecycle for the differential test bed (slice 2+).
# Source after run/lib.sh (for PM_* / TEST_DIR / LOGS_DIR) and
# vm/vm-common.sh (for vm_define / wait_for_ssh / vm_ssh / vm_down).
# Source, don't execute.
#
# Guest model (mirrors the container mounts, but explicit copies --
# VMs have no bind mounts):
#   PM binaries   scp $PM_EMERGE -> /usr/local/bin/ + applet symlinks
#   bed scripts   scp layers/ + atomlists/ -> /TEST/ (ro-by-convention)
#   outputs       guest /TEST/logs/$RUN -> scp -r back to host $OUT
# The guest never sees host paths; the host never trusts guest state
# except through the pulled $OUT (graded by the same compare scripts).

# Filesystem matrix (slice 3): VM_FS selects the golden backing.
# Default xfs = golden.qcow2 (continuity with the slice-2 baseline);
# VM_FS=ext4|btrfs selects golden-<fs>.qcow2 (built by make-fs-image.sh).
vm_golden() {
  local fs=${VM_FS:-xfs}
  case $fs in
    xfs) echo "$VM_WORK/golden.qcow2" ;;
    ext4|btrfs) echo "$VM_WORK/golden-$fs.qcow2" ;;
    *) echo "!!! VM_FS must be xfs|ext4|btrfs (got $fs)" >&2; exit 2 ;;
  esac
}

vm_overlay() {  # <label> -> path (fresh overlay on the selected golden)
  local label=$1 path="$VM_WORK/$label.qcow2" golden
  golden=$(vm_golden)
  [ -f "$golden" ] || {
    echo "!!! no golden image: $golden (build it: vm/make-image.sh, vm/make-fs-image.sh)" >&2
    exit 2
  }
  rm -f "$path"
  qemu-img create -F qcow2 -b "$golden" -f qcow2 "$path" > /dev/null
  echo "$path"
}

vm_run_boot() {  # <label> -> prints guest IP (define, boot, wait)
  local label=$1 disk seed_ip
  disk=$(vm_overlay "$label")
  seed_ip="$VM_WORK/$label-seed.iso"
  # Seed chatter must not reach stdout: this function's stdout IS the IP.
  "$VM_HERE/make-seed-iso.sh" "$label" "$VM_SSH_PUBKEY" "$seed_ip" > /dev/null
  vm_define "$label" "$disk" "$seed_ip" > /dev/null
  wait_for_ssh "$label" 60
}

vm_push_pm() {  # <ip> -- PM binaries + applet symlinks into the guest
  local ip=$1 base
  base=$(basename "$PM_EMERGE")
  scp $(ssh_opts) "$PM_EMERGE" "${VM_SSH_USER}@${ip}:/usr/local/bin/$base"
  vm_ssh "$ip" "chmod +x /usr/local/bin/$base
    for l in emerge ebuild mrg; do ln -sf $base /usr/local/bin/\$l; done
    /usr/local/bin/emerge --help > /dev/null"
}

vm_push_test() {  # <ip> -- bed scripts the guest layer needs
  local ip=$1
  vm_ssh "$ip" "mkdir -p /TEST"
  scp $(ssh_opts) -r "$TEST_DIR/layers" "$TEST_DIR/atomlists" \
    "${VM_SSH_USER}@${ip}:/TEST/"
}

vm_pull() {  # <ip> <guest-path> <host-dest>
  local ip=$1 src=$2 dst=$3
  mkdir -p "$dst"
  scp $(ssh_opts) -r "${VM_SSH_USER}@${ip}:${src}/." "$dst/"
}

vm_teardown() {  # <label> -- destroy domain, drop overlay + seed
  local label=$1
  vm_down "$label" "$VM_WORK/$label.qcow2" 2>/dev/null || true
  rm -f "$VM_WORK/$label-seed.iso"
}
