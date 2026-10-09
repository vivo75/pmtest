#!/usr/bin/env bash
# Regenerate fixtures/helpers/xattr/ by RUNNING the real Portage helpers
# (plan #326 S7, D4: expected values come from running the real helper,
# never from reasoning about it). Standalone; it is NOT wired into
# generate.sh (that file is frozen for this slice).
#
# Per case (xattr/<case>/), checked in by hand (the inputs):
#   args           the exact helper argv after the script path, one element
#                  per line as raw bytes (`<SCRATCH>/stage-<case>/...` and
#                  `<CHECKOUT>` stand for the stage and checkout paths).
#   stdin          (optional) the exact stdin bytes, raw (`<SCRATCH>` for the
#                  stage path; may hold NUL bytes: dump stdin is NUL-separated
#                  like estrip's `--dump < <(echo -n "$1")` feed).
#   env            every variable the run sets, `KEY=value` lines in LC_ALL=C
#                  sorted order; empty value means unset. Placeholders:
#                  `<SCRATCH>` (the stage), `<CHECKOUT>` (the Portage checkout).
#   in.manifest    the input tree, materialised under <stage>/in (dump cases),
#                  <stage>/in (restore dest files) or <stage>/src (install
#                  sources); format is doins/materialise.py's (see
#                  doins/README.md), reused verbatim.
#   xattrs         (optional) `<qpath> <name> <hex-value>` lines applied to
#                  the materialised tree (doins' convention).
#   src.manifest + src.xattrs + pairs (only restore-roundtrip): the attributed
#                  source tree materialised under <stage>/src; `pairs` maps
#                  `<src-qpath> <dst-qpath>` lines. The generator dumps each
#                  source with the real --dump (argv form, pairs order) and
#                  rewrites the `# file:` lines to the fresh dest paths, so
#                  stdin is genuine real output, the way estrip produces it.
# Per case, regenerated (the oracle):
#   out.txt        stdout bytes, scrubbed (`<SCRATCH>`/`<CHECKOUT>`); absent
#                  when empty.
#   stderr.txt, rc.txt (always).
#   out.xattrs     (restore cases) the resulting xattrs: `<qpath> <name>
#                  <hex-value>` lines, sorted, over the dest tree (user.*
#                  only, like the doins out.manifest xattr columns).
#   out.manifest   (install cases) the D3 tree dump of <stage>/dest after the
#                  run (doins/README.md's format, xattrs included).
#   README         what the case isolates, its regression signature, the run
#                  shape and provenance.
#
# Usage:
#   fixtures/helpers/generate-xattr.sh
#   PORTAGE_CHECKOUT=/path/to/portage fixtures/helpers/generate-xattr.sh
#
# Requirements: the Portage checkout (default: the sibling checkout at
# ../portuale/3rdparty/portage), /usr/bin/python, python3, install(1).
# Scratch lives on tmpfs under /dev/shm (/dev/shm/pmtest-xattr-gen.*) and is
# removed on exit. /var/tmp is NOT used: it is utf8only ZFS here (rejects
# non-UTF-8 names), its readdir order is hash order, and its xattr support
# differs. user.* xattrs are probed on the scratch tmpfs and the result is
# recorded in every README.
#
# Reproducibility: a second run on the same host leaves every file
# byte-identical except the `date:` line in the READMEs (UTC day
# granularity), which is the only intentionally varying field.

set -euo pipefail
umask 022

XATTR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd -P)/xattr"
PMTEST_ROOT="$(cd "$XATTR_DIR/../../.." && pwd -P)"
DOINS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd -P)/doins"

PORTAGE_CHECKOUT="${PORTAGE_CHECKOUT:-$PMTEST_ROOT/../portuale/3rdparty/portage}"
PORTAGE_CHECKOUT="$(cd "$PORTAGE_CHECKOUT" >/dev/null && pwd -P)" || { echo "generate-xattr.sh: bad PORTAGE_CHECKOUT" >&2; exit 1; }
PYTHON=/usr/bin/python

die() { printf 'generate-xattr.sh: %s\n' "$*" >&2; exit 1; }

[[ -f "$PORTAGE_CHECKOUT/bin/xattr-helper.py" ]] \
  || die "no real xattr-helper.py under $PORTAGE_CHECKOUT/bin (set \$PORTAGE_CHECKOUT)"
