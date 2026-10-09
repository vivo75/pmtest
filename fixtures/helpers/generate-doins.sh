#!/usr/bin/env bash
# Regenerate fixtures/helpers/doins/ by RUNNING the real Portage
# ebuild-helpers/doins (plan #326 D4: expected values come from running
# the real helper, never from reasoning about it). Standalone; the
# coordinator wires it into generate.sh.
#
# Per case (doins/<case>/), checked in by hand (the inputs):
#   cmd            the helper-level argv, one line: `<helper> <args...>`
#                  (e.g. `doins -r tree`, `dodoc -r tree/sub tree/file.txt`;
#                  ASCII only, space-separated, run with cwd=<SRC>).
#   env            every variable the wrapper reads, `KEY=value` lines in
#                  LC_ALL=C sorted order, empty value means unset. Scratch
#                  paths use placeholders: @ED@ (D and ED), @T@ (T),
#                  @DISTDIR@ (PORTAGE_ACTUAL_DISTDIR),
#                  @CHECKOUT@ (the Portage checkout),
#                  @PYSHIM@ (the PORTAGE_PYTHON argv-logging shim below).
#                  The generator validates the key set and substitutes the
#                  placeholders; the file doubles as the scrubbed record.
#   in.manifest    the source tree, materialised under <SRC> (see
#                  doins/materialise.py for the format; `@SRC@`/`@DISTDIR@`
#                  in link targets substitute the real trees).
#   ed.manifest    (optional) the pre-existing ED tree, materialised fresh
#                  before every run.
#   dist.manifest  (optional) the PORTAGE_ACTUAL_DISTDIR tree, under @DISTDIR@.
#   xattrs         (optional) `<qpath> <name> <hex-value>` lines applied to
#                  the materialised source tree (user.* attributes).
# Per case, regenerated (the oracle):
#   args           the exact doins.py argv after the script path, one element
#                  per line as raw bytes: `\` is written `\\` and a newline
#                  inside an element `\n` (an element never contains NUL, so
#                  no other escape is needed); <SCRATCH>/<CHECKOUT> are
#                  substituted and newins' random tmpdir suffix is
#                  `newins.RAND`, so the file is stable across runs.
#   out.manifest   the D3 tree dump of ED after the run (format in
#                  doins/README.md).
#   stderr.txt, rc.txt, stdout.txt (only when non-empty).
#   out.root.manifest, stderr.root.txt, rc.root.txt, stdout.root.txt (only
#                  when the root run differs; every case runs as the invoking
#                  user and as root, each on a fresh ED).
#   README         what the case isolates, its regression signature, the run
#                  shape and provenance.
#
# Capture method (D4): PORTAGE_PYTHON points at a wrapper script that
# appends its argv (NUL-separated, one invocation per record) to a log and
# then execs /usr/bin/python with the same argv, so the run itself is real
# and `args` is exactly what the bash wrapper built.
#
# Usage:
#   fixtures/helpers/generate-doins.sh
#   PORTAGE_CHECKOUT=/path/to/portage fixtures/helpers/generate-doins.sh
#
# Requirements: the Portage checkout (default: the sibling checkout at
# ../portuale/3rdparty/portage), /usr/bin/python, python3, setfattr (only
# probed), install(1), passwordless sudo. Scratch lives on tmpfs under /tmp
# (/tmp/pmtest-doins-gen.*) and is removed on exit. /var/tmp is NOT used:
# it is utf8only ZFS here (rejects non-UTF-8 names), its readdir order is
# hash order, and its xattr support differs. user.* xattrs are probed on
# the scratch tmpfs and the result is recorded in every README.
#
# Reproducibility: a second run on the same host leaves every file
# byte-identical except the `date:` line in the READMEs (UTC day
# granularity), which is the only intentionally varying field. Source
# mtimes are pinned (materialise.py MTIME) so the `-p` case is stable;
# stderr/stdout are scrubbed of scratch and checkout paths.

set -euo pipefail
umask 022

DOINS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd -P)/doins"
PMTEST_ROOT="$(cd "$DOINS_DIR/../../.." && pwd -P)"
HELPERS_BIN=""

PORTAGE_CHECKOUT="${PORTAGE_CHECKOUT:-$PMTEST_ROOT/../portuale/3rdparty/portage}"
PORTAGE_CHECKOUT="$(cd "$PORTAGE_CHECKOUT" >/dev/null && pwd -P)" || { echo "generate-doins.sh: bad PORTAGE_CHECKOUT" >&2; exit 1; }
HELPERS_BIN="$PORTAGE_CHECKOUT/bin/ebuild-helpers"
PYTHON=/usr/bin/python

