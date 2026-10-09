#!/bin/bash
# z326-closeout.sh -- the #326 Z close-out run: nopy / noportage builds
# vs real Portage (plan docs/02.326-no-portage-runtime.opus.md, "### Z").
#
#   differential-test-bed/run/z326-closeout.sh [--jobs N]
#       [--skip-leg-a] [--skip-leg-b] [--skip-ref] [--skip-gate] [--skip-l31b]
#       [--leg-a-dir <run>] [--leg-b-dir <run>]
#
# --leg-a-dir / --leg-b-dir point at an existing nopy run dir (a name
# under logs/, e.g. from an earlier invocation) so --skip-leg-a/b can
# still feed the audit/ref/compare stages without rebuilding.
#
# Legs (all foreground, sequential):
#   (a) [nopy]       nopy-build.sh --variant nopy --reinstall over
#                    atomlists/z326-nopy.txt (eix, bash, P0 probes):
#                    --buildpkg (gpkg), --usepkgonly re-merge, xpak build.
#   (b) [noportage]  nopy-build.sh --variant noportage --reinstall over
#                    atomlists/l1-merge-gate.txt (glibc + bash), same steps.
#   phase-env audit  compare/z326-audit.py over both leg run dirs:
#                    portuale-python was the only interpreter any
#                    Portage helper invoked (build systems may use a
#                    real python; the audit separates the two).
#   (c) reference    real Portage builds the same two lists from source
#                    in the normal image (layers/z326/
#                    ref-build-merge-snapshot.sh, the l1 build path),
#                    then compare/vdb+files via normalize.py + diff.py
#                    (strict, existing known-divergences.yaml only) and
#                    the gpkgs via gpkg_diff.py --mode strict.
#   [gate]           l1-merge-from-binpkg.sh on the gate list, then
#                    again with L1_SKIP_BUILD=1 L1_CONSUME_REINSTALL=1.
#   l31b             L31B_SKIP_BUILD=1 l31b-two-container.sh.
#
# Requires GENTOO_MIRRORS="http://<eth0 IP>:8080" in the environment
# (the local distfiles proxy; forwarded into every fetching
# container). Env: Z326_JOBS (default 16, MAKEOPTS -j for the
# from-source builds), Z326_REF_TIMEOUT (default 28800).
#
# Output: differential-test-bed/logs/z326-<timestamp>/ (legs.tsv, the
# two reference snapshots + diff/gpkg reports, gate/l31b run ids,
# z326-report.txt); logs/z326-report.txt symlinks the latest report.
# Reference binpkgs persist in logs/_z326-pkgcache-{nopy,noportage}/.
#
# Exit: 0 green, 1 divergence or step failure, 2 setup error.

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/lib.sh"

if [ -z "${GENTOO_MIRRORS:-}" ]; then
  echo "!!! z326-closeout: GENTOO_MIRRORS is unset." >&2
  echo '!!!   export GENTOO_MIRRORS=http://$(ip -j -4 a s eth0 | jq -r ".[0].addr_info[0].local"):8080' >&2
  echo "!!!   (every bed run that fetches must use the local distfiles proxy)" >&2
  exit 2
fi

JOBS=${Z326_JOBS:-16}
SKIP_A=0 SKIP_B=0 SKIP_REF=0 SKIP_GATE=0 SKIP_L31B=0
LEG_A_GIVEN="" LEG_B_GIVEN=""
while [ $# -gt 0 ]; do
  case $1 in
    --jobs) JOBS=${2:?--jobs needs a number}; shift 2 ;;
    --skip-leg-a) SKIP_A=1; shift ;;
    --skip-leg-b) SKIP_B=1; shift ;;
    --skip-ref) SKIP_REF=1; shift ;;
    --skip-gate) SKIP_GATE=1; shift ;;
    --skip-l31b) SKIP_L31B=1; shift ;;
    --leg-a-dir) LEG_A_GIVEN=${2:?--leg-a-dir needs a logs/ run name}; shift 2 ;;
    --leg-b-dir) LEG_B_GIVEN=${2:?--leg-b-dir needs a logs/ run name}; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

RUN="z326-$(timestamp)"
OUT="$LOGS_DIR/$RUN"
mkdir -p "$OUT"
ln -sfn "$RUN" "$LOGS_DIR/z326-latest"
: > "$OUT/legs.tsv"
: > "$OUT/z326-report.txt"
overall_rc=0
note() { printf '%s\n' "$*" | tee -a "$OUT/z326-report.txt"; }
fail() { printf 'FAIL %s\n' "$*" | tee -a "$OUT/z326-report.txt"; overall_rc=1; }
pass() { printf 'ok   %s\n' "$*" | tee -a "$OUT/z326-report.txt"; }

