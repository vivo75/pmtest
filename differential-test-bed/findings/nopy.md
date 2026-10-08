# nopy / noportage findings

[nopy] is the bed image with `sys-apps/portage` unmerged and every
`/usr/bin/python*` removed (only the portuale binary is mounted);
[noportage] is the normal bed image with the `portage` Python package
removed but Python itself kept. Both are defined in the portuale plan
`docs/02.326-no-portage-runtime.opus.md` section 0.7 ([nopy]/[noportage])
and run by `differential-test-bed/run/nopy-build.sh`, which builds an
atom with `portuale emerge -1 --buildpkg` (`BINPKG_FORMAT=gpkg`,
then a `--usepkgonly` re-merge, then a `BINPKG_FORMAT=xpak` build).

## #326 P0 — live helper inventory (2026-10-08)

Runs from `/home/vivo/repo/PORTUALE/pmtest`, one atom per run, sequential,
via `differential-test-bed/run/nopy-build.sh [--variant V] [--bin DIR]
[--env K=V] ATOM`. 16 runs: 5 NO-S1/nopy, 5 WITH-S1/nopy,
5 WITH-S1/noportage, 1 WITH-S1/noportage with `PORTAGE_IPC_DAEMON=1`.

PM HEAD: portuale `5a9fbc33` on `backlog/326`, dirty — the uncommitted S1
fix (`rust/portuale/src/ebuild_package.rs`, `rust/portuale/src/ebuild_phases.rs`:
`PORTAGE_PYM_PATH` falls back to `/` without a checkout). The runner
rebuilds the PM itself, so each report belongs to the binary it used.
pmtest `a9fe70e` on `backlog/326` (plus its working-tree bed files).

Binaries (sha256):

- NO-S1 (commit 5a9fbc33 without the fix, built in the detached worktree
  `/var/tmp/pmtest/wt-326-nos1` with
  `CARGO_TARGET_DIR=/var/tmp/pmtest/wt-326-nos1-target`, copy at
  `/var/tmp/pmtest/wt-326-nos1-bin/portuale`):
  `b3a1daff62e8dc885389fced57db0984bf40ba03e796c321345a0bb593b5278f`
- WITH-S1 (the portuale working tree as-is, with the fix, default registry
  bin dir `/home/vivo/repo/PORTUALE/portuale/rust/target/release`):
  `05fb5281d3636a86f0a9de72f062d961e49cc708cdc0167ed34d32e9392bdaf8`

Image sanity (checked 2026-10-08): nopy image — `compgen -c python`
prints nothing, `/usr/lib/portage` absent, `/usr/bin/python*` absent.
noportage image — python3 kept (`/usr/bin/python3`,
`/usr/lib/python-exec/python3.14/python`), `getfattr`/`setfattr`/
`install-xattr` present.

