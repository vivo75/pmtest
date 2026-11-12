# pmtest — testing and comparing package managers

> **LLM agents: read [`USAGE.AGENTS.md`](USAGE.AGENTS.md) first.** It has the
> commands, what is allowed and what is forbidden, and how to measure the
> efficiency of a package manager. This README stays the detailed reference
> (layout, images, provenance).

This repository **tests and compares package managers** of several versions
and kinds (portuale, Portage, others).

Role (portuale charter, `../portuale/docs/charter.md`): portuale is an
independent Gentoo package manager, not a Portage fork. Portage is a
teacher, no longer the oracle. Correctness is judged by five health
properties (dependencies hold, legal order, newest visible versions,
removal keeps libraries, helpful messages), checked by the standalone
health checker `pytests-contract-suite/health_checker.py`, not by
matching Portage's output. The checker covers properties 1 to 4; property 5
(helpful messages) has no checker yet. pmtest also
supports Portage's development. The pinned outputs, the harvested corpus
and the Portage-vs-portuale comparisons record what Portage printed: use
them as a regression and comparison tool, not as a statement of what is
right.

Current content: **the test infrastructure built for portuale** (extracted
from `../portuale`, commit `f8c2142508cf1ec942d0902c6689d6fc0cfeec5e`). Since
`portuale@f982876` it lives **only here**: the package manager's tree deleted
its own copies of `tests/`, `TEST/`, `bench/` and `python/` (it keeps
`fixtures/`, which the Rust unit tests also need, and `scripts/`).
No package-manager logic lives here: only harnesses, fixtures and oracles.
(`../2p` was only a temporary working clone and is no longer a source.)

## Layout

| Dir | Origin | Contents |
|---|---|---|
| `pytests-contract-suite/` | `portuale/tests/` | pytest contract suite (black-box through the CLI): `emerge --pretend`, merge/unmerge, `output_invariants`, corpus, benchmark gate, musl smoke; `health_checker.py` (+ `test_health_checker.py`) checks a plan against the charter's health properties 1 to 4. The pinned outputs record what Portage printed. |
| `fixtures/` | `portuale/fixtures/` | synthetic trees (`repo/`, `overlay/`, `etc/portage/`, `var/db`, `pkgdir/`, `binhost/`, `distfiles/`) the suite runs against. **Single copy**: since 2026-09-18 the package manager's tree has none of its own, and `portuale/fixtures` is a symlink to this one (`portuale@335543e`), so both the contract suite and the Rust `#[cfg(test)]` tests read it. Every addition or fix is made here. |
| `differential-test-bed/` | `portuale/TEST/` | container test bed: Portage-vs-portuale comparison layers (L0 resolver, L1 merge-from-binpkg, L2 builder, L3 source build) as a regression and comparison tool, plus the portuale-only health layer (`run/l0-health.sh`, `compare/health-mutants.py`, `compare/health-report.py`, `compare/check-world-mutants.py`, `compare/world-crosscheck.py`) + `atomlists/`, `compare/`, `layers/`, `images/overlay/porttest/`, `create-container.bash` |
| `bench/` | `portuale/bench/` | benchmark harness (batch mode) + a real Gentoo snapshot (`gentoo_snapshot.json`) |
| `scripts/` | `portuale/scripts/` | primitive-tree-differential, repin-review, md5-cache-audit, upstream-resolver-translate |
| `python-harness/` | `portuale/python/` | Python harness on the reference side (`versions`/`atom`/`use_reduce`/`required_use`) |
| `managers/` | new | registry + adapter for each package manager under test (see `managers/README.md`) |
| `3rdparty` | symlink → `../portuale/3rdparty` | pinned upstream checkouts (Portage for the harnesses and as a reference, test gpg keys); package-manager material, never committed inside pmtest — the symlink is. Needs `../portuale` with `3rdparty/` populated (see `setup.sh` there). |

Left out of the copy (regenerable or host-specific scratch): `differential-test-bed/logs/`,
`differential-test-bed/WORKDIR/`, `differential-test-bed/repos/`, `differential-test-bed/stage3-*.tar.xz`,
`fixtures/var/cache/`, `__pycache__/`, `.pytest_cache/`, `target/`.

## Usage

```sh
# fixture-based suite against the active package manager (see managers/)
python3 -m pytest pytests-contract-suite -q
PMTEST_PM=portage python3 -m pytest pytests-contract-suite -q

# health check of portuale's L0 plans (no Portage run; needs the image below)
differential-test-bed/run/l0-health.sh

# Portage-vs-portuale comparison on a real tree (needs the image below)
differential-test-bed/run/l0-resolver.sh
differential-test-bed/run/l1-merge-from-binpkg.sh
```

Which binary is tested is decided by the **registry** (`managers/`), not by
hardcoded paths: the tests point at `emerge`/`ebuild`/`mrg` symlinks
resolved by the active package manager. How to add or change a package
manager is explained in [`managers/README.md`](managers/README.md).

## Building the container image (`localhost/test-portuale:latest`)

All the needed code is already in `differential-test-bed/`:
`create-container.bash`, `init.c` (the PID 1 that runs
`differential-test-bed/scripts/` in lexicographic order),
`images/overlay/porttest/` (the synthetic overlay for L1/L2) and `net/`.
The image does not contain the package manager's binaries: they are mounted
at run time by `differential-test-bed/run/lib.sh`. To provide on the host
(never committed, see `differential-test-bed/.gitignore`):

- `podman` + `buildah`, `gcc`, `python3` + `PyYAML`;
- the local git mirrors in `differential-test-bed/repos/{gentoo,buildovl}`.
  The script uses them as `file://` remotes and runs
  `git fetch --shallow-since=<date> <LAST_COMMIT>` at the pins declared at
  the top of the script; in practice they are symlinks to the host's
  already synchronized checkouts;
- the stage3 (`stage3-amd64-systemd-<ts>.tar.xz`): if it is missing from
  `differential-test-bed/`, the script downloads it from
  `distfiles.gentoo.org`.

Command (must run as root; inside it uses `sudo -su vivo` for
podman/buildah, with subuid/subgid configured):

```sh
sudo differential-test-bed/create-container.bash
```

The script: builds `init`, unpacks the stage3 into `WORKDIR/`, clones the
repos at the pins, copies the `porttest` overlay (automatic commit), writes
`resolv.conf`/`make.conf`/`repos.conf`, remaps the uids for the userpriv
container and commits the image `localhost/test-portuale:latest` with
entrypoint `/init`. Check with `podman images` and, if needed, with the
commented commands at the bottom of the script.

## Provenance

Extracted from `PORTUALE/portuale` at the commit above. There is no sync to
redo: since `portuale@f982876` those directories no longer exist in the
package manager's tree, and pmtest is the only copy. Additions and fixes to
the infrastructure are made **here**.

What pmtest still reads from the package manager's tree, and which must
therefore exist next to it:

- the package manager's registry entry (`managers/managers.yaml`) — source
  and binaries, rebuilt on every run;
- `3rdparty/` (symlink to `../portuale/3rdparty`) — the Portage checkout at
  its pin, the reference of the Python harnesses and the carrier of the
  test gpg keyring. If it is missing, the harnesses refuse to start instead
  of falling back to the Portage installed on the host.

The infrastructure is not changed to make a package manager pass: bugs are
fixed in the package manager, and expected divergences go in
`differential-test-bed/compare/known-divergences.yaml`.
