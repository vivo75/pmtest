#!/bin/bash
# L0 fixture-oracle bed, all thirteen atomlists in sequence (backlog #87).
#
# There are thirteen lists today (`atomlists/l0-fixture-oracle{,-host,-rdcpin,
# -slotop,-whpin,-r25,-g210,-g212,-g213,-g214,-g215,-g216,-244}.txt`) and six env knobs (`FX_SLOTOP_BDEP`, `FX_WORLD_EXTRA`,
# `FX_HOST_ROOTS`, `FX_HOST_RUNNING_ROOT` (backlog #242 Slice D: the main
# list resolves the running root against the container host, retiring
# `skipped-updates-cross-root-missed-line`), `FX_PRUNE_VDB`,
# `FX_SOUSAT_UNSAT`, declared at `run/l0-fixture-oracle.sh`'s call site and
# `layers/l0-fixture-oracle/in-container.sh`), and only the first list
# runs by default -- so #76 B3's and #79 D1's permanent cells are
# exercised only when a human remembers the exact `FX_*` invocation.
# This runner closes that gap: it runs all thirteen lists with their
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
  "l0-fixture-oracle.txt|FX_HOST_RUNNING_ROOT=1"
  "l0-fixture-oracle-host.txt|FX_HOST_ROOTS=1"
  "l0-fixture-oracle-rdcpin.txt|FX_WORLD_EXTRA=dev-libs/rdctarget"
  "l0-fixture-oracle-slotop.txt|FX_SLOTOP_BDEP=1 FX_HOST_ROOTS=1"
  "l0-fixture-oracle-whpin.txt|FX_WORLD_EXTRA=dev-libs/whtarget"
  "l0-fixture-oracle-r25.txt|FX_WORLD_EXTRA=dev-libs/r25consumer"
  "l0-fixture-oracle-g210.txt|FX_WORLD_EXTRA='dev-libs/reinstslotconsumer dev-libs/reinstslotbound'"
  "l0-fixture-oracle-g212.txt|"
  "l0-fixture-oracle-g213.txt|FX_PRUNE_VDB=1"
  "l0-fixture-oracle-g214.txt|FX_WORLD_EXTRA='app-misc/abicons app-misc/abiforce'"
  "l0-fixture-oracle-g215.txt|FX_SOUSAT_UNSAT=1 FX_HOST_ROOTS=1"
  "l0-fixture-oracle-g216.txt|FX_HOST_RUNNING_ROOT=1"
  "l0-fixture-oracle-244.txt|"
)

failures=0
ran=0
for spec in "${LISTS[@]}"; do
  list="${spec%%|*}"
  knobs="${spec#*|}"
  echo ">>> fixture-oracle-all: $list${knobs:+ ($knobs)}"
  if [ -n "$knobs" ]; then
    # shellcheck disable=SC2086
    eval "env $knobs \"\$HERE/l0-fixture-oracle.sh\" \"\$HERE/../atomlists/\$list\""
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
