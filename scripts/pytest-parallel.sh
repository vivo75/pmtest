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
exec "$venv/bin/python" -m pytest pytests-contract-suite -q -n "${JOBS:-8}" \
  --basetemp="${PMTEST_BASETEMP:-/var/tmp/pytest-parallel}" -p no:cacheprovider "$@"