[[ -f "$PORTAGE_CHECKOUT/bin/install.py" ]] \
  || die "no real install.py under $PORTAGE_CHECKOUT/bin (set \$PORTAGE_CHECKOUT)"
[[ -f "$PORTAGE_CHECKOUT/bin/ebuild-helpers/xattr/install" ]] \
  || die "no real ebuild-helpers/xattr/install under $PORTAGE_CHECKOUT (set \$PORTAGE_CHECKOUT)"
[[ -d "$PORTAGE_CHECKOUT/lib/portage" ]] || die "no lib/portage under $PORTAGE_CHECKOUT"
[[ -x "$PYTHON" ]] || die "no $PYTHON"
[[ -f "$DOINS_DIR/materialise.py" ]] || die "no $DOINS_DIR/materialise.py"
command -v install >/dev/null || die "missing tool: install"

# --- provenance (D4) ---------------------------------------------------------
REPOS_TOML="$PORTAGE_CHECKOUT/../repos.toml"
if [[ -f "$REPOS_TOML" ]]; then
  PORTAGE_REF="$(python3 -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1],"rb"))["portage"]["ref"])' "$REPOS_TOML")"
  PORTAGE_COMMIT="$(python3 -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1],"rb"))["portage"]["commit"])' "$REPOS_TOML")"
else
  PORTAGE_REF="$(git -C "$PORTAGE_CHECKOUT" describe --tags 2>/dev/null || echo unknown)"
  PORTAGE_COMMIT="$(git -C "$PORTAGE_CHECKOUT" rev-parse HEAD 2>/dev/null || echo unknown)"
fi
WORKTREE_COMMIT="$(git -C "$PORTAGE_CHECKOUT" rev-parse HEAD 2>/dev/null || echo unknown)"
PYTHON_VERSION="$("$PYTHON" --version 2>&1)"
RUN_UID="$(id -u)"
RUN_DATE="$(date -u +%Y-%m-%d)"
GEN_CHARMAP="$(LANG=C.utf8 locale charmap 2>/dev/null || echo unknown)"

# --- scratch on tmpfs (/dev/shm, never /var/tmp) ------------------------------
SCRATCH="$(mktemp -d /dev/shm/pmtest-xattr-gen.XXXXXX)"
[[ "$(stat -f -c %T "$SCRATCH")" == tmpfs ]] || die "$SCRATCH is not on tmpfs"
STAGE_FS="$(stat -f -c %T "$SCRATCH")"
cleanup() {
  case "$SCRATCH" in
    /dev/shm/pmtest-xattr-gen.?*) rm -rf -- "$SCRATCH" ;;
  esac
}
trap cleanup EXIT

# Raw-byte names must be accepted here (the non-UTF-8 fixtures).
if python3 - "$SCRATCH" <<'PYEOF' 2>/dev/null; then
import os, sys
p = os.path.join(os.fsencode(sys.argv[1]), b'.raw-probe-\xff')
fd = os.open(p, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
os.close(fd)
os.unlink(p)
PYEOF
  RAW_NAMES_OK=1
else
  RAW_NAMES_OK=0
fi
(( RAW_NAMES_OK )) || die "scratch $SCRATCH rejects non-UTF-8 names"

# user.* xattrs must work here.
if touch "$SCRATCH/.xattr-probe" \
  && setfattr -n user.probe -v ok "$SCRATCH/.xattr-probe" 2>/dev/null \
  && [[ "$(getfattr --only-values -n user.probe "$SCRATCH/.xattr-probe" 2>/dev/null)" == ok ]]; then
  XATTR_FS="user.* xattrs work on $STAGE_FS"
else
  XATTR_FS="user.* xattrs DO NOT work on $STAGE_FS"
fi
rm -f "$SCRATCH/.xattr-probe"

# Cases in run order.
CASES=(dump-empty dump-two dump-escapes dump-names dump-symlink dump-argv dump-missing dump-newline-joined restore-roundtrip restore-malformed restore-no-pathname restore-missing-file argv-no-action argv-both argv-help install-file install-D install-d install-t install-multi install-missing)

# --- per-case notes: what the case isolates and its regression signature -----
case_blurb() { # <case>
  case $1 in
    dump-empty) cat <<'EOF'
Isolates --dump of a file with no xattrs: real lists the attrs and
`continue`s silently, so stdout is empty and rc is 0 (no `# file:`
header for an attr-less file).
If the native port regressed to printing a header anyway, out.txt
would be present instead of absent.
EOF
      ;;
    dump-two) cat <<'EOF'
