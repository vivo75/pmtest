#!/usr/bin/env bash
# Regenerate fixtures/helpers/gpkg/ by RUNNING the real
# 3rdparty/portage/bin/gpkg-helper.py `compress` (plan #326 S4, decisions
# D3/D4: expected values come from running the real helper, never from
# reasoning about it).
#
# Per case (gpkg/<case>/), checked in by hand:
#   image.manifest   the image tree (owners, setuid, hardlinks, long names do
#                    not survive git); NOTE  what the case isolates.
# Per case and compressor (gpkg/<case>/<comp>/), regenerated:
#   args env         the helper argv and the pinned settings (placeholders
#                    @OUT@ @METADATA@ @IMAGE@ @SCRATCH@ @GNUPGHOME@)
#   out.gpkg.tar     the real artifact
#   out.fields       the D3 field dump (dump_fields.py; format in gpkg/README.md)
#   stderr.txt rc.txt
#   out.root.* ...   the same run as root, kept only when its field dump
#                    differs from the user run (owners / uname / gname).
# Per case: README (NOTE + provenance).  Shared inputs: gpkg/metadata/ (the
# build-info of a real build) and ../gpg-keyring/ (signing).
#
# Usage:
#   fixtures/helpers/generate-gpkg.sh
#   PORTAGE_CHECKOUT=/path/to/portage fixtures/helpers/generate-gpkg.sh
#
# Requirements: the Portage checkout (default: the sibling checkout at
# ../portuale/3rdparty/portage), /usr/bin/python, python3, zstd, xz, bzip2,
# gzip, gpg, flock, passwordless sudo.  Scratch lives on tmpfs under /tmp
# (/tmp/pmtest-gpkg-gen.*) and is removed on exit.  tmpfs, not /var/tmp/pmtest
# (zfs here): zfs rejects non-UTF-8 names (case non-utf8) AND hands readdir
# back in a per-directory hash order, which would make the raw os.walk order
# of the metadata members (gpkg.py:1844-1862) differ between runs; tmpfs
# order is deterministic for a fixed creation order.
#
# Reproducibility: a second run on the same host leaves every out.fields
# byte-identical.  out.gpkg.tar may differ between runs ONLY in the bytes
# that depend on `datetime.now()`: the mtime fields of the container and
# metadata tar headers (and therefore the metadata member's compressed
# bytes, the Manifest digests of it, the header checksums); the image tar is
# stable because the materialiser pins every file mtime.  The README `date:`
# line (UTC day) varies too.

set -euo pipefail

HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd -P)"
PMTEST_ROOT="$(cd "$HELPERS_DIR/../.." && pwd -P)"
GPKG_DIR="$HELPERS_DIR/gpkg"
KEYRING_DIR="$HELPERS_DIR/gpg-keyring"
PORTAGE_CHECKOUT="${PORTAGE_CHECKOUT:-$PMTEST_ROOT/../portuale/3rdparty/portage}"
PORTAGE_CHECKOUT="$(cd "$PORTAGE_CHECKOUT" >/dev/null && pwd -P)" || { echo "generate-gpkg.sh: bad PORTAGE_CHECKOUT" >&2; exit 1; }
PYTHON=/usr/bin/python

die() { printf 'generate-gpkg.sh: %s\n' "$*" >&2; exit 1; }

[[ -f "$PORTAGE_CHECKOUT/bin/gpkg-helper.py" ]] \
  || die "no gpkg-helper.py under $PORTAGE_CHECKOUT/bin (set \$PORTAGE_CHECKOUT)"
[[ -d "$PORTAGE_CHECKOUT/lib/portage" ]] || die "no lib/portage under $PORTAGE_CHECKOUT"
[[ -x "$PYTHON" ]] || die "no $PYTHON"
[[ -d "$GPKG_DIR/metadata" ]] || die "no $GPKG_DIR/metadata"
[[ -d "$KEYRING_DIR" ]] || die "no $KEYRING_DIR"
sudo -n true 2>/dev/null || die "passwordless sudo is required for the root runs"
for t in zstd xz bzip2 gzip gpg flock python3; do
  command -v "$t" >/dev/null || die "missing tool: $t"
