#!/bin/bash
# L2 on VMs -- portuale as builder: both PMs build the atom list from
# source (`--buildpkgonly`) in their own throwaway guests, archives are
# structurally validated and diffed on the host, then the cross-install
# triplet (ref/cand/ctrl) merges into fresh guests and snapshots are
# diffed. Same grading as run/l2-portuale-builder.sh; reports l2-vm-*.
#
#   differential-test-bed/run/l2-portuale-builder-vm.sh [atomlist]
#
# Env: L2_MODE=strict|payload-tolerant (default strict),
#      L2_REBUILD=1, L2_SKIP_BUILD=1, L2_JOBS, L2_SKIP_PORTAGE_UPGRADE,
#      L2_BUILD_MODE, L2_CACHELESS, L2_STALECACHE, L2_KEEP_UNKNOWN,
#      VM_FS (default xfs), PMTEST_PM (registry).
#
# Exit: 0 green, 1 unexplained finding(s), 2 setup error.

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

MODE=${L2_MODE:-strict}
case $MODE in strict|payload-tolerant) ;; *) echo "L2_MODE must be strict|payload-tolerant" >&2; exit 2 ;; esac

VM_FS=${VM_FS:-xfs}
case $VM_FS in xfs|ext4|btrfs) ;; *) echo "VM_FS must be xfs|ext4|btrfs" >&2; exit 2 ;; esac
echo ">>> guest filesystem: $VM_FS"

# Backend-private pkgcaches AND distfiles (provenance per backend, F4;
# the shared container path accumulates root-owned files no VM-side
# pull can overwrite).
PKG_PORTAGE="$LOGS_DIR/_l2-pkgcache-portage-vm"
PKG_PORTUALE="$LOGS_DIR/_l2-pkgcache-portuale-vm"
DISTFILES=${L2_DISTFILES:-$LOGS_DIR/_l2-distfiles-vm}
RUN="l2-vm-$(timestamp)"
OUT="$LOGS_DIR/$RUN"
mkdir -p "$OUT" "$PKG_PORTAGE" "$PKG_PORTUALE" "$DISTFILES"
ln -sfn "$RUN" "$LOGS_DIR/l2-vm-latest"

ensure_pm_built "$OUT"

CURRENT_LABEL=""
cleanup() { [ -n "$CURRENT_LABEL" ] && vm_teardown "$CURRENT_LABEL"; true; }
trap cleanup EXIT

