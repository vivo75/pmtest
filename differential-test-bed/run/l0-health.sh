#!/bin/bash
# L0 health -- portuale only: check every L0 plan against the charter's
# properties 1 (dependencies hold) and 2 (order is legal) with
# pytests-contract-suite/health_checker.py, inside the container so it can
# read the VDB. Portage is not run.
#
#   differential-test-bed/run/l0-health.sh [atomlist]
#
# Output: differential-test-bed/logs/l0-health-<timestamp>/ (plans/,
# health.jsonl, health-report.txt). Exit: 0 when no plan has a failure the
# plan itself introduced, 1 otherwise, 2 on a setup error.

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/lib.sh"

ATOMLIST=$(realpath -e "${1:-$TEST_DIR/atomlists/l0-resolve.txt}" 2>/dev/null) \
  || { echo "atom list not found: ${1:-$TEST_DIR/atomlists/l0-resolve.txt}" >&2; exit 2; }
case $ATOMLIST in
  "$TEST_DIR"/*) REL_ATOMLIST="/TEST/${ATOMLIST#"$TEST_DIR"/}" ;;
  *) echo "atom list must live under $TEST_DIR/ (it is bind-mounted at /TEST)" >&2; exit 2 ;;
esac

RUN="l0-health-$(timestamp)"
OUT="$LOGS_DIR/$RUN"
mkdir -p "$OUT"
ensure_pm_built "$OUT"
ensure_image

echo ">>> planning and checking in $IMAGE  (out: $OUT)"
podman_run_pm "porttest-l0-health-$$" "${MIRROR_ENV[@]}" \
  -v "$REPO_ROOT/pytests-contract-suite/health_checker.py:/HC/health_checker.py:ro" \
  --entrypoint /bin/bash "$IMAGE" \
  /TEST/layers/l0-health/in-container.sh "$REL_ATOMLIST" "/TEST/logs/$RUN"

python3 "$TEST_DIR/compare/health-report.py" "$OUT/health.jsonl" | tee "$OUT/health-report.txt"
exit "${PIPESTATUS[0]}"