die() { printf 'generate-doins.sh: %s\n' "$*" >&2; exit 1; }

[[ -f "$PORTAGE_CHECKOUT/bin/doins.py" ]] \
  || die "no real doins.py under $PORTAGE_CHECKOUT/bin (set \$PORTAGE_CHECKOUT)"
[[ -x "$HELPERS_BIN/doins" ]] \
  || die "no real ebuild-helpers/doins under $HELPERS_BIN (set \$PORTAGE_CHECKOUT)"
[[ -d "$PORTAGE_CHECKOUT/lib/portage" ]] || die "no lib/portage under $PORTAGE_CHECKOUT"
[[ -x "$PYTHON" ]] || die "no $PYTHON"
[[ -f "$DOINS_DIR/materialise.py" ]] || die "no $DOINS_DIR/materialise.py"
command -v install >/dev/null || die "missing tool: install"
sudo -n true 2>/dev/null || die "passwordless sudo is required for the root runs"

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
RUN_UID="$(id -u)"
RUN_DATE="$(date -u +%Y-%m-%d)"
GEN_CHARMAP="$(LANG=C.utf8 locale charmap 2>/dev/null || echo unknown)"

# --- scratch on tmpfs --------------------------------------------------------
SCRATCH="$(mktemp -d /tmp/pmtest-doins-gen.XXXXXX)"
[[ "$(stat -f -c %T "$SCRATCH")" == tmpfs ]] || die "$SCRATCH is not on tmpfs"
STAGE_FS="$(stat -f -c %T "$SCRATCH")"
cleanup() {
  # the root runs leave root-owned files, hence sudo; only our own scratch
  # directory (matched by pattern) is ever removed
  case "$SCRATCH" in
    /tmp/pmtest-doins-gen.?*) sudo -n rm -rf -- "$SCRATCH" ;;
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

# user.* xattrs must work here (the xattr-exclude case).
if touch "$SCRATCH/.xattr-probe" \
  && setfattr -n user.probe -v ok "$SCRATCH/.xattr-probe" 2>/dev/null \
  && [[ "$(getfattr --only-values -n user.probe "$SCRATCH/.xattr-probe" 2>/dev/null)" == ok ]]; then
  XATTR_FS="user.* xattrs work on $STAGE_FS"
else
  XATTR_FS="user.* xattrs DO NOT work on $STAGE_FS"
fi
rm -f "$SCRATCH/.xattr-probe"

# --- PORTAGE_PYTHON argv-logging shim (the args capture) --------------------
PYSHIM="$SCRATCH/pyshim"
cat >"$PYSHIM" <<'EOF'
#!/usr/bin/env bash
# Appends this invocation's argv (NUL-separated, plus a NUL record
# separator) to $DOINS_ARGV_LOG, then execs the real interpreter, so the
# run itself is real. Byte-transparent: bash never decodes "$@" here.
log=${DOINS_ARGV_LOG:?pyshim: DOINS_ARGV_LOG unset}
for a in "$@"; do printf '%s\0' "$a" >>"$log"; done
printf '\0' >>"$log"
exec /usr/bin/python "$@"
EOF
chmod +x "$PYSHIM"

# --- canonical env key set (every variable the wrapper reads) ----------------
# Empty value means unset. Sorted in LC_ALL=C order; each case env file must
# carry exactly these keys.
CANON_KEYS=(CATEGORY D DIROPTIONS DOINSSTRICTOPTION EAPI EBUILD_PHASE ED EPREFIX FEATURES INSOPTIONS INSDESTTREE LANG NOCOLOR PATH PF PORTAGE_ACTUAL_DISTDIR PORTAGE_BIN_PATH PORTAGE_PYM_PATH PORTAGE_PYTHON PORTAGE_PYTHONPATH PORTAGE_REPO_NAME PORTAGE_XATTR_EXCLUDE T __E_DOCDESTTREE __E_INSDESTTREE)

# Cases in run order.
CASES=(files-no-r dirs-only-no-r recursive newins insopts-mode insopts-preserve diropts-mode owner-root unknown-lax unknown-strict dodoc-r doheader doconfd xattr-exclude missing-source die-eapi8 nodie-eapi3 distdir-deref eapi3-copy empty-dir-r phase-defaults-r phase-defaults-files phase-defaults-distfile dangling-abs-kept dangling-abs-nodistdir)

