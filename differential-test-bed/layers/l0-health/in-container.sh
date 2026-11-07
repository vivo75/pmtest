#!/bin/bash
# L0 health, in-container half: portuale only, no Portage arm.
#
# Plans every entry of an atom list (plus the L0 whole-graph runs) with
# `emerge -pv --json` and checks each plan with health_checker.py against
# this container's own VDB, which the host cannot see.
#
#   in-container.sh /TEST/atomlists/l0-resolve.txt /TEST/logs/<run>

set -u
ATOMLIST=${1:?atom list path}
OUTDIR=${2:?output dir}
PTL=/usr/local/bin/emerge
export PORTAGE_CONFIGROOT=/ ROOT=/ LC_ALL=C.UTF-8 TZ=UTC
mkdir -p "$OUTDIR/plans"
: > "$OUTDIR/meta.tsv"   # label \t exit code

# The same @world seed as layers/l0/in-container.sh, so @world means the same.
printf '%s\n' app-misc/tmux app-portage/eix app-portage/gentoolkit dev-libs/blake3 \
  > /var/lib/portage/world

slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' ; }
probe() {  # label, emerge args
  local label=$1; shift
  timeout 1200 "$PTL" "$@" --color=n --json \
    > "$OUTDIR/plans/$label.json" 2> "$OUTDIR/plans/$label.stderr"
  printf '%s\t%s\n' "$label" "$?" >> "$OUTDIR/meta.tsv"
  echo "  $label (rc=$(tail -n1 "$OUTDIR/meta.tsv" | cut -f2))"
}

while IFS= read -r line || [ -n "$line" ]; do
  line=${line%%#*}; line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$line" ] && probe "$(slug "$line")" -pv "$line"
done < "$ATOMLIST"
probe MULTI_emptytree-system -pve @system
probe MULTI_deep-update-world -puvD @world
probe MULTI_depclean -pvc

python3 /HC/health_checker.py --vdb /var/db/pkg "$OUTDIR"/plans/*.json > "$OUTDIR/health.jsonl"
echo "health checker rc=$?"
