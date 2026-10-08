#!/usr/bin/env bash
# Regenerate the filter-bash-environment oracle under
# fixtures/helpers/filter-env/ by RUNNING the real helper (plan #326 D4:
# expected values come from running the real helper, never from reasoning
# about it). Called from generate.sh; can also run standalone as
# fixtures/helpers/generate-filter-env.sh.
#
# What it produces, per fixtures/helpers/filter-env/<case>/:
#   out, stderr.txt, rc.txt, README (plus out.bz2 instead of out for
#   large pkgcache cases; see below)
# from the checked-in args (argv[1], the pattern, exactly as bytes) and
# in (stdin bytes) or in.bz2 (bzip2-compressed stdin bytes, for raw
# inputs larger than 64 KiB). args and in/in.bz2 are NEVER written here
# for captured/edge cases: captured environments are checked-in verbatim,
# edge inputs are hand-written. For pkgcache-* cases the checked-in
# in/in.bz2 is re-extracted from the L1 pkgcache sample when that cache
# is present (otherwise the checked-in input is kept and only outputs
# are recomputed).
#
# Usage:
#   fixtures/helpers/generate-filter-env.sh
#   PORTAGE_CHECKOUT=/path/to/portage fixtures/helpers/generate-filter-env.sh
#
# Requirements: the Portage checkout (default: the sibling checkout at
# ../portuale/3rdparty/portage), /usr/bin/python. Scratch lives under
# /var/tmp/pmtest only and is removed on exit.
#
# Reproducibility: a second run on the same host leaves every file
# byte-identical except the `date:` line in the filter-env READMEs (UTC
# day granularity), which is the only intentionally varying field.

set -euo pipefail

FILTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd -P)/filter-env"
PMTEST_ROOT="$(cd "$FILTER_DIR/../../.." && pwd -P)"
PKGCACHE_DIR="$PMTEST_ROOT/differential-test-bed/logs/_l1-pkgcache"

PORTAGE_CHECKOUT="${PORTAGE_CHECKOUT:-$PMTEST_ROOT/../portuale/3rdparty/portage}"
PORTAGE_CHECKOUT="$(cd "$PORTAGE_CHECKOUT" >/dev/null && pwd -P)"

die() { printf 'generate-filter-env.sh: %s\n' "$*" >&2; exit 1; }

[[ -f "$PORTAGE_CHECKOUT/bin/filter-bash-environment.py" ]] \
  || die "no real filter-bash-environment.py under $PORTAGE_CHECKOUT/bin (set \$PORTAGE_CHECKOUT)"
[[ -x /usr/bin/python ]] || die "no /usr/bin/python"

# --- provenance (D4) -------------------------------------------------------
REPOS_TOML="$PORTAGE_CHECKOUT/../repos.toml"
if [[ -f "$REPOS_TOML" ]]; then
  PORTAGE_REF="$(python3 -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1],"rb"))["portage"]["ref"])' "$REPOS_TOML")"
  PORTAGE_COMMIT="$(python3 -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1],"rb"))["portage"]["commit"])' "$REPOS_TOML")"
else
  PORTAGE_REF="$(git -C "$PORTAGE_CHECKOUT" describe --tags 2>/dev/null || echo unknown)"
  PORTAGE_COMMIT="$(git -C "$PORTAGE_CHECKOUT" rev-parse HEAD 2>/dev/null || echo unknown)"
  printf 'generate-filter-env.sh: warning: no %s, provenance from git\n' "$REPOS_TOML" >&2
fi
PYTHON_VERSION="$(/usr/bin/python --version 2>&1)"
RUN_DATE="$(date -u +%Y-%m-%d)"

# --- scratch (under /var/tmp/pmtest only) ----------------------------------
mkdir -p /var/tmp/pmtest
SCRATCH="$(mktemp -d /var/tmp/pmtest/filter-env-gen.XXXXXX)"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

