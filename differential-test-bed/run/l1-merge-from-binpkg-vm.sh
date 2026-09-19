#!/bin/bash
# L1 on VMs -- merge parity from an identical prebuilt binpkg set.
# Same three phases and grading as run/l1-merge-from-binpkg.sh, but every
# container becomes a throwaway VM (fresh overlay on the golden image):
# Portage builds the set from source once (binpkgs pulled to a persistent
# host pkgcache), then both PMs merge that same set in their own fresh
# guest, snapshots are pulled back and diffed on the host.
# Reports are l1-vm-* so container reports stay.
#
#   differential-test-bed/run/l1-merge-from-binpkg-vm.sh [atomlist]
#
# Env: L1_REBUILD=1 (wipe the VM pkgcache), L1_SKIP_BUILD=1 (reuse it),
#      L1_JOBS (default 1, deterministic), L1_SKIP_PORTAGE_UPGRADE,
#      VM_FS (default xfs), PMTEST_PM (registry).
#
# Exit: 0 green, 1 unexplained divergence, 2 setup error.

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/lib.sh"
. "$HERE/../vm/vm-common.sh"
. "$HERE/../vm/vm-lib.sh"

ATOMLIST=$(realpath -e "${1:-$TEST_DIR/atomlists/l1-merge.txt}" 2>/dev/null) \
  || { echo "atom list not found" >&2; exit 2; }
case $ATOMLIST in
  "$TEST_DIR"/layers/*|"$TEST_DIR"/atomlists/*)
    REL_ATOMLIST="/TEST/${ATOMLIST#"$TEST_DIR"/}" ;;
  *) echo "atom list must live under $TEST_DIR/layers/ or $TEST_DIR/atomlists/" >&2; exit 2 ;;
esac

VM_FS=${VM_FS:-xfs}
case $VM_FS in xfs|ext4|btrfs) ;; *) echo "VM_FS must be xfs|ext4|btrfs" >&2; exit 2 ;; esac
echo ">>> guest filesystem: $VM_FS"

# Own pkgcache: binpkgs are backend-independent bytes, but provenance
# stays clean with one cache per backend (F4: same conditions per run).
PKGCACHE="$LOGS_DIR/_l1-pkgcache-vm"
RUN="l1-vm-$(timestamp)"
OUT="$LOGS_DIR/$RUN"
mkdir -p "$OUT" "$PKGCACHE"
ln -sfn "$RUN" "$LOGS_DIR/l1-vm-latest"

ensure_pm_built "$OUT"

CURRENT_LABEL=""
# NB: the trap must always exit 0: a `[ -n ... ] && ...` guard that ends
# false would otherwise override the run's own exit code on success.
cleanup() { [ -n "$CURRENT_LABEL" ] && vm_teardown "$CURRENT_LABEL"; true; }
trap cleanup EXIT

[ "${L1_REBUILD:-0}" = 1 ] && { echo ">>> L1_REBUILD: wiping $PKGCACHE"; rm -rf "${PKGCACHE:?}"/*; }

# The porttest synthetic overlay is pushed (not mounted) into every
# guest; build.sh / consume.sh only stage it when the atom list
# actually has `porttest/` atoms.
PORTTEST_OVL="$TEST_DIR/images/overlay/porttest"
NEED_OVL=0
[ -d "$PORTTEST_OVL/porttest" ] && grep -q '^porttest/' "$ATOMLIST" && NEED_OVL=1

vm_boot() {  # <label> -> prints guest IP
  local label=$1
  vm_run_boot "$label"
}

# --- build (Portage only) ------------------------------------------------
if [ "${L1_SKIP_BUILD:-0}" != 1 ]; then
  LABEL="porttest-l1-vm-build-$$"
  CURRENT_LABEL="$LABEL"
  echo ">>> building the set from source with Portage (pkgcache: $PKGCACHE)"
  IP=$(vm_boot "$LABEL")
  [ "$NEED_OVL" = 1 ] && vm_push "$IP" "$PORTTEST_OVL/." /porttest-overlay
  vm_push_test "$IP"
  vm_ssh "$IP" \
    "PKGDIR=/pkgs" \
    "L1_JOBS=${L1_JOBS:-1}" \
    "L1_SKIP_PORTAGE_UPGRADE=${L1_SKIP_PORTAGE_UPGRADE:-0}" \
    /TEST/layers/l1/build.sh "$REL_ATOMLIST"
  echo ">>> pulling binpkgs to $PKGCACHE"
  rm -rf "${PKGCACHE:?}"/*
  vm_pull "$IP" /pkgs "$PKGCACHE"
  vm_teardown "$LABEL"
  CURRENT_LABEL=""
  echo ">>> cached $(find "$PKGCACHE" -name '*.gpkg.tar' | wc -l) binpkgs"
else
  echo ">>> L1_SKIP_BUILD: using $(find "$PKGCACHE" -name '*.gpkg.tar' | wc -l) cached binpkgs"
fi

# --- consume (both PMs, identical fresh guests) --------------------------
consume() {  # pm
  local pm=$1 label=$2 ip
  CURRENT_LABEL="$label"
  echo ">>> merging with $pm"
  ip=$(vm_boot "$label")
  # Both sides get the PM checkout at its build-time path (as the
  # container bed bind-mounts it for both): identical guests, fair run.
  vm_share_pm "$label"
  [ "$NEED_OVL" = 1 ] && vm_push "$ip" "$PORTTEST_OVL/." /porttest-overlay
  vm_push_pm "$ip"
  vm_push_test "$ip"
  vm_mount_pm "$ip"
  vm_push "$ip" "$PKGCACHE/." /pkgs
  vm_ssh "$ip" \
    "PKGDIR=/pkgs" \
    "L1_SKIP_PORTAGE_UPGRADE=${L1_SKIP_PORTAGE_UPGRADE:-0}" \
    /TEST/layers/l1/consume.sh "$pm" "$REL_ATOMLIST" "/TEST/logs/$RUN/$pm"
  mkdir -p "$OUT"
  vm_pull_prefix "$ip" "/TEST/logs/$RUN/$pm" "$OUT"
  vm_teardown "$label"
  CURRENT_LABEL=""
}
consume portage "porttest-l1-vm-portage-$$"
consume portuale "porttest-l1-vm-portuale-$$"

# --- normalise + diff ----------------------------------------------------
echo ">>> normalising (fs=$VM_FS)"
python3 "$TEST_DIR/compare/normalize.py" "$OUT/portage"
python3 "$TEST_DIR/compare/normalize.py" "$OUT/portuale"

echo ">>> diffing"
set +e
python3 "$TEST_DIR/compare/diff.py" --backend vm --fs "$VM_FS" \
  "$OUT/portage" "$OUT/portuale" \
  "$TEST_DIR/compare/known-divergences.yaml" | tee "$OUT/l1-report.txt"
rc=${PIPESTATUS[0]}
set -e

ln -sfn "$RUN/l1-report.txt" "$LOGS_DIR/l1-vm-report.txt"
echo ">>> report: $OUT/l1-report.txt   (rc=$rc)"
exit "$rc"
