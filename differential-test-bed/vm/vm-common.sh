#!/bin/bash
# Shared helpers for the VM test-bed scripts (differential-test-bed/vm/).
# Source, don't execute. Host-side only; the guest half lives in
# layers/* and is backend-agnostic (same scripts containers run).

set -euo pipefail

VM_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$VM_HERE/pins.sh"

VM_TEST_DIR=$(cd "$VM_HERE/.." && pwd)
VM_REPO_ROOT=$(cd "$VM_HERE/../.." && pwd)
# Host-local VM state (base/golden/run overlays, seeds, logs).
# Git-ignored: images are rebuilt from pins, never committed (F2).
VM_WORK=${VM_WORK:-$VM_TEST_DIR/vm/work}
VM_IMAGE=${PORTTEST_VM_IMAGE:-$VM_WORK/golden.qcow2}

VM_VIRSH="virsh --connect qemu:///system"

ssh_opts() {
  # Throwaway guests share IPs and host keys across runs; SSH is only a
  # transport here, never an identity check. One flag set everywhere so
  # runs are reproducible regardless of host ~/.ssh state. The client
  # identity is the private half of the seeded pubkey: these scripts
  # must run as a normal user (sudo is used internally only for
  # nbd/mount), otherwise the wrong ~/.ssh is offered and auth fails.
  printf '%s\n' -o BatchMode=yes -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i "${VM_SSH_PUBKEY%.pub}"
}

vm_ip() {  # <domain> -> prints the DHCP lease IP (empty when none yet)
  local dom=$1 mac out
  # No 2>/dev/null here: a failing virsh must be loud, or every caller
  # degrades into mysterious timeouts (seen once with polkit).
  out=$($VM_VIRSH domiflist "$dom" 2>&1) \
    || { echo "!!! domiflist $dom failed: $out" >&2; return 0; }
  mac=$(printf '%s\n' "$out" | awk -v net="$VM_NET" '$3==net{print $5}')
  [ -n "$mac" ] || { echo "!!! no $VM_NET nic on $dom" >&2; return 0; }
  out=$($VM_VIRSH net-dhcp-leases "$VM_NET" 2>&1) \
    || { echo "!!! net-dhcp-leases $VM_NET failed: $out" >&2; return 0; }
  printf '%s\n' "$out" \
    | awk -v mac="$mac" '$3==mac && $5!=""{print $5}' | cut -d/ -f1 | head -n 1
  # Columns are: Expiry-Date Expiry-Time MAC Proto IP Hostname ... --
  # the MAC is $3, not $2.
  return 0
}

wait_for_ssh() {  # <domain> [tries] -- exits 2 on timeout
  local dom=$1 tries=${2:-60} ip
  for ((i = 1; i <= tries; i++)); do
    ip=$(vm_ip "$dom")
    if [ -n "$ip" ] && ssh $(ssh_opts) "${VM_SSH_USER}@${ip}" true 2>/dev/null; then
      echo "$ip"
      return 0
    fi
    sleep 10
  done
  echo "!!! no SSH on $dom after $((tries * 10))s" >&2
  return 2
}

vm_ssh() {  # <ip> <cmd...> -- run a command in the guest, code passthrough
  local ip=$1
  shift
  ssh $(ssh_opts) "${VM_SSH_USER}@${ip}" "$@"
}

vm_define() {  # <name> <disk.qcow2> [seed.iso] -- (re)define a UEFI domain
  local name=$1 disk=$2 seed=${3:-}
  $VM_VIRSH undefine "$name" --nvram 2>/dev/null || true
  local seed_arg=()
  [ -n "$seed" ] && seed_arg=(--disk "$seed,device=cdrom")
  virt-install --connect qemu:///system --name "$name" \
    --memory "$VM_MEMORY_MB" --vcpus "$VM_VCPUS" --cpu host-model \
    --disk "$disk" "${seed_arg[@]}" \
    --os-variant gentoo \
    --boot loader=/usr/share/edk2/OvmfX64/OVMF_CODE_4M.qcow2,loader.readonly=yes,loader.type=pflash,nvram.template=/usr/share/edk2/OvmfX64/OVMF_VARS_4M.qcow2 \
    --network network="$VM_NET" --graphics none --noautoconsole --import \
    > /dev/null
}

vm_down() {  # <name> [disk-to-delete] -- destroy, undefine, drop overlay
  local name=$1 disk=${2:-}
  $VM_VIRSH destroy "$name" 2>/dev/null || true
  $VM_VIRSH undefine "$name" --nvram 2>/dev/null || true
  [ -n "$disk" ] && rm -f "$disk"
}

vm_claim() {  # <file...> -- take back ownership libvirt gave to qemu:qemu
  # Attaching a disk chowns it to qemu; destroy-based teardown can leave
  # it stuck that way, breaking later writes (qemu-img snapshot, seed
  # rebuild). Run after vm_down, before touching the file again.
  sudo chown "$(id -un):$(id -gn)" "$@" 2>/dev/null || true
}

nbd_dev() {  # echo a free /dev/nbdN (loads nbd module); caller disconnects
  sudo modprobe nbd 2>/dev/null || true
  for n in $(seq 0 15); do
    [ -e "/sys/block/nbd$n/pid" ] && continue
    echo "/dev/nbd$n"
    return 0
  done
  echo "no free nbd device" >&2
  return 2
}