# --- run the real helper, byte-exact ---------------------------------------
# args file bytes become argv[1] (via surrogateescape round-trip, so even
# non-UTF-8 patterns survive); in_raw bytes become stdin. Nothing is
# decoded, stripped or newline-terminated along the way.
run_case() { # <casedir> <in_raw> <out_raw>
  python3 - "$PORTAGE_CHECKOUT/bin/filter-bash-environment.py" \
    "$1/args" "$2" "$3" "$1/stderr.txt" "$1/rc.txt" <<'PYEOF'
import os, subprocess, sys
script, args_p, in_p, out_p, err_p, rc_p = sys.argv[1:7]
pattern = open(args_p, 'rb').read()
data = open(in_p, 'rb').read()
p = subprocess.run(['/usr/bin/python', script, os.fsdecode(pattern)],
                   input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
open(out_p, 'wb').write(p.stdout)
open(err_p, 'wb').write(p.stderr)
open(rc_p, 'w', newline='\n').write('%d\n' % p.returncode)
PYEOF
}

# --- L1 pkgcache source for pkgcache-* cases --------------------------------
# Maps a case name to its representative binpkg path relative to
# differential-test-bed/logs/_l1-pkgcache. The representative is the
# smallest build number among binpkgs with byte-identical decompressed
# environment.bz2 inputs (deduplicated; see the case README for the full
# duplicate list). Fails for any other name.
pkgcache_src() { # <case>
  case $1 in
    pkgcache-acct-group-nullmail-0-r2-1) printf 'acct-group/nullmail/nullmail-0-r2-1.gpkg.tar';;
    pkgcache-acct-user-nullmail-0-r2-1) printf 'acct-user/nullmail/nullmail-0-r2-1.gpkg.tar';;
    pkgcache-app-admin-sudo-1.9.17_p2-1) printf 'app-admin/sudo/sudo-1.9.17_p2-1.gpkg.tar';;
    pkgcache-app-crypt-libmd-1.2.0-1) printf 'app-crypt/libmd/libmd-1.2.0-1.gpkg.tar';;
    pkgcache-app-misc-jq-1.8.2-1) printf 'app-misc/jq/jq-1.8.2-1.gpkg.tar';;
    pkgcache-app-shells-bash-completion-2.18.0-1) printf 'app-shells/bash-completion/bash-completion-2.18.0-1.gpkg.tar';;
    pkgcache-app-shells-bash-5.3_p15-1) printf 'app-shells/bash/bash-5.3_p15-1.gpkg.tar';;
    pkgcache-app-shells-bash-5.3_p15-2) printf 'app-shells/bash/bash-5.3_p15-2.gpkg.tar';;
    pkgcache-app-shells-bash-5.3_p15-6) printf 'app-shells/bash/bash-5.3_p15-6.gpkg.tar';;
    pkgcache-app-shells-gentoo-bashcomp-20250620-1) printf 'app-shells/gentoo-bashcomp/gentoo-bashcomp-20250620-1.gpkg.tar';;
    pkgcache-app-text-tree-2.2.1-1) printf 'app-text/tree/tree-2.2.1-1.gpkg.tar';;
    pkgcache-dev-libs-libbsd-0.11.8-1) printf 'dev-libs/libbsd/libbsd-0.11.8-1.gpkg.tar';;
    pkgcache-dev-libs-oniguruma-6.9.10-1) printf 'dev-libs/oniguruma/oniguruma-6.9.10-1.gpkg.tar';;
    pkgcache-mail-mta-nullmailer-2.2-r2-1) printf 'mail-mta/nullmailer/nullmailer-2.2-r2-1.gpkg.tar';;
    pkgcache-sys-apps-dmidecode-3.7-1) printf 'sys-apps/dmidecode/dmidecode-3.7-1.gpkg.tar';;
    pkgcache-sys-apps-lsb-release-3.3-1) printf 'sys-apps/lsb-release/lsb-release-3.3-1.gpkg.tar';;
    pkgcache-sys-apps-miscfiles-1.5-r4-1) printf 'sys-apps/miscfiles/miscfiles-1.5-r4-1.gpkg.tar';;
    pkgcache-sys-apps-portage-3.0.82.2-1) printf 'sys-apps/portage/portage-3.0.82.2-1.gpkg.tar';;
    pkgcache-sys-apps-portage-3.0.82.2-3) printf 'sys-apps/portage/portage-3.0.82.2-3.gpkg.tar';;
    pkgcache-sys-apps-portage-3.0.82.2-7) printf 'sys-apps/portage/portage-3.0.82.2-7.gpkg.tar';;
    pkgcache-sys-apps-pv-1.10.4-1) printf 'sys-apps/pv/pv-1.10.4-1.gpkg.tar';;
    pkgcache-sys-apps-pv-1.10.4-2) printf 'sys-apps/pv/pv-1.10.4-2.gpkg.tar';;
    pkgcache-sys-libs-glibc-2.43-r2-1) printf 'sys-libs/glibc/glibc-2.43-r2-1.gpkg.tar';;
    pkgcache-sys-libs-glibc-2.43-r2-2) printf 'sys-libs/glibc/glibc-2.43-r2-2.gpkg.tar';;
    pkgcache-sys-libs-glibc-2.43-r2-5) printf 'sys-libs/glibc/glibc-2.43-r2-5.gpkg.tar';;
    pkgcache-sys-process-htop-3.5.1-1) printf 'sys-process/htop/htop-3.5.1-1.gpkg.tar';;
    pkgcache-virtual-logger-0-r3-1) printf 'virtual/logger/logger-0-r3-1.gpkg.tar';;
    pkgcache-virtual-mta-1-r2-1) printf 'virtual/mta/mta-1-r2-1.gpkg.tar';;
    *) return 1;;
  esac
}

