#!/bin/bash
# L1 direct-path cell for backlog #349 S4 (`ebuild` reads its configuration).
#
# No bed script drives `portuale ebuild ... merge`, so the L1 gate
# (`l1-merge-from-binpkg.sh`, an `emerge`-flow binary merge) does not
# exercise the code S4 changes: the direct path's `PORTAGE_TMPDIR` /
# `DISTDIR` / `FEATURES` resolution (plus the `binpkg-multi-instance`
# layout) under the container's stock `make.globals`. This cell runs a
# real `portuale ebuild ... merge` of dos2unix (a small package with IUSE=test, which the image's install-QA hook needs on the direct path) with
# that stock config, next to an identical Portage `ebuild ... merge`,
# and records both (rc, installed vdb entry, builddir location).
#
#   differential-test-bed/run/l1-ebuild-direct.sh
#
# Env: PORTTEST_IMAGE (like every other run script). Read-only on the
# host tree except the log dir. Exit 0 when both PMs merge rc 0 with
# the same installed version, 1 on any divergence, 2 on setup error.

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/lib.sh"

ensure_pm_built "$LOGS_DIR/l1-ebuild-direct-preflight"
ensure_image
pm_mounts

RUN="l1-ebuild-direct-$(timestamp)"
OUT="$LOGS_DIR/$RUN"
mkdir -p "$OUT"
ln -sfn "$RUN" "$LOGS_DIR/l1-ebuild-direct-latest"

# The newest stable-looking (no -9999, _alpha, _beta, _pre, _rc) dos2unix ebuild in the container's stock gentoo repo (same
# selection rule on both sides, resolved inside the container so the
# host never guesses a version).
pick_and_merge() {  # pm
  local pm=$1 driver
  if [ "$pm" = portage ]; then
    driver="ebuild"
  else
    driver="/usr/local/bin/portuale ebuild"
  fi
  podman_run_pm "porttest-l1-ebuild-direct-$pm-$$" \
    --entrypoint /bin/bash "$IMAGE" \
    -c "
      set -u
      ebuild_file=\$(ls /var/db/repos/gentoo/app-text/dos2unix/dos2unix-*.ebuild 2>/dev/null | grep -vE '9999|_alpha|_beta|_pre|_rc' | sort -V | tail -1)
      [ -n \"\$ebuild_file\" ] || { echo '!!! no dos2unix ebuild in the stock repo' >&2; exit 2; }
      echo \">>> \$ebuild_file\"
      $driver \"\$ebuild_file\" merge
      rc=\$?
      echo \">>> rc=\$rc\"
      ls -d /var/db/pkg/app-text/dos2unix-* 2>/dev/null
      find /var/tmp/portage/app-text -maxdepth 1 2>/dev/null || true
      exit \$rc
    " >"$OUT/$pm.log" 2>&1
  echo "$?"
}

portage_rc=$(pick_and_merge portage) || true
portuale_rc=$(pick_and_merge portuale) || true

{
  echo "portage_rc=$portage_rc"
  echo "portuale_rc=$portuale_rc"
  echo "--- portage vdb ---"
  grep -h "app-text/dos2unix-" "$OUT/portage.log" || true
  echo "--- portuale vdb ---"
  grep -h "app-text/dos2unix-" "$OUT/portuale.log" || true
} >"$OUT/l1-ebuild-direct-report.txt"

if [ "$portage_rc" != 0 ] || [ "$portuale_rc" != 0 ]; then
  echo ">>> DIVERGENCE: portage rc=$portage_rc portuale rc=$portuale_rc (see $OUT/)"
  exit 1
fi
# Same installed version on both sides (the last `ls` line of each log).
if ! diff <(grep -o "app-text/dos2unix-[^ ]*" "$OUT/portage.log" | sort -u) \
          <(grep -o "app-text/dos2unix-[^ ]*" "$OUT/portuale.log" | sort -u) \
          >>"$OUT/l1-ebuild-direct-report.txt"; then
  echo ">>> DIVERGENCE: installed dos2unix differs (see $OUT/)"
  exit 1
fi
echo ">>> green: both PMs merged the same dos2unix, rc 0 (see $OUT/)"
