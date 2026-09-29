#!/bin/bash
# #182 proof: kill -9 the test process holding `loopback_sshd` and show the
# fixture's sshd dies with it (e6093eb: sshd -D + PR_SET_PDEATHSIG + kill/wait
# teardown). pgrep before / after, plus a leftover-container check.
set -u
cd "$(dirname "$0")/../.." || exit 2

echo "=== before ==="
date -u +%Y-%m-%dT%H:%M:%SZ
pgrep -a sshd || echo '(no sshd)'
echo "--- containers ---"
podman ps --format '{{.ID}} {{.Image}} {{.Names}}' || true

echo "=== start pytest (mrg_remote family starts the loopback_sshd fixture) ==="
python3 -m pytest pytests-contract-suite/test_portuale.py -k 'mrg_remote' -q \
  > /tmp/opencode/182-pytest.log 2>&1 &
PYT=$!
echo "pytest pid $PYT"

DEADMON=''
for _ in $(seq 1 300); do
  DEADMON=$(pgrep -f 'sshd.*loopback-sshd.*/sshd_config' | head -1 || true)
  [ -n "$DEADMON" ] && break
  kill -0 "$PYT" 2>/dev/null || break
  sleep 0.2
done
if [ -z "$DEADMON" ]; then
  echo "PROOF-FAIL: fixture sshd never appeared (pytest still running? $(kill -0 $PYT 2>/dev/null && echo yes || echo no))"
  tail -20 /tmp/opencode/182-pytest.log 2>/dev/null
  kill -9 "$PYT" 2>/dev/null
  exit 1
fi
echo "fixture sshd pid $DEADMON ($(ps -o args= -p "$DEADMON"))"

echo "=== kill -9 pytest ==="
kill -9 "$PYT" 2>/dev/null
sleep 2

echo "=== after ==="
date -u +%Y-%m-%dT%H:%M:%SZ
if kill -0 "$DEADMON" 2>/dev/null; then
  echo "PROOF-FAIL: fixture sshd $DEADMON survived kill -9 of pytest"
  pgrep -a sshd
  exit 1
fi
echo "fixture sshd $DEADMON is gone"
pgrep -a sshd || echo '(no sshd)'
echo "--- containers ---"
podman ps --format '{{.ID}} {{.Image}} {{.Names}}' || true
echo "PROOF-OK"