done

# --- provenance (D4) --------------------------------------------------------
REPOS_TOML="$PORTAGE_CHECKOUT/../repos.toml"
if [[ -f "$REPOS_TOML" ]]; then
  PORTAGE_REF="$(python3 -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1],"rb"))["portage"]["ref"])' "$REPOS_TOML")"
  PORTAGE_COMMIT="$(python3 -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1],"rb"))["portage"]["commit"])' "$REPOS_TOML")"
else
  PORTAGE_REF="$(git -C "$PORTAGE_CHECKOUT" describe --tags 2>/dev/null || echo unknown)"
  PORTAGE_COMMIT="$(git -C "$PORTAGE_CHECKOUT" rev-parse HEAD 2>/dev/null || echo unknown)"
fi
PYTHON_VERSION="$("$PYTHON" --version 2>&1)"
RUN_DATE="$(date -u +%Y-%m-%d)"
declare -A CVER
CVER[zstd]="$(zstd --version | head -n1 | sed 's/\*\*\* //; s/ \*\*\*//')"
CVER[xz]="$(xz --version | head -n1)"
CVER[bzip2]="$(bzip2 --help 2>&1 | head -n1)"
CVER[gzip]="$(gzip --version | head -n1)"
GPG_VERSION="$(gpg --version | head -n1)"
locale -a 2>/dev/null >"$GPKG_DIR/locale-a.txt" || true
MAKEOPTS_PIN="-j4"
GEN_LANG="C.utf8"
GLOBAL_CONFIG_PATH="$(PYTHONPATH="$PORTAGE_CHECKOUT/lib" "$PYTHON" -c 'import portage.const as c; print(c.GLOBAL_CONFIG_PATH)')"
GNU_UID="$(id -u)"
USER_PASSWD="$(getent passwd "$GNU_UID" || true)"
USER_GROUP="$(getent group "$(id -g)" || true)"
ROOT_PASSWD="$(getent passwd 0 || true)"
ROOT_GROUP="$(getent group 0 || true)"
NOENT="$(getent passwd 4242 || echo 'none'); $(getent group 4243 || echo 'none')"

# --- scratch ------------------------------------------------------------------
SCRATCH="$(mktemp -d /tmp/pmtest-gpkg-gen.XXXXXX)"
[[ "$(stat -f -c %T "$SCRATCH")" == tmpfs ]] || die "$SCRATCH is not on tmpfs"
GNUPGHOME_COPY="$SCRATCH/gnupg"
cleanup() {
  if [[ -d "$GNUPGHOME_COPY" ]]; then
    gpgconf --homedir "$GNUPGHOME_COPY" --kill all >/dev/null 2>&1 || true
  fi
  # the root runs leave root-owned files, hence sudo; only our own scratch
  # directories (matched by pattern) are ever removed
  case "$SCRATCH" in
    /tmp/pmtest-gpkg-gen.?*) sudo -n rm -rf -- "$SCRATCH" ;;
  esac
}
trap cleanup EXIT

# Hermetic Portage configuration: an empty make.conf under a private
# PORTAGE_CONFIGROOT, so nothing of this host's /etc/portage leaks in; the
# settings the helper reads come from the environment below.
mkdir -p "$SCRATCH/cfg/etc/portage"
: >"$SCRATCH/cfg/etc/portage/make.conf"

# The test keyring, copied so gpg can write its agent sockets and random_seed.
cp -a "$KEYRING_DIR" "$GNUPGHOME_COPY"
chmod 700 "$GNUPGHOME_COPY"

# mkname <length>: "lb" + x padding + "-1.0-1", exactly <length> characters.
mkname() {
  local n=$1 pad
  pad="$(printf 'x%.0s' $(seq $((n - 8))))"
  printf 'lb%s-1.0-1' "$pad"
}

