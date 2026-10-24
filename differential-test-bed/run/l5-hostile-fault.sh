#!/bin/bash
# L5 hostile-fault cell (backlog #514) -- run one hostile shape per gpkg
# with control Portage and candidate portuale, and compare the exit codes.
#
#   differential-test-bed/run/l5-hostile-fault.sh [atomlist]
#
# Env: PORTTEST_IMAGE, PORTTEST_PODMAN. Exit: 0 green, 1 unexplained
# findings, 2 setup error.

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/lib.sh"

ATOMLIST=$(realpath -e "${1:-$TEST_DIR/atomlists/l5-hostile.txt}" 2>/dev/null) \
  || { echo "atom list not found: ${1:-$TEST_DIR/atomlists/l5-hostile.txt}" >&2; exit 2; }
case $ATOMLIST in
  "$TEST_DIR"/*) REL_ATOMLIST="/TEST/${ATOMLIST#"$TEST_DIR"/}" ;;
  *) echo "atom list must live under $TEST_DIR/ (it is bind-mounted at /TEST)" >&2; exit 2 ;;
esac

RUN="l5-hostile-$(timestamp)"
OUT="$LOGS_DIR/$RUN"
mkdir -p "$OUT"
ln -sfn "$RUN" "$LOGS_DIR/l5-hostile-latest"

ensure_pm_built "$OUT"
ensure_image

echo ">>> running hostile-fault cases in $IMAGE  (out: $OUT)"
podman_run_pm "porttest-l5hostile-$$" \
  -v "$REPO_ROOT/fixtures:/fixtures:ro" \
  --entrypoint /bin/bash "$IMAGE" \
  /TEST/layers/l5-hostile/in-container.sh "$REL_ATOMLIST" "/TEST/logs/$RUN"

echo ">>> report: $OUT/run.log  meta: $OUT/meta.tsv"