[ "${L2_REBUILD:-0}" = 1 ] && { echo ">>> L2_REBUILD: wiping the pkgcaches"; rm -rf "${PKG_PORTAGE:?}"/* "${PKG_PORTUALE:?}"/*; }

PORTTEST_OVL="$TEST_DIR/images/overlay/porttest"
NEED_OVL=0
[ -d "$PORTTEST_OVL/porttest" ] && grep -q '^porttest/' "$ATOMLIST" && NEED_OVL=1

UNEXPLAINED=0
KNOWN_HITS=0

# finding lines that are a filed portuale producer gap, not a regression
# (ids match differential-test-bed/findings/l2.md; delete an entry when its gap is fixed).
KNOWN_FINDINGS=(
  # `porttest/setuid`'s three byte-identical binaries share one build-id;
  # which name the shared `.build-id/e0/2277…` links target depends on
  # `estrip`'s `___parallel` traversal order. Real disagrees with itself
  # (oracle `pt-setuid`, a later real L2 build `pt-sticky`), so this one
  # link pair is the only ungradable row (#38 S0/S2).
  "l2-gpkg-dostrip-splitdebug|usr/lib/debug/\.build-id/e0/2277.*: a=.*b="
  # Portuale never tracks repo revisions (`PORTAGE_REPO_REVISIONS` is
  # `"{}"` until it does -- emerge_build.rs documents it), while real
  # fills them via git retrieve_head whenever git exists. The VM golden
  # has git (needed for repo clones); the container image has none, so
  # real writes `{}` there too and the pair matches. Filed in
  # vm/FINDINGS.md (L1 section); delete when portuale tracks revisions.
  # Tradeoff, stated plainly: the environment.bz2 row masks on the file
  # name only, so a FUTURE unrelated env delta would hide behind this
  # entry too -- re-tighten (match on content) when the gap is fixed.
  "l2-vm-repo-revisions|metadata/REPO_REVISIONS differs"
  "l2-vm-repo-revisions-env|metadata/environment\.bz2 differs"
)

classify_file() {  # <label> <findings-file>
  local label=$1 f=$2 line id kid pat
  [ -s "$f" ] || return 0
  while IFS= read -r line; do
    case $line in
      "[UNEXPLAINED]"*|"gpkg-diff:"*|"gpkg-structure"*) continue ;;
      "[outer-name]"*|"[payload]"*) continue ;;   # informational (soft)
    esac
    case $line in
      "["*) : ;; *) continue ;;
    esac
    id=""
    for k in "${KNOWN_FINDINGS[@]}"; do
      kid=${k%%|*}; pat=${k#*|}
      if printf '%s\n' "$line" | grep -qE "$pat"; then id=$kid; break; fi
    done
    if [ -n "$id" ]; then
      echo "[known:$id] $label: $line" >> "$OUT/classification.txt"
      KNOWN_HITS=$((KNOWN_HITS + 1))
    else
      echo "[UNEXPLAINED] $label: $line" >> "$OUT/classification.txt"
      UNEXPLAINED=$((UNEXPLAINED + 1))
    fi
  done < <(grep -E '^\[' "$f" || true)
}
: > "$OUT/classification.txt"

# --- build ---------------------------------------------------------------
# One fresh guest per builder; the shared DISTFILES round-trips through
# the host (push before, pull after) so the second builder reuses the
# first builder's downloads exactly like the shared container mount.
build_one() {  # <label> <build-portage.sh|build-portuale.sh> <host-pkgcache>
  local label=$1 script=$2 cache=$3 ip
  CURRENT_LABEL="$label"
  ip=$(vm_run_boot "$label")
  vm_share_pm "$label"
  [ "$NEED_OVL" = 1 ] && vm_push "$ip" "$PORTTEST_OVL/." /porttest-overlay
  vm_push_pm "$ip"
  vm_push_test "$ip"
  vm_mount_pm "$ip"
  vm_push "$ip" "$DISTFILES/." /distfiles
  set -o pipefail
  vm_ssh "$ip" \
    "PKGDIR=/pkgs" "DISTDIR=/distfiles" \
    "L2_JOBS=${L2_JOBS:-1}" \
    "L2_SKIP_PORTAGE_UPGRADE=${L2_SKIP_PORTAGE_UPGRADE:-0}" \
    "L2_PORTAGE_PIN=${L2_PORTAGE_PIN:-3.0.82.2}" \
    "L2_BUILD_MODE=${L2_BUILD_MODE:-bpkgonly}" \
    "L2_CACHELESS=${L2_CACHELESS:-0}" \
    "L2_STALECACHE=${L2_STALECACHE:-0}" \
    "/TEST/layers/l2/$script" "$REL_ATOMLIST" 2>&1 | tee "$OUT/build-$label.log"
  set +o pipefail
  rm -rf "${cache:?}"/*
  vm_pull "$ip" /pkgs "$cache"
  vm_pull "$ip" /distfiles "$DISTFILES"
  vm_teardown "$label"
  CURRENT_LABEL=""
  echo ">>> cached $(find "$cache" -name '*.gpkg.tar' | wc -l) archives in $cache"
}

if [ "${L2_SKIP_BUILD:-0}" != 1 ]; then
  echo ">>> building the set with Portage (archive-only)"
  build_one "porttest-l2-vm-build-portage-$$" build-portage.sh "$PKG_PORTAGE"
  echo ">>> building the set with portuale (archive-only)"
  build_one "porttest-l2-vm-build-portuale-$$" build-portuale.sh "$PKG_PORTUALE"
else
  echo ">>> L2_SKIP_BUILD: reusing $(find "$PKG_PORTAGE" -name '*.gpkg.tar' | wc -l) portage + $(find "$PKG_PORTUALE" -name '*.gpkg.tar' | wc -l) portuale archives"
fi

# --- structural validation ----------------------------------------------
echo ">>> gpkg-structure over both pkgdirs"
set +e
"$TEST_DIR/compare/gpkg-structure.sh" --dir "$PKG_PORTAGE" --packages > "$OUT/structure-portage.txt" 2>&1
rc_p=$?
"$TEST_DIR/compare/gpkg-structure.sh" --dir "$PKG_PORTUALE" --packages > "$OUT/structure-portuale.txt" 2>&1
rc_u=$?
set -e
classify_file "structure-portage" "$OUT/structure-portage.txt"
classify_file "structure-portuale" "$OUT/structure-portuale.txt"

# --- archive-vs-archive pairs -------------------------------------------
echo ">>> gpkg-diff portage-built vs portuale-built per atom"
: > "$OUT/archive-diffs.txt"
while IFS= read -r line || [ -n "$line" ]; do
  atom=${line%%#*}; atom=$(printf '%s' "$atom" | tr -d '[:space:]')
  [ -n "$atom" ] || continue
  cat=${atom%%/*}; pn=${atom#*/}
  a=$(find "$PKG_PORTAGE/$cat" -name "$pn-*.gpkg.tar" 2>/dev/null | LC_ALL=C sort | head -1 || true)
  b=$(find "$PKG_PORTUALE/$cat" -name "$pn-*.gpkg.tar" 2>/dev/null | LC_ALL=C sort | head -1 || true)
  pair_out="$OUT/archive-$cat-$pn.txt"
  {
    echo "### $atom"
    echo "portage : ${a:-MISSING}"
    echo "portuale: ${b:-MISSING}"
  } > "$pair_out"
  if [ -n "$a" ] && [ -n "$b" ]; then
    set +e
    "$TEST_DIR/compare/gpkg-diff.sh" --mode "$MODE" "$a" "$b" >> "$pair_out" 2>&1
    set -e
    cat "$pair_out" >> "$OUT/archive-diffs.txt"
    classify_file "archive-diff:$atom" "$pair_out"
  else
    echo "[UNEXPLAINED] archive-diff:$atom: archive missing (portage='$a' portuale='$b')" >> "$OUT/classification.txt"
    UNEXPLAINED=$((UNEXPLAINED + 1))
  fi
