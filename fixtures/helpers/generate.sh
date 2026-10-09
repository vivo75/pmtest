#!/usr/bin/env bash
# Regenerate every oracle file under fixtures/helpers/ by RUNNING the real
# Portage helpers (plan #326 D4: expected values come from running the real
# helper, never from reasoning about it).
#
# What it produces:
#   chmod-lite/<case>/{out.manifest,out.root.manifest,stderr.txt,
#     stderr.root.txt,rc.txt,rc.root.txt,README}
#     from the checked-in in.manifest (the input tree's source of truth),
#     once as the invoking user and once as root.
#   locale/{table.tsv,locale-a.txt,README}
#     from the real `python -c 'import locale; ...'` probe and locale(1).
#   filter-env/<case>/{out,stderr.txt,rc.txt,README}
#     from the checked-in args (argv[1], the pattern, exactly as bytes)
#     and in (stdin bytes), via the sibling generate-filter-env.sh (which
#     this script calls at the end).
#   gpkg/<case>/<comp>/..., xpak/<case>/... and doins/<case>/... (plan #326
#     S4/S5/S6), via the sibling generate-gpkg.sh, generate-xpak.sh and
#     generate-doins.sh, also called at the end.
#
# Usage:
#   fixtures/helpers/generate.sh
#   PORTAGE_CHECKOUT=/path/to/portage fixtures/helpers/generate.sh
#
# Requirements: the Portage checkout (default: the sibling checkout at
# ../portuale/3rdparty/portage), /usr/bin/python, find(1), locale(1),
# passwordless sudo. Scratch lives under /var/tmp/pmtest only and is
# removed on exit.
#
# Reproducibility: a second run on the same host leaves every file
# byte-identical except the `date:` line in the chmod-lite READMEs (UTC
# day granularity), which is the only intentionally varying field.

set -euo pipefail

HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd -P)"
PMTEST_ROOT="$(cd "$HELPERS_DIR/../.." && pwd -P)"
CHMOD_DIR="$HELPERS_DIR/chmod-lite"
LOCALE_DIR="$HELPERS_DIR/locale"

PORTAGE_CHECKOUT="${PORTAGE_CHECKOUT:-$PMTEST_ROOT/../portuale/3rdparty/portage}"

die() { printf 'generate.sh: %s\n' "$*" >&2; exit 1; }

[[ -x "$PORTAGE_CHECKOUT/bin/chmod-lite" ]] \
  || die "no real chmod-lite at $PORTAGE_CHECKOUT/bin/chmod-lite (set \$PORTAGE_CHECKOUT)"
[[ -f "$PORTAGE_CHECKOUT/bin/chmod-lite.py" ]] \
  || die "no chmod-lite.py next to $PORTAGE_CHECKOUT/bin/chmod-lite"
[[ -d "$PORTAGE_CHECKOUT/lib/portage" ]] \
  || die "no lib/portage under $PORTAGE_CHECKOUT (set \$PORTAGE_CHECKOUT)"

# The phase environment for the helper (bin/phase-helpers.sh `unpack`).
export PORTAGE_BIN_PATH="$PORTAGE_CHECKOUT/bin"
export PORTAGE_PYM_PATH="$PORTAGE_CHECKOUT/lib"
export PORTAGE_PYTHON=/usr/bin/python
[[ -x "$PORTAGE_PYTHON" ]] || die "no $PORTAGE_PYTHON"

sudo -n true 2>/dev/null || die "passwordless sudo is required for the root runs"

# --- provenance (D4) -------------------------------------------------------
REPOS_TOML="$PORTAGE_CHECKOUT/../repos.toml"
if [[ -f "$REPOS_TOML" ]]; then
  PORTAGE_REF="$(python3 -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1],"rb"))["portage"]["ref"])' "$REPOS_TOML")"
  PORTAGE_COMMIT="$(python3 -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1],"rb"))["portage"]["commit"])' "$REPOS_TOML")"
else
  PORTAGE_REF="$(git -C "$PORTAGE_CHECKOUT" describe --tags 2>/dev/null || echo unknown)"
  PORTAGE_COMMIT="$(git -C "$PORTAGE_CHECKOUT" rev-parse HEAD 2>/dev/null || echo unknown)"
  printf 'generate.sh: warning: no %s, provenance from git\n' "$REPOS_TOML" >&2
