#!/bin/bash
# L32 -- the life-cycle + fault bed (#32). One harness, two halves:
#
# S1 life-cycle:
#   C1  -C / --depclean    (S0 group 1)
#   C2  soname bump -> preserved-libs (S0 group 2)
#   C3  CONFIG_PROTECT over a user-modified config (S0 group 3)
#   C4  --resume after SIGKILL mid-merge (S0 group 4)
#
# S2 fault injection:
#   F1  disk-full / ENOSPC on a small dedicated tmpfs (S0 group 5a/5a2)
#   F2  corrupt/truncated binpkg merged with --usepkgonly (S0 group 5b)
#   F3  local binhost HTTP 500, abort then source fallback (S0 group 5c)
#
#   control   -- BOTH sides real Portage through the same harness; the two
#                snapshots are normalised + diffed with NO allowlist and
#                must be 0 unexplained. That is the gate and the noise
#                floor for every cell.
#   candidate -- reference side stays real Portage; the other side runs
#                the SAME cell with portuale's real CLI
#                (layers/l32/run-cell.sh portuale). Every diff row is
#                recorded and triaged against findings/l5.md expected
#                shapes; nothing here gates.
#
# Mirrors run/l1-merge-from-binpkg.sh + P-G1's run/l31-remote-merge.sh
# shape: same lib.sh helpers, same compare/ invocations, no new diff
# semantics.
#
#   differential-test-bed/run/l32-lifecycle.sh [C1|C2|C3|C4|F1|F2|F3|all]
#
# Env: PORTTEST_IMAGE, PORTTEST_PODMAN,
#      L32_MODE=control|candidate    (default control),
#      L32_SKIP_BUILD=1              (prebuilt portuale; PMTEST_NO_BUILD=1),
#      L32_REBUILD=1                 (force overlay regeneration),
#      L32_SKIP_PORTAGE_UPGRADE=1    (keep the image Portage on both sides),
#      L32_F1_TMPFS                  (F1 tmpfs size, default 16m),
#      L1_JOBS / MAKEOPTS            (in-container -j, default -j2)
#
# Exit: control 0 green / 1 unexplained / 2 setup error; candidate always
# 0 (the diffs are triage material, not a gate).
#
# Logs: differential-test-bed/logs/l32-<stamp>/ + logs/l32-latest symlink
# (gitignored).

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/lib.sh"

CELL=${1:-all}
case $CELL in
  all|C1|C2|C3|C4|F1|F2|F3) ;;
  *) echo "usage: l32-lifecycle.sh [C1|C2|C3|C4|F1|F2|F3|all]" >&2; exit 2 ;;
esac
case ${L32_MODE:-control} in
  control|candidate) MODE=${L32_MODE:-control} ;;
  *) echo "L32_MODE must be control|candidate" >&2; exit 2 ;;
esac
if [ "${L32_SKIP_BUILD:-0}" = 1 ]; then export PMTEST_NO_BUILD=1; fi

RUN="l32-$(timestamp)"
OUT="$LOGS_DIR/$RUN"
OVL_DIR="$LOGS_DIR/_l32-overlay"
mkdir -p "$OUT" "$OVL_DIR"
ln -sfn "$RUN" "$LOGS_DIR/l32-latest"
ensure_image

# --- fixture overlay (host-generated, ro-mounted at /l32-overlay) -------
if [ "${L32_SKIP_BUILD:-0}" != 1 ] || [ ! -d "$OVL_DIR/l32/l32" ] || [ "${L32_REBUILD:-0}" = 1 ]; then
  echo ">>> regenerating the l32 fixture overlay under $OVL_DIR"
  bash "$TEST_DIR/layers/l32/gen-overlay.sh" "$OVL_DIR/l32" > "$OUT/overlay-gen.log"
fi

# --- pre-build / preflight ----------------------------------------------
if [ "$MODE" = candidate ]; then
  ensure_pm_built "$OUT"
  portuale_phase_helpers_preflight
else
  pm_stamp "$OUT"
  pm_mounts
fi

# --- run header ---------------------------------------------------------
{
  echo "# L32 life-cycle bed run header"
  echo "run_id	$RUN"
  echo "mode	$MODE"
  echo "cell	$CELL"
  echo "profile	release"
  echo "pm_under_test	$PM_NAME $PM_VERSION"
  echo "image	$IMAGE"
  echo "nice	nice -n 19"
  echo "makeopts	${MAKEOPTS:--j2}"
  echo "portage_pin	${L32_PORTAGE_PIN:-3.0.82.2}"
  echo "host_date_utc	$(date -u +%FT%TZ)"
  echo "## df -h /home"
  df -h /home
  echo "## df -i /tmp"
  df -i /tmp
} > "$OUT/header.txt"
echo ">>> run $RUN (mode=$MODE cell=$CELL) -> $OUT"

