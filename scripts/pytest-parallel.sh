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
# Space preflight (backlog #756, #762): one full run leaves ~11 GB and ~1.8 M
# inodes in the basetemp, and a 1 M-inode tmpfs such as /tmp dies with ENOSPC
# while gigabytes are free, which reads as a product regression. Two stale runs
# fill the 48 GB mount. Portuale's check-work-space.sh does both checks (50%
# free on /tmp and /var/tmp, free inodes on the basetemp's filesystem); this
# must stay after the basetemp is resolved above (argv wins over PMTEST_BASETEMP)
# and before the rm -rf below, so a refusal neither deletes the tree it protects
# nor creates anything. PMTEST_MIN_FREE_PERCENT=40 and PMTEST_MIN_BASETEMP_INODES=<n>
# lower the floors for a deliberate small run. (Not PMTEST_MIN_FREE_INODES:
# conftest owns that name for its own per-tmp-dir guard.)
checker="$here/../portuale/LLM/tools/check-work-space.sh"
if [ -f "$checker" ]; then
    if ! sh "$checker" --basetemp "$basetemp" "${PMTEST_MIN_FREE_PERCENT:-50}" >&2; then
        echo "pytest-parallel: not enough room for the basetemp '$basetemp' (see above)" >&2
        echo "  point it elsewhere: PMTEST_BASETEMP=/var/tmp/pytest-parallel or --basetemp=<dir>" >&2
        exit 2
    fi
else
    # pmtest checked out alone: the same two checks, minimal form.
    min_free=${PMTEST_MIN_FREE_PERCENT:-50}
    min_inodes=${PMTEST_MIN_BASETEMP_INODES:-2500000}
    case "$min_inodes" in
        ''|*[!0-9]*|0)
            echo "pytest-parallel: PMTEST_MIN_BASETEMP_INODES must be a positive integer (got '$min_inodes')" >&2
            exit 2
            ;;
    esac
    for mount in /tmp /var/tmp; do
        read -r total free < <(df -Pk "$mount" | awk 'NR==2 {print $2, $4}')
        if [ -n "${total:-}" ] && [ -n "${free:-}" ] &&
           [ $(( free * 100 / total )) -lt "$min_free" ]; then
            echo "pytest-parallel: $mount has only $(( free * 100 / total ))% free (need ${min_free}%)" >&2
            exit 2
        fi
    done
    anchor=$basetemp
    while [ -n "$anchor" ] && [ "$anchor" != "/" ] && [ ! -e "$anchor" ]; do
        anchor=$(dirname "$anchor")
    done
    read -r i_total i_free < <(df -Pi "$anchor" 2>/dev/null | awk 'NR==2 {print $2, $4}')
    if [ "${i_total:-}" = 0 ]; then
        echo "pytest-parallel: WARN '$anchor' reports 0 inodes (allocated on demand); inode check skipped" >&2
    elif [ -z "${i_total:-}" ] || [ "${i_free:-0}" -lt "$min_inodes" ]; then
        echo "pytest-parallel: basetemp '$basetemp' is on a filesystem with only ${i_free:-?} free inodes (need ${min_inodes})" >&2
        exit 2
    fi
fi
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