fi
PYTHON_VERSION="$("$PORTAGE_PYTHON" --version 2>&1)"
RUN_UID="$(id -u)"
RUN_UMASK="$(umask)"
RUN_DATE="$(date -u +%Y-%m-%d)"
GEN_LOCALE="LC_ALL=${LC_ALL-unset} LC_CTYPE=${LC_CTYPE-unset} LANG=${LANG-unset} charmap=$(locale charmap 2>/dev/null || echo unknown)"

# --- scratch (under /var/tmp/pmtest only) ----------------------------------
mkdir -p /var/tmp/pmtest
SCRATCH="$(mktemp -d /var/tmp/pmtest/helpers-gen.XXXXXX)"
MOUNTED=()
cleanup() {
  if ((${#MOUNTED[@]})); then
    local m
    for m in "${MOUNTED[@]}"; do sudo umount "$m" 2>/dev/null || true; done
  fi
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

# The host filesystem may reject non-UTF-8 names outright (EILSEQ, e.g. a
# zfs dataset with utf8only): probe once. A case whose in.manifest needs
# raw bytes (a '%' escape) is then staged on a tmpfs bind-mounted under
# the scratch dir -- still literally under /var/tmp/pmtest -- and the
# mount is recorded in that case's README.
rc=0
python3 - "$SCRATCH" <<'PYEOF' || rc=$?
import os, sys
p = os.path.join(os.fsencode(sys.argv[1]), b'.raw-probe-\xff')
try:
    fd = os.open(p, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    os.close(fd)
    os.unlink(p)
except OSError:
    sys.exit(10)
PYEOF
case $rc in
  0) RAW_NAMES_OK=1 ;;
  10) RAW_NAMES_OK=0 ;;
  *) die "scratch probe failed unexpectedly (rc=$rc)" ;;
esac

# --- manifest helpers (byte-exact; argv paths stay ASCII, names are bytes) --
build_tree() { # <in.manifest> <treedir>
  python3 - "$1" "$2" <<'PYEOF'
import os, sys
manifest, tree = sys.argv[1], sys.argv[2]
def unquote(s):
    out = bytearray()
    b = s.encode('ascii')
    i = 0
    while i < len(b):
        if b[i] == 0x25:  # '%'
            try:
                out += bytes((int(b[i+1:i+3], 16),))
            except ValueError:
                raise SystemExit('%s: bad escape in %r' % (manifest, s))
            i += 3
        else:
            out.append(b[i])
            i += 1
    return bytes(out)
raw = open(manifest, 'rb').read().decode('ascii')  # manifests are pure ASCII
lines = raw.split('\n')
if lines and lines[-1] == '':
    lines.pop()
entries = []
prev = None
for ln, line in enumerate(lines, 1):
    parts = line.split(' ')
    if len(parts) < 3:
        raise SystemExit('%s:%d: malformed line' % (manifest, ln))
    typ, mode, rest = parts[0], parts[1], ' '.join(parts[2:])
    if typ == 'l':
        if mode != '----' or ' -> ' not in rest:
            raise SystemExit('%s:%d: symlink line needs ---- and " -> "' % (manifest, ln))
        penc, tenc = rest.split(' -> ', 1)
        path, target = unquote(penc), unquote(tenc)
    elif typ in ('d', 'f'):
        if len(mode) != 4 or any(c not in '01234567' for c in mode):
            raise SystemExit('%s:%d: mode must be 4 octal digits' % (manifest, ln))
        if ' -> ' in rest:
            raise SystemExit('%s:%d: unexpected " -> "' % (manifest, ln))
        penc, path, target = rest, unquote(rest), None
    else:
        raise SystemExit('%s:%d: type must be d, f or l' % (manifest, ln))
    comps = path.split(b'/')
    if any(c in (b'', b'.', b'..') for c in comps):
        raise SystemExit('%s:%d: path must be relative without . or ..' % (manifest, ln))
    if prev is not None and not prev < penc:
        raise SystemExit('%s:%d: lines must be sorted by path' % (manifest, ln))
    prev = penc
    entries.append((typ, mode, path, target))
tbin = os.fsencode(tree)
made = {tbin}
for typ, mode, path, target in entries:
    full = os.path.join(tbin, path)
    if os.path.dirname(full) not in made:
        raise SystemExit('%s: parent of %r is not an explicit d entry' % (manifest, path))
    if typ == 'd':
        os.mkdir(full)
        made.add(full)
    elif typ == 'f':
        open(full, 'wb').close()
    else:
        os.symlink(target, full)
def depth(e):
    return e[2].count(b'/')
for typ, mode, path, target in sorted(entries, key=depth, reverse=True):
    if typ == 'l':
        continue
    os.chmod(os.path.join(tbin, path), int(mode, 8))
PYEOF
}

walk_tree() { # <treedir> <out.manifest>
  python3 - "$1" "$2" <<'PYEOF'
import os, stat as statm, sys
tree = os.fsencode(sys.argv[1])
out = sys.argv[2]
def quote(b):
    o = []
    for byte in b:
        c = chr(byte)
        if 'A' <= c <= 'Z' or 'a' <= c <= 'z' or '0' <= c <= '9' or c in '._/+-':
            o.append(c)
        else:
            o.append('%%%02X' % byte)
    return ''.join(o)
def fail(e):
    raise e  # never silently skip an unreadable subtree
recs = []
for dp, dns, fns in os.walk(tree, onerror=fail):
    for name in dns + fns:
        full = os.path.join(dp, name)
        st = os.lstat(full)
        rel = os.path.relpath(full, tree)
        if statm.S_ISDIR(st.st_mode):
            line = 'd %04o %s' % (st.st_mode & 0o7777, quote(rel))
        elif statm.S_ISREG(st.st_mode):
            line = 'f %04o %s' % (st.st_mode & 0o7777, quote(rel))
        elif statm.S_ISLNK(st.st_mode):
            line = 'l ---- %s -> %s' % (quote(rel), quote(os.readlink(full)))
        else:
            raise SystemExit('unsupported file type: %r' % (full,))
        recs.append((quote(rel), line))
recs.sort()
with open(out, 'w', newline='\n') as f:
    for _, line in recs:
        f.write(line + '\n')
PYEOF
}

# --- real chmod-lite, exactly as bin/phase-helpers.sh `unpack` runs it ------
run_user() { # <treedir> <stderr-file> <rc-file>
  local tree=$1 err=$2 rcf=$3 rc=0
  ( cd "$tree" && find . -mindepth 1 -maxdepth 1 ! -type l \
      -exec "$PORTAGE_BIN_PATH/chmod-lite" {} + 2>"$err" ) || rc=$?
  printf '%s\n' "$rc" >"$rcf"
}

run_root() { # <treedir> <stderr-file> <rc-file>
  local tree=$1 err=$2 rcf=$3 rc=0
  ( cd "$tree" && sudo --preserve-env=PORTAGE_BIN_PATH,PORTAGE_PYM_PATH,PORTAGE_PYTHON \
      find . -mindepth 1 -maxdepth 1 ! -type l \
      -exec "$PORTAGE_BIN_PATH/chmod-lite" {} + 2>"$err" ) || rc=$?
  printf '%s\n' "$rc" >"$rcf"
}

# --- per-case notes: what the case isolates and its regression signature ---
case_blurb() { # <case>
  case $1 in
    basic) cat <<'EOF'
Isolates the two arms of portage.util.apply_permissions as driven by
chmod-lite.py (filemode=0644/filemask=0022 on files,
dirmode=0755/dirmask=0022 on directories): missing read bits are added
(0600->0644, 0640->0644), surplus write bits are stripped (0777->0755),
and owner-execute is preserved (0700->0744), because the mask only ever
clears 0022 and the mode only ever adds. Three levels of nesting prove
the recursion reaches depth.
If the native port regressed to forcing exact 0644/0755, out.manifest
would show the 0744 entries as 0644.
EOF
      ;;
    special-bits) cat <<'EOF'
Isolates how the mask logic treats the setuid/setgid/sticky bits: real
never forces exact 0644/0755, it only adds missing mode bits and clears
0022, so setuid (4755), setgid (2755) and sticky (1777) inputs keep their
special bits while losing any group/other write bits present. The 6711
file additionally gains the missing read bits (6711->6755).
If the native port regressed to chmod 0644/0755 semantics, the special
bits would come out cleared (e.g. 4755 recorded as 0755).
EOF
      ;;
    symlinks) cat <<'EOF'