Isolates --dump of a file with two user.* xattrs, fed on stdin exactly
as estrip feeds it (one path, no trailing newline: `--dump <
<(echo -n "$1")`). Both attrs dump as `name="value"` lines under a
`# file: <path>` header, in listxattr order.
If the native port regressed to sorting the attrs, the two value lines
would swap.
EOF
      ;;
    dump-escapes) cat <<'EOF'
Isolates --dump's octal quoting: the value holds `"` (`\042`), `\`
(`\134`), a newline (`\012`) and NUL (`\000`); only NUL, `"`, newline,
CR and backslash are escaped. 0xff and non-ASCII UTF-8 bytes pass
through RAW (the dump is not ASCII-clean). Attr names escape `=` the
same way values do.
If the native port regressed to escaping 0xff, the value line would
carry `\377` where out.txt has the raw byte.
EOF
      ;;
    dump-names) cat <<'EOF'
Isolates --dump over NUL-separated stdin paths (the helper splits stdin
on NUL only) whose names need no quoting: a name with a space and a
name with a non-UTF-8 byte both appear RAW in their `# file:` lines.
If the native port regressed to splitting stdin on newlines, only one
section (or none) would dump.
EOF
      ;;
    dump-symlink) cat <<'EOF'
Isolates --dump of a symlink: real follows it (portage.util._xattr
calls os.listxattr with follow_symlinks=True, the default), so the
dump shows the TARGET's attrs under the LINK's `# file:` path.
If the native port regressed to llistxattr (nofollow), out.txt would
be empty.
EOF
      ;;
    dump-argv) cat <<'EOF'
Isolates --dump with paths as argv instead of stdin: argv wins (stdin
is not even read) and the dump is identical to dump-two's. This pins
the `if options.paths: ... else: read stdin` branch.
If the native port regressed to always reading stdin, out.txt would be
empty here.
EOF
      ;;
    dump-missing) cat <<'EOF'
Isolates --dump of a missing path: real lets the FileNotFoundError
propagate (full traceback, rc 1); the pinned bytes are the final
`FileNotFoundError: [Errno 2] No such file or directory:` line naming
the path as bytes. Nothing is printed to stdout.
EOF
      ;;
    dump-newline-joined) cat <<'EOF'
Isolates the stdin split rule: two paths joined by `\n` (not NUL) are
ONE path to real (`stdin.read().split(b"\0")`), so the run fails with
FileNotFoundError naming the embedded-newline blob, rc 1.
If the native port regressed to splitting on newlines, two sections
would dump with rc 0.
EOF
      ;;
    restore-roundtrip) cat <<'EOF'
Isolates --restore: stdin is a genuine real --dump of the src tree
(regenerated here on every run, `# file:` lines rewritten to the fresh
dest paths, pairs order), applied to fresh files. The resulting xattrs
are byte-identical to the sources, including the escapes value with
its NUL, 0xff and UTF-8 bytes (see dump-escapes); file contents are
untouched. out.xattrs records name plus value hex per file.
If the native port regressed in unquoting (e.g. `\000`), the fresh2
user.esc hex would differ.
EOF
      ;;
    restore-malformed) cat <<'EOF'
Isolates --restore on a line that is neither a `# file:` header nor a
`name=value` entry: real raises `ValueError: line 1: malformed entry`
(rc 1, traceback). Blank lines are skipped, anything else non-empty is
malformed.
EOF
      ;;
    restore-no-pathname) cat <<'EOF'
Isolates --restore of an attr line before any `# file:` header: real
raises `ValueError: line 1: missing pathname` (rc 1, traceback).
EOF
      ;;
    restore-missing-file) cat <<'EOF'
Isolates --restore onto a missing path: real's xattr.set raises the
FileNotFoundError through (rc 1, traceback), naming the path as bytes.
EOF
      ;;
    argv-no-action) cat <<'EOF'
Isolates xattr-helper.py with neither --dump nor --restore: argparse
exits 2 with `xattr-helper.py: error: missing action!` after the usage
line (stdout empty).
EOF
      ;;
    argv-both) cat <<'EOF'