# --- one in-container cell run ------------------------------------------
run_cell() {  # <pm> <tag>  (tag is the path under <run>/<cell>/)
  local pm=$1 tag=$2
  local name="porttest-l32-${CELL}-${tag//\//-}-$$"
  # F1 is the one cell with a mount of its own: a small DEDICATED tmpfs at
  # the portage workdir, so ENOSPC never touches /home or the host /tmp.
  # It is created *inside* the cell (after the fixture preflight) by
  # run-cell.sh, which needs SYS_ADMIN to mount it; a host --tmpfs would
  # also starve `upgrade_portage`'s own build in the same workdir.
  local extra=()
  case $CELL in
    F1) extra=(--cap-add SYS_ADMIN) ;;
  esac
  echo ">>> cell $CELL: $pm ($tag)"
  set +e
  nice -n 19 "$PODMAN" run --rm --name "$name" \
    --security-opt seccomp=unconfined --cgroups=enabled --cgroupns=private \
    "${PM_MOUNTS[@]}" "${extra[@]}" \
    -v "$OVL_DIR:/l32-overlay:ro" \
    -e "MAKEOPTS=${MAKEOPTS:--j2}" \
    -e "L32_F1_TMPFS=${L32_F1_TMPFS:-16m}" \
    -e "L32_SKIP_PORTAGE_UPGRADE=${L32_SKIP_PORTAGE_UPGRADE:-0}" \
    --entrypoint /bin/bash "$IMAGE" \
    /TEST/layers/l32/run-cell.sh "$pm" "$CELL" "/TEST/logs/$RUN/$CELL/$tag"
  local rc=$?
  set -e
  echo ">>> cell $CELL $pm rc=$rc"
  return "$rc"
}

# NB: never toggles `set -e` itself -- the caller disables errexit around it
# and reads $?, so a hidden `set -e` here would abort on the very diff rc it
# is trying to report (S1 bug: candidate C1 aborted after the first cell).
normalize_diff() {  # <level> <prefix-a> <prefix-b> <report>
  local lvl=$1 a=$2 b=$3 report=$4
  python3 "$TEST_DIR/compare/normalize.py" "$a"
  python3 "$TEST_DIR/compare/normalize.py" "$b"
  echo ">>> diffing ($lvl; no known-divergences allowlist)"
  python3 "$TEST_DIR/compare/diff.py" --layer l32 "$a" "$b" | tee "$report"
  return "${PIPESTATUS[0]}"
}

unexplained_of() {  # <report>
  local n
  n=$(sed -n 's/^  UNEXPLAINED *: *\([0-9][0-9]*\)$/\1/p' "$1" | tail -1)
  echo "${n:-?}"
}

CELLS=(C1 C2 C3 C4 F1 F2 F3)
if [ "$CELL" != all ]; then CELLS=("$CELL"); fi

ROWS=()
BAD=0
for c in "${CELLS[@]}"; do
  CELL=$c
  if [ "$MODE" = control ]; then
    run_cell portage "control/portage-a" \
      || { echo "!!! $c control side A setup error" >&2; exit 2; }
    run_cell portage "control/portage-b" \
      || { echo "!!! $c control side B setup error" >&2; exit 2; }
    A="$OUT/$c/control/portage-a"; B="$OUT/$c/control/portage-b"
    REPORT="$OUT/$c/control/report.txt"
    set +e; normalize_diff "control" "$A" "$B" "$REPORT"; rc=$?; set -e
    n=$(unexplained_of "$REPORT")
    ROWS+=("$c	control	$n	rc=$rc")
    [ "$rc" = 0 ] || BAD=1
  else
    run_cell portage "candidate/portage" \
      || { echo "!!! $c candidate reference side setup error" >&2; exit 2; }
    run_cell portuale "candidate/portuale" \
      || true
    A="$OUT/$c/candidate/portage"; B="$OUT/$c/candidate/portuale"
    REPORT="$OUT/$c/candidate/report.txt"
    set +e; normalize_diff "candidate" "$A" "$B" "$REPORT"; rc=$?; set -e
    n=$(unexplained_of "$REPORT")
    ROWS+=("$c	candidate	$n	rc=$rc")
  fi
done

# --- post-run: portage versions both sides -----------------------------
{
  echo "## portage versions (both sides)"
  for c in "${CELLS[@]}"; do
    for tag in $( [ "$MODE" = control ] && echo control/portage-a control/portage-b || echo candidate/portage candidate/portuale ); do
      p="$OUT/$c/$tag.meta.tsv"
      ver=$(grep -h '^portage_version' "$p" 2>/dev/null | cut -f2- || true)
      echo "$c	$tag	${ver:-unknown}"
    done
  done
} >> "$OUT/header.txt"

{
  echo "## cell summary"
  for r in "${ROWS[@]}"; do echo "$r"; done
} >> "$OUT/header.txt"
for r in "${ROWS[@]}"; do echo ">>> $r"; done

ln -sfn "$RUN/l32-report.txt" "$LOGS_DIR/l32-report.txt" 2>/dev/null || true
# one stable path to the report set for the latest run
: > "$OUT/l32-report.txt"
for c in "${CELLS[@]}"; do
  if [ -f "$OUT/$c/$MODE/report.txt" ]; then
    cat "$OUT/$c/$MODE/report.txt" >> "$OUT/l32-report.txt"
  fi
done
echo ">>> run dir: $OUT"

if [ "$MODE" = control ]; then
  exit "$BAD"
fi
exit 0