Runner exit code was 0 for all 16 runs (a failing build is a result, not
a runner error). Every run: step1 rc=1, step2 SKIP, step3 SKIP (steps 2
and 3 need step1's binpkgs). No run produced step2/step3 logs.
`artifacts/binpkgs*` holds only empty directories in every run
(0 files). No `artifacts/build-*.log`, no `installed-porttest.txt` and
no `*-modes.txt` in any run. All 6 noportage step1 logs contain the line
`!!! Unable to unshare (for FEATURES="network-sandbox / ipc-sandbox /
mount-sandbox / pid-sandbox"); src_* phases run without namespace
isolation`; no nopy log contains it.

Delta vs previous report: none — no previous nopy/noportage report
exists. This section is the baseline.

### Run table

| # | binary | variant | env | atom | step1 | step2 | step3 | first failure (phase + message) | run dir |
|---|---|---|---|---|---|---|---|---|---|
| 1 | NO-S1 | nopy | - | app-portage/eix | 1 | SKIP | SKIP | clean: `PORTAGE_PYM_PATH does not exist: ''` (app-shells/push-3.4) | nopy-20261008T140354Z |
| 2 | NO-S1 | nopy | - | porttest/helper-unpack | 1 | SKIP | SKIP | clean: `PORTAGE_PYM_PATH does not exist: ''` | nopy-20261008T140358Z |
| 3 | NO-S1 | nopy | - | porttest/helper-doins | 1 | SKIP | SKIP | clean: `PORTAGE_PYM_PATH does not exist: ''` | nopy-20261008T140400Z |
| 4 | NO-S1 | nopy | - | porttest/helper-docompress | 1 | SKIP | SKIP | clean: `PORTAGE_PYM_PATH does not exist: ''` | nopy-20261008T140402Z |
| 5 | NO-S1 | nopy | - | porttest/helper-package | 1 | SKIP | SKIP | clean: `PORTAGE_PYM_PATH does not exist: ''` | nopy-20261008T140405Z |
| 6 | WITH-S1 | nopy | - | app-portage/eix | 1 | SKIP | SKIP | pretend: `filter-bash-environment.py failed` (app-shells/push-3.4; `/usr/bin/python: No such file or directory`) | nopy-20261008T140409Z |
| 7 | WITH-S1 | nopy | - | porttest/helper-unpack | 1 | SKIP | SKIP | pretend: `filter-bash-environment.py failed` (`/usr/bin/python: No such file or directory`) | nopy-20261008T140413Z |
| 8 | WITH-S1 | nopy | - | porttest/helper-doins | 1 | SKIP | SKIP | pretend: `filter-bash-environment.py failed` (`/usr/bin/python: No such file or directory`) | nopy-20261008T140415Z |
| 9 | WITH-S1 | nopy | - | porttest/helper-docompress | 1 | SKIP | SKIP | pretend: `filter-bash-environment.py failed` (`/usr/bin/python: No such file or directory`) | nopy-20261008T140418Z |
| 10 | WITH-S1 | nopy | - | porttest/helper-package | 1 | SKIP | SKIP | pretend: `filter-bash-environment.py failed` (`/usr/bin/python: No such file or directory`) | nopy-20261008T140420Z |
| 11 | WITH-S1 | noportage | - | app-portage/eix | 1 | SKIP | SKIP | install: `doins failed` (app-shells/push-3.4; `doins.py: No such file or directory`) | nopy-20261008T140423Z |
| 12 | WITH-S1 | noportage | - | porttest/helper-unpack | 1 | SKIP | SKIP | package: `Failed to create binpkg file` (`gpkg-helper.py: No such file or directory`) | nopy-20261008T140426Z |
| 13 | WITH-S1 | noportage | - | porttest/helper-doins | 1 | SKIP | SKIP | install: `doins failed` (`doins.py: No such file or directory`) | nopy-20261008T140429Z |
| 14 | WITH-S1 | noportage | - | porttest/helper-docompress | 1 | SKIP | SKIP | install: `ecompress: one or more files coudn't be compressed` (`ecompress-file: No such file or directory`, 2x) | nopy-20261008T140432Z |
| 15 | WITH-S1 | noportage | - | porttest/helper-package | 1 | SKIP | SKIP | package: `Failed to create binpkg file` (`gpkg-helper.py: No such file or directory`) | nopy-20261008T140436Z |
| 16 | WITH-S1 | noportage | PORTAGE_IPC_DAEMON=1 | porttest/helper-package | 1 | SKIP | SKIP | install: `has_version: unexpected ebuild-ipc exit code: 127` (`ebuild-ipc: No such file or directory`) | nopy-20261008T140440Z |

### Run 1 — NO-S1, nopy, app-portage/eix (`logs/nopy-20261008T140354Z`)

`result.tsv`: step1 1, step2 SKIP, step3 SKIP. Runner rc 0.

First failure in `step1-build-gpkg.log` (clean phase of the push-3.4
dependency; the atom itself was never reached):

```
>>> Emerging (1 of 3) app-shells/push-3.4::gentoo
>>> Building package for app-shells/push-3.4...
/tmp/portuale-rt.3/bin/phase-functions.sh: line 401: cd: null directory
 * ERROR: app-shells/push-3.4::gentoo failed (clean phase):
 *   PORTAGE_PYM_PATH does not exist: ''
 *
 * Call stack:
 *            ebuild.sh, line  838:  Called __ebuild_main 'clean'
 *   phase-functions.sh, line 1216:  Called __dyn_clean
 *   phase-functions.sh, line  402:  Called die
 * The specific snippet of code:
 *   	cd "${PORTAGE_PYM_PATH}" || \
 *   		die "PORTAGE_PYM_PATH does not exist: '${PORTAGE_PYM_PATH}'"
```

Keyword grep (`chmod-lite|ecompress-file|ebuild-ipc|filter-bash-environment|gpkg-helper|xpak-helper|doins.py`):
no matches in the step log; no `artifacts/build-*.log` present.

Artifacts: `artifacts/binpkgs` (empty directory only).

### Run 2 — NO-S1, nopy, porttest/helper-unpack (`logs/nopy-20261008T140358Z`)

`result.tsv`: step1 1, step2 SKIP, step3 SKIP. Runner rc 0.

First failure in `step1-build-gpkg.log` (clean phase):

```
>>> Emerging (1 of 1) porttest/helper-unpack-1.0::porttest
>>> Building package for porttest/helper-unpack-1.0...
/tmp/portuale-rt.6/bin/phase-functions.sh: line 401: cd: null directory
 * ERROR: porttest/helper-unpack-1.0::porttest failed (clean phase):
 *   PORTAGE_PYM_PATH does not exist: ''
 *
 * Call stack:
 *            ebuild.sh, line  838:  Called __ebuild_main 'clean'
 *   phase-functions.sh, line 1216:  Called __dyn_clean
 *   phase-functions.sh, line  402:  Called die
 * The specific snippet of code:
 *   	cd "${PORTAGE_PYM_PATH}" || \
 *   		die "PORTAGE_PYM_PATH does not exist: '${PORTAGE_PYM_PATH}'"
```

Keyword grep: no matches in the step log; no `artifacts/build-*.log`.

Artifacts: `artifacts/binpkgs` (empty directory only). No `workdir-*.txt`,
no `helper-unpack-modes.txt` (unpack never ran).

### Run 3 — NO-S1, nopy, porttest/helper-doins (`logs/nopy-20261008T140400Z`)

`result.tsv`: step1 1, step2 SKIP, step3 SKIP. Runner rc 0.

First failure (clean phase): `phase-functions.sh: line 401: cd: null
directory`, then `ERROR: porttest/helper-doins-1.0::porttest failed
(clean phase): PORTAGE_PYM_PATH does not exist: ''` (same 10-line hunk
shape as run 2, with the atom's own paths).

Keyword grep: no matches; no `artifacts/build-*.log`.

Artifacts: `artifacts/binpkgs` (empty directory only). No
`installed-porttest.txt`.

### Run 4 — NO-S1, nopy, porttest/helper-docompress (`logs/nopy-20261008T140402Z`)

`result.tsv`: step1 1, step2 SKIP, step3 SKIP. Runner rc 0.

First failure (clean phase): `phase-functions.sh: line 401: cd: null
directory`, then `ERROR:
porttest/helper-docompress-1.0::porttest failed (clean phase):
PORTAGE_PYM_PATH does not exist: ''` (same hunk shape as run 2).

Keyword grep: no matches; no `artifacts/build-*.log`.

Artifacts: `artifacts/binpkgs` (empty directory only).

### Run 5 — NO-S1, nopy, porttest/helper-package (`logs/nopy-20261008T140405Z`)

`result.tsv`: step1 1, step2 SKIP, step3 SKIP. Runner rc 0.

First failure (clean phase): `phase-functions.sh: line 401: cd: null
directory`, then `ERROR: porttest/helper-package-1.0::porttest failed
(clean phase): PORTAGE_PYM_PATH does not exist: ''` (same hunk shape
as run 2).

Keyword grep: no matches; no `artifacts/build-*.log`.

Artifacts: `artifacts/binpkgs` (empty directory only). No
`installed-porttest.txt`.

### Run 6 — WITH-S1, nopy, app-portage/eix (`logs/nopy-20261008T140409Z`)

`result.tsv`: step1 1, step2 SKIP, step3 SKIP. Runner rc 0.

First failure in `step1-build-gpkg.log` (pretend phase of the push-3.4
dependency; clean passed — the log's `Working directory: '/'` line
shows the fallback):

```
>>> Emerging (1 of 3) app-shells/push-3.4::gentoo
>>> Building package for app-shells/push-3.4...
/tmp/portuale-rt.3/bin/phase-functions.sh: line 206: /usr/bin/python: No such file or directory
 * ERROR: app-shells/push-3.4::gentoo failed (pretend phase):
 *   filter-bash-environment.py failed
 *
 * Call stack:
 *            ebuild.sh, line  838:  Called __ebuild_main 'pretend'
 *   phase-functions.sh, line 1261:  Called ___save_and_filter_ebuild_env '/var/tmp/portage/app-shells/push-3.4/temp/environment' '--filter-features'
 *   phase-functions.sh, line  250:  Called __filter_readonly_variables '--filter-features'
 *   phase-functions.sh, line  207:  Called die
 * The specific snippet of code:
 *   	"${PORTAGE_PYTHON:-/usr/bin/python}" "${PORTAGE_BIN_PATH}"/filter-bash-environment.py "${filtered_vars[*]}" \
 *   	|| die "filter-bash-environment.py failed"
```

The run ends with `emerge: app-shells/push-3.4: merge failed (127)`.

Keyword grep (3 distinct messages, 1 occurrence each — lines 22, 30, 31):

- `filter-bash-environment.py failed` (x1)
- `"${PORTAGE_PYTHON:-/usr/bin/python}" "${PORTAGE_BIN_PATH}"/filter-bash-environment.py "${filtered_vars[*]}" \` (x1)
- `|| die "filter-bash-environment.py failed"` (x1)

No `chmod-lite|ecompress-file|ebuild-ipc|gpkg-helper|xpak-helper|doins.py`
matches; no `artifacts/build-*.log`.

Artifacts: `artifacts/binpkgs` (empty directory only).

### Run 7 — WITH-S1, nopy, porttest/helper-unpack (`logs/nopy-20261008T140413Z`)

`result.tsv`: step1 1, step2 SKIP, step3 SKIP. Runner rc 0.

First failure (pretend phase):

```
/tmp/portuale-rt.6/bin/phase-functions.sh: line 206: /usr/bin/python: No such file or directory
 * ERROR: porttest/helper-unpack-1.0::porttest failed (pretend phase):
 *   filter-bash-environment.py failed
```

followed by the same call stack (`__ebuild_main 'pretend'` ...
`___save_and_filter_ebuild_env ... '--filter-features'` ...
`__filter_readonly_variables` ... `die`) and snippet as run 6.

Keyword grep: the same 3 `filter-bash-environment` messages, 1x each;
no other keyword matches; no `artifacts/build-*.log`.

Artifacts: `artifacts/binpkgs` (empty directory only). No `workdir-*.txt`,
no `helper-unpack-modes.txt` (unpack never ran).

### Run 8 — WITH-S1, nopy, porttest/helper-doins (`logs/nopy-20261008T140415Z`)

`result.tsv`: step1 1, step2 SKIP, step3 SKIP. Runner rc 0.

First failure (pretend phase): `/usr/bin/python: No such file or
directory`, then `ERROR: porttest/helper-doins-1.0::porttest failed
(pretend phase): filter-bash-environment.py failed` (same hunk shape
as run 7).

Keyword grep: the same 3 `filter-bash-environment` messages, 1x each;
no other keyword matches; no `artifacts/build-*.log`.

Artifacts: `artifacts/binpkgs` (empty directory only). No
`installed-porttest.txt`.

### Run 9 — WITH-S1, nopy, porttest/helper-docompress (`logs/nopy-20261008T140418Z`)

`result.tsv`: step1 1, step2 SKIP, step3 SKIP. Runner rc 0.

First failure (pretend phase): `/usr/bin/python: No such file or
directory`, then `ERROR: porttest/helper-docompress-1.0::porttest
failed (pretend phase): filter-bash-environment.py failed` (same hunk
shape as run 7).

Keyword grep: the same 3 `filter-bash-environment` messages, 1x each;
no other keyword matches; no `artifacts/build-*.log`.

Artifacts: `artifacts/binpkgs` (empty directory only).

### Run 10 — WITH-S1, nopy, porttest/helper-package (`logs/nopy-20261008T140420Z`)

`result.tsv`: step1 1, step2 SKIP, step3 SKIP. Runner rc 0.

First failure (pretend phase): `/usr/bin/python: No such file or
directory`, then `ERROR: porttest/helper-package-1.0::porttest failed
(pretend phase): filter-bash-environment.py failed` (same hunk shape
as run 7).

Keyword grep: the same 3 `filter-bash-environment` messages, 1x each;
no other keyword matches; no `artifacts/build-*.log`.

Artifacts: `artifacts/binpkgs` (empty directory only). No
`installed-porttest.txt`.

### Run 11 — WITH-S1, noportage, app-portage/eix (`logs/nopy-20261008T140423Z`)

`result.tsv`: step1 1, step2 SKIP, step3 SKIP. Runner rc 0.

First failure in `step1-build-gpkg.log` (install phase of push-3.4;
unpack and src phases passed):

```
>>> Emerging (1 of 3) app-shells/push-3.4::gentoo
>>> Building package for app-shells/push-3.4...
!!! Unable to unshare (for FEATURES="network-sandbox / ipc-sandbox / mount-sandbox / pid-sandbox"); src_* phases run without namespace isolation
find: ‘/tmp/portuale-rt.3/bin/chmod-lite’: No such file or directory
/usr/lib/python-exec/python3.14/python: can't open file '/tmp/portuale-rt.3/bin/doins.py': [Errno 2] No such file or directory
 * ERROR: app-shells/push-3.4::gentoo failed (install phase):
 *   doins failed
```

The run ends with `emerge: app-shells/push-3.4: merge failed (1)`.

Keyword grep (2 distinct messages, 1x each — lines 21, 22):

- `find: ‘/tmp/portuale-rt.3/bin/chmod-lite’: No such file or directory` (x1)
- `/usr/lib/python-exec/python3.14/python: can't open file '/tmp/portuale-rt.3/bin/doins.py': [Errno 2] No such file or directory` (x1)

No `ecompress-file|ebuild-ipc|filter-bash-environment|gpkg-helper|xpak-helper`
matches; no `artifacts/build-*.log`.

Artifacts: `artifacts/binpkgs` (empty directory only), plus
`artifacts/workdir-app-shells_push-3.4.txt` (WORKDIR listing at
container exit, `%m %y %P`):

```
700 d
775 d push-3.4
664 f push-3.4/.gitignore
664 f push-3.4/Makefile
664 f push-3.4/README.md
775 d push-3.4/bin
775 f push-3.4/bin/push.sh
```

### Run 12 — WITH-S1, noportage, porttest/helper-unpack (`logs/nopy-20261008T140426Z`)

`result.tsv`: step1 1, step2 SKIP, step3 SKIP. Runner rc 0.

Unpack and install passed (`Final size of build directory: 6 KiB`,
`Final size of installed tree: 11 KiB`); the log also shows a QA
notice `world writable file(s): //usr/share/porttest/helper-unpack/file0777`.
First failure (package phase):

```
find: ‘/tmp/portuale-rt.6/bin/chmod-lite’: No such file or directory
 * Final size of build directory:  6 KiB
 * Final size of installed tree:  11 KiB
 * QA Notice: world writable file(s):
 *   //usr/share/porttest/helper-unpack/file0777
[... QA boilerplate ...]
/usr/lib/python-exec/python3.14/python: can't open file '/tmp/portuale-rt.6/bin/gpkg-helper.py': [Errno 2] No such file or directory
 * ERROR: porttest/helper-unpack-1.0:: failed (package phase):
 *   Failed to create binpkg file
 *
 * Call stack:
 *   misc-functions.sh, line 743:  Called __dyn_package
 *   misc-functions.sh, line 626:  Called die
 * The specific snippet of code:
 *   			die "Failed to create binpkg file"
```

The run ends with `emerge: porttest/helper-unpack-1.0: merge failed (1)`.

Keyword grep (2 distinct messages, 1x each — lines 19, 27):

- `find: ‘/tmp/portuale-rt.6/bin/chmod-lite’: No such file or directory` (x1)
- `/usr/lib/python-exec/python3.14/python: can't open file '/tmp/portuale-rt.6/bin/gpkg-helper.py': [Errno 2] No such file or directory` (x1)

No `ecompress-file|ebuild-ipc|filter-bash-environment|xpak-helper|doins.py`
matches; no `artifacts/build-*.log`.

Artifacts: `artifacts/binpkgs/porttest/helper-unpack` (empty
directories only, 0 files). No `workdir-*.txt` and no
`helper-unpack-modes.txt` were captured for this run, so the recorded
WORKDIR modes are absent; the only modes evidence is the QA notice
above. Against the real-Portage oracle (644 file0600 / 755 file0777 /
755 sub0700 / 644 sub0700/nested0640 / 755 sub0775): file0777 is
observed world-writable in the installed tree instead of 755; the other
four entries are NOT OBSERVED (no modes.txt, no workdir listing).

### Run 13 — WITH-S1, noportage, porttest/helper-doins (`logs/nopy-20261008T140429Z`)

`result.tsv`: step1 1, step2 SKIP, step3 SKIP. Runner rc 0.

First failure in `step1-build-gpkg.log` (install phase):

```
>>> Emerging (1 of 1) porttest/helper-doins-1.0::porttest
>>> Building package for porttest/helper-doins-1.0...
!!! Unable to unshare (for FEATURES="network-sandbox / ipc-sandbox / mount-sandbox / pid-sandbox"); src_* phases run without namespace isolation
/usr/lib/python-exec/python3.14/python: can't open file '/tmp/portuale-rt.6/bin/doins.py': [Errno 2] No such file or directory
 * ERROR: porttest/helper-doins-1.0::porttest failed (install phase):
 *   doins failed
```

The run ends with `emerge: porttest/helper-doins-1.0: merge failed (1)`.

Keyword grep (1 distinct message, 1x — line 19):

- `/usr/lib/python-exec/python3.14/python: can't open file '/tmp/portuale-rt.6/bin/doins.py': [Errno 2] No such file or directory` (x1)

No `chmod-lite` line in this log (the ebuild sets up its source tree
without unpacking a tarball). No other keyword matches; no
`artifacts/build-*.log`.

Artifacts: `artifacts/binpkgs` (empty directory only), plus
`artifacts/workdir-porttest_helper-doins-1.0.txt` (the ebuild-created
source tree; install never ran):

```
700 d
755 d doins-src
644 f doins-src/99pt-helper-doins
644 f doins-src/README.porttest
755 d doins-src/payload
777 l doins-src/payload/abs-link
644 f doins-src/payload/hard-a
644 f doins-src/payload/hard-b
755 d doins-src/payload/nested
644 f doins-src/payload/nested/inner.txt
644 f doins-src/payload/plain.txt
777 l doins-src/payload/rel-link
644 f doins-src/pt-helper-doins.confd
644 f doins-src/pt_helper.h
644 f doins-src/secure.txt
644 f doins-src/single.txt
```

No `installed-porttest.txt` (nothing was installed).

### Run 14 — WITH-S1, noportage, porttest/helper-docompress (`logs/nopy-20261008T140432Z`)

`result.tsv`: step1 1, step2 SKIP, step3 SKIP. Runner rc 0.

Install ran (`Final size of build directory: 8 KiB`, `Final size of
installed tree: 9 KiB`). First failure (install phase):

```
 * Final size of build directory:  8 KiB
 * Final size of installed tree:  9 KiB
/tmp/portuale-rt.6/bin/isolated-functions.sh: line 474: /tmp/portuale-rt.6/bin/ecompress-file: No such file or directory
/tmp/portuale-rt.6/bin/isolated-functions.sh: line 474: /tmp/portuale-rt.6/bin/ecompress-file: No such file or directory
 * ERROR: porttest/helper-docompress-1.0::porttest failed (install phase):
 *   ecompress: one or more files coudn't be compressed
```

The run ends with `emerge: porttest/helper-docompress-1.0: merge
failed (1)`.

Keyword grep (1 distinct message, 2x — lines 21, 22):

- `/tmp/portuale-rt.6/bin/isolated-functions.sh: line 474: /tmp/portuale-rt.6/bin/ecompress-file: No such file or directory` (x2)

No other keyword matches; no `artifacts/build-*.log`.

Artifacts: `artifacts/binpkgs` (empty directory only), plus
`artifacts/workdir-porttest_helper-docompress-1.0.txt`:

```
700 d
755 d docsrc
644 f docsrc/BIG-aux.txt
644 f docsrc/BIG-doc.txt
```

No `installed-porttest.txt` (merge failed).

### Run 15 — WITH-S1, noportage, porttest/helper-package (`logs/nopy-20261008T140436Z`)

`result.tsv`: step1 1, step2 SKIP, step3 SKIP. Runner rc 0.

Install ran (`Final size of build directory: 1 KiB`, `Final size of
installed tree: 12 KiB`). First failure (package phase):

```
/usr/lib/python-exec/python3.14/python: can't open file '/tmp/portuale-rt.6/bin/gpkg-helper.py': [Errno 2] No such file or directory
 * ERROR: porttest/helper-package-1.0:: failed (package phase):
 *   Failed to create binpkg file
 *
 * Call stack:
 *   misc-functions.sh, line 743:  Called __dyn_package
 *   misc-functions.sh, line 626:  Called die
 * The specific snippet of code:
 *   			die "Failed to create binpkg file"
```

The run ends with `emerge: porttest/helper-package-1.0: merge failed (1)`.

Keyword grep (1 distinct message, 1x — line 21):

- `/usr/lib/python-exec/python3.14/python: can't open file '/tmp/portuale-rt.6/bin/gpkg-helper.py': [Errno 2] No such file or directory` (x1)

No other keyword matches; no `artifacts/build-*.log`.

Artifacts: `artifacts/binpkgs/porttest/helper-package` (empty
directories only, 0 files). No `installed-porttest.txt` (merge failed).

### Run 16 — WITH-S1, noportage, PORTAGE_IPC_DAEMON=1, porttest/helper-package (`logs/nopy-20261008T140440Z`)

`result.tsv`: step1 1, step2 SKIP, step3 SKIP. Runner rc 0.
Extra container env: `-e PORTAGE_IPC_DAEMON=1` (recorded in `env.txt`).

Install ran (`Final size of build directory: 1 KiB`, `Final size of
installed tree: 12 KiB`). First failure (install phase, inside
`install_qa_check` → `60python-site` → `has_version`):

```
/tmp/portuale-rt.6/bin/phase-functions.sh: line 1272: /tmp/portuale-rt.6/bin/ebuild-ipc: No such file or directory
(repeated: lines 18, 19, 20, 22, 23, 24, 25, 26 and 29)
[... sizes ...]
/tmp/portuale-rt.6/bin/phase-functions.sh: line 1272: /tmp/portuale-rt.6/bin/ebuild-ipc: No such file or directory
env: ‘/tmp/portuale-rt.6/bin/ebuild-ipc’: No such file or directory
 * ERROR: porttest/helper-package-1.0::porttest failed (install phase):
 *   has_version: unexpected ebuild-ipc exit code: 127
 *
 * Call stack:
 *         misc-functions.sh, line 743:  Called install_qa_check
 *         misc-functions.sh, line 129:  Called source '/var/db/repos/gentoo/metadata/install-qa-check.d/60python-site'
 *           60python-site, line 311:  Called python_site_check
 *           60python-site, line  49:  Called nonfatal 'has_version' '>=dev-python/gpep517-8'
 *   isolated-functions.sh, line  86:  Called has_version '>=dev-python/gpep517-8'
 *        phase-helpers.sh, line 944:  Called ___best_version_and_has_version_common '>=dev-python/gpep517-8'
 *        phase-helpers.sh, line 929:  Called die
 * The specific snippet of code:
 *   				die "${FUNCNAME[1]}: unexpected ebuild-ipc exit code: ${retval}"
/tmp/portuale-rt.6/bin/isolated-functions.sh: line 200: /tmp/portuale-rt.6/bin/ebuild-ipc: No such file or directory
```

The run ends with `emerge: porttest/helper-package-1.0: merge failed (1)`.

Keyword grep (3 distinct messages — 13 `ebuild-ipc` token hits total):

- `/tmp/portuale-rt.6/bin/phase-functions.sh: line 1272: /tmp/portuale-rt.6/bin/ebuild-ipc: No such file or directory` (x9)
- `env: ‘/tmp/portuale-rt.6/bin/ebuild-ipc’: No such file or directory` (x1)
- `has_version: unexpected ebuild-ipc exit code: 127` plus the `die "${FUNCNAME[1]}: unexpected ebuild-ipc exit code: ${retval}"` snippet line (x1 each)
- `/tmp/portuale-rt.6/bin/isolated-functions.sh: line 200: /tmp/portuale-rt.6/bin/ebuild-ipc: No such file or directory` (x1)

No `chmod-lite|ecompress-file|filter-bash-environment|gpkg-helper|xpak-helper|doins.py`
matches; no `artifacts/build-*.log`.

Artifacts: `artifacts/binpkgs` (empty directory only), plus
`artifacts/workdir-porttest_helper-package-1.0.txt`, whose full content is:

```
700 d
```

No `installed-porttest.txt` (merge failed).

### Plan section 0.3 helper table — observed outcomes

| 0.3 row (call site → helper) | Observed outcome |
|---|---|
| `phase-functions.sh:206` → `filter-bash-environment.py` (every phase) | Observed in runs 6–10 (WITH-S1, nopy): pretend phase, `${PORTAGE_PYTHON:-/usr/bin/python} .../filter-bash-environment.py` fails with `/usr/bin/python: No such file or directory`, then `die "filter-bash-environment.py failed"`. In runs 11–16 (WITH-S1, noportage) every build passes pretend and later phases, so the filter ran there. Not reached in runs 1–5 (clean dies first). |
| `misc-functions.sh:622` → `gpkg-helper.py compress` (`__dyn_package`, gpkg) | Observed in run 12 (helper-unpack) and run 15 (helper-package), both WITH-S1 noportage: package phase, `can't open file '.../bin/gpkg-helper.py': [Errno 2]`, then `die "Failed to create binpkg file"`. Not reached in runs 1–10 (earlier failures) nor run 16 (install dies first). |
| `misc-functions.sh:601` → `xpak-helper.py recompose` (`__dyn_package`, xpak) | NOT OBSERVED. No run reached step 3 (`BINPKG_FORMAT=xpak`): every step1 failed, so every step3 is SKIP; the `xpak-helper` token is absent from all 16 step logs. |
| `ebuild-helpers/doins:104-106` → `doins.py` (doins/newins/doheader/doenvd/dodoc/doconfd) | Observed in run 11 (app-portage/eix via push-3.4) and run 13 (helper-doins), both WITH-S1 noportage: install phase, `can't open file '.../bin/doins.py': [Errno 2]`, then `doins failed`. Not reached in runs 1–10 (earlier failures) nor runs 12/14/15/16 (those ebuilds use `cp -a`, not doins, by probe design). |
| `ebuild-helpers/dohtml:15-16` → `dohtml.py` | NOT OBSERVED — never in scope: no run installs an EAPI < 7 ebuild, and the `dohtml` token was not searched for. No run output mentions dohtml. |
| `phase-helpers.sh:511` → `chmod-lite` (end of every unpack) | Observed in run 11 (eix/push-3.4) and run 12 (helper-unpack), both WITH-S1 noportage: `find: '.../bin/chmod-lite': No such file or directory` (1x each); unpack/install continue (silent). Run 12 additionally shows `QA Notice: world writable file(s): //usr/share/porttest/helper-unpack/file0777`. Not reached in runs 1–10 (earlier failures); absent from runs 13–16 logs (those ebuilds unpack no tarball / the line never fires). |
| `ecompress:264` → `ecompress-file` (every docompress file) | Observed in run 14 (helper-docompress, WITH-S1 noportage): install phase, `isolated-functions.sh: line 474: .../bin/ecompress-file: No such file or directory` (2x), then `ecompress: one or more files coudn't be compressed`. Not reached in any other run. |
| `estrip:306,325` → `xattr-helper.py --dump/--restore` (only without getfattr/setfattr) | NOT OBSERVED. The `xattr-helper` token is absent from all 16 step logs; the noportage image ships `getfattr`/`setfattr`, and no run reached a state invoking the fallback. |
| `ebuild-helpers/xattr/install:39-40` → `install.py` (only FEATURES=xattr without install-xattr) | NOT OBSERVED. All runs used `FEATURES="buildpkg -sign"` (no `xattr`); the `install.py`/`install-xattr` tokens are absent from all logs. |
| `install-qa-check.d/90config-impl-decl:102` → `python -c 'import locale...'` (`has_utf8_ctype`) | NOT OBSERVED. The `getlocale`/`has_utf8_ctype`/`90config` tokens are absent from all 16 step logs; no run output shows that QA check running. |
| `ebuild-ipc` (isolated-functions.sh:200, misc-functions.sh:751, phase-functions.sh:1272, phase-helpers.sh:912,929; only with PORTAGE_IPC_DAEMON) | Observed in run 16 only (WITH-S1 noportage, `PORTAGE_IPC_DAEMON=1` in the calling env): install phase, `.../bin/ebuild-ipc: No such file or directory` (9x at phase-functions.sh:1272, 1x via `env:`, 1x at isolated-functions.sh:200), then `has_version: unexpected ebuild-ipc exit code: 127` via install_qa_check → 60python-site. The token is absent from runs 1–15. |

## #326 S2 — bed runs (2026-10-08)

S2 binary (working tree on `backlog/326`, HEAD `46283232` + the uncommitted
S2 change): sha256
`890862078555c8125e09e2569cef6849ef6d3741f9c3c02706602db082de30db`
(`rust/target/release/portuale`, built 2026-10-08T17:41:36Z; registry
reports `46283232-dirty`). pmtest `b518207` on `backlog/326` plus the
working-tree file `differential-test-bed/atomlists/l3-326-helpers.txt`.
Runner exit code 0 for all 4 runs (a failing build is a result, not a
runner error). Every run: step1 rc=1, step2 SKIP, step3 SKIP.

### Run table

| # | variant | atom | step1 | first failure (phase + message) | run dir |
|---|---|---|---|---|---|
| 1 | noportage | app-portage/eix | 1 | install (app-shells/push-3.4 dep): `portuale: no native helper for: python /tmp/portuale-rt.3/bin/doins.py --preserve_symlinks ... --helper=doins --dest=/var/tmp/portage/app-shells/push-3.4/image/usr/share/push -- bin/push.sh`, then `ERROR: app-shells/push-3.4::gentoo failed (install phase): doins failed` | nopy-20261008T190415Z |
| 2 | noportage | porttest/helper-unpack | 1 | package: `portuale: no native helper for: python /tmp/portuale-rt.6/bin/gpkg-helper.py compress helper-unpack-1.0-1 ...`, then `ERROR: porttest/helper-unpack-1.0:: failed (package phase): Failed to create binpkg file` | nopy-20261008T190431Z |
| 3 | noportage | porttest/helper-docompress | 1 | package: `portuale: no native helper for: python /tmp/portuale-rt.6/bin/gpkg-helper.py compress helper-docompress-1.0-1 ...`, then `ERROR: porttest/helper-docompress-1.0:: failed (package phase): Failed to create binpkg file` | nopy-20261008T190438Z |
| 4 | nopy | app-portage/eix | 1 | pretend (app-shells/push-3.4 dep): `portuale: no native helper for: python /tmp/portuale-rt.3/bin/filter-bash-environment.py D EBUILD_PHASE_FUNC ...`, then `ERROR: app-shells/push-3.4::gentoo failed (pretend phase): filter-bash-environment.py failed` | nopy-20261008T190442Z |

### Grep counts (step1-build-gpkg.log)

| run | chmod-lite | ecompress-file | world writable | no native helper | filter-bash-environment |
|---|---|---|---|---|---|
| nopy-20261008T190415Z (noportage eix) | 0 | 0 | 0 | 1 | 0 |
| nopy-20261008T190431Z (noportage helper-unpack) | 0 | 0 | 0 | 1 | 0 |
| nopy-20261008T190438Z (noportage helper-docompress) | 0 | 0 | 0 | 1 | 0 |
| nopy-20261008T190442Z (nopy eix) | 0 | 0 | 0 | 1 | 4 |

### Expectations table

| expectation | verdict | evidence line |
|---|---|---|
| noportage eix gets past src_unpack with no chmod-lite `find:` error | MET | run 1: no `chmod-lite` line at all (count 0); push-3.4 reached the install phase, so unpack (and its trailing chmod-lite) completed |
| noportage eix next fails at doins with the 127 `no native helper` message | MET | run 1: `portuale: no native helper for: python /tmp/portuale-rt.3/bin/doins.py ...` then `failed (install phase): doins failed` (at the push-3.4 dependency; eix itself was not reached) |
| noportage helper-unpack shows no `world writable` QA notice | MET | run 2: `world writable` count 0; install completed (`Final size of installed tree: 11 KiB`) |
| noportage helper-docompress gets past install | MET | run 3: `Final size of installed tree: 9 KiB`; failure is in the package phase (gpkg-helper, S4) |
| nopy eix dies in pretend at the filter with the 127 message | MET | run 4: `portuale: no native helper for: python /tmp/portuale-rt.3/bin/filter-bash-environment.py D ...` then `failed (pretend phase): filter-bash-environment.py failed` |
