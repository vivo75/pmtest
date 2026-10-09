# `differential-test-bed/` — real-tree validation for portuale

Scaffolding for running `portuale` (and the real `emerge`) against a real
Gentoo tree inside container images.

Two things live here:

1. **The legacy `/init` probes** (`scripts/`, `create-container.bash`) —
   ad-hoc reproducers from earlier slices, run in lexicographic order by
   the container's PID-1 `/init`.
2. **The differential test bed** (`run/`, `compare/`, `layers/`,
   `atomlists/`, `net/`, `images/`) — the structured Portuale-vs-Portage
   comparison described in
   [`docs/history/real-world-testing.md`](../docs/history/real-world-testing.md). Built
   slice by slice; **slice 1 = infra + L0**.

---

## The differential test bed

### Prerequisites

Check them all in one shot: `../scripts/check-prereqs.sh`.

- `podman` + `buildah`; root containers are fine (and preferred where
  they give a cleaner test — see the doc §1.10).
- The `localhost/test-portuale:latest` image:
  `sudo differential-test-bed/create-container.bash`. It bakes the pinned `gentoo` +
  `buildovl` repos, the `porttest` overlay skeleton
  (`images/overlay/porttest/`), and stable portage.
- Host: `python3` + `PyYAML`, and `dev-util/diffoscope` for L2 drill-down.
- `portuale` is built automatically by the `run/` orchestrators
  (`cargo build --release -p portuale`, plus the `emerge`/`ebuild`/`mrg`
  multicall symlinks).

### L0 — resolver parity at real-tree scale

```sh
differential-test-bed/run/l0-resolver.sh                       # full atom list
differential-test-bed/run/l0-resolver.sh differential-test-bed/atomlists/foo.txt
```

Runs `emerge -pv` for every entry in `atomlists/l0-resolve.txt` under
both real portage (`/usr/sbin/emerge`) and portuale
(`/usr/local/bin/emerge`) inside a throwaway container, then
`compare/resolve-compare.py` diffs the merge lists / USE / order /
errors / exit codes. Findings that match `compare/known-divergences.yaml`
are "explained"; the run is green iff none are unexplained **and**
`compare/check-invariants.py` finds no violation in portuale's own output
(the expectation-free checks from `pytests-contract-suite/output_invariants.py`, over each
probe's extra `--json`/`--tree`/`--quiet` runs, plus a zero
unparsed-dependency-token count; report in `invariants.txt`).

Output: `differential-test-bed/logs/l0-<timestamp>/` (raw `emerge` outputs, `meta.tsv`,
`fingerprint.tsv`, `l0-report.txt`, `l0-report.json`);
`differential-test-bed/logs/l0-report.txt` symlinks the latest.

Env: `L0_SKIP_PORTAGE_UPGRADE=1` (skip the `=sys-apps/portage-3.0.82.2`
step), `L0_SKIP_MULTI=1` (skip the `@system`/`@world` whole-graph runs),
`L0_SKIP_INVARIANTS=1` (skip the extra portuale mode runs),
`L0_EMERGE_OPTS`, `PORTTEST_IMAGE`, `PORTTEST_PODMAN`.

### L0 fixture oracle — real `emerge` on the checked-in fixture tree

```sh
differential-test-bed/run/l0-fixture-oracle.sh        # differential-test-bed/atomlists/l0-fixture-oracle.txt
```

