#!/bin/bash
# L31 -- the remote-merge bed (#31). Smallest bed that runs:
#
#   control   -- merge one $PKGDIR with REAL Portage into two fresh
#                container ROOTs (portage-vs-portage). Normalise + diff
#                with compare/ helpers and NO allowlist: the control pair
#                must be 0 unexplained -- that is S1's gate and S2's noise
#                floor.
#   candidate -- the reference side stays real Portage; the other side
#                merges the same gpkgs through `mrg --remote-*` over the R9
#                loopback-sshd stand-in into a far ROOT inside its
#                container (layers/l31/consume-remote.sh). S1 only proves
#                the harness executes: every candidate diff is recorded and
#                NOT triaged (S2 does that).
#
# Mirrors run/l1-merge-from-binpkg.sh's shape (same lib.sh helpers, same
# build/consume staging, same compare/ invocations, no new diff semantics).
#
#   differential-test-bed/run/l31-remote-merge.sh [atomlist]
#
# Env: PORTTEST_IMAGE, PORTTEST_PODMAN,
#      L31_MODE=control|candidate   (default control),
#      L31_SKIP_BUILD=1             (reuse the pkgcache as-is),
#      L31_REBUILD=1                (wipe the pkgcache first),
#      L31_JOBS                     (MAKEOPTS -j, default 4),
#      L1_SKIP_PORTAGE_UPGRADE=1    (escape hatch: do NOT move to the pin)
#
# Exit: 0 green, 1 unexplained divergence, 2 setup error.

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/lib.sh"

ATOMLIST=$(realpath -e "${1:-$TEST_DIR/atomlists/l31-s0.txt}" 2>/dev/null) \
  || { echo "atom list not found" >&2; exit 2; }