# Duplicate binpkgs whose decompressed environment.bz2 is byte-identical
# to the representative above (64 binpkgs collapse to 28 unique inputs).
# Empty for cases with no duplicates; used only for the README.
pkgcache_dups() { # <case>
  case $1 in
    pkgcache-app-misc-jq-1.8.2-1) printf 'app-misc/jq/jq-1.8.2-2.gpkg.tar';;
    pkgcache-app-shells-bash-5.3_p15-1) printf 'app-shells/bash/bash-5.3_p15-{3,4,5,7,8,9,10,11,12,13,14,15,16,17,18}.gpkg.tar (15 binpkgs, all L1_JOBS=1)';;
    pkgcache-app-text-tree-2.2.1-1) printf 'app-text/tree/tree-2.2.1-2.gpkg.tar';;
    pkgcache-dev-libs-oniguruma-6.9.10-1) printf 'dev-libs/oniguruma/oniguruma-6.9.10-2.gpkg.tar';;
    pkgcache-sys-apps-lsb-release-3.3-1) printf 'sys-apps/lsb-release/lsb-release-3.3-2.gpkg.tar';;
    pkgcache-sys-apps-portage-3.0.82.2-1) printf 'sys-apps/portage/portage-3.0.82.2-{2,4,5,6}.gpkg.tar (4 binpkgs)';;
    pkgcache-sys-libs-glibc-2.43-r2-2) printf 'sys-libs/glibc/glibc-2.43-r2-{3,4,6,7,8,9,10,11,12,13,14,15,16}.gpkg.tar (13 binpkgs)';;
    *) printf '';;
  esac
}

# --- per-case notes: what the case isolates and its regression signature --
# Every note names the branch of filter_bash_environment it exercises and
# what the output would look like if that branch regressed.
case_blurb() { # <case>
  case $1 in
    captured-phases-pretend|captured-helper-unpack-pretend)
      cat <<'EOF'
Isolates the real end-of-phase save after pkg_pretend
(__ebuild_main tail: ___save_and_filter_ebuild_env --filter-features):
the 2378-byte captured pattern (EAPI 8, EMERGE_FROM=ebuild, so the
mutable+saved branch, not the binary branch) run over the captured
declare dump verbatim, which mixes declare -x/--/-r/-rx/-i/-a forms,
integer/readonly attributes, arrays and shell function bodies.
If the native port regressed (wrong variable kept or dropped, a
continuation line mishandled), out would differ byte-for-byte; the
Rust test asserts byte identity.
EOF
      ;;
    captured-phases-setup|captured-helper-unpack-setup)
      cat <<'EOF'
Isolates the real end-of-phase save after pkg_setup (same
--filter-features call shape as pretend): the 2378-byte captured
pattern over the setup-phase declare dump, which additionally carries
the .pretended-stamp state and sourced pretend environment.
If the native port regressed on any assignment form in this dump
(multiline values, declare --, readonly flags), out would differ
byte-for-byte.
EOF
      ;;
    captured-phases-unpack|captured-helper-unpack-unpack)
      cat <<'EOF'
Isolates the real end-of-phase save after src_unpack: the 2378-byte
captured pattern over the unpack-phase declare dump (WORKDIR freshly
recreated, userpriv in effect for the phase itself). The unpack
command additionally re-ran pretend/setup first (its clean wiped
their stamps); those re-saves differed from the dedicated pretend and
setup captures only in BASHPID/PPID and were deduped away.
If the native port regressed on this input shape (e.g. sandbox or
userpriv variables kept or dropped wrongly), out would differ
byte-for-byte.
EOF
      ;;
    captured-phases-prepare|captured-helper-unpack-prepare)
      cat <<'EOF'
