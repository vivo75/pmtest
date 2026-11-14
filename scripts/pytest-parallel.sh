#!/bin/bash
# Run the contract suite in parallel (pytest-xdist, 8 workers by default).
# Serial: ~630 s; -n 8: ~90 s on the 32-core build host, same 4206 passes.
# The xdist venv lives in /var/tmp (tmpfs: rebuilt after a reboot, ~10 s).
# Usage: scripts/pytest-parallel.sh [pytest args...]   (JOBS=16 to change -n)
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
venv=${PMTEST_XDIST_VENV:-/var/tmp/pxvenv}
if [ ! -x "$venv/bin/python" ] || ! "$venv/bin/python" -c 'import xdist' 2>/dev/null; then
  python3 -m venv --system-site-packages "$venv"
  "$venv/bin/pip" install -q pytest-xdist
fi
cd "$here"
# Space preflight: one full run leaves ~11 GB in the basetemp under /var/tmp
# (a 48 GB mount). Two or three stale runs fill it and the suite then fails
# with ENOSPC, not with a real test failure. Require 50% free on both mounts;
# override with PMTEST_MIN_FREE_PERCENT=40 for a deliberate small run.
min_free=${PMTEST_MIN_FREE_PERCENT:-50}
for mount in /tmp /var/tmp; do
    read -r total free < <(df -Pk "$mount" | awk 'NR==2 {print $2, $4}')
    if [ -n "${total:-}" ] && [ -n "${free:-}" ] &&
       [ $(( free * 100 / total )) -lt "$min_free" ]; then
        echo "pytest-parallel: $mount has only $(( free * 100 / total ))% free (need ${min_free}%)" >&2
        echo "  clean finished basetemps (never the one a live suite is using): see portuale/LLM/tools/check-work-space.sh" >&2
        exit 2
    fi
done
# Backlog #634: the basetemp may hold root-owned residue from an earlier
# run as root (a merge test chowns paths to root), which this user cannot
# remove -- pytest then dies with INTERNALERROR (rc 3) instead of running
# anything. Reclaim it up front like conftest's sudo reclaim does for its
# own default; if it cannot be reclaimed, say exactly that (with the fix)
# and exit 2 instead of letting pytest INTERNALERROR.
basetemp="${PMTEST_BASETEMP:-/var/tmp/pytest-parallel}"
prev=""
for arg in "$@"; do
    if [ -n "$prev" ]; then
        basetemp="$arg"
        prev=""
    fi
    case "$arg" in
        --basetemp=*) basetemp="${arg#--basetemp=}" ;;
        --basetemp) prev="yes" ;;
    esac
done
if [ -n "$basetemp" ] && [ "$basetemp" != "/" ] && [ -e "$basetemp" ]; then
    if ! rm -rf "$basetemp" 2>/dev/null && [ -e "$basetemp" ]; then
        echo "pytest-parallel: cannot reclaim basetemp '$basetemp' (root-owned residue from an earlier run as root?)" >&2
        echo "  fix with: sudo rm -rf '$basetemp'" >&2
        echo "  or point this run elsewhere: PMTEST_BASETEMP=<fresh-dir> scripts/pytest-parallel.sh ..." >&2
        exit 2
    fi
fi
exec "$venv/bin/python" -m pytest pytests-contract-suite -q -n "${JOBS:-8}" \
  --basetemp="${PMTEST_BASETEMP:-/var/tmp/pytest-parallel}" -p no:cacheprovider "$@"
