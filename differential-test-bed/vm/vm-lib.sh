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
  # NOTE: one `local` per line (see clone_pin lesson in
  # firstboot-customize.sh): a forward reference works only by accident
  # of the caller's dynamic scope.
  local label=$1
  local path="$VM_WORK/$label.qcow2"
  local golden
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
  # compare/ runs inside the guest too (consume.sh -> snapshot.sh);
  # ship it without caches.
  tar -C "$TEST_DIR" -cf - --exclude='__pycache__' compare \
    | ssh $(ssh_opts) "${VM_SSH_USER}@${ip}" 'tar -C /TEST -xf -'
}

vm_push() {  # <ip> <src> <dst-dir> -- scp -r host src into guest dir
  local ip=$1 src=$2 dst=$3
  vm_ssh "$ip" "mkdir -p $dst"
  scp $(ssh_opts) -r "$src" "${VM_SSH_USER}@${ip}:${dst}/"
}

vm_pull() {  # <ip> <guest-path> <host-dest>
  local ip=$1 src=$2 dst=$3
  mkdir -p "$dst"
  scp $(ssh_opts) -r "${VM_SSH_USER}@${ip}:${src}/." "$dst/"
}

vm_pull_prefix() {  # <ip> <guest-prefix> <host-dir> -- $prefix.* files
  # consume.sh writes "$OUT.*" (prefix, not directory), mirroring the
  # container layout ($OUT/<pm>.* directly under the run dir).
  local ip=$1 pre=$2 dst=$3
  mkdir -p "$dst"
  scp $(ssh_opts) "${VM_SSH_USER}@${ip}:${pre}.*" "$dst/"
}

vm_share_pm() {  # <label> -- share the active PM's checkout via virtiofs
  # The PM checkout must appear in the guest at its build-time path:
  # portuale resolves repo_root() from compile-time CARGO_MANIFEST_DIR,
  # and L1+ phase execution reads bin/ + 3rdparty through it -- exactly
  # what the container bed bind-mounts ($PM_REPO:$PM_REPO:ro).
  # 9p cannot be hotplugged (libvirt: only virtiofs can), hence virtiofs
  # with a per-run daemon (domains already carry shared memory backing).
  # Sockets live in VM_SOCK_DIR, NOT VM_WORK: unix socket paths die
  # past SUN_LEN (108) and VM_WORK-based names overflow with long labels.
  local label=$1
  local sockdir=${VM_SOCK_DIR:-/tmp/porttest-vm-socks}
  local sock="$sockdir/$label-pm.sock"
  local pidf="$VM_WORK/$label-virtiofsd.pid"
  mkdir -p "$sockdir"
  rm -f "$sock" "$pidf"
  setsid /usr/libexec/virtiofsd --shared-dir="$PM_REPO" --socket-path="$sock" \
    --cache=never --log-level=warn </dev/null >>"$VM_WORK/$label-virtiofsd.log" 2>&1 &
  echo $! > "$pidf"
  local i
  for i in $(seq 1 30); do
    [ -S "$sock" ] && break
    sleep 1
  done
  [ -S "$sock" ] || {
    echo "!!! virtiofsd produced no socket for $label (log follows)" >&2
    tail -n 15 "$VM_WORK/$label-virtiofsd.log" >&2 || true
    return 2
  }
  chmod 777 "$sock"  # qemu connects as qemu:qemu (test-only NAT)
  local xml
  xml=$(mktemp)
  cat > "$xml" <<EOF
<filesystem type='mount' accessmode='passthrough'>
  <driver type='virtiofs' queue='1024'/>
  <source socket='$sock'/>
  <target dir='pmrepo'/>
</filesystem>
EOF
  virsh --connect qemu:///system attach-device "$label" "$xml" --live
  rm -f "$xml"
}

vm_unshare() {  # <label> -- stop the virtiofs daemon, drop the socket
  local label=$1
  local sockdir=${VM_SOCK_DIR:-/tmp/porttest-vm-socks}
  local pidf="$VM_WORK/$label-virtiofsd.pid"
  [ -f "$pidf" ] && kill "$(cat "$pidf")" 2>/dev/null || true
  pkill -f "virtiofs[d].*$label-pm.sock" 2>/dev/null || true
  # virtiofsd also drops its own <socket>.pid next to the socket.
  rm -f "$sockdir/$label-pm.sock" "$sockdir/$label-pm.sock.pid" \
    "$pidf" "$VM_WORK/$label-virtiofsd.log"
}

vm_mount_pm() {  # <ip> -- mount the shared PM checkout at $PM_REPO
  local ip=$1
  # A checkout without its gitignored 3rdparty/ breaks phase execution
  # confusingly (empty PORTAGE_PYM_PATH); fail loud here instead.
  [ -d "$PM_REPO/3rdparty/portage" ] \
    || { echo "!!! $PM_REPO/3rdparty/portage missing (gitignored checkout content)" >&2; return 2; }
  vm_ssh "$ip" "modprobe virtiofs 2>/dev/null; modprobe fuse 2>/dev/null; true"
  vm_ssh "$ip" "mkdir -p '$PM_REPO' && mount -t virtiofs -o ro pmrepo '$PM_REPO' && test -f '$PM_REPO/bin/ebuild.sh'"
}

vm_teardown() {  # <label> -- destroy domain, drop overlay + seed + share
  local label=$1
  vm_down "$label" "$VM_WORK/$label.qcow2" 2>/dev/null || true
  rm -f "$VM_WORK/$label-seed.iso"
  vm_unshare "$label"
}