Isolates the real end-of-phase save after src_prepare (default
no-op prepare plus PATCHES handling): the 2378-byte captured pattern
over the prepare-phase declare dump.
If the native port regressed on any line kind in this dump
(function bodies passing through, readonly rewrites), out would
differ byte-for-byte.
EOF
      ;;
    captured-phases-configure|captured-helper-unpack-configure)
      cat <<'EOF'
Isolates the real end-of-phase save after src_configure (default
configure plus the ASFLAGS/CC/CFLAGS export block): the 2378-byte
captured pattern over the configure-phase declare dump.
If the native port regressed on any line kind in this dump, out
would differ byte-for-byte.
EOF
      ;;
    captured-phases-compile|captured-helper-unpack-compile)
      cat <<'EOF'
Isolates the real end-of-phase save after src_compile: the 2378-byte
captured pattern over the compile-phase declare dump.
If the native port regressed on any line kind in this dump, out
would differ byte-for-byte.
EOF
      ;;
    captured-phases-test|captured-helper-unpack-test)
      cat <<'EOF'
Isolates the real test-phase save ("Test phase [not enabled]", the
src_test short-circuit): the 2378-byte captured pattern over the
test-phase declare dump. This save was observed during the `install`
command run, which chains the test phase before installing.
If the native port regressed on any line kind in this dump, out
would differ byte-for-byte.
EOF
      ;;
    captured-phases-install|captured-helper-unpack-install)
      cat <<'EOF'
Isolates the real end-of-phase save after src_install (same
--filter-features call shape as every other phase end): the
2378-byte captured pattern over the install-phase declare dump
(image populated, build-info written just before).
If the native port regressed on any line kind in this dump, out
would differ byte-for-byte.
EOF
      ;;
    captured-phases-install-buildinfo|captured-helper-unpack-install-buildinfo)
      cat <<'EOF'
Isolates the real build-info save inside __dyn_install
(___save_and_filter_ebuild_env --exclude-init-phases --filter-path
--filter-sandbox --allow-extra-vars, the same option set as the
merge-time PORTAGE_UPDATE_ENV regen): the 2366-byte
--allow-extra-vars pattern, which filters PATH and SANDBOX_* but lets
the saved-readonly set (A/CATEGORY/PVR/PF/PN/PR/PV/P) through.
HOSTNAME stays filtered -- it also arrives via bash's own dynamic
variable list, which --allow-extra-vars does not cover. The pattern
additionally carries LD_PRELOAD plus SANDBOX_DENY/PREDICT/READ/
VERBOSE/WRITE as dynamic entries: this save runs sandboxed, and
libsandbox re-injects those variables even into the `env -i` probe
that collects bash's variables, so the "hygienic" list is not
hygienic here (verified: `sandbox env -i bash -c '... ${!L*} ...'`
still reports them).
If the native port regressed to the --filter-features shape here
(filtering the extra vars, or failing to filter PATH), out would
differ byte-for-byte.
EOF
      ;;
    captured-phases-preinst|captured-helper-unpack-preinst)
      cat <<'EOF'
Isolates the real env save after pkg_preinst (the binpkg/merge-time
call shape: standalone `ebuild ... preinst`, PORTAGE_UPDATE_ENV
unset so no regen, then the usual --filter-features end-of-phase
save): the 2378-byte captured pattern over the preinst declare
dump. Merge-time preinst/postinst with PORTAGE_UPDATE_ENV set would
add a second --allow-extra-vars save; that variant was not reachable
through the ebuild command and is covered by install-buildinfo
instead.
If the native port regressed on any line kind in this dump, out
would differ byte-for-byte.
EOF
      ;;
    captured-phases-postinst|captured-helper-unpack-postinst)
      cat <<'EOF'
Isolates the real env save after pkg_postinst (same merge-time call
shape as preinst): the 2378-byte captured pattern over the postinst
declare dump.
If the native port regressed on any line kind in this dump, out
would differ byte-for-byte.
EOF
      ;;
    fixture-env-1)
      cat <<'EOF'