# --- per-case notes: what the case isolates and its regression signature ----
case_blurb() { # <case>
  case $1 in
    files-no-r) cat <<'EOF'
Isolates doins without -r on a mix of files and directories: the files
are installed and the directories are silently skipped (no warning, rc
0). The symlinked dir tree/linkdir is NOT skipped: without -r a
symlink-to-dir still installs as a symlink (main() only treats real
dirs as skippable when --preserve_symlinks is off or the source is not
a link).
If the native port regressed to warning on skipped dirs, stderr.txt
would be non-empty; if it skipped symlinked dirs, tree/linkdir would be
missing from out.manifest.
EOF
      ;;
    dirs-only-no-r) cat <<'EOF'
Isolates doins without -r where every source is a directory: each is
skipped (None, no message), so any_success stays false and doins.py
exits 1 with NO output of its own; the only stderr is the wrapper's
`doins failed` die banner.
If the native port regressed to exiting 0 on all-skipped, rc.txt would
read 0.
EOF
      ;;
    recursive) cat <<'EOF'
Isolates doins -r over the standard tree: nested dirs and files,
an empty dir, a relative and an absolute symlink, a symlinked dir, a
hardlink pair, a dangling symlink and a non-UTF-8 name. Real installs
the absolute symlink (target under the default b"/" distdir, hence
"inside" it) as a regular file with the target's contents, preserves
the relative, dangling and dir symlinks verbatim, and installs the
hardlink pair as two independent files (separate inodes, same bytes).
If the native port regressed to preserving hardlinks, the hlink column
would group tree/hard1 and tree/hard2; if it dereferenced relative
symlinks, tree/link-rel would come out a regular file.
EOF
      ;;
    newins) cat <<'EOF'
Isolates newins (rename): the wrapper copies the source to a mktemp
dir under $T and calls doins on the renamed copy, so args shows a
single doins.py invocation whose source is $T/newins.RANDOM/renamed.txt
(the random suffix is normalised to newins.RAND) with --helper=doins.
If the native port regressed to installing under the old name,
out.manifest would list tree/file.txt instead of renamed.txt.
EOF
      ;;
    insopts-mode) cat <<'EOF'
Isolates insopts -m0600: the installed file gets 0600 while created
parent dirs keep the diroptions default 0755.
If the native port regressed to the 0755 default, tree/file.txt would
come out 0755.
EOF
      ;;
    insopts-preserve) cat <<'EOF'
Isolates insopts -p: installed files keep their source mtimes
(materialise.py pins every source to the same MTIME), so out.manifest
carries an mtime column here and nowhere else. Created dirs still get
fresh mtimes (install_dir never stamps), so dirs carry no mtime even
in this case.
If the native port regressed to fresh mtimes, the mtime column would
differ from the pinned value.
EOF
      ;;
    diropts-mode) cat <<'EOF'
Isolates diropts -m0700 with -r: every dir real itself creates gets
0700 while files keep the insoptions default 0755. Only the exact dest
gets chmodded: makedirs parents (usr, usr/lib) keep their natural 0755,
which is why the dump shows 0755 above usr/lib/probe and 0700 below it.
If the native port regressed to chmodding parents too, usr and usr/lib
would read 0700.
EOF
      ;;
    owner-root) cat <<'EOF'
Isolates insopts -o root -g root. As a non-root user the lchown fails:
real still installs the file (with the copied mode, since chmod never
runs after the failed chown) but logs a "Failed to copy file"
traceback and exits 1. As root the same run is silent, rc 0, owned
0:0 with the parsed default mode 0755. Both runs are recorded.
If the native port regressed to skipping the file on chown failure,
out.manifest would miss tree/file.txt instead of listing it 1000:100.
EOF
      ;;
    unknown-lax) cat <<'EOF'
Isolates an install option doins.py does not parse but install(1)
accepts (-v, verbose): without DOINSSTRICTOPTION real warns "Unknown
install options" and falls back to spawning install(1), rc 0. The
fallback is visible in stdout.txt (`'src' -> 'dest'` lines).
If the native port regressed to refusing unknown options outright,
rc.txt would read 1 and stdout.txt would be absent.
EOF
      ;;
    unknown-strict) cat <<'EOF'
Isolates the same unknown option with DOINSSTRICTOPTION=1
(--strict_option): real refuses after the "Unknown install options"
warning, never creates the dest tree, and dies, rc 1.
If the native port regressed to falling back anyway, rc.txt would
read 0 with an installed file.
EOF
      ;;
    dodoc-r) cat <<'EOF'