case $ATOMLIST in
  "$TEST_DIR"/*) REL_ATOMLIST="/TEST/${ATOMLIST#"$TEST_DIR"/}" ;;
  *) echo "atom list must live under $TEST_DIR/" >&2; exit 2 ;;
esac

MODE=${L31_MODE:-control}
case $MODE in control|candidate) ;; *) echo "L31_MODE must be control|candidate" >&2; exit 2 ;; esac

PKGCACHE="$LOGS_DIR/_l31-pkgcache"
RUN="l31-$(timestamp)"
OUT="$LOGS_DIR/$RUN"
mkdir -p "$OUT" "$PKGCACHE"
ln -sfn "$RUN" "$LOGS_DIR/l31-latest"

ensure_pm_built "$OUT"
# Only the candidate side runs portuale's phase runtime (the control pair is
# portage-vs-portage and must not depend on portuale's gitignored checkout).
[ "$MODE" = candidate ] && portuale_phase_helpers_preflight
ensure_image

# The porttest synthetic overlay is live-mounted into every container
# (exactly like L1); both the real builder/consumer and mrg's staged repo
# see it.
PORTTEST_OVL="$TEST_DIR/images/overlay/porttest"
ovl_mount=()
[ -d "$PORTTEST_OVL/porttest" ] && ovl_mount=(-v "$PORTTEST_OVL:/porttest-overlay:ro")

# --- run header ---------------------------------------------------------
{
  echo "# L31 remote-merge bed run header"
  echo "run_id	$RUN"
  echo "mode	$MODE"
  echo "profile	release"
  echo "pm_under_test	$PM_NAME $PM_VERSION"
  echo "image	$IMAGE"
  echo "atomlist	$REL_ATOMLIST"
  echo "atomlist_sha256	$(sha256sum "$ATOMLIST" | cut -d' ' -f1)"
  echo "host_date_utc	$(date -u +%FT%TZ)"
  echo "## atomlist"
  sed 's/^/  /' "$ATOMLIST"
  echo "## df -h /home"
  df -h /home
  echo "## df -i /tmp"
  df -i /tmp
} > "$OUT/header.txt"
echo ">>> run $RUN (mode=$MODE) -> $OUT"

# --- build the gpkg set once with real Portage (cached) -----------------
[ "${L31_REBUILD:-0}" = 1 ] && { echo ">>> L31_REBUILD: wiping $PKGCACHE"; rm -rf "${PKGCACHE:?}"/*; }

if [ "${L31_SKIP_BUILD:-0}" != 1 ]; then
  echo ">>> building the set from source with Portage (pkgcache: $PKGCACHE)"
  "$PODMAN" run --rm --name "porttest-l31-build-$$" \
    --security-opt seccomp=unconfined --cgroups=enabled --cgroupns=private \
    -v "$TEST_DIR:/TEST:ro" -v "$PKGCACHE:/pkgs" "${ovl_mount[@]}" \
    -e PKGDIR=/pkgs \
    -e "L1_JOBS=${L31_JOBS:-4}" \
    -e "L1_SKIP_PORTAGE_UPGRADE=${L1_SKIP_PORTAGE_UPGRADE:-0}" \
    --entrypoint /bin/bash "$IMAGE" \
    /TEST/layers/l1/build.sh "$REL_ATOMLIST"
else
  echo ">>> L31_SKIP_BUILD: using $(find "$PKGCACHE" -name '*.gpkg.tar' | wc -l) cached binpkgs"
fi

# --- real-Portage consume (reference side of both modes) ----------------
consume_real() {  # <name> <container-out-prefix>
  echo ">>> merging with real Portage ($1)"
  podman_run_pm "porttest-l31-$1-$$" \
    -v "$PKGCACHE:/pkgs:ro" "${ovl_mount[@]}" \
    -e PKGDIR=/pkgs \
    -e "L1_SKIP_PORTAGE_UPGRADE=${L1_SKIP_PORTAGE_UPGRADE:-0}" \
    -e "L1_JOBS=${L31_JOBS:-4}" \
    --entrypoint /bin/bash "$IMAGE" \
    /TEST/layers/l1/consume.sh portage "$REL_ATOMLIST" "$2"
}

if [ "$MODE" = control ]; then
  consume_real "l31-control-a" "/TEST/logs/$RUN/control/portage-a" || { echo "!!! control side A failed" >&2; exit 2; }
  consume_real "l31-control-b" "/TEST/logs/$RUN/control/portage-b" || { echo "!!! control side B failed" >&2; exit 2; }
  PREFIX_A="$OUT/control/portage-a"
  PREFIX_B="$OUT/control/portage-b"
  LVL=control
else
  consume_real "l31-cand-portage" "/TEST/logs/$RUN/candidate/portage" || { echo "!!! candidate reference side failed" >&2; exit 2; }
  echo ">>> candidate side: mrg --remote-* over loopback sshd into a far ROOT"
  set +e
  podman_run_pm "porttest-l31-cand-mrg-$$" \
    -v "$PKGCACHE:/pkgs:ro" "${ovl_mount[@]}" \
    -e PKGDIR=/pkgs \
    --entrypoint /bin/bash "$IMAGE" \
    /TEST/layers/l31/consume-remote.sh "$REL_ATOMLIST" \
    "/TEST/logs/$RUN/candidate/mrg" "/"
  mrg_rc=$?
  set -e
  echo ">>> candidate container rc=$mrg_rc (harness execution; diffs below are recorded, not triaged)"
  PREFIX_A="$OUT/candidate/portage"
  PREFIX_B="$OUT/candidate/mrg"
  LVL=candidate
fi

# --- normalise + diff (no allowlist: control must be 0 unexplained) -----
echo ">>> normalising ($LVL)"
python3 "$TEST_DIR/compare/normalize.py" "$PREFIX_A"
python3 "$TEST_DIR/compare/normalize.py" "$PREFIX_B"

echo ">>> diffing ($LVL; no known-divergences allowlist in S1)"
set +e
python3 "$TEST_DIR/compare/diff.py" --layer l31 "$PREFIX_A" "$PREFIX_B" \
  | tee "$OUT/l31-report.txt"
rc=${PIPESTATUS[0]}
set -e

# --- post-run header facts ---------------------------------------------
{
  echo "## portage versions (both sides)"
  for side in A:"$PREFIX_A" B:"$PREFIX_B"; do
    label=${side%%:*}; prefix=${side#*:}
    ver=$(grep -h '^portage_version' "$prefix.meta.tsv" 2>/dev/null | cut -f2- || true)
    echo "$label	${ver:-unknown}"
  done
  # The candidate container's rc = the worst per-atom `mrg` rc (consumed
  # via `exit "$worst"` in consume-remote.sh); the per-atom split is in
  # candidate/mrg.mrg-rcs.tsv. S1 review: the old label always read 0.
  [ "$MODE" = candidate ] && echo "candidate_container_rc	$mrg_rc"
} >> "$OUT/header.txt"

ln -sfn "$RUN/l31-report.txt" "$LOGS_DIR/l31-report.txt"
echo ">>> report: $OUT/l31-report.txt   (mode=$MODE rc=$rc)"
exit "$rc"