Isolates the filter on the smallest real vdb environment in the
fixtures (fixtures/var/db/pkg/dev-libs/infoenvpkg-1.0, a bare
`declare -x CHOST` dump): the captured install-phase pattern
(2378 bytes) must leave the single declaration untouched.
If the native port regressed to dropping plain `declare -x` lines,
out would be empty instead of echoing the input.
EOF
      ;;
    fixture-env-2)
      cat <<'EOF'
Isolates the filter on the second tiny vdb environment in the
fixtures (fixtures/var/db/pkg/dev-libs/infoinstpkg-1.0: CHOST plus
CFLAGS): the captured install-phase pattern (2378 bytes) must leave
both declarations untouched.
If the native port regressed to dropping plain assignments, out
would be short instead of echoing the input.
EOF
      ;;
    edge-heredoc-in-func)
      cat <<'EOF'
Isolates here-document tracking inside a function body: the
`cat <<EOF` line arms here_doc_delim, so the following
`declare -x FEATURES=...` line -- which matches the pattern -- passes
through unfiltered, and filtering resumes only after the closing
EOF. The top-level FEATURES assignment is still dropped.
If the native port regressed to filtering inside here-documents,
out would miss the inner line; if it lost the delimiter, lines
after EOF would pass through unfiltered too.
EOF
      ;;
    edge-ctrl-a)
      cat <<'EOF'
Isolates the \1 stripping (bug #222091): \1 bytes are removed from
kept values, on single-line assignments and on multi-line
continuation lines alike, while a filtered (\1-bearing) assignment
is dropped whole.
If the native port regressed to keeping \1, out would contain raw
0x01 bytes; if it stripped them from filtered lines only, the kept
lines would still carry them.
EOF
      ;;
    edge-multiline-backslash-quote)
      cat <<'EOF'
Isolates have_end_quote on a multi-line value whose first line ends
in backslash-quote (`...line1\\"`): the escaped quote is not the end
quote, so the value continues onto the next line, and both lines pass
through (the variable is kept).
If the native port regressed to treating `\"` as the closing quote,
the continuation line would be parsed as a fresh (garbage) line.
EOF
      ;;
    edge-declare-ar)
      cat <<'EOF'
Isolates `declare -<flags>` assignments: the kept array loses only
its `r` flag (`declare -ar` -> `declare -a`, the
filter_declare_readonly_opt rewrite on the assignment path) while
the pattern-matching array (BASH_REMATCH, a real bash_vars entry of
the captured pattern) is dropped whole.
If the native port regressed to keeping `-r` or to missing flagged
assignments, out would show `declare -ar` or the dropped array.
EOF
      ;;
    edge-declare-noassign)
      cat <<'EOF'
Isolates `declare` without assignment (var_declare_re, including the
`declare -- x` form real `declare -p` output contains): kept names
pass through byte-identical, `declare -r x` still loses its `r`
(`declare -r MY_RW` -> `declare MY_RW`), and pattern-matching names
(D, with and without `--`) are dropped.
If the native port regressed to requiring `=` on declare lines,
these lines would vanish or pass through unfiltered.
EOF
      ;;
    edge-declare-r-rewrite)
      cat <<'EOF'
Isolates the `declare -r` rewrite (filter_declare_readonly_opt):
`-r` alone is dropped (`declare -r` -> `declare`), other flags are
kept (`-rx` -> `-x`, `-ir` -> `-i`), and a pattern-matching readonly
assignment is dropped rather than rewritten.
If the native port regressed to keeping readonly flags, out would
still say `declare -r`.
EOF
      ;;
    edge-utf8-name)
      cat <<'EOF'
Isolates a non-ASCII (UTF-8) variable name: `caf\xc3\xa9` matches the
script-appended `.*\W.*` alternative (Python bytes `\W` is ASCII
only), so the declaration is filtered -- bash cannot support such
names -- while the ASCII neighbour is kept.
If the native port regressed to Unicode `\W` semantics, the name
would be kept instead of dropped.
EOF
      ;;
    edge-invalid-utf8-name)
      cat <<'EOF'
Isolates an invalid-UTF-8 variable name (lone byte 0xFF): like the
UTF-8 case it matches `.*\W.*` and is dropped, pinning that the
matcher works on raw bytes and never decodes names.
If the native port regressed to decoding names as UTF-8 str, it
would fail on or skip this line instead of dropping it cleanly.
EOF
      ;;
    edge-no-trailing-newline)
      cat <<'EOF'