Isolates dodoc -r at EAPI 8: the wrapper forces INSOPTIONS=-m0644,
DIROPTIONS empty, dest usr/share/doc/$PF and re-execs doins with
__PORTAGE_HELPER=dodoc, so args shows --helper=dodoc (which changes
doins.py's no--recursive directory branch) and --dest with a trailing
slash. Files come out 0644.
If the native port regressed to the 0755 default, every file here
would read 0755.
EOF
      ;;
    doheader) cat <<'EOF'
Isolates doheader at EAPI 8: dest /usr/include/ (trailing slash, from
the wrapper's INSDESTTREE) with INSOPTIONS forced to -m0644 even at
EAPI 8 (the respects_insopts predicate is false there), --helper=doins.
If the native port regressed to honouring the caller's empty
INSOPTIONS, the header would come out 0755.
EOF
      ;;
    doconfd) cat <<'EOF'
Isolates doconfd at EAPI 8: dest /etc/conf.d/ with INSOPTIONS forced
to -m0644 (same EAPI 8 forcing as doheader), --helper=doins.
If the native port regressed to the 0755 default, the conffile would
read 0755.
EOF
      ;;
    xattr-exclude) cat <<'EOF'
Isolates FEATURES=xattr with a PORTAGE_XATTR_EXCLUDE glob: the source
file carries user.keep and user.drop; real copies only user.keep
(--enable_copy_xattr --xattr_exclude=user.drop in args, fnmatch
against the full attribute name). out.manifest records kept xattrs as
name=hex-value pairs.
If the native port regressed to copying everything, out.manifest
would list user.drop too; if it copied nothing, no xattr column.
EOF
      ;;
    missing-source) cat <<'EOF'
Isolates a missing source file: os.stat raises inside the in-process
runner ("intentionally", per the comment), the traceback propagates
out of main (rc 1), and the wrapper's die banner follows.
If the native port regressed to treating a missing source as skipped,
rc.txt would read 0 or 1 without the FileNotFoundError traceback.
EOF
      ;;
    die-eapi8) cat <<'EOF'
Isolates --helpers_can_die (EAPI 8) on an install_dir failure: the
pre-existing ED tree has a regular file where tree/empty must be
created, makedirs raises, and real lets it propagate (traceback plus
die banner, rc 1).
Compare nodie-eapi3, the same blockage at EAPI 3: the failure is
logged ("install_dir failed.") and swallowed, rc 0. Real differs at
the EAPI 3/4 boundary (___eapi_helpers_can_die), not between EAPI 6
and 8, which both die.
EOF
      ;;
    nodie-eapi3) cat <<'EOF'
Isolates helpers that cannot die (EAPI 3, no --helpers_can_die) on the
same install_dir failure as die-eapi8: real logs "install_dir failed."
with a traceback and continues, rc 0. At EAPI <= 6 the wrapper reads
the legacy INSDESTTREE instead of __E_INSDESTTREE (hence
INSDESTTREE=/usr/lib/probe in env and no --preserve_symlinks /
--helpers_can_die in args).
If the native port regressed to dying here, rc.txt would read 1.
EOF
      ;;
    distdir-deref) cat <<'EOF'
Isolates the PORTAGE_ACTUAL_DISTDIR symlink rule: with --distdir set,
an absolute symlink pointing inside the distdir is dereferenced
(installed as a regular file with the target's contents, so fake-DISTDIR
links are not reproduced), while an absolute symlink outside it and a
relative symlink are preserved verbatim.
If the native port regressed to preserving distdir-internal links,
abs-in-dist would be l rather than f in out.manifest.
EOF
      ;;
    dangling-abs-kept) cat <<'EOF'
Isolates doins -r on an absolute symlink that points outside
PORTAGE_ACTUAL_DISTDIR and dangles (the target is a file the package
itself installs later -- porttest/helper-doins's abs-link, #326 Z): it is
installed as a symlink, never stat'ed.
If the native port regressed to dereferencing it, rc.txt would read 1
with a FileNotFoundError, and payload/abs-link would be missing.
EOF
      ;;
    dangling-abs-nodistdir) cat <<'EOF'
Isolates the --distdir default: with PORTAGE_ACTUAL_DISTDIR unset the
wrapper passes no --distdir, _parse_args turns "" into b"/", every
absolute link target starts with it, and the dangling abs-link is
dereferenced: FileNotFoundError, rc 1. This is why a phase env that
lacks PORTAGE_ACTUAL_DISTDIR breaks dangling-abs-kept's shape.
If the native port regressed to a different default, abs-link would be
installed and rc.txt would read 0.
EOF
      ;;
    eapi3-copy) cat <<'EOF'
