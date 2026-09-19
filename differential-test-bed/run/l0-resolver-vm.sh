#!/bin/bash
# L0 on VMs -- resolver parity at real-tree scale, same probes and
# grading as run/l0-resolver.sh, but the in-container.sh half runs in a
# throwaway VM (fresh overlay on the golden image) instead of a
# throwaway container. Reports are l0-vm-* so container reports stay.
#
#   differential-test-bed/run/l0-resolver-vm.sh [atomlist]
#
# Env: as l0-resolver.sh (L0_SKIP_PORTAGE_UPGRADE, L0_SKIP_MULTI,
#      L0_SKIP_INVARIANTS, L0_EMERGE_OPTS, L0_PORTAGE_PIN), plus
#      PMTEST_PM (registry) and VM_WORK (overlay/scratch location).
#
# Exit: 0 green, 1 unexplained divergences, 2 setup error.

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/lib.sh"
. "$HERE/../vm/vm-common.sh"
. "$HERE/../vm/vm-lib.sh"

ATOMLIST=$(realpath -e "${1:-$TEST_DIR/atomlists/l0-resolve.txt}" 2>/dev/null) \
  || { echo "atom list not found: ${1:-$TEST_DIR/atomlists/l0-resolve.txt}" >&2; exit 2; }
case $ATOMLIST in
  "$TEST_DIR"/layers/*|"$TEST_DIR"/atomlists/*)
    REL_ATOMLIST="/TEST/${ATOMLIST#"$TEST_DIR"/}" ;;
  *) echo "atom list must live under $TEST_DIR/layers/ or $TEST_DIR/atomlists/" >&2; exit 2 ;;
esac

RUN="l0-vm-$(timestamp)"
OUT="$LOGS_DIR/$RUN"
mkdir -p "$OUT"
ln -sfn "$RUN" "$LOGS_DIR/l0-vm-latest"

# Guest filesystem under test (slice 3 matrix): selects the golden
# backing (vm_golden) and scopes fs-qualified allowlist entries.
# The guest also records it in fingerprint.tsv (`fs` line).
VM_FS=${VM_FS:-xfs}
case $VM_FS in xfs|ext4|btrfs) ;; *) echo "VM_FS must be xfs|ext4|btrfs" >&2; exit 2 ;; esac
echo ">>> guest filesystem: $VM_FS"

ensure_pm_built

LABEL="porttest-l0-vm-$$"
cleanup() { vm_teardown "$LABEL"; }
trap cleanup EXIT

echo ">>> booting $LABEL"
IP=$(vm_run_boot "$LABEL")
# The IP must be exactly one dotted quad: a polluted capture (stray
# stdout inside the boot path) must fail here loudly, never as a
# confusing scp/ssh error three lines later.
[[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "!!! bad guest IP from vm_run_boot: [$IP]" >&2; exit 2; }
echo ">>> guest at $IP"
vm_push_pm "$IP"
vm_push_test "$IP"

echo ">>> running L0 probes on $LABEL (out: $OUT)"
vm_ssh "$IP" \
  "L0_SKIP_PORTAGE_UPGRADE=${L0_SKIP_PORTAGE_UPGRADE:-0}" \
  "L0_SKIP_MULTI=${L0_SKIP_MULTI:-0}" \
  "L0_SKIP_INVARIANTS=${L0_SKIP_INVARIANTS:-0}" \
  "L0_EMERGE_OPTS=${L0_EMERGE_OPTS:--pv}" \
  "L0_PORTAGE_PIN=${L0_PORTAGE_PIN:-3.0.82.2}" \
  /TEST/layers/l0/in-container.sh "$REL_ATOMLIST" "/TEST/logs/$RUN"

echo ">>> pulling $OUT"
vm_pull "$IP" "/TEST/logs/$RUN" "$OUT"

echo ">>> comparing (fs=$VM_FS)"
set +e
python3 "$TEST_DIR/compare/resolve-compare.py" --fs "$VM_FS" --backend vm "$OUT" "$TEST_DIR/compare/known-divergences.yaml"
rc=$?
python3 "$TEST_DIR/compare/check-invariants.py" "$OUT" | tee "$OUT/invariants.txt"
[ "${PIPESTATUS[0]}" = 0 ] || [ "$rc" != 0 ] || rc=1
set -e

ln -sfn "$RUN/l0-report.txt" "$LOGS_DIR/l0-vm-report.txt"
ln -sfn "$RUN/l0-report.json" "$LOGS_DIR/l0-vm-report.json"
echo ">>> report: $OUT/l0-report.txt   (rc=$rc)"
exit $rc