Isolates xattr-helper.py with both --dump and --restore: the dump
branch wins (`if options.dump: ... elif options.restore:`), so with
empty stdin the run is silent, rc 0.
If the native port regressed to refusing the combination, rc.txt would
read 2.
EOF
      ;;
    argv-help) cat <<'EOF'
Isolates xattr-helper.py --help: argparse prints the usage + doc text
to stdout, rc 0. The text is Portage's (kept for the message shape,
not byte-compared by the port: argparse wraps to the terminal width).
EOF
      ;;
    install-file) cat <<'EOF'
Isolates install.py as the ebuild-helpers/xattr/install wrapper runs
it (`__PORTAGE_HELPER_CWD`, `__PORTAGE_HELPER_PATH`, cwd = the lib
dir): `install -m0644 src dest` runs real install(1), then copies
xattrs except PORTAGE_XATTR_EXCLUDE (here user.drop): the dest is 0644
with only user.keep. The dest file is created by install(1), not by
the helper.
If the native port regressed to copying excluded attrs, out.manifest
would list user.drop too.
EOF
      ;;
    install-D) cat <<'EOF'
Isolates `install -D -m0644 src dest/sub/c`: leading dest components
are created, the file is 0644, and with PORTAGE_XATTR_EXCLUDE unset
ALL source xattrs are copied.
If the native port regressed to skipping the copy without an exclude
list, the xattr columns would be missing.
EOF
      ;;
    install-d) cat <<'EOF'
Isolates `install -d dir/sub`: directory creation takes the early
return (`if opts.directory ...: return EX_OK`), so no xattr copy runs
at all. rc 0, the dir exists, out.manifest lists it.
EOF
      ;;
    install-t) cat <<'EOF'
Isolates `install -m0600 -t dir src1 src2`: each source lands under the
target dir by basename (`os.path.join(target, basename)`), mode 0600,
with the exclude applied per file (a.txt loses user.drop, b.txt keeps
its user.keep).
If the native port regressed to copying only the first source's
xattrs, b.txt would have no xattr column.
EOF
      ;;
    install-multi) cat <<'EOF'
Isolates several sources without -t (last arg an existing dir): same
per-file landing as -t. With PORTAGE_XATTR_EXCLUDE unset all attrs
survive on both files.
EOF
      ;;
    install-missing) cat <<'EOF'