Stages a copy of `fixtures/` inside the container (absolute repo
locations, `PORTAGE_REPOSITORIES`, categories, per-ebuild Manifests, the
fixture vdb as the running root — 12 documented deltas in
`layers/l0-fixture-oracle/stage.sh`) and runs real `emerge -p` and
portuale on the same cases through the same comparator as L0, against
`compare/known-divergences-fixture-oracle.yaml`. Real-execution-only:
no contract `CASES` entry, no Python mirror. Findings and their
adjudication: `differential-test-bed/findings/l0-fixture-oracle.md` (backlog #49).

### L1 — merge parity from an identical prebuilt binpkg set

```sh
differential-test-bed/run/l1-merge-from-binpkg.sh                       # the default set
differential-test-bed/run/l1-merge-from-binpkg.sh differential-test-bed/atomlists/l1-porttest.txt   # synthetic edge cases
```

`atomlists/l1-porttest.txt` is the `porttest` synthetic set (§7 of
`docs/history/real-world-testing.md`) — nine fixtures each isolating one
merge-path behaviour (setuid/caps, hardlinks, symlink farm, `keepdir`,
`dodoc`, `INSTALL_MASK`, `pkg_*` phase markers, `splitdebug`, unicode
names). Live-mounted from `images/overlay/porttest/`, staged only when
the atom list has `porttest/` atoms — no image rebuild.

Portage builds `atomlists/l1-merge.txt` (+ deps) from source **once**,
into a persistent `differential-test-bed/logs/_l1-pkgcache/` `$PKGDIR`. Then Portage and
portuale each `emerge -k --getbinpkg --oneshot` that same `$PKGDIR` into their own
fresh container's `/`; `compare/snapshot.sh` captures exactly the merged
files + `/etc` + the VDB; `compare/normalize.py` strips the legitimately-
volatile bits (`BUILD_TIME`/`COUNTER`, `env_update` output, `.pyc`,
regenerated caches — see `normalize.md`); `compare/diff.py` emits typed
findings (`MISSING`/`MODE`/`OWNER`/`XATTR`/`SIZE`/`CONTENT`/`SYMLINK`/
`VDB:<file>`/`CONTENTS`, plus a non-fatal `MTIME` count). Green iff every
hard finding matches `known-divergences.yaml`.

Output: `differential-test-bed/logs/l1-<timestamp>/` (`portage.*` / `portuale.*` snapshots
+ merge logs, `l1-report.txt`, `l1-report.json`);
`differential-test-bed/logs/l1-report.txt` symlinks the latest.

Env: `L1_REBUILD=1` (wipe the pkgcache), `L1_SKIP_BUILD=1` (reuse it),
`L1_JOBS`, `L1_SKIP_PORTAGE_UPGRADE`, `PORTTEST_IMAGE`, `PORTTEST_PODMAN`.

> **Do not pass `L1_SKIP_PORTAGE_UPGRADE=1` for L1.** The image's base
> portage (`3.0.81.3`) predates the VDB **consolidated `metadata` file**
> (`_consolidate_to_metadata_file`, `vartree.py`), which portuale mirrors
> because it targets `3.0.82.2` (the version the run upgrades to). Skip
> the upgrade and every merged package shows a spurious
> `[VDB] …/metadata  present for portuale, absent for portage` finding —
> a reference-version artefact, not a portuale bug. (L0 is `--pretend`
> only, so `L0_SKIP_PORTAGE_UPGRADE=1` there is fine and faster.)

The reinstall + upgrade sub-cases are a slice-2 follow-up.

### L2 — portuale as builder (structure + cross-install)

```sh
differential-test-bed/run/l2-portuale-builder.sh differential-test-bed/atomlists/l1-porttest.txt   # fixture track, strict
L2_MODE=payload-tolerant L2_BUILD_MODE=deep \
  differential-test-bed/run/l2-portuale-builder.sh                               # real L1 set
```

Both package managers build the atom list from source into separate
fresh `$PKGDIR`s with a shared `DISTDIR`
(`layers/l2/build-portage.sh`, `layers/l2/build-portuale.sh`), then:
`gpkg-structure.sh --dir … --packages` validates every archive
(member set, inner roots, the stable metadata-key set, Manifest,
filename↔`BUILD_ID`, `Packages` stanza);
`gpkg-diff.sh --mode strict|payload-tolerant` diffs each
portage-built/portuale-built pair (outer layout, normalised metadata,
image paths/attrs, payload; strict = payload hard, for the
deterministic `porttest` fixtures); finally real Portage merges the
portuale-built **candidate** and the portage-built **reference** into
two identical fresh containers (`layers/l1/consume.sh`), portuale
merges the portage-built set as the L1 **control**, and
`diff.py --layer l2 [--tolerate-payload]` compares the normalised
snapshots. `L2_BUILD_MODE=bpkgonly` (default) is archive-only
`--buildpkgonly`; `deep` builds+merges the dependency closure first
(real `-B` refuses unmerged deps).

Output: `differential-test-bed/logs/l2-<timestamp>/` (`structure-*.txt`,
`archive-<cat>-<pn>.txt`, `cross-install.txt`, `control.txt`,
`classification.txt`, `l2-report.txt`, `l2-report.json`);
`differential-test-bed/logs/l2-report.txt` symlinks the latest. Env: `L2_MODE`,
`L2_BUILD_MODE`, `L2_BINPKG_FORMAT=gpkg|xpak`, `L2_REBUILD`, `L2_SKIP_BUILD`, `L2_JOBS`,
`L2_SKIP_PORTAGE_UPGRADE`, `PORTTEST_*`.

Status (2026-09-13): the **fixture track is green modulo filed
producer gaps** — 0 unexplained structural/archive findings, 0
unexplained in the cross-install diff, control 0/0. The real set is
**blocked** on a systemic build-env gap (see
[`findings/l2.md`](findings/l2.md) `l2-bpkgonly-env`); all open
findings are filed there and adjudicated temporarily via
`known-divergences.yaml` (`layer: l2`, `owner: portuale-bug`).

Host-only self-tests (no container): `compare/test-gpkg-structure.sh`,
`compare/test-gpkg-diff.sh`, `compare/test-diff-tolerance.py`.

### L3+ (not yet implemented)

L3 source parity (`run/l3-source-parity.sh` + `layers/l3/build-and-merge.sh`)
builds one atom list from source under both PMs and diffs the snapshots.
The per-slice smoke is `atomlists/l3-smoke.txt` (tree, pv, dmidecode plus
glibc + bash — the two packages whose files every process maps, so the
smoke also covers the SOURCE half of the merge-path safety gate):

```sh
differential-test-bed/run/l3-source-parity.sh differential-test-bed/atomlists/l3-smoke.txt
```

About 15 min at `-j28` serial (≈9 min building, ≈5.5 min for the two
full-tree snapshots, run one after the other), `L3_PM=both`, no control pair. By default the two sides
now run concurrently (`L3_CONCURRENT=1`, one 6-core CCX half each, wall time ≈ max(side A, side B);
`L3_CONCURRENT=0` restores the old serial order), each at `-j${L3_JOBS:-1}` (smoke use: `L3_JOBS=12`). Effective build args resolve
as: env `L3_BUILD_ARGS` when set → else the atom list's `# l3-build-args:`
directive → else `--emptytree --oneshot --usepkg=n --color=n` (#280); the
smoke list carries `# l3-build-args: --oneshot --usepkg=n --color=n`
(deps come from the image, no `--emptytree`). Builds run on a tmpfs at
`/var/tmp/portage` (`L3_TMPFS=1`, size `L3_TMPFS_SIZE`, default `8g`:
measured peaks 3.1 GiB for `l3-core`, 0.9 GiB for the smoke; `L3_TMPFS=0` = disk); the mount needs `exec` because podman's
`--tmpfs` defaults to `noexec` and builds run configure scripts there
(#282). The image now ships Portage 3.0.82.2 baked in
(`create-container.bash`, #281), so the layers' portage-upgrade blocks
are no-ops.

`net/up.sh` / `net/down.sh` (shared network + volumes) for the HTTP
binhost / `mrg` client. Designs, controls, deferred fixtures, risks,
and metrics: `docs/real-world-testing.md` §§2–8 (extracted from
`docs/history/real-world-testing.md`, whose §14 slice history and §1
methodology critique stay there).

### L31b — remote merge into a separate bare client (portuale #326 S8)

The two-container companion to `run/l31-remote-merge.sh` (l31, whose
candidate merges over a loopback sshd into a far ROOT inside the *same*
container). L31b is the cell portuale's S8a change needs: the server
installs and verifies its own binary on the client, which only a
separate bare machine can prove.

```sh
differential-test-bed/images/build-mrg-client.sh   # once: localhost/test-mrg-client:latest
differential-test-bed/run/l31b-two-container.sh                       # default atomlists/l31-s0.txt
L31B_SKIP_BUILD=1 differential-test-bed/run/l31b-two-container.sh     # reuse the shared _l31-pkgcache
```

What it proves: a `test-mrg-client` container (the nopy image asserted
at build time — bash ≥ 5.3, the §6 tool floor, sshd, NO portuale, NO
Python, NO repo mount, NO `/opt/bin`) is reached over a dedicated
podman network (created per run, removed on exit) and merged into its
own `/` through one `mrg --remote-binpkg` per atom — the same trial
path l31 uses for the same atom list, so the pkgcache
(`logs/_l31-pkgcache`) is shared with l31 and "the same gpkgs" is
literal. The client snapshot is diffed against real Portage's consume
of those gpkgs with the same normalise/diff tooling and no allowlist.
Green iff 0 hard / 0 unexplained **and** the install-bin assertions in
`<run>/install-bin.txt` hold:

- first pass: exactly one `portuale-remote: install-bin 0` line, and
  the client holds `/usr/local/bin/portuale-<hash>` (`/opt/bin` is
  absent from the client image, so the D5 search deterministically
  lands there) with the server binary's SHA-256 and mode 0755;
- re-run against the same client: no `install-bin` line, same path,
  same digest, same inode/mtime.

Two bed-side orderings matter, both documented in the scripts: the
parity snapshot is taken after the *first* pass (the trial path
re-executes hooks on a re-merge, so a post-re-run snapshot would carry
both passes' `phase.log` lines), and the bed `INSTALL_MASK` is staged
in the client's `make.conf` by `layers/l31b/client-init.sh` (the
client merge resolves it from the client's own config, as real
Portage would; l31 gets this for free because its client and server
are one container).

Env: `PORTTEST_MRG_CLIENT_IMAGE` (default
`localhost/test-mrg-client:latest`), `L31B_SKIP_BUILD=1`,
`L31B_REBUILD=1` (wipes the *shared* `_l31-pkgcache`), `L31B_JOBS`,
`L31B_SINGLE=1` (one pass only; skips the re-run assertions),
`L31B_KEEP=1` (leave the client + network up for forensics),
`L1_SKIP_PORTAGE_UPGRADE`. Exit: 0 green, 1 divergence or assertion
failure, 2 setup error. Output: `differential-test-bed/logs/l31b-<timestamp>/`
(`reference.*` / `client.*` snapshots, per-atom `*.first/second.*`
mrg logs, `install-bin.txt`, `l31b-report.txt`);
`differential-test-bed/logs/l31b-report.txt` symlinks the latest.
The non-root (`--remote-portuale-dir`) and arch-mismatch
(`--remote-portuale-binary`) variants are unit-tested in portuale;
the bed cell covers the root login only.

### Layout

```
run/          host orchestrators (l0-resolver.sh, l0-fixture-oracle.sh,
              l1-merge-from-binpkg.sh, l2-portuale-builder.sh,
              l3-source-parity.sh, l31-remote-merge.sh,
              l31b-two-container.sh, lib.sh)
layers/l0/    in-container.sh — the per-atom probe driver
layers/l0-fixture-oracle/  stage.sh + in-container.sh (real emerge on fixtures)
layers/l1/    build.sh (Portage, from source) + consume.sh (one PM, merge + snapshot)
layers/l2/    build-portage.sh + build-portuale.sh (archive-only / deep)
layers/l3/    source-build parity (build-and-merge.sh)
layers/l31/   consume-remote.sh (one-container remote merge over loopback sshd)
layers/l31b/  client-init.sh + server-merge.sh + client-snapshot.sh
              (two-container remote merge over a dedicated network)
atomlists/    curated atom / package lists
compare/      resolve-compare.py (L0), snapshot.sh + normalize.py + diff.py (L1/L2),
              gpkg-structure.sh + gpkg-diff.sh (L2), test-*.sh, normalize.md,
              known-divergences.yaml, known-divergences-fixture-oracle.yaml
net/          up.sh / down.sh
images/       Containerfile material + overlay/porttest/ (incl. metadata/md5-cache)
              + mrg-client/ (the l31b bare-client recipe) + build-*.sh
logs/         run output (git-ignored)  — incl. _l1-pkgcache/, _l2-*
```

---

## The legacy `/init` probes

From the repo root:

```sh
podman run --rm --cgroups=enabled --cgroupns=private \
  --security-opt seccomp=unconfined \
  -v ./differential-test-bed/scripts:/TEST/scripts -v ./differential-test-bed/logs:/TEST/logs \
  -v "$PWD/rust/target/release:/usr/local/bin" \
  localhost/test-portuale
```

- `/TEST/scripts` — executables run in lexicographic order by `/init`.
- `00-install-portage.sh` — upgrades the image's stable portage to
  `~amd64 =sys-apps/portage-3.0.82.2` (the version portuale mirrors).
  Must stay lexicographically first.
- `10-config-dump.sh`, `20-real-compare.sh`, `31-…`, `40-…`, `42-…`,
  `43-…` — earlier-slice reproducers.

Inside the container you are `root` (user namespaces; uid 1000 outside).