Isolates an input whose last line has no trailing newline: real
passes the line through as-is and adds no newline, so out ends
without one too.
If the native port regressed to always terminating output lines, out
would gain a trailing newline.
EOF
      ;;
    edge-empty)
      cat <<'EOF'
Isolates the empty input: real copies nothing, exits 0, writes no
stdout and no stderr. It pins the trivial edge of the read loop.
If the native port regressed to erroring on empty input, rc.txt
would be nonzero or stderr.txt non-empty.
EOF
      ;;
    edge-pattern-metachars)
      cat <<'EOF'
Isolates that the pattern is live Python regex, using only
metacharacters a real caller puts there (`.` and `*` from entries
like `BASH_FUNC_.*` and `___.*`): `BASH_FUNC_foo` and `___save_x`
match and are dropped, `BASH_FUNCX` (missing the literal `_`) is
kept, and the script-appended `\d.*` alternative drops `9LIVES`.
If the native port regressed to literal or shell-glob matching, the
kept/dropped sets would flip.
EOF
      ;;
    error-bad-pattern)
      cat <<'EOF'
Isolates real's failure mode on an uncompilable pattern: re.error
propagates as an uncaught traceback on stderr, stdout stays empty,
exit code 1. No real caller produces this (patterns are
space-joined variable names, always compilable); it pins the "fail
loudly" behaviour the native port must reproduce for patterns
outside its accepted subset.
If the native port regressed to exiting 0 or swallowing the error,
rc.txt/stderr.txt would differ.
EOF
      ;;
    pkgcache-*)
      cat <<'EOF'
Isolates the end-of-phase filter (P1: the 2378-byte captured
--filter-features pattern, byte-identical to
captured-phases-install/args, EMERGE_FROM=ebuild so the
mutable+saved branch, not the binary branch) over a real
binary-package environment: the decompressed environment.bz2 from
the L1 pkgcache sample. The input is already-filtered build output,
so it exercises kept-variable passthrough at scale -- declare -x/-a
arrays, declare --, readonly rewrites, integer attributes, shell
function bodies with here-documents (<<) and multiline quoted values.
If the native port regressed on any line kind in this dump (a kept
variable dropped, a filtered one leaked, a continuation or here-doc
line mishandled, a flag rewrite missed), out would differ
byte-for-byte; the Rust test asserts byte identity (decompressing
in.bz2/out.bz2 first when present).
EOF
      ;;
  esac
}

# --- capture coordinates for the README ------------------------------------
# case: ebuild relpath | ebuild command | EBUILD_PHASE of the save
capture_coords() { # <case>
  case $1 in
    captured-phases-*)
      phase=${1#captured-phases-}
      case $phase in
        install-buildinfo) cmd="install"; ephase="install";;
        test) cmd="install"; ephase="test";;
        *) cmd="$phase"; ephase="$phase";;
      esac
      printf 'porttest/porttest/phases/phases-1.0.ebuild | %s | %s' "$cmd" "$ephase"
      ;;
    captured-helper-unpack-*)
      phase=${1#captured-helper-unpack-}
      case $phase in
        install-buildinfo) cmd="install"; ephase="install";;
        test) cmd="install"; ephase="test";;
        *) cmd="$phase"; ephase="$phase";;
      esac
      printf 'porttest/porttest/helper-unpack/helper-unpack-1.0.ebuild | %s | %s' "$cmd" "$ephase"
      ;;
  esac
}