Isolates an install(1) failure (missing source): real returns
install(1)'s rc 1 WITHOUT a traceback (copy_xattrs never runs); the
pinned bytes are install(1)'s own `install: cannot stat '...': No such
file or directory` stderr line.
If the native port regressed to tracing back here, stderr.txt would
hold a Python traceback instead.
EOF
      ;;
  esac
}

# --- small helpers ------------------------------------------------------------

# Substitute <SCRATCH>/<CHECKOUT> in a checked-in file to a stage file.
sub_in() { # <checked-in> <stage-file>
  python3 - "$1" "$2" "$SCRATCH" "$PORTAGE_CHECKOUT" <<'PYEOF'
import sys
src, dst, scratch, checkout = sys.argv[1:5]
data = open(src, 'rb').read()
data = data.replace(b'<SCRATCH>', scratch.encode()).replace(b'<CHECKOUT>', checkout.encode())
open(dst, 'wb').write(data)
PYEOF
}

# Scrub stage/checkout paths from a captured file, in place.
scrub() { # <file>
  python3 - "$1" "$SCRATCH" "$PORTAGE_CHECKOUT" <<'PYEOF'
import sys
p, scratch, checkout = sys.argv[1:4]
data = open(p, 'rb').read()
data = data.replace(scratch.encode(), b'<SCRATCH>').replace(checkout.encode(), b'<CHECKOUT>')
open(p, 'wb').write(data)
PYEOF
}

# env file -> ENV_ARGS array (empty value means unset).
build_env() { # <env-file>
  ENV_ARGS=()
  local line k v
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z "$line" ]] && continue
    k=${line%%=*}; v=${line#*=}
    v=${v//<SCRATCH>/$SCRATCH}
    v=${v//<CHECKOUT>/$PORTAGE_CHECKOUT}
    [[ -z "$v" ]] && continue
    ENV_ARGS+=("$k=$v")
  done <"$1"
}

# args file -> ARGV array (one element per line, placeholders substituted).
build_argv() { # <args-file>
  ARGV=()
  local line
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line//<SCRATCH>/$SCRATCH}
    line=${line//<CHECKOUT>/$PORTAGE_CHECKOUT}
    ARGV+=("$line")
  done <"$1"
}

# Apply an xattrs file (doins' `<qpath> <name> <hex-value>` convention) to a tree.
apply_xattrs() { # <xattrs-file> <tree>
  python3 - "$1" "$2" <<'PYEOF'
import os, re, sys
xp, tree = sys.argv[1], os.fsencode(sys.argv[2])
def unesc(s):
    import re as _re
    return _re.sub(rb"%([0-9A-F]{2})", lambda m: bytes([int(m.group(1), 16)]),
                   s.encode("ascii"))
for ln, line in enumerate(open(xp, encoding="ascii"), 1):
    line = line.rstrip("\n")
    if not line or line.startswith("#"):
        continue
    try:
        qpath, name, hexval = line.split(" ")
    except ValueError:
        sys.exit("%s:%d: want '<qpath> <name> <hex-value>'" % (xp, ln))
    os.setxattr(os.path.join(tree, unesc(qpath)), os.fsencode(name),
                bytes.fromhex(hexval), follow_symlinks=False)
PYEOF
}

# Dump user.* xattrs of a tree: `<qpath> <name> <hex-value>` lines, sorted.
dump_xattrs() { # <tree> <out>
  python3 - "$1" "$2" <<'PYEOF'
import errno, os, sys
tree = os.fsencode(sys.argv[1])
def quote(b):
    o = []
    for byte in b:
        c = chr(byte)
        if 'A' <= c <= 'Z' or 'a' <= c <= 'z' or '0' <= c <= '9' or c in '._/+-':
            o.append(c)
        else:
            o.append('%%%02X' % byte)
    return ''.join(o)
lines = []
for dp, dns, fns in os.walk(tree):
    for name in dns + fns:
        full = os.path.join(dp, name)
        rel = os.path.relpath(full, tree)
        try:
            attrs = os.listxattr(full, follow_symlinks=False)
        except OSError as e:
            if e.errno != errno.ENOTSUP:
                raise
            attrs = []
        for a in sorted(attrs):
            ab = a if isinstance(a, bytes) else os.fsencode(a)
            if not ab.startswith(b'user.'):
                continue
            lines.append('%s %s %s' % (
                quote(rel), ab.decode('ascii'),
                os.getxattr(full, a, follow_symlinks=False).hex()))
with open(sys.argv[2], 'w', newline='\n') as f:
    for ln in sorted(lines):
        f.write(ln + '\n')
PYEOF
}

# ED tree -> out.manifest (D3 dump, doins/README.md's format).
dump_tree() { # <treedir> <out.manifest>
  python3 - "$1" "$2" "$SCRATCH" <<'PYEOF'
import errno, hashlib, os, stat as statm, sys
tree = os.fsencode(sys.argv[1])
out_p = sys.argv[2]
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
    raise e
raw = []
for dp, dns, fns in os.walk(tree, onerror=fail):
    for name in dns + fns:
        full = os.path.join(dp, name)
        st = os.lstat(full)
        raw.append((os.path.relpath(full, tree), full, st))
raw.sort(key=lambda r: quote(r[0]))
classes, order = {}, []
for rel, full, st in raw:
    if statm.S_ISREG(st.st_mode) and st.st_nlink > 1:
        key = (st.st_dev, st.st_ino)
        if key not in classes:
            classes[key] = 'h%d' % len(order)
            order.append(key)
scratch_s = sys.argv[3]
lines = []
for rel, full, st in raw:
    q = quote(rel)
    uid, gid = st.st_uid, st.st_gid
    xcols = []
    try:
        attrs = os.listxattr(full, follow_symlinks=False)
    except OSError as e:
        if e.errno != errno.ENOTSUP:
            raise
        attrs = []
    for a in sorted(attrs):
        ab = a if isinstance(a, bytes) else os.fsencode(a)
        if not ab.startswith(b'user.'):
            continue
        xcols.append('xattr:%s=%s' % (
            ab.decode('ascii'), os.getxattr(full, a, follow_symlinks=False).hex()))
    x = (' ' + ' '.join(xcols)) if xcols else ''
    if statm.S_ISDIR(st.st_mode):
        lines.append('d %04o %d %d - - %s%s' % (st.st_mode & 0o7777, uid, gid, q, x))
    elif statm.S_ISREG(st.st_mode):
        h = open(full, 'rb').read()
        cols = 'f %04o %d %d %d sha256:%s %s' % (
            st.st_mode & 0o7777, uid, gid, len(h), hashlib.sha256(h).hexdigest(), q)
        if statm.S_ISREG(st.st_mode) and st.st_nlink > 1:
            cols += ' hlink=%s' % classes[(st.st_dev, st.st_ino)]
        lines.append(cols + x)
    elif statm.S_ISLNK(st.st_mode):
        lines.append('l ---- %d %d - - %s -> %s%s' % (
            uid, gid, q, quote(os.readlink(full)), x))
    else:
        raise SystemExit('unsupported file type: %r' % (full,))
with open(out_p, 'w', newline='\n') as f:
    for ln in lines:
        ln = ln.replace(scratch_s, '<SCRATCH>')
        f.write(ln + '\n')
PYEOF
}

write_readme() { # <case> <run-shape-text>
  local kc=$1 shape=$2
  {
    printf 'xattr oracle case: %s\n\n' "$kc"
    case_blurb "$kc"
    printf '\nRun shape: %s\n' "$shape"
    printf 'Regenerate with fixtures/helpers/generate-xattr.sh.\n'
    printf '\nProvenance (D4):\n'
    printf '  portage-ref: %s\n' "$PORTAGE_REF"
    printf '  portage-commit: %s (3rdparty/repos.toml [portage] commit)\n' "$PORTAGE_COMMIT"
    printf '  worktree-commit: %s\n' "$WORKTREE_COMMIT"
    printf '  python: %s (%s)\n' "$PYTHON_VERSION" "$PYTHON"
    printf '  uid: %s, umask: 022 (enforced)\n' "$RUN_UID"
    printf '  staging: %s (raw non-UTF-8 names OK: %s)\n' "$STAGE_FS" "$([ "$RAW_NAMES_OK" -eq 1 ] && echo yes || echo no)"
    printf '  xattr-fs: %s\n' "$XATTR_FS"
    printf '  generator-locale: LANG=C.utf8 (enforced); charmap=%s\n' "$GEN_CHARMAP"
    printf '  date: %s (UTC day granularity; the only field that may change\n' "$RUN_DATE"
    printf '    between regenerations)\n'
    # shellcheck disable=SC2016
    printf '  scrub: <SCRATCH>/<CHECKOUT> in args/stdin/out/stderr/stdout\n'
  } >"$XATTR_DIR/$kc/README"
}

publish_basic() { # <case> <stage>
  local kc=$1 stage=$2 casedir="$XATTR_DIR/$1"
  cp "$stage/args" "$casedir/args"
  if [[ -f "$stage/stdin" ]]; then cp "$stage/stdin" "$casedir/stdin"; else rm -f "$casedir/stdin"; fi
  cp "$stage/env" "$casedir/env"
  if [[ -s "$stage/out" ]]; then cp "$stage/out" "$casedir/out.txt"; else rm -f "$casedir/out.txt"; fi
  cp "$stage/stderr" "$casedir/stderr.txt"
  cp "$stage/rc" "$casedir/rc.txt"
}

# --- runners ------------------------------------------------------------------

# xattr-helper.py dump/restore with a checked-in stdin (or none).
run_helper_text() { # <case> <script>
  local kc=$1 script=$2 casedir="$XATTR_DIR/$1"
  local stage="$SCRATCH/stage-$kc"
  rm -rf "$stage"; mkdir -p "$stage/in"
  if [[ -f "$casedir/in.manifest" ]]; then
    python3 "$DOINS_DIR/materialise.py" "$casedir/in.manifest" "$stage/in" "$stage/in" "$stage/in"
  fi
  if [[ -f "$casedir/xattrs" ]]; then
    apply_xattrs "$casedir/xattrs" "$stage/in"
  fi
  build_env "$casedir/env"
  build_argv "$casedir/args"
  cp "$casedir/args" "$stage/args"; cp "$casedir/env" "$stage/env"
  local rc=0
  if [[ -f "$casedir/stdin" ]]; then
    sub_in "$casedir/stdin" "$stage/stdin.raw"
    cp "$stage/stdin.raw" "$stage/stdin"
    scrub "$stage/stdin"
    ( cd "$stage" && env -i "${ENV_ARGS[@]}" "$PYTHON" "$PORTAGE_CHECKOUT/bin/$script" "${ARGV[@]}" \
      <"$stage/stdin.raw" >"$stage/out" 2>"$stage/stderr" ) || rc=$?
  else
    rm -f "$casedir/stdin"
    ( cd "$stage" && env -i "${ENV_ARGS[@]}" "$PYTHON" "$PORTAGE_CHECKOUT/bin/$script" "${ARGV[@]}" \
      >"$stage/out" 2>"$stage/stderr" ) || rc=$?
  fi
  printf '%s\n' "$rc" >"$stage/rc"
  scrub "$stage/out"; scrub "$stage/stderr"
  publish_basic "$kc" "$stage"
}

# restore-roundtrip: stdin is a genuine real --dump of the src tree.
run_restore_roundtrip() {
  local kc=restore-roundtrip casedir="$XATTR_DIR/restore-roundtrip"
  local stage="$SCRATCH/stage-$kc"
  rm -rf "$stage"; mkdir -p "$stage/in" "$stage/src"
  python3 "$DOINS_DIR/materialise.py" "$casedir/in.manifest" "$stage/in" "$stage/in" "$stage/in"
  python3 "$DOINS_DIR/materialise.py" "$casedir/src.manifest" "$stage/src" "$stage/src" "$stage/src"
  apply_xattrs "$casedir/src.xattrs" "$stage/src"
  build_env "$casedir/env"
  # Dump each source (argv form, pairs order) and rewrite to the dest paths.
  : >"$stage/stdin.raw"
  while read -r src_q _ || [[ -n $src_q ]]; do
    [[ -z "$src_q" ]] && continue
    ( cd "$stage" && env -i "${ENV_ARGS[@]}" "$PYTHON" "$PORTAGE_CHECKOUT/bin/xattr-helper.py" \
      --dump "$stage/src/$src_q" >>"$stage/stdin.raw" 2>"$stage/dump-err" ) \
      || die "$kc: dump of src $src_q failed"
    [[ -s "$stage/dump-err" ]] && die "$kc: dump of src $src_q wrote stderr"
  done <"$casedir/pairs"
  python3 - "$stage/stdin.raw" "$stage/src" "$stage/in" "$casedir/pairs" <<'PYEOF'
import sys
p, src, dst, pairs_p = sys.argv[1:5]
data = open(p, 'rb').read()
for line in open(pairs_p, encoding='ascii'):
    line = line.rstrip('\n')
    if not line:
        continue
    src_q, dst_q = line.split(' ')
    old = b'# file: ' + src.encode() + b'/' + src_q.encode() + b'\n'
    new = b'# file: ' + dst.encode() + b'/' + dst_q.encode() + b'\n'
    assert data.count(old) == 1, (old, data.count(old))
    data = data.replace(old, new)
open(p, 'wb').write(data)
PYEOF
  cp "$stage/stdin.raw" "$stage/stdin"
  scrub "$stage/stdin"
  build_argv "$casedir/args"
  cp "$casedir/args" "$stage/args"; cp "$casedir/env" "$stage/env"
  local rc=0
  ( cd "$stage" && env -i "${ENV_ARGS[@]}" "$PYTHON" "$PORTAGE_CHECKOUT/bin/xattr-helper.py" \
    "${ARGV[@]}" <"$stage/stdin.raw" >"$stage/out" 2>"$stage/stderr" ) || rc=$?
  printf '%s\n' "$rc" >"$stage/rc"
  scrub "$stage/out"; scrub "$stage/stderr"
  publish_basic "$kc" "$stage"
  dump_xattrs "$stage/in" "$stage/out.xattrs"
  cp "$stage/out.xattrs" "$casedir/out.xattrs"
  write_readme "$kc" "cwd=<stage>; real \`xattr-helper.py --restore\` (no extra argv) with stdin = the real \`--dump\` of the src tree (src.manifest + src.xattrs, pairs order) with \`# file:\` lines rewritten to the fresh dest files (in.manifest); out.xattrs dumps the resulting user.* xattrs."
}

# install.py as the xattr/install wrapper runs it.
run_install() { # <case>
  local kc=$1 casedir="$XATTR_DIR/$1"
  local stage="$SCRATCH/stage-$kc"
  rm -rf "$stage"; mkdir -p "$stage/src" "$stage/dest"
  if [[ -f "$casedir/in.manifest" ]]; then
    python3 "$DOINS_DIR/materialise.py" "$casedir/in.manifest" "$stage/src" "$stage/src" "$stage/src"
  fi
  if [[ -f "$casedir/xattrs" ]]; then
    apply_xattrs "$casedir/xattrs" "$stage/src"
  fi
  build_env "$casedir/env"
  build_argv "$casedir/args"
  cp "$casedir/args" "$stage/args"; cp "$casedir/env" "$stage/env"
  rm -f "$casedir/stdin" "$stage/stdin"
  local rc=0
  ( cd "$PORTAGE_CHECKOUT/lib" && env -i "${ENV_ARGS[@]}" "$PYTHON" "$PORTAGE_CHECKOUT/bin/install.py" \
    "${ARGV[@]}" >"$stage/out" 2>"$stage/stderr" ) || rc=$?
  printf '%s\n' "$rc" >"$stage/rc"
  scrub "$stage/out"; scrub "$stage/stderr"
  publish_basic "$kc" "$stage"
  rm -f "$casedir/stdin"
  if [[ -d "$stage/dest" ]]; then
    dump_tree "$stage/dest" "$stage/out.manifest"
    cp "$stage/out.manifest" "$casedir/out.manifest"
  else
    rm -f "$casedir/out.manifest"
  fi
  write_readme "$kc" "cwd=<checkout>/lib with __PORTAGE_HELPER_CWD=<stage> (as ebuild-helpers/xattr/install runs it: \`export __PORTAGE_HELPER_CWD=\$PWD; cd \$PORTAGE_PYM_PATH\`); real \`install.py <args>\`; out.manifest is the D3 tree dump of <stage>/dest (doins/README.md's format, user.* xattrs included)."
}

NCASES=0
for kc in "${CASES[@]}"; do
  casedir="$XATTR_DIR/$kc"
  [[ -f "$casedir/args" ]] || die "missing $casedir/args"
  [[ -f "$casedir/env" ]] || die "missing $casedir/env"
  case $kc in
    restore-roundtrip)
      [[ -f "$casedir/in.manifest" ]] || die "missing $casedir/in.manifest"
      [[ -f "$casedir/src.manifest" ]] || die "missing $casedir/src.manifest"
      [[ -f "$casedir/src.xattrs" ]] || die "missing $casedir/src.xattrs"
      [[ -f "$casedir/pairs" ]] || die "missing $casedir/pairs"
      run_restore_roundtrip
      ;;
    install-*)
      run_install "$kc"
      ;;
    argv-*)
      run_helper_text "$kc" "xattr-helper.py"
      write_readme "$kc" "cwd=<stage>; real \`xattr-helper.py <args>\` with empty stdin (argv errors and --help never touch the tree)."
      ;;
    dump-missing | dump-newline-joined)
      [[ -f "$casedir/in.manifest" ]] || die "missing $casedir/in.manifest"
      [[ -f "$casedir/stdin" ]] || die "missing $casedir/stdin"
      run_helper_text "$kc" "xattr-helper.py"
      write_readme "$kc" "cwd=<stage>; real \`xattr-helper.py --dump\` with the checked-in stdin fed raw (estrip's \`--dump < <(echo -n ...)\` shape); in.manifest + xattrs are the input tree."
      ;;
    dump-argv)
      [[ -f "$casedir/in.manifest" ]] || die "missing $casedir/in.manifest"
      run_helper_text "$kc" "xattr-helper.py"
      write_readme "$kc" "cwd=<stage>; real \`xattr-helper.py --dump <path>\` with the path as argv (no stdin at all); in.manifest + xattrs are the input tree."
      ;;
    dump-* | restore-malformed | restore-no-pathname | restore-missing-file)
      script=xattr-helper.py
      run_helper_text "$kc" "$script"
      if [[ $kc == dump-* ]]; then
        write_readme "$kc" "cwd=<stage>; real \`xattr-helper.py --dump\` with the checked-in stdin fed raw (estrip's \`--dump < <(echo -n ...)\` shape, single path without trailing newline unless the case says otherwise); in.manifest + xattrs are the input tree."
      else
        write_readme "$kc" "cwd=<stage>; real \`xattr-helper.py --restore\` with the checked-in stdin fed raw; in.manifest is the (fresh) dest tree."
      fi
      ;;
  esac
  NCASES=$(( NCASES + 1 ))
done

printf 'generate-xattr.sh: wrote %d xattr cases.\n' "$NCASES"
