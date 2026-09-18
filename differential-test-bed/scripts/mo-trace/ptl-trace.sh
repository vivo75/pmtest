#!/bin/bash
# Run portuale's emerge with PORTUALE_MO_SEL=1 and split the merge-order
# trace into its own file -- the portuale half of the harness described
# in differential-test-bed/scripts/mo-trace/README.md.
#
#   ptl-trace.sh OUT-PREFIX [--] <emerge args...>
#
# Writes:
#   OUT-PREFIX.portuale.out   stdout
#   OUT-PREFIX.portuale.err   stderr (includes the MO_SEL lines)
#   OUT-PREFIX.portuale.trace just the MO_SEL lines (align-traces input)
#
# Env: PORTUALE_BIN overrides the binary (default: the `emerge` applet of
# the PM selected by $PMTEST_PM in managers/managers.yaml). PORTUALE_MO_SEL
# is forced on.

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: ptl-trace.sh OUT-PREFIX [--] <emerge args...>" >&2
    exit 2
fi

OUT=$1
shift
[ "${1:-}" = "--" ] && shift

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$HERE/../../.." && pwd)
if [ -n "${PORTUALE_BIN:-}" ]; then
    BIN=$PORTUALE_BIN
else
    pm_env=$(python3 "$REPO_ROOT/managers/registry.py" --sh --no-build) || {
        echo "ptl-trace: cannot resolve the PM under test (PMTEST_PM=${PMTEST_PM:-portuale})" >&2
        exit 2
    }
    eval "$pm_env"
    BIN="$PM_BIN_DIR/emerge"
fi

if [ ! -x "$BIN" ]; then
    echo "ptl-trace: no executable at $BIN (run a differential-test-bed/run/l*.sh once, or build the PM)" >&2
    exit 2
fi

PORTUALE_MO_SEL=1 "$BIN" "$@" >"$OUT.portuale.out" 2>"$OUT.portuale.err"
rc=$?
grep '^MO_SEL ' "$OUT.portuale.err" >"$OUT.portuale.trace" || true
echo "ptl-trace: rc=$rc  $(wc -l <"$OUT.portuale.trace") MO_SEL lines -> $OUT.portuale.trace"
exit $rc