done < "$ATOMLIST"

# --- cross-install ------------------------------------------------------
consume() {  # <label> <pkgdir> <portage|portuale>
  local label=$1 pkgdir=$2 pm=$3 ip
  CURRENT_LABEL="porttest-l2-vm-$label-$$"
  echo ">>> cross-install $label: $pm merges $(basename "$pkgdir")"
  ip=$(vm_run_boot "$CURRENT_LABEL")
  vm_share_pm "$CURRENT_LABEL"
  vm_push_pm "$ip"
  vm_push_test "$ip"
  vm_mount_pm "$ip"
  vm_push "$ip" "$pkgdir/." /pkgs
  vm_ssh "$ip" \
    "PKGDIR=/pkgs" \
    "L1_SKIP_PORTAGE_UPGRADE=${L2_SKIP_PORTAGE_UPGRADE:-0}" \
    /TEST/layers/l1/consume.sh "$pm" "$REL_ATOMLIST" "/TEST/logs/$RUN/$label"
  vm_pull_prefix "$ip" "/TEST/logs/$RUN/$label" "$OUT"
  vm_teardown "$CURRENT_LABEL"
  CURRENT_LABEL=""
}
consume ref  "$PKG_PORTAGE"  portage
consume cand "$PKG_PORTUALE" portage
consume ctrl "$PKG_PORTAGE"  portuale