Isolates EAPI 3 (no --preserve_symlinks): symlinks install as copies
of their targets (link-rel becomes a regular file with file.txt's
bytes); a dangling symlink aborts the run instead (os.stat raises,
uncaught traceback, rc 1 -- observed in a probe, not pinned here).
If the native port regressed to preserving symlinks at EAPI 3,
link-rel would be l rather than f in out.manifest.
EOF
      ;;
    empty-dir-r) cat <<'EOF'
Isolates doins -r on an empty directory: creating the dest dir counts
as success even with no files (rc 0), pinning the `if not relpath_list:
return True` branch.
If the native port regressed to failing on empty input, rc.txt would
read 1.
EOF
      ;;
    phase-defaults-r) cat <<'EOF'
Isolates doins -r as a real install phase runs it: INSOPTIONS=-m0644
and DIROPTIONS=-m0755 (the phase-helpers.sh defaults),
PORTAGE_ACTUAL_DISTDIR pointing at a scratch distdir that exists, and
FEATURES=xattr with the make.globals PORTAGE_XATTR_EXCLUDE (checked in
single-lined; equivalent, since movefile splits it on any whitespace).
Files come out 0644 (even the 0600 secret.txt), created dirs 0755, the
@SRC@-absolute link stays a link (its target is outside the distdir),
and the two user.keep xattrs survive the default excludes.
If the native port regressed to the empty-option defaults, files would
read 0755; if it dropped xattrs, the xattr columns would be missing.
EOF
      ;;
    phase-defaults-files) cat <<'EOF'
Isolates doins without -r under the same phase defaults: the top-level
files and links install (files 0644, symlinks preserved verbatim,
including the dangling link and the absolute links, whose targets are
outside the distdir). No xattrs are set here, so out.manifest carries
no xattr columns.
If the native port regressed to the 0755 default, every file here would
read 0755; if it dereferenced absolute links, link-abs would come out a
regular file.
EOF
      ;;
    phase-defaults-distfile) cat <<'EOF'
Isolates dodoc on a fetch-style distfile link under the same phase
defaults: tree/manual.pdf is an absolute symlink into
PORTAGE_ACTUAL_DISTDIR, the way a fetch-restricted or $A-linked file
appears under DISTDIR (whose entries are links into the real distdir).
The dodoc wrapper forces its dest (usr/share/doc/$PF) and -m0644, and
real dereferences the link (doins.py only preserves absolute symlinks
pointing outside the distdir), so the dest holds a regular 0644 file
with the distfile's bytes.
If the native port regressed to preserving the link, manual.pdf would
be l rather than f in out.manifest.
EOF
      ;;
  esac
}

# --- argv log -> args file (raw bytes, scrubbed, stable) --------------------
argv_to_args() { # <argv.log> <args-out> <scratch> <checkout>
  python3 - "$1" "$2" "$3" "$4" <<'PYEOF'
import re, sys
log_p, out_p, scratch, checkout = sys.argv[1:5]
blob = open(log_p, 'rb').read()
records, cur = [], []
for elt in blob.split(b'\0'):
    if elt == b'':
        if cur:
            records.append(cur)
            cur = []
    else:
        cur.append(elt)
if cur:
    records.append(cur)
if len(records) != 1:
    sys.exit('expected exactly 1 python invocation, got %d' % len(records))
argv = records[0]
if not argv[0].endswith(b'/doins.py'):
    sys.exit('argv[0] is not doins.py: %r' % (argv[0],))
out = []
for elt in argv[1:]:
    elt = elt.replace(scratch.encode(), b'<SCRATCH>')
    elt = elt.replace(checkout.encode(), b'<CHECKOUT>')
    elt = re.sub(rb'newins\.[A-Za-z0-9]+', b'newins.RAND', elt)
    elt = elt.replace(b'\\', b'\\\\').replace(b'\n', b'\\n')
    out.append(elt)
with open(out_p, 'wb') as f:
    for elt in out:
        f.write(elt + b'\n')
PYEOF
}