Isolates symlink handling on both levels: the find driver never passes
top-level symlinks to the helper (! -type l), and inside a processed
tree apply_secpass_permissions leaves symlinks alone (follow_links is
False, "mode doesn't matter for symlinks") and os.walk does not descend
into symlinked dirs. The dir-a subtree is still fixed through its real
path; every symlink keeps its target, including the dangling ones, and
the top-level links are byte-identical before and after.
If the native port regressed to following symlinks, the walk would
descend through link-to-dir and dangling links would error; if it lost
the find-side skip, the top-level links would vanish from out.manifest
or gain modes.
EOF
      ;;
    non-utf8) cat <<'EOF'
Isolates non-UTF-8 file names (bytes 0xFF and lone 0xE9, invalid UTF-8):
chmod-lite.py takes argv as raw bytes (surrogateescape) and re-execs
under PYTHONUTF8 when the locale encoding is not UTF-8, so such names
must be fixed like any other. The file inside the non-UTF-8 dir proves
the recursion descends through it.
If the native port regressed to decoding argv as UTF-8 str, it would
fail on or skip these entries instead of recording 0644/0755.
EOF
      ;;
    unreadable) cat <<'EOF'
Isolates directories real initially cannot read or list (0000, and 0300
write+exec without read): apply_recursive_permissions always fixes a
directory before traversing it (bug 554084), so by the time os.walk
lists the children the parents are already 0755 and the whole subtree
is fixed, including the 0000 file inside the 0000 dir.
If the native port regressed to listing before fixing, the unreadable
subtrees would keep their input modes (or the run would record errors
in stderr.txt with a nonzero rc.txt).
EOF
      ;;
    empty) cat <<'EOF'