# run_case <case> <basename> <compressor> <run: user|root> <signed: 0|1> <stage: SCRATCH dir>
# Leaves $stage/work-<comp>-<run>/{out.gpkg.tar,out.fields,stderr.txt,rc.txt}.
run_one() {
  local case=$1 basename=$2 comp=$3 run=$4 signed=$5 stage=$6
  local work="$stage/work-$case-$comp-$run" sudo_cmd=() f
  mkdir -p "$work/metadata" "$work/image" "$work/home"
  if [[ $run == root ]]; then sudo_cmd=(sudo -n); fi
  # metadata files created in sorted name order, so the raw os.walk order the
  # helper sees is reproducible on a given filesystem
  for f in $(cd "$GPKG_DIR/metadata" && LC_ALL=C ls); do
    cp "$GPKG_DIR/metadata/$f" "$work/metadata/$f"
  done
  "${sudo_cmd[@]}" python3 "$GPKG_DIR/materialise.py" "$GPKG_DIR/$case/image.manifest" "$work/image"
  local envv=(
    PATH=/usr/local/bin:/usr/bin:/bin
    HOME="$work/home"
    LANG="$GEN_LANG"
    PYTHONPATH="$PORTAGE_CHECKOUT/lib"
    PORTAGE_BIN_PATH="$PORTAGE_CHECKOUT/bin"
    PORTAGE_PYM_PATH="$PORTAGE_CHECKOUT/lib"
    PORTAGE_PYTHON="$PYTHON"
    PORTAGE_CONFIGROOT="$SCRATCH/cfg"
    BINPKG_COMPRESS="$comp"
    PORTAGE_BZIP2_COMMAND=bzip2
    MAKEOPTS="$MAKEOPTS_PIN"
  )
  if [[ $signed == 1 ]]; then
    envv+=(
      FEATURES=binpkg-signing
      BINPKG_GPG_SIGNING_BASE_COMMAND="flock $SCRATCH/portage-binpkg-gpg.lock /usr/bin/gpg --sign --armor --batch --no-tty --yes --pinentry-mode loopback --passphrase GentooTest [PORTAGE_CONFIG]"
      BINPKG_GPG_SIGNING_DIGEST=SHA512
      BINPKG_GPG_SIGNING_GPG_HOME="$GNUPGHOME_COPY"
      BINPKG_GPG_SIGNING_KEY=0x8812797DDF1DD192
    )
  fi
  local rc=0
  "${sudo_cmd[@]}" env -i "${envv[@]}" "$PYTHON" "$PORTAGE_CHECKOUT/bin/gpkg-helper.py" \
    compress "$basename" "$work/out.gpkg.tar" "$work/metadata" "$work/image" \
    >"$work/stdout.txt" 2>"$work/stderr.txt" || rc=$?
  if [[ $run == root ]]; then sudo -n chown -R "$(id -u):$(id -g)" "$work"; fi
  printf '%s\n' "$rc" >"$work/rc.txt"
  if [[ -s "$work/out.gpkg.tar" ]]; then
    python3 "$GPKG_DIR/dump_fields.py" "$work/out.gpkg.tar" >"$work/out.fields"
  fi
  # scrub scratch paths from stderr so it is reproducible
  sed -i "s#$stage#<SCRATCH>#g; s#$SCRATCH#<SCRATCH>#g; s#$PORTAGE_CHECKOUT#<CHECKOUT>#g" "$work/stderr.txt"
  [[ -s "$work/stdout.txt" ]] && sed -i "s#$stage#<SCRATCH>#g" "$work/stdout.txt" || true
}

