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
# Backlog #756: the basetemp needs ~1.8 M inodes for a complete run (measured
# 2026-11-15: 1 804 465 for 4967 tests). A 1 M-inode tmpfs such as /tmp dies
# with ENOSPC while gigabytes are free, which reads as a product regression.
# This check must stay after the basetemp is resolved above (argv wins over
# PMTEST_BASETEMP) and before the rm -rf below, so a refusal neither deletes
# the tree it protects nor creates anything. PMTEST_MIN_BASETEMP_INODES lowers
# the floor for a deliberate small run, like PMTEST_MIN_FREE_PERCENT does for
# space. (Not PMTEST_MIN_FREE_INODES: conftest owns that name for its own
# per-tmp-dir guard, with a different default -- two knobs, two names, and a
# value that is not a positive integer is refused rather than silently ignored.)
min_inodes=${PMTEST_MIN_BASETEMP_INODES:-2500000}
case "$min_inodes" in
    ''|*[!0-9]*)
        echo "pytest-parallel: PMTEST_MIN_BASETEMP_INODES must be a positive integer (got '$min_inodes')" >&2
        exit 2
        ;;
esac
if [ "$min_inodes" -le 0 ]; then
    echo "pytest-parallel: PMTEST_MIN_BASETEMP_INODES must be greater than 0 (got $min_inodes)" >&2
    exit 2
fi
anchor=$basetemp
while [ -n "$anchor" ] && [ "$anchor" != "/" ] && [ ! -e "$anchor" ]; do
    anchor=$(dirname "$anchor")
done
inode_stats=$(df -Pi "$anchor" 2>/dev/null | awk 'NR==2 {print $2" "$4}')
i_total=${inode_stats%% *}
i_free=${inode_stats##* }
if [ -z "${i_total:-}" ] || [ "${i_total:-0}" -eq 0 ]; then
    echo "pytest-parallel: cannot read inode counts for '$anchor' (0 or unknown); refusing to guess" >&2
    exit 2
fi
if [ "${i_free}" -lt "${min_inodes}" ]; then
    echo "pytest-parallel: basetemp '$basetemp' is on a filesystem with only ${i_free} free inodes (need ${min_inodes})" >&2
    echo "  a complete run needs ~1.8 M inodes (backlog #756); a 1 M-inode tmpfs like /tmp cannot hold one" >&2
    echo "  point it elsewhere: PMTEST_BASETEMP=/var/tmp/pytest-parallel or --basetemp=<dir>" >&2
    echo "  deliberate small run? PMTEST_MIN_BASETEMP_INODES=<n> lowers the floor" >&2
    exit 2
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