Isolates the empty tree: find matches nothing, so chmod-lite runs with
no arguments, exits 0, and writes nothing. It pins the trivial edge of
the find -exec {} + driver.
If the native port regressed to erroring on zero arguments, rc.txt
would be nonzero and stderr.txt non-empty.
EOF
      ;;
    top-file) cat <<'EOF'
Isolates the degenerate tree whose root holds only plain files (the
WORKDIR look of a single-file fetch): each file is passed to the helper
directly and fixed non-recursively (0600->0644, 0644 stays, 0777->0755).
If the native port regressed to treating top-level files as
directories, lone-0600 would come out 0755 instead of 0644.
EOF
      ;;
  esac
}

CASES=(basic special-bits symlinks non-utf8 unreadable empty top-file)

for kc in "${CASES[@]}"; do
  casedir="$CHMOD_DIR/$kc"
  [[ -f "$casedir/in.manifest" ]] || die "missing $casedir/in.manifest"
  # Stage the tree; raw-byte names go on a tmpfs bind mount when the host
  # filesystem rejects them (see the probe above).
  stagedir="$SCRATCH/tree-$kc"
  staging_note="scratch dir directly"
  if grep -q '%' "$casedir/in.manifest" && (( ! RAW_NAMES_OK )); then
    stagedir="$SCRATCH/mnt-$kc"
    mkdir -p "$stagedir"
    sudo mount -t tmpfs -o size=64m,nr_inodes=16k tmpfs "$stagedir" \
      || die "cannot mount tmpfs staging for case $kc"
    MOUNTED+=("$stagedir")
    staging_note="tmpfs bind mount (host filesystem rejects non-UTF-8 names)"
  else
    mkdir -p "$stagedir"
  fi
  # User run on a fresh tree.
  usertree="$stagedir/user"
  mkdir -p "$usertree"
  build_tree "$casedir/in.manifest" "$usertree"
  run_user "$usertree" "$casedir/stderr.txt" "$casedir/rc.txt"
  walk_tree "$usertree" "$casedir/out.manifest"
  # Root run on a second fresh tree (never on the already-fixed one).
  roottree="$stagedir/root"
  mkdir -p "$roottree"
  build_tree "$casedir/in.manifest" "$roottree"
  run_root "$roottree" "$casedir/stderr.root.txt" "$casedir/rc.root.txt"
  walk_tree "$roottree" "$casedir/out.root.manifest"
  # Root-vs-user verdict for the README.
  relation=identical
  for pair in "out.manifest out.root.manifest" "stderr.txt stderr.root.txt" "rc.txt rc.root.txt"; do
    if ! cmp -s "$casedir/${pair% *}" "$casedir/${pair#* }"; then
      relation="DIFFER (user ${pair% *} vs root ${pair#* }: see the two files)"
      break
    fi
  done
  {
    printf 'chmod-lite oracle case: %s\n\n' "$kc"
    case_blurb "$kc"
    printf '\nRun exactly as the unpack phase runs it (bin/phase-helpers.sh):\n'
    printf '  cd <tree>\n'
    printf '  find . -mindepth 1 -maxdepth 1 ! -type l \\\n'
    printf '    -exec <checkout>/bin/chmod-lite {} +\n'
    printf 'with PORTAGE_BIN_PATH=<checkout>/bin,\n'
    printf 'PORTAGE_PYM_PATH=<checkout>/lib, PORTAGE_PYTHON=/usr/bin/python.\n'
    printf 'File contents are empty (out of scope: only type/mode/path/target\n'
    printf 'are recorded); symlink modes are always ----.\n'
    printf '\nProvenance (D4):\n'
    printf '  portage-ref: %s\n' "$PORTAGE_REF"
    printf '  portage-commit: %s (3rdparty/repos.toml [portage] commit)\n' "$PORTAGE_COMMIT"
    printf '  python: %s (%s)\n' "$PYTHON_VERSION" "$PORTAGE_PYTHON"
    printf '  uid: %s, umask: %s\n' "$RUN_UID" "$RUN_UMASK"
    printf '  staging: %s\n' "$staging_note"
    printf '  generator-locale: %s\n' "$GEN_LOCALE"
    printf '  date: %s (UTC day granularity; the only field that may change\n' "$RUN_DATE"
    printf '    between regenerations)\n'
    printf '  root-vs-user: %s\n' "$relation"
  } >"$casedir/README"