# --- ED tree -> out.manifest (D3 dump) ---------------------------------------
dump_tree() { # <treedir> <out.manifest> <mtimes: 0|1>
  # Uses global DUMP_SUDO (empty, or `sudo -n` for root-owned trees the
  # invoking user could not otherwise read, e.g. mode 0600 files).
  "${DUMP_SUDO[@]}" python3 - "$1" "$2" "$3" "$SCRATCH" <<'PYEOF'
import errno, hashlib, os, stat as statm, sys
tree = os.fsencode(sys.argv[1])
out_p, want_mtime = sys.argv[2], sys.argv[3] == '1'
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
raw = []
for dp, dns, fns in os.walk(tree, onerror=fail):
    for name in dns + fns:
        full = os.path.join(dp, name)
        st = os.lstat(full)
        raw.append((os.path.relpath(full, tree), full, st))
raw.sort(key=lambda r: quote(r[0]))
# hardlink classes over (dev, ino), numbered in first-path order
classes, order = {}, []
for rel, full, st in raw:
    if statm.S_ISREG(st.st_mode) and st.st_nlink > 1:
        key = (st.st_dev, st.st_ino)
        if key not in classes:
            classes[key] = 'h%d' % len(order)
            order.append(key)
scratch_s = sys.argv[4]
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
        if want_mtime:
            cols += ' mtime=%d' % st.st_mtime_ns
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
        # Preserved absolute symlinks can point back into the stage (e.g.
        # the distdir-deref case); scrub those like everywhere else so the
        # dump is stable across runs. Sorting used the ED-relative quoted
        # path, so this changes no order.
        ln = ln.replace(scratch_s, '<SCRATCH>')
        f.write(ln + '\n')
PYEOF
}