write_args_env() {
  local dir=$1 basename=$2 comp=$3 signed=$4
  printf 'compress\n%s\n@OUT@\n@METADATA@\n@IMAGE@\n' "$basename" >"$dir/args"
  {
    printf 'BINPKG_COMPRESS=%s\nMAKEOPTS=%s\nPORTAGE_BZIP2_COMMAND=bzip2\nLANG=%s\n' \
      "$comp" "$MAKEOPTS_PIN" "$GEN_LANG"
    printf '# BINPKG_COMPRESS_FLAGS and BINPKG_COMPRESS_FLAGS_%s: unset (make.globals default: empty)\n' "${comp^^}"
    if [[ $signed == 1 ]]; then
      printf 'FEATURES=binpkg-signing\n'
      printf 'BINPKG_GPG_SIGNING_BASE_COMMAND=flock @SCRATCH@/portage-binpkg-gpg.lock /usr/bin/gpg --sign --armor --batch --no-tty --yes --pinentry-mode loopback --passphrase GentooTest [PORTAGE_CONFIG]\n'
      printf 'BINPKG_GPG_SIGNING_DIGEST=SHA512\nBINPKG_GPG_SIGNING_GPG_HOME=@GNUPGHOME@\nBINPKG_GPG_SIGNING_KEY=0x8812797DDF1DD192\n'
    else
      printf '# FEATURES: unset (no binpkg-signing)\n'
    fi
  } >"$dir/env"
}

# do_case <case> <basename> <signed> <stage-root> <compressors...>
do_case() {
  local case=$1 basename=$2 signed=$3 stage=$4; shift 4
  local comp out run same
  for comp in "$@"; do
    out="$GPKG_DIR/$case/$comp"
    mkdir -p "$out"
    write_args_env "$out" "$basename" "$comp" "$signed"
    for run in user root; do
      [[ $signed == 1 && $run == root ]] && continue
      run_one "$case" "$basename" "$comp" "$run" "$signed" "$stage"
    done
    local wu="$stage/work-$case-$comp-user" wr="$stage/work-$case-$comp-root"
    cp "$wu/rc.txt" "$out/rc.txt"; cp "$wu/stderr.txt" "$out/stderr.txt"
    [[ -s "$wu/out.gpkg.tar" ]] && { cp "$wu/out.gpkg.tar" "$out/out.gpkg.tar"; cp "$wu/out.fields" "$out/out.fields"; }
    rm -f "$out"/out.root.* "$out"/rc.root.txt "$out"/stderr.root.txt
    if [[ -d $wr ]]; then
      same=1
      if [[ -s "$wu/out.fields" || -s "$wr/out.fields" ]]; then
        cmp -s "$wu/out.fields" "$wr/out.fields" || same=0
      fi
      [[ "$(cat "$wu/rc.txt")" == "$(cat "$wr/rc.txt")" ]] || same=0
      printf '%s' "$same" >"$stage/same-$case-$comp"
      if [[ $same == 0 ]]; then
        cp "$wr/rc.txt" "$out/rc.root.txt"; cp "$wr/stderr.txt" "$out/stderr.root.txt"
        [[ -s "$wr/out.gpkg.tar" ]] && { cp "$wr/out.gpkg.tar" "$out/out.root.gpkg.tar"; cp "$wr/out.fields" "$out/out.root.fields"; }
      fi
    else
      printf 'n/a' >"$stage/same-$case-$comp"
    fi
  done
}