done

# --- locale oracle ----------------------------------------------------------
mkdir -p "$LOCALE_DIR"
TABLE="$LOCALE_DIR/table.tsv"
LOCALE_A="$LOCALE_DIR/locale-a.txt"
locale -a >"$LOCALE_A"

VALS=(C POSIX C.UTF-8 en_US.UTF-8 en_US.utf8 en_US en_US.ISO-8859-1 xx_YY.ISO-8859-1)
{
  printf 'case\tLC_ALL\tLC_CTYPE\tLANG\tpython_stdout\tlocale_charmap\tis_utf8\n'
  # Each row: case|LC_ALL|LC_CTYPE|LANG, '-' means unset, '' means set-but-empty.
  rows=('all-unset|-|-|-')
  for var in LC_ALL LC_CTYPE LANG; do
    for val in "${VALS[@]}" ''; do
      if [[ -z "$val" ]]; then name="$var=empty"; else name="$var=$val"; fi
      a=-; c=-; l=-
      case $var in LC_ALL) a=$val;; LC_CTYPE) c=$val;; LANG) l=$val;; esac
      rows+=("$name|$a|$c|$l")
    done
  done
  rows+=('mix-LANG-en_US.UTF-8-LC_CTYPE-C|-|C|en_US.UTF-8')
  rows+=('mix-LANG-C-LC_CTYPE-en_US.UTF-8|-|en_US.UTF-8|C')
  rows+=('mix-LC_ALL-C-LANG-en_US.UTF-8|C|-|en_US.UTF-8')
  for row in "${rows[@]}"; do
    IFS='|' read -r name a c l <<<"$row"
    cmd=(env -i PATH=/usr/bin:/bin)
    if [[ "$a" != '-' ]]; then cmd+=("LC_ALL=$a"); fi
    if [[ "$c" != '-' ]]; then cmd+=("LC_CTYPE=$c"); fi
    if [[ "$l" != '-' ]]; then cmd+=("LANG=$l"); fi
    # Real program, byte-exact from bin/install-qa-check.d/90config-impl-decl.
    pyout="$("${cmd[@]}" /usr/bin/python -c 'import locale; print(locale.getlocale()[1])')"
    # locale charmap stdout in the same env (its stderr diagnostics are noise).
    cmout="$("${cmd[@]}" locale charmap 2>/dev/null)"
    is_utf8=0
    if [[ "$pyout" == 'UTF-8' ]]; then is_utf8=1; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$a" "$c" "$l" "$pyout" "$cmout" "$is_utf8"
  done
} >"$TABLE"