read_atoms() {  # <atomlist> -> stdout, one atom per line
  local line f=$1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}; line=$(printf '%s' "$line" | tr -d '[:space:]')
    [ -n "$line" ] && printf '%s\n' "$line"
  done < "$f"
}

note "# z326 close-out $RUN ($(date -u +%FT%TZ))"
note "pm: $PM_NAME $PM_VERSION (profile $PM_PROFILE)"
ensure_pm_built "$OUT"

# --- legs (a) + (b) ----------------------------------------------------
# Result via $RUN_LEG_DIR (globals, not command substitution, so the
# leg's own console output stays on this shell's stdout).
RUN_LEG_DIR=""
run_leg() {  # <leg-id> <variant> <atomlist>; sets RUN_LEG_DIR
  local leg=$1 variant=$2 list=$3
  mapfile -t atoms < <(read_atoms "$list")
  note "--- leg $leg: --variant $variant --reinstall ${atoms[*]}"
  set +e
  NOPY_SNAPSHOT=1 NOPY_AUDIT=1 NOPY_JOBS="$JOBS" \
    "$HERE/nopy-build.sh" --variant "$variant" --reinstall "${atoms[@]}"
  local rc=$?
  set -e
  RUN_LEG_DIR=$(readlink "$LOGS_DIR/nopy-latest")
  printf '%s\t%s\t%s\trc=%s\n' "$leg" "$variant" "$RUN_LEG_DIR" "$rc" >> "$OUT/legs.tsv"
  return "$rc"
}

LEG_A_DIR="" LEG_B_DIR=""
if [ "$SKIP_A" = 0 ]; then
  set +e; run_leg "a-nopy" nopy "$TEST_DIR/atomlists/z326-nopy.txt"; rc=$?; set -e
  LEG_A_DIR=$RUN_LEG_DIR
  [ "$rc" = 0 ] && pass "leg (a) runner ok ($LEG_A_DIR)" || fail "leg (a) runner rc=$rc"
elif [ -n "$LEG_A_GIVEN" ]; then
  LEG_A_DIR=$LEG_A_GIVEN
  printf 'a-nopy\tgiven\t%s\n' "$LEG_A_DIR" >> "$OUT/legs.tsv"
  note "--- leg (a) given: $LEG_A_DIR"
else note "--- leg (a) skipped"; fi
if [ "$SKIP_B" = 0 ]; then
  set +e; run_leg "b-noportage" noportage "$TEST_DIR/atomlists/l1-merge-gate.txt"; rc=$?; set -e
  LEG_B_DIR=$RUN_LEG_DIR
  [ "$rc" = 0 ] && pass "leg (b) runner ok ($LEG_B_DIR)" || fail "leg (b) runner rc=$rc"
elif [ -n "$LEG_B_GIVEN" ]; then
  LEG_B_DIR=$LEG_B_GIVEN
  printf 'b-noportage\tgiven\t%s\n' "$LEG_B_DIR" >> "$OUT/legs.tsv"
  note "--- leg (b) given: $LEG_B_DIR"
else note "--- leg (b) skipped"; fi

# --- phase-env audits --------------------------------------------------
audit_leg() {  # <leg-id> <legdir>
  [ -n "$2" ] || { note "audit $1: no run dir (leg skipped)"; return 0; }
  note "--- audit $1 ($2)"
  set +e
  python3 "$TEST_DIR/compare/z326-audit.py" "$LOGS_DIR/$2" 2>&1 | tee "$OUT/audit-$1.txt"
  local rc=${PIPESTATUS[0]}
  set -e
  [ "$rc" = 0 ] && pass "audit $1 PASS" || fail "audit $1 rc=$rc"
  return 0
}
if [ -n "$LEG_A_DIR" ]; then audit_leg "a-nopy" "$LEG_A_DIR"; fi
if [ -n "$LEG_B_DIR" ]; then audit_leg "b-noportage" "$LEG_B_DIR"; fi

