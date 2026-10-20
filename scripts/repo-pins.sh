#!/bin/bash
# Print the current gentoo/buildovl versions; --write refreshes the pin file,
# --check (default) exits 1 when the repos differ from differential-test-bed/repo-pins.txt.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
pin=$here/differential-test-bed/repo-pins.txt
root=${GENTOO_REPOS:-/.gentoo/repos}
ts=$(cat "$root/gentoo/metadata/timestamp.chk")
head=$(git -C "$root/buildovl" rev-parse HEAD)
case "${1:---check}" in
  --write)
    sed -i -e "s|^gentoo_timestamp_chk=.*|gentoo_timestamp_chk=$ts|" \
           -e "s|^buildovl_head=.*|buildovl_head=$head|" \
           -e "s|^recorded=.*|recorded=$(date +%F)|" "$pin" ;;
  --check)
    grep -qxF "gentoo_timestamp_chk=$ts" "$pin" && grep -qxF "buildovl_head=$head" "$pin" \
      || { echo "repo drift: gentoo=$ts buildovl=$head (pin: $pin)" >&2; exit 1; } ;;
  --write-stdout) ;;
  *) echo "usage: $0 [--check|--write|--write-stdout]" >&2; exit 2 ;;
esac
echo "gentoo_timestamp_chk=$ts"; echo "buildovl_head=$head"