echo ">>> normalising (fs=$VM_FS)"
for d in ref cand ctrl; do python3 "$TEST_DIR/compare/normalize.py" "$OUT/$d" >/dev/null; done

TOL=()
[ "$MODE" = payload-tolerant ] && TOL=(--tolerate-payload)
echo ">>> diffing ref vs cand"
set +e
python3 "$TEST_DIR/compare/diff.py" --layer l2 --backend vm --fs "$VM_FS" "${TOL[@]}" \
  "$OUT/ref" "$OUT/cand" "$TEST_DIR/compare/known-divergences.yaml" \
  | tee "$OUT/cross-install.txt"
rc_diff=${PIPESTATUS[0]}
set -e
echo ">>> control diff (portuale consumes the portage-built set)"
set +e
python3 "$TEST_DIR/compare/diff.py" --layer l2 --backend vm --fs "$VM_FS" "${TOL[@]}" \
  "$OUT/ref" "$OUT/ctrl" "$TEST_DIR/compare/known-divergences.yaml" \
  > "$OUT/control.txt" 2>&1
rc_ctrl=$?
set -e

# --- report --------------------------------------------------------------
{
  echo "# L2 report -- portuale as builder (VM bed, fs=$VM_FS)"
  echo
  echo "atoms   : $REL_ATOMLIST"
  echo "mode    : $MODE"
  echo "dates   : $(date -u +%FT%TZ)"
  echo "portage : $PKG_PORTAGE ($(find "$PKG_PORTAGE" -name '*.gpkg.tar' | wc -l) archives)"
  echo "portuale: $PKG_PORTUALE ($(find "$PKG_PORTUALE" -name '*.gpkg.tar' | wc -l) archives)"
  echo
  echo "## structure"
  echo "  portage findings : $(grep -cE '^\[' "$OUT/structure-portage.txt" || true)"
  echo "  portuale findings: $(grep -cE '^\[' "$OUT/structure-portuale.txt" || true)"
  echo
  echo "## archive diffs (portage-built vs portuale-built)"
  grep -E '^gpkg-diff:' "$OUT/archive-diffs.txt" || true
  echo
  echo "## cross-install (real Portage merges portuale-built)"
  sed -n '/^## summary/,/^$/p' "$OUT/cross-install.txt"
  echo "## control (portuale merges portage-built)"
  sed -n '/^## summary/,/^$/p' "$OUT/control.txt"
  echo
  echo "## classification"
  echo "  known (filed portuale producer gaps): $KNOWN_HITS"
  echo "  UNEXPLAINED                         : $UNEXPLAINED"
  echo "  cross-install diff rc               : $rc_diff"
  echo "  control diff rc                     : $rc_ctrl"
  echo
  if [ "$UNEXPLAINED" -gt 0 ]; then
    echo "## unexplained findings"
    grep '^\[UNEXPLAINED\]' "$OUT/classification.txt" || true
    echo
  fi
  if [ "$KNOWN_HITS" -gt 0 ]; then
    echo "## known findings (adjudicated, see differential-test-bed/findings/l2.md)"
    grep '^\[known:' "$OUT/classification.txt" | sort | uniq -c | sort -rn || true
    echo
  fi
} > "$OUT/l2-report.txt"
ln -sfn "$RUN/l2-report.txt" "$LOGS_DIR/l2-vm-report.txt"
trap - EXIT

cat "$OUT/l2-report.txt"
rc=0
[ "$UNEXPLAINED" = 0 ] || rc=1
[ "$rc_diff" = 0 ] || rc=1
[ "$rc_ctrl" = 0 ] || rc=1
echo ">>> report: $OUT/l2-report.txt   (rc=$rc)"
exit "$rc"