# --- leg (c) reference --------------------------------------------------
PORTTEST_OVL="$TEST_DIR/images/overlay/porttest"
ref_side() {  # <leg-id> <atomlist> <pkgcache> <out-name>
  local leg=$1 list=$2 cache=$3 name=$4
  local rel
  case $list in "$TEST_DIR"/*) rel="/TEST/${list#"$TEST_DIR"/}" ;; *) echo "atom list must live under $TEST_DIR/" >&2; return 2 ;; esac
  mkdir -p "$cache"
  local ovl=()
  [ -d "$PORTTEST_OVL/porttest" ] && ovl=(-v "$PORTTEST_OVL:/porttest-overlay:ro")
  local distfiles=${NOPY_DISTFILES:-$LOGS_DIR/_l2-distfiles}
  mkdir -p "$distfiles"
  note "--- ref $leg: real Portage from-source + snapshot (pkgcache $cache)"
  # argv array (timeout cannot exec the podman_run_pm function).
  ref_argv=("$PODMAN" run --rm --name "porttest-z326-ref-$leg-$$"
    --security-opt seccomp=unconfined --cgroups=enabled --cgroupns=private
    "${PM_MOUNTS[@]}"
    -v "$cache:/pkgs" "${ovl[@]}"
    -v "$distfiles:/distfiles" -e DISTDIR=/distfiles
    -e PKGDIR=/pkgs
    -e "Z326_JOBS=$JOBS" -e Z326_REINSTALL=1
    -e "L1_SKIP_PORTAGE_UPGRADE=${L1_SKIP_PORTAGE_UPGRADE:-0}"
    ${MIRROR_ENV[@]+"${MIRROR_ENV[@]}"}
    --entrypoint /bin/bash "$IMAGE"
    /TEST/layers/z326/ref-build-merge-snapshot.sh "$rel" "/TEST/logs/$RUN/$name")
  set +e
  timeout "${Z326_REF_TIMEOUT:-28800}" "${ref_argv[@]}" \
    2>&1 | tee "$OUT/ref-$leg-console.log"
  local rc=${PIPESTATUS[0]}
  set -e
  [ "$rc" = 0 ] && pass "ref $leg ok" || fail "ref $leg rc=$rc"
  return 0
}

compare_side() {  # <leg-id> <legdir> <ref-name> <diff-name>
  local leg=$1 legdir=$2 ref=$3 name=$4
  [ -n "$legdir" ] || { note "compare $leg: leg skipped"; return 0; }
  local full="$LOGS_DIR/$legdir"
  if [ ! -f "$full/snap.files.tsv" ]; then
    fail "compare $leg: no portuale snapshot ($full/snap.files.tsv)"; return 0
  fi
  if [ ! -f "$OUT/$ref.files.tsv" ]; then
    fail "compare $leg: no reference snapshot ($OUT/$ref.files.tsv)"; return 0
  fi
  # Normalise into the z326 run dir (copies: never write .norm next to
  # the leg's own logs).
  cp "$full/snap.files.tsv" "$OUT/$name-port.files.tsv"
  cp "$full/snap.mtimes.tsv" "$OUT/$name-port.mtimes.tsv"
  cp "$full/snap.vdb.tar" "$OUT/$name-port.vdb.tar"
  cp "$full/snap.meta.tsv" "$OUT/$name-port.meta.tsv"
  cp "$OUT/$ref.files.tsv" "$OUT/$name-ref.files.tsv"
  cp "$OUT/$ref.mtimes.tsv" "$OUT/$name-ref.mtimes.tsv"
  cp "$OUT/$ref.vdb.tar" "$OUT/$name-ref.vdb.tar"
  cp "$OUT/$ref.meta.tsv" "$OUT/$name-ref.meta.tsv"
  note "--- diff $leg (strict, existing allowlist only)"
  python3 "$TEST_DIR/compare/normalize.py" "$OUT/$name-port"
  python3 "$TEST_DIR/compare/normalize.py" "$OUT/$name-ref"
  set +e
  python3 "$TEST_DIR/compare/diff.py" "$OUT/$name-ref" "$OUT/$name-port" \
    "$TEST_DIR/compare/known-divergences.yaml" 2>&1 | tee "$OUT/diff-$leg.txt"
  local rc=${PIPESTATUS[0]}
  set -e
  [ "$rc" = 0 ] && pass "diff $leg green" || fail "diff $leg rc=$rc"
  return 0
}

gpkg_side() {  # <leg-id> <legdir> <ref-pkgcache>
  local leg=$1 legdir=$2 cache=$3
  [ -n "$legdir" ] || { note "gpkg $leg: leg skipped"; return 0; }
  local full="$LOGS_DIR/$legdir"
  note "--- gpkg $leg (strict, per-PF newest pair)"
  : > "$OUT/gpkg-$leg.txt"
  local n_pairs=0 n_hard=0
  mkdir -p "$OUT/gpkg-$leg-logs"
  # Portuale PFs from this leg's artifacts (fresh per run; the PKGDIR
  # layout nests by category, so enumerate with find).
  newest() { find "$2" -name "$1-"'*.gpkg.tar' -printf '%T@ %p\n' 2>/dev/null | LC_ALL=C sort -rn | head -n 1 | cut -d' ' -f2-; }
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    local base pf pa pr
    base=$(basename "$a")
    pf=$(printf '%s' "$base" | sed 's|-[0-9][^-]*\.gpkg\.tar$||; s|\.gpkg\.tar$||')
    # Newest same-PF archive on each side (BUILD_IDs differ per build).
    pa=$(newest "$pf" "$full/artifacts/binpkgs")
    pr=$(newest "$pf" "$cache")
    if [ -z "$pa" ] || [ -z "$pr" ]; then
      printf 'UNPAIRED %s port=%s ref=%s\n' "$pf" "${pa:-(none)}" "${pr:-(none)}" | tee -a "$OUT/gpkg-$leg.txt"
      continue
    fi
    n_pairs=$((n_pairs + 1))
    set +e
    bash "$TEST_DIR/compare/gpkg-diff.sh" --mode strict "$pr" "$pa" > "$OUT/gpkg-$leg-logs/$pf.txt" 2>&1
    local rc=$?
    set -e
    if [ "$rc" = 0 ]; then
      printf 'ok   %s\n' "$pf" | tee -a "$OUT/gpkg-$leg.txt"
    else
      n_hard=$((n_hard + 1))
      printf 'HARD %s (rc=%s)\n' "$pf" "$rc" | tee -a "$OUT/gpkg-$leg.txt"
      sed 's/^/    /' "$OUT/gpkg-$leg-logs/$pf.txt" | tee -a "$OUT/gpkg-$leg.txt"
    fi
  done < <(find "$full/artifacts/binpkgs" -name '*.gpkg.tar' 2>/dev/null | LC_ALL=C sort)
  printf 'gpkg %s: %s pairs, %s with hard findings\n' "$leg" "$n_pairs" "$n_hard" | tee -a "$OUT/gpkg-$leg.txt"
  [ "$n_hard" = 0 ] && pass "gpkg $leg clean ($n_pairs pairs)" || fail "gpkg $leg: $n_hard/$n_pairs pairs hard"
  return 0
}

if [ "$SKIP_REF" = 0 ]; then
  if [ -n "$LEG_A_DIR" ]; then
    ref_side "a-nopy" "$TEST_DIR/atomlists/z326-nopy.txt" "$LOGS_DIR/_z326-pkgcache-nopy" "ref-nopy"
    compare_side "a-nopy" "$LEG_A_DIR" "ref-nopy" "z326-nopy"
    gpkg_side "a-nopy" "$LEG_A_DIR" "$LOGS_DIR/_z326-pkgcache-nopy"
  else note "--- ref/compare a-nopy skipped"; fi
  if [ -n "$LEG_B_DIR" ]; then
    ref_side "b-noportage" "$TEST_DIR/atomlists/l1-merge-gate.txt" "$LOGS_DIR/_z326-pkgcache-noportage" "ref-noportage"
    compare_side "b-noportage" "$LEG_B_DIR" "ref-noportage" "z326-noportage"
    gpkg_side "b-noportage" "$LEG_B_DIR" "$LOGS_DIR/_z326-pkgcache-noportage"
  else note "--- ref/compare b-noportage skipped"; fi
else note "--- leg (c) skipped"; fi

# --- [gate] ---------------------------------------------------------------
if [ "$SKIP_GATE" = 0 ]; then
  note "--- [gate] l1-merge-from-binpkg on the gate list"
  set +e
  "$HERE/l1-merge-from-binpkg.sh" "$TEST_DIR/atomlists/l1-merge-gate.txt" 2>&1 | tee "$OUT/gate-console.log"
  rc=${PIPESTATUS[0]}
  set -e
  [ "$rc" = 0 ] && pass "[gate] green ($(readlink "$LOGS_DIR/l1-latest"))" || fail "[gate] rc=$rc"
  note "--- [gate] reinstall cell (L1_SKIP_BUILD=1 L1_CONSUME_REINSTALL=1)"
  set +e
  L1_SKIP_BUILD=1 L1_CONSUME_REINSTALL=1 \
    "$HERE/l1-merge-from-binpkg.sh" "$TEST_DIR/atomlists/l1-merge-gate.txt" 2>&1 | tee "$OUT/gate-reinstall-console.log"
  rc=${PIPESTATUS[0]}
  set -e
  [ "$rc" = 0 ] && pass "[gate reinstall] green ($(readlink "$LOGS_DIR/l1-latest"))" || fail "[gate reinstall] rc=$rc"
else note "--- [gate] skipped"; fi

# --- l31b -----------------------------------------------------------------
if [ "$SKIP_L31B" = 0 ]; then
  note "--- l31b two-container cell (L31B_SKIP_BUILD=1)"
  set +e
  L31B_SKIP_BUILD=1 "$HERE/l31b-two-container.sh" 2>&1 | tee "$OUT/l31b-console.log"
  rc=${PIPESTATUS[0]}
  set -e
  [ "$rc" = 0 ] && pass "l31b green ($(readlink "$LOGS_DIR/l31b-latest"))" || fail "l31b rc=$rc"
else note "--- l31b skipped"; fi

ln -sfn "$RUN/z326-report.txt" "$LOGS_DIR/z326-report.txt"
note "=== z326 $RUN done (overall rc=$overall_rc): $OUT"
exit "$overall_rc"