write_readme() {
  local case=$1 basename=$2 signed=$3 stage=$4; shift 4
  local comps="$*" comp same_line="" vers=""
  for comp in "$@"; do
    vers+="    $comp: ${CVER[$comp]}"$'\n'
    same_line+="$comp=$(cat "$stage/same-$case-$comp") "
  done
  {
    printf 'gpkg compress oracle case: %s\n\n' "$case"
    cat "$GPKG_DIR/$case/NOTE"
    printf '\nRun exactly as bin/ebuild-pyhelper runs gpkg-helper.py:\n'
    printf '  /usr/bin/python <checkout>/bin/gpkg-helper.py compress <basename> <out> <metadata_dir> <image_dir>\n'
    printf 'with PYTHONPATH=<checkout>/lib, PORTAGE_BIN_PATH=<checkout>/bin, PORTAGE_PYM_PATH=<checkout>/lib,\n'
    # shellcheck disable=SC2016
    printf 'PORTAGE_PYTHON=/usr/bin/python, under `env -i`, with a hermetic empty make.conf\n'
    printf '(PORTAGE_CONFIGROOT=<scratch>/cfg); every setting real reads from portage.settings is\n'
    printf 'pinned in <comp>/env.  basename: %s (%d chars).\n' "$basename" "${#basename}"
    printf 'Inputs: image.manifest (this dir) materialised by ../materialise.py; metadata = ../metadata/\n'
    printf '(25 build-info files of a real porttest build, see ../README.md).\n\n'
    printf 'Provenance (D4):\n'
    printf '  portage-ref: %s\n' "$PORTAGE_REF"
    printf '  portage-commit: %s\n' "$PORTAGE_COMMIT"
    printf '  python: %s (%s)\n' "$PYTHON_VERSION" "$PYTHON"
    printf '  compressors (cases run: %s):\n%s' "$comps" "$vers"
    [[ $signed == 1 ]] && printf '  gpg: %s\n' "$GPG_VERSION"
    printf '  MAKEOPTS: %s (zstd/xz -T4)\n' "$MAKEOPTS_PIN"
    printf '  BINPKG_COMPRESS_FLAGS, BINPKG_COMPRESS_FLAGS_<NAME>: unset (make.globals default empty)\n'
    printf '  PORTAGE_BZIP2_COMMAND: bzip2\n'
    printf '  FEATURES: %s\n' "$([[ $signed == 1 ]] && echo 'binpkg-signing' || echo 'unset')"
    printf '  global config: %s (make.globals); make.conf: empty\n' "$GLOBAL_CONFIG_PATH"
    printf '  /etc/passwd (user run): %s\n' "$USER_PASSWD"
    printf '  /etc/group  (user run): %s\n' "$USER_GROUP"
    printf '  /etc/passwd (root run): %s\n' "$ROOT_PASSWD"
    printf '  /etc/group  (root run): %s\n' "$ROOT_GROUP"
    printf '  uid 4242 / gid 4243: %s\n' "$NOENT"
    printf '  staging filesystem (tmpfs; see generate-gpkg.sh header): %s\n' "$(stat -f -c %T "$stage")"
    printf '  LANG=%s; locale -a: see ../locale-a.txt (the helper needs a UTF-8 locale; C.utf8 is present)\n' "$GEN_LANG"
    printf '  date: %s (UTC day granularity; the only field that may change between regenerations)\n' "$RUN_DATE"
    printf '  root-vs-user identical (per compressor; 1 = identical so only the user files are kept, 0 = differs so out.root.* are kept): %s\n' "$same_line"
  } >"$GPKG_DIR/$case/README"
}

ALL=(zstd xz bzip2 gzip)
mkdir -p "$SCRATCH/stage"
STAGE="$SCRATCH/stage"

BN_LONG="$(mkname 154)"; BN_153="$(mkname 153)"
[[ ${#BN_LONG} -eq 154 && ${#BN_153} -eq 153 ]] || die "mkname length"

do_case plain         plain-1.0-1   0 "$STAGE" "${ALL[@]}";  write_readme plain         plain-1.0-1   0 "$STAGE" "${ALL[@]}"
do_case special       special-1.0-1 0 "$STAGE" "${ALL[@]}";  write_readme special       special-1.0-1 0 "$STAGE" "${ALL[@]}"
do_case empty         empty-1.0-1   0 "$STAGE" "${ALL[@]}";  write_readme empty         empty-1.0-1   0 "$STAGE" "${ALL[@]}"
do_case longname      longname-1.0-1 0 "$STAGE" zstd;        write_readme longname      longname-1.0-1 0 "$STAGE" zstd
do_case long-basename "$BN_LONG"    0 "$STAGE" zstd;         write_readme long-basename "$BN_LONG"    0 "$STAGE" zstd
do_case basename-153  "$BN_153"     0 "$STAGE" zstd;         write_readme basename-153  "$BN_153"     0 "$STAGE" zstd
do_case signed        signed-1.0-1  1 "$STAGE" zstd;         write_readme signed        signed-1.0-1  1 "$STAGE" zstd

do_case non-utf8      non-utf8-1.0-1 0 "$STAGE" zstd;        write_readme non-utf8      non-utf8-1.0-1 0 "$STAGE" zstd

printf 'generate-gpkg.sh: done (%s)\n' "$GPKG_DIR"
