#!/bin/bash
# L0 fixture-oracle bed, all four atomlists in sequence (backlog #87).
#
# There are four lists today (`atomlists/l0-fixture-oracle{,-host,-rdcpin,
# -slotop}.txt`) and three env knobs (`FX_SLOTOP_BDEP`, `FX_WORLD_EXTRA`,
# `FX_HOST_ROOTS`, declared at `run/l0-fixture-oracle.sh`'s call site and
# `layers/l0-fixture-oracle/in-container.sh:84`), and only the first list
# runs by default -- so #76 B3's and #79 D1's permanent cells are
# exercised only when a human remembers the exact `FX_*` invocation.
# This runner closes that gap: it runs all four lists with their
# documented knobs, one after the other, and reports a combined rc.
# Everything after #87 in the Tier 2 close-out uses this as the standard
# bed step.
#
# Each list keeps its own log dir (`logs/l0-fx-<timestamp>-<list>/`), so
# an existing single-list invocation stays reproducible by path.
#
# Env: PORTTEST_IMAGE, PORTTEST_PODMAN (as for l0-fixture-oracle.sh).
# Exit: 0 when every list is green, 1 when any list reports unexplained
# findings, 2 on setup error.

set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# list-file-name | env assignments (quoted for eval)
LISTS=(
  "l0-fixture-oracle.txt|"
  "l0-fixture-oracle-host.txt|FX_HOST_ROOTS=1"
  "l0-fixture-oracle-rdcpin.txt|FX_WORLD_EXTRA=dev-libs/rdctarget"
  "l0-fixture-oracle-slotop.txt|FX_SLOTOP_BDEP=1 FX_HOST_ROOTS=1"
)

failures=0
ran=0
for spec in "${LISTS[@]}"; do
  list="${spec%%|*}"
  knobs="${spec#*|}"
  echo ">>> fixture-oracle-all: $list${knobs:+ ($knobs)}"
  if [ -n "$knobs" ]; then
    # shellcheck disable=SC2086
    env $knobs "$HERE/l0-fixture-oracle.sh" "$HERE/../atomlists/$list"
  else
    "$HERE/l0-fixture-oracle.sh" "$HERE/../atomlists/$list"
  fi
  rc=$?
  ran=$((ran + 1))
  if [ $rc -ne 0 ]; then
    echo ">>> fixture-oracle-all: $list FAILED (rc=$rc)"
    failures=$((failures + 1))
  else
    echo ">>> fixture-oracle-all: $list green"
  fi
done

echo ">>> fixture-oracle-all: $((ran - failures))/$ran lists green"
[ "$failures" -eq 0 ]