NCASES=0
for casedir in "$FILTER_DIR"/*/; do
  kc="$(basename "$casedir")"
  [[ -f "$casedir/args" ]] || die "missing $casedir/args"
  has_in=0
  has_inbz2=0
  if [[ -f "$casedir/in" ]]; then has_in=1; fi
  if [[ -f "$casedir/in.bz2" ]]; then has_inbz2=1; fi
  if (( has_in && has_inbz2 )); then die "$kc: both in and in.bz2 present"; fi
  if (( ! has_in && ! has_inbz2 )); then die "missing $casedir/in or in.bz2"; fi
  # --- pkgcache refresh: re-extract from the binpkg when present ---------
  if [[ "$kc" == pkgcache-* ]]; then
    src_rel="$(pkgcache_src "$kc")" || die "no pkgcache mapping for $kc"
    src_abs="$PKGCACHE_DIR/$src_rel"
    if [[ -f "$src_abs" ]]; then
      python3 - "$src_abs" "$SCRATCH/$kc.pkg.raw" <<'PYEOF'
import bz2, io, sys, tarfile
src, dst = sys.argv[1:3]
with tarfile.open(src, 'r:*') as outer:
    meta = None
    for m in outer.getmembers():
        if 'metadata.tar' in m.name:
            meta = m
            break
    if meta is None:
        raise SystemExit('no metadata tar in %s' % src)
    blob = outer.extractfile(meta).read()
bio = io.BytesIO(blob)
with tarfile.open(fileobj=bio, mode='r:*') as inner:
    env = inner.extractfile('metadata/environment.bz2').read()
open(dst, 'wb').write(bz2.decompress(env))
PYEOF
      raw_size="$(wc -c <"$SCRATCH/$kc.pkg.raw" | tr -d ' ')"
      if (( raw_size > 65536 )); then
        bzip2 -9 -c "$SCRATCH/$kc.pkg.raw" >"$SCRATCH/$kc.new_in.bz2"
        if [[ -f "$casedir/in" ]]; then rm -f "$casedir/in"; fi
        if [[ -f "$casedir/out" ]]; then rm -f "$casedir/out"; fi
        if [[ ! -f "$casedir/in.bz2" ]] || ! cmp -s "$SCRATCH/$kc.new_in.bz2" "$casedir/in.bz2"; then
          mv "$SCRATCH/$kc.new_in.bz2" "$casedir/in.bz2"
        else
          rm -f "$SCRATCH/$kc.new_in.bz2"
        fi
        has_in=0
        has_inbz2=1
      else
        if [[ -f "$casedir/in.bz2" ]]; then rm -f "$casedir/in.bz2"; fi
        if [[ -f "$casedir/out.bz2" ]]; then rm -f "$casedir/out.bz2"; fi
        if [[ ! -f "$casedir/in" ]] || ! cmp -s "$SCRATCH/$kc.pkg.raw" "$casedir/in"; then
          cp "$SCRATCH/$kc.pkg.raw" "$casedir/in"
        fi
        has_in=1
        has_inbz2=0
      fi
    else
      printf 'generate-filter-env.sh: warning: pkgcache %s missing, keeping checked-in input for %s\n' "$src_abs" "$kc" >&2
    fi
  fi
  # --- resolve the raw input for the run ---------------------------------
  if (( has_inbz2 )); then
    bzip2 -dc "$casedir/in.bz2" >"$SCRATCH/$kc.in.raw"
    IN_RAW="$SCRATCH/$kc.in.raw"
  else
    IN_RAW="$casedir/in"
  fi
  OUT_RAW="$SCRATCH/$kc.out.raw"
  run_case "$casedir" "$IN_RAW" "$OUT_RAW"
  # --- store the raw output in the checked-in form ------------------------
  if (( has_inbz2 )); then
    bzip2 -9 -c "$OUT_RAW" >"$SCRATCH/$kc.new_out.bz2"
    if [[ -f "$casedir/out" ]]; then rm -f "$casedir/out"; fi
    if [[ ! -f "$casedir/out.bz2" ]] || ! cmp -s "$SCRATCH/$kc.new_out.bz2" "$casedir/out.bz2"; then
      mv "$SCRATCH/$kc.new_out.bz2" "$casedir/out.bz2"
    else
      rm -f "$SCRATCH/$kc.new_out.bz2"
    fi
  else
    if [[ -f "$casedir/out.bz2" ]]; then rm -f "$casedir/out.bz2"; fi
    cp "$OUT_RAW" "$casedir/out"
  fi
  in_size="$(wc -c <"$IN_RAW" | tr -d ' ')"
  args_size="$(wc -c <"$casedir/args" | tr -d ' ')"
  out_size="$(wc -c <"$OUT_RAW" | tr -d ' ')"
  in_stored=""
  out_stored=""
  if (( has_inbz2 )); then
    in_stored="$(wc -c <"$casedir/in.bz2" | tr -d ' ')"
    out_stored="$(wc -c <"$casedir/out.bz2" | tr -d ' ')"
  else
    if [[ -f "$casedir/out" ]]; then out_stored="$(wc -c <"$casedir/out" | tr -d ' ')"; fi
  fi
  {
    printf 'filter-env oracle case: %s\n\n' "$kc"
    case_blurb "$kc"
    printf '\nRun exactly as the phase runtime runs it:\n'
    if (( has_inbz2 )); then
      printf '  bzip2 -dc in.bz2 | /usr/bin/python <checkout>/bin/filter-bash-environment.py "$(cat args)" 2> stderr.txt | bzip2 -9 > out.bz2\n'
      printf '  (stored compressed because the raw input exceeds 64 KiB;\n'
      printf '  decompress both sides before comparing.)\n'
    else
      printf '  /usr/bin/python <checkout>/bin/filter-bash-environment.py "$(cat args)" < in > out 2> stderr.txt\n'
    fi
    printf 'Byte-exact: the args file bytes are argv[1] (no trailing newline\n'
    if (( has_inbz2 )); then
      printf 'added, none present); the decompressed in.bz2 bytes are stdin verbatim.\n'
    else
      printf 'added, none present); the in file bytes are stdin verbatim.\n'
    fi
    printf '\nProvenance (D4):\n'
    printf '  portage-ref: %s\n' "$PORTAGE_REF"
    printf '  portage-commit: %s (3rdparty/repos.toml [portage] commit)\n' "$PORTAGE_COMMIT"
    printf '  python: %s (/usr/bin/python)\n' "$PYTHON_VERSION"
    case $kc in
      captured-*)
        printf '  capture: instrumented real Portage in bed container\n'
        printf '    localhost/test-portuale:latest (Portage 3.0.82.2, container python 3.14.6)\n'
        printf '    with bin/filter-bash-environment.py replaced by a logging\n'
        printf '    wrapper (argv[1] + stdin recorded per call, then the real\n'
        printf '    script re-executed with identical argv + stdin).\n'
        printf '    ebuild | command | EBUILD_PHASE: %s\n' "$(capture_coords "$kc")"
        printf '    EMERGE_FROM=ebuild (the ebuild(1) branch, same pattern\n'
        printf '    branch as a source merge; the binary-merge branch and the\n'
        printf '    preprocess --filter-locale/--filter-path/--filter-sandbox\n'
        printf '    option set did not occur in these runs).\n'
        ;;
      fixture-env-1)
        printf '  input: decompressed fixtures/var/db/pkg/dev-libs/infoenvpkg-1.0/environment.bz2\n'
        printf '    with the captured install-phase pattern (2378 bytes,\n'
        printf '    byte-identical to captured-phases-install/args) as args.\n'
        ;;
      fixture-env-2)
        printf '  input: decompressed fixtures/var/db/pkg/dev-libs/infoinstpkg-1.0/environment.bz2\n'
        printf '    with the captured install-phase pattern (2378 bytes,\n'
        printf '    byte-identical to captured-phases-install/args) as args.\n'
        ;;
      pkgcache-*)
        src_rel="$(pkgcache_src "$kc")"
        dups="$(pkgcache_dups "$kc")"
        printf '  input: decompressed environment.bz2 from the L1 pkgcache sample\n'
        printf '    differential-test-bed/logs/_l1-pkgcache/%s\n' "$src_rel"
        printf '    with the captured install-phase pattern P1 (2378 bytes,\n'
        printf '    byte-identical to captured-phases-install/args) as args.\n'
        if [[ -n "$dups" ]]; then
          printf '    deduped: byte-identical inputs from %s share this case.\n' "$dups"
        else
          printf '    deduped: no other binpkg in the 64-file sample shares this input.\n'
        fi
        printf '    64 binpkgs collapse to 28 unique inputs (this case is one).\n'
        ;;
      edge-*|error-*)
        printf '  input: hand-written (see the case name); args is the captured\n'
        printf '    install-phase pattern (2378 bytes) except edge-pattern-metachars\n'
        printf '    (its own minimal real-caller-vocabulary pattern) and\n'
        printf '    error-bad-pattern (the single byte `(`).\n'
        ;;
    esac
    if (( has_inbz2 )); then
      printf '  sizes: args=%s in=%s out=%s (stored: in.bz2=%s out.bz2=%s; raw in exceeds 64 KiB)\n' "$args_size" "$in_size" "$out_size" "$in_stored" "$out_stored"
    else
      printf '  sizes: args=%s in=%s out=%s\n' "$args_size" "$in_size" "$out_size"
    fi
    printf '  date: %s (UTC day granularity; the only field that may change\n' "$RUN_DATE"
    printf '    between regenerations)\n'
  } >"$casedir/README"
  NCASES=$(( NCASES + 1 ))
done

printf 'generate-filter-env.sh: wrote %d filter-env cases.\n' "$NCASES"