# Rows whose value has no exact `locale -a` entry (mechanical, from the table).
not_installed_rows="$(python3 - "$TABLE" "$LOCALE_A" <<'PYEOF'
import sys
table, la = sys.argv[1], sys.argv[2]
installed = set(open(la, errors='replace').read().split())
seen = {}
for line in open(table, errors='replace').read().splitlines()[1:]:
    cols = line.split('\t')
    for v in cols[1:4]:
        if v not in ('-', '') and v not in installed:
            seen.setdefault(v, []).append(cols[0])
for v, rows in seen.items():
    print('%s: %s' % (v, ', '.join(rows)))
PYEOF
)"

{
  cat <<EOF
Locale oracle for has_utf8_ctype
(bin/install-qa-check.d/90config-impl-decl: has_utf8_ctype passes iff the
probe below prints exactly UTF-8).

Real program, byte-exact from 90config-impl-decl:102:
  /usr/bin/python -c 'import locale; print(locale.getlocale()[1])'

Each table row ran under 'env -i PATH=/usr/bin:/bin' plus only the listed
variables; locale_charmap is the stdout of 'locale charmap' in the same
env (its stderr "Cannot set ..." diagnostics are not recorded). An unset
variable is written '-', a set-but-empty one as an empty field. is_utf8
is 1 exactly when python_stdout is 'UTF-8', mirroring the [[ ... == UTF-8 ]]
test in has_utf8_ctype.
EOF
  printf '\nRows using a locale value with no exact `locale -a` entry:\n'
  if [[ -n "$not_installed_rows" ]]; then
    printf '%s\n' "$not_installed_rows" | sed 's/^/  /'
  else
    printf '  (none)\n'
  fi
  cat <<EOF
Whether such a value still resolves (C.UTF-8 is a glibc built-in, and
spelling variants such as en_US.UTF-8 match their installed lowercase
form) is visible in the table itself: python_stdout/locale_charmap show
the effective locale. Only a value with no match at all falls back to
the C locale (python prints None, charmap ANSI_X3.4-1968).

If the native port regressed to answering from its own default locale
instead of the phase environment, rows such as LC_ALL=en_US (ISO8859-1,
is_utf8=0) would come out UTF-8/1.

Provenance (D4):
  portage-ref: $PORTAGE_REF
  portage-commit: $PORTAGE_COMMIT (3rdparty/repos.toml [portage] commit)
  python: $PYTHON_VERSION (/usr/bin/python)
  installed locales: see locale-a.txt
EOF
} >"$LOCALE_DIR/README"

printf 'generate.sh: wrote %d chmod-lite cases and the locale table.\n' "${#CASES[@]}"

# --- filter-bash-environment oracle (plan #326 S3) ---------------------------
# A sibling script owns this section's cases (captured real patterns plus
# hand-written edges); it shares the provenance convention above. The
# checkout override passes through so both halves regenerate against the
# same Portage.
PORTAGE_CHECKOUT="$PORTAGE_CHECKOUT" "$HELPERS_DIR/generate-filter-env.sh"

# --- gpkg compress, xpak recompose and doins oracles (plan #326 S4/S5/S6) ---
# Sibling scripts own these cases; formats in gpkg/README.md, the
# generate-xpak.sh header and doins/README.md.
PORTAGE_CHECKOUT="$PORTAGE_CHECKOUT" "$HELPERS_DIR/generate-gpkg.sh"
PORTAGE_CHECKOUT="$PORTAGE_CHECKOUT" "$HELPERS_DIR/generate-xpak.sh"
PORTAGE_CHECKOUT="$PORTAGE_CHECKOUT" "$HELPERS_DIR/generate-doins.sh"