# --- build ENV_ARGS from the case env file --------------------------------------
# build_env <ed> <t> <dist>  (empty value means unset)
build_env() {
  local ed=$1 t=$2 dist=$3
  ENV_ARGS=()
  PRESERVE_LIST=DOINS_ARGV_LOG
  local line k v
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z "$line" ]] && continue
    k=${line%%=*}; v=${line#*=}
    v=${v//@ED@/$ed}
    v=${v//@T@/$t}
    v=${v//@DISTDIR@/$dist}
    v=${v//@CHECKOUT@/$PORTAGE_CHECKOUT}
    v=${v//@PYSHIM@/$PYSHIM}
    [[ -z "$v" ]] && continue
    ENV_ARGS+=("$k=$v")
    PRESERVE_LIST+=",$k"
  done <"$CASEDIR_ENV"
}

# --- one full run (user or root) ----------------------------------------------
# Uses globals: HELPER_ARGV (array), ENV_ARGS (array), MTIMES, STAGE_SRC.
run_one() { # <run> <stage>   (writes argv/rc/stdout/stderr/out under stage)
  local run=$1 stage=$2
  local ed=$stage/ed t=$stage/t
  rm -rf "$ed" "$t"
  mkdir -p "$t"
  cp -a "$stage/ed0" "$ed"
  : >"$stage/argv-$run.log"
  local rc=0
  if [[ $run == root ]]; then
    # NB: never a VAR=x sudo prefix. The case variables are exported in
    # the subshell and cross sudo via --preserve-env, then env -i rebuilds
    # the exact minimal environment from arguments, as in the user run.
    # sudo keeps cwd, so both runs start in the source tree.
    # shellcheck disable=SC2024 # redirects intentionally outside sudo: outputs stay user-owned.
    ( cd "$STAGE_SRC" && export "${ENV_ARGS[@]}" "DOINS_ARGV_LOG=$stage/argv-$run.log" \
        && sudo -n --preserve-env="$PRESERVE_LIST" env -i "${ENV_ARGS[@]}" \
        "DOINS_ARGV_LOG=$stage/argv-$run.log" \
        bash "$HELPERS_BIN/${HELPER_ARGV[0]}" "${HELPER_ARGV[@]:1}" \
        >"$stage/stdout-$run.txt" 2>"$stage/stderr-$run.txt" ) || rc=$?
  else
    ( cd "$STAGE_SRC" && env -i "${ENV_ARGS[@]}" \
        "DOINS_ARGV_LOG=$stage/argv-$run.log" \
        bash "$HELPERS_BIN/${HELPER_ARGV[0]}" "${HELPER_ARGV[@]:1}" \
        >"$stage/stdout-$run.txt" 2>"$stage/stderr-$run.txt" ) || rc=$?
  fi
  printf '%s\n' "$rc" >"$stage/rc-$run.txt"
  argv_to_args "$stage/argv-$run.log" "$stage/args-$run" "$SCRATCH" "$PORTAGE_CHECKOUT"
  if [[ $run == root ]]; then DUMP_SUDO=(sudo -n); else DUMP_SUDO=(); fi
  dump_tree "$ed" "$stage/out-$run.manifest" "$MTIMES"
  sed -i "s#$SCRATCH#<SCRATCH>#g; s#$PORTAGE_CHECKOUT#<CHECKOUT>#g" \
    "$stage/stderr-$run.txt" "$stage/stdout-$run.txt"
  [[ -s "$stage/stdout-$run.txt" ]] || rm -f "$stage/stdout-$run.txt"
  if [[ $run == root ]]; then
    # hand the tree back to the invoking user for comparison and cleanup;
    # the dump above already recorded the root ownership.
    sudo -n chown -R "$(id -u):$(id -g)" "$ed" "$t" "$stage/out-$run.manifest" || true
  fi
}

NCASES=0
for kc in "${CASES[@]}"; do
  casedir="$DOINS_DIR/$kc"
  [[ -f "$casedir/cmd" ]] || die "missing $casedir/cmd"
  [[ -f "$casedir/env" ]] || die "missing $casedir/env"
  [[ -f "$casedir/in.manifest" ]] || die "missing $casedir/in.manifest"
  # env key set must be exactly the canonical one
  cut -d= -f1 "$casedir/env" >"$SCRATCH/keys.got"
  printf '%s\n' "${CANON_KEYS[@]}" >"$SCRATCH/keys.want"
  cmp -s "$SCRATCH/keys.got" "$SCRATCH/keys.want" \
    || die "$kc: env keys differ from the canonical set (diff: $(diff "$SCRATCH/keys.got" "$SCRATCH/keys.want" | head -5))"
  # helper argv
  cmdline="$(cat "$casedir/cmd")"
  [[ -n "$cmdline" ]] || die "$kc: empty cmd"
  IFS=' ' read -r -a HELPER_ARGV <<<"$cmdline"
  [[ -x "$HELPERS_BIN/${HELPER_ARGV[0]}" ]] || die "$kc: unknown helper ${HELPER_ARGV[0]}"
  MTIMES=0
  [[ "$kc" == insopts-preserve ]] && MTIMES=1
  # stage trees
  stage="$SCRATCH/stage-$kc"
  src="$stage/src" dist="$stage/dist"
  rm -rf "$stage"; mkdir -p "$src" "$dist" "$stage/ed0"
  python3 "$DOINS_DIR/materialise.py" "$casedir/in.manifest" "$src" "$src" "$dist"
  if [[ -f "$casedir/dist.manifest" ]]; then
    python3 "$DOINS_DIR/materialise.py" "$casedir/dist.manifest" "$dist" "$src" "$dist"
  fi
  if [[ -f "$casedir/ed.manifest" ]]; then
    python3 "$DOINS_DIR/materialise.py" "$casedir/ed.manifest" "$stage/ed0" "$src" "$dist"
  fi
  if [[ -f "$casedir/xattrs" ]]; then
    python3 - "$casedir/xattrs" "$src" <<'PYEOF'
import os, re, sys
xp, src = sys.argv[1], os.fsencode(sys.argv[2])
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
    os.setxattr(os.path.join(src, unesc(qpath)), name.encode("ascii"),
                bytes.fromhex(hexval), follow_symlinks=False)
PYEOF
  fi
  # env with placeholders substituted (empty means unset)
  CASEDIR_ENV="$casedir/env"
  STAGE_SRC="$src"
  build_env "$stage/ed" "$stage/t" "$dist"
  # @ED@/@T@ substitute the stage trees, re-materialised fresh before every
  # run, so args stay identical between the runs after scrubbing.
  run_one user "$stage"
  run_one root "$stage"
  # args must be run-independent (placeholders scrubbed); fail loudly if not
  cmp -s "$stage/args-user" "$stage/args-root" \
    || die "$kc: args differ between user and root runs"
  # publish the user run; keep the root run only where it differs
  cp "$stage/args-user" "$casedir/args"
  cp "$stage/out-user.manifest" "$casedir/out.manifest"
  cp "$stage/stderr-user.txt" "$casedir/stderr.txt"
  cp "$stage/rc-user.txt" "$casedir/rc.txt"
  if [[ -f "$stage/stdout-user.txt" ]]; then
    cp "$stage/stdout-user.txt" "$casedir/stdout.txt"
  else
    rm -f "$casedir/stdout.txt"
  fi
  relation=identical
  for pair in "out-user.manifest out-root.manifest:out.manifest out.root.manifest" "stderr-user.txt stderr-root.txt:stderr.txt stderr.root.txt" "rc-user.txt rc-root.txt:rc.txt rc.root.txt"; do
    stage_pair=${pair%%:*}; pub_pair=${pair#*:}
    if ! cmp -s "$stage/${stage_pair% *}" "$stage/${stage_pair#* }"; then
      relation="DIFFER (user ${pub_pair% *} vs root ${pub_pair#* }: see the two files)"
      break
    fi
  done
  if [[ -f "$stage/stdout-user.txt" ]]; then ustdout="$(cat "$stage/stdout-user.txt")"; else ustdout=""; fi
  if [[ -f "$stage/stdout-root.txt" ]]; then rstdout="$(cat "$stage/stdout-root.txt")"; else rstdout=""; fi
  [[ "$ustdout" == "$rstdout" ]] || relation="DIFFER (user stdout.txt vs root stdout.root.txt: see the two files)"
  rm -f "$casedir"/out.root.manifest "$casedir"/stderr.root.txt "$casedir"/rc.root.txt "$casedir"/stdout.root.txt
  if [[ "$relation" != identical ]]; then
    cmp -s "$stage/out-user.manifest" "$stage/out-root.manifest" \
      || cp "$stage/out-root.manifest" "$casedir/out.root.manifest"
    cmp -s "$stage/stderr-user.txt" "$stage/stderr-root.txt" \
      || cp "$stage/stderr-root.txt" "$casedir/stderr.root.txt"
    cmp -s "$stage/rc-user.txt" "$stage/rc-root.txt" \
      || cp "$stage/rc-root.txt" "$casedir/rc.root.txt"
    if [[ "$ustdout" != "$rstdout" ]]; then
      if [[ -f "$stage/stdout-root.txt" ]]; then
        cp "$stage/stdout-root.txt" "$casedir/stdout.root.txt"
      fi
    fi
  fi
  {
    printf 'doins oracle case: %s\n\n' "$kc"
    case_blurb "$kc"
    printf '\nRun exactly as an install phase runs it (bin/ebuild-helpers/%s):\n' "${HELPER_ARGV[0]}"
    printf '  cd <SRC> && env -i <env> %s\n' "$cmdline"
    printf 'with <env> from the checked-in env file (placeholders @ED@ @T@\n'
    printf '@DISTDIR@ @CHECKOUT@ @PYSHIM@ substituted with the stage trees,\n'
    printf 'empty value unset), PORTAGE_PYTHON pointing at the argv-logging\n'
    printf 'shim (see the header), and the checked-in manifests materialised\n'
    printf 'by doins/materialise.py (source mtimes pinned, so -p is stable).\n'
    printf 'File contents are recorded as size + sha256 (out of scope for\n'
    printf 'chmod-lite, in scope here per D3); symlink modes are always ----.\n'
    printf 'args holds the exact doins.py argv after the script path, one\n'
    # shellcheck disable=SC2016 # literal backticks: README text, not expansion.
    printf 'element per line as raw bytes (`\\\\` for backslash, `\\n` for\n'
    printf 'newline; <SCRATCH>/<CHECKOUT> substituted, newins tmpdir suffix\n'
    printf 'as newins.RAND). stdout.txt exists only when non-empty.\n'
    printf '\nProvenance (D4):\n'
    printf '  portage-ref: %s\n' "$PORTAGE_REF"
    printf '  portage-commit: %s (3rdparty/repos.toml [portage] commit)\n' "$PORTAGE_COMMIT"
    printf '  python: %s (%s)\n' "$PYTHON_VERSION" "$PYTHON"
    printf '  uid: %s, umask: 022 (enforced)\n' "$RUN_UID"
    printf '  staging: %s (raw non-UTF-8 names OK: %s)\n' "$STAGE_FS" "$([ "$RAW_NAMES_OK" -eq 1 ] && echo yes || echo no)"
    printf '  xattr-fs: %s\n' "$XATTR_FS"
    printf '  generator-locale: LANG=C.utf8 (enforced); charmap=%s\n' "$GEN_CHARMAP"
    printf '  date: %s (UTC day granularity; the only field that may change\n' "$RUN_DATE"
    printf '    between regenerations)\n'
    # shellcheck disable=SC2016
    printf '  scrub: <SCRATCH>/<CHECKOUT> in args/stderr/stdout; newins.RAND\n'
    printf '  root-vs-user: %s\n' "$relation"
  } >"$casedir/README"
  NCASES=$(( NCASES + 1 ))
done

printf 'generate-doins.sh: wrote %d doins cases.\n' "$NCASES"
