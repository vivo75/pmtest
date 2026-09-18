"""Resolution of the package manager under test (`managers/managers.yaml`).

Single source of truth for the registry: the pytest contract suite
(`pytests-contract-suite/conftest.py`), the benchmark harness
(`bench/run_benchmark.py`) and the differential test bed
(`differential-test-bed/run/lib.sh`, through `--sh`) all resolve their
binaries here instead of hardcoding a path. The active entry is picked
by `$PMTEST_PM` (default: `portuale`); see `managers/README.md` for the
entry format.

Errors are raised, never printed: each caller maps them to its own
idiom (pytest fail/skip, a shell exit, a benchmark error). Two kinds:

  RegistryError   the registry or the request is wrong -- fatal for
                  everyone (unknown `$PMTEST_PM`, missing yaml, a build
                  that produced nothing).
  NotProvided     this entry legitimately cannot provide what was asked
                  (a prebuilt reference PM has no neutral harness
                  binary). Callers that can degrade do; the test bed,
                  which cannot, treats it as fatal.

`--sh` prints `eval`-able assignments for the bash orchestrators:

    eval "$(python3 managers/registry.py --sh)"
"""

import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - PyYAML is a documented host prereq
    yaml = None

PMTEST_ROOT = Path(__file__).resolve().parents[1]
MANAGERS_YAML = PMTEST_ROOT / "managers" / "managers.yaml"
DEFAULT_PM = "portuale"

APPLETS = ("emerge", "ebuild", "mrg")

# Neutral CLI harnesses: the cargo package each one is built from.
HARNESS_PACKAGES = {
    "versions": "versions-harness",
    "atom": "atom-harness",
    "use_reduce": "use-reduce-harness",
    "required_use": "required-use-harness",
}


class RegistryError(Exception):
    """The registry, or the request made of it, is wrong."""


class NotProvided(RegistryError):
    """The active entry cannot provide this binary (and never could)."""


_registry_cache = None


def registry():
    """The `pms:` mapping, loaded once."""
    global _registry_cache
    if _registry_cache is None:
        if yaml is None:
            raise RegistryError("PyYAML is required to read managers/managers.yaml")
        try:
            data = yaml.safe_load(MANAGERS_YAML.read_text())
        except FileNotFoundError:
            raise RegistryError(f"PM registry not found: {MANAGERS_YAML}") from None
        _registry_cache = (data or {}).get("pms") or {}
    return _registry_cache


def active_pm(name=None):
    """(name, entry) of the PM selected via `$PMTEST_PM`."""
    name = name or os.environ.get("PMTEST_PM", DEFAULT_PM)
    reg = registry()
    if name not in reg:
        raise RegistryError(
            f"PMTEST_PM={name!r} is not in managers/managers.yaml "
            f"(available: {', '.join(sorted(reg)) or 'none'})"
        )
    return name, reg[name] or {}


def resolve_path(raw):
    """A registry path, made absolute and canonical.

    Relative entries resolve against the pmtest root. The result is
    canonicalised because it is used as a container mount point and as a
    prefix to prune from filesystem snapshots, where `a/../b` and `b`
    would be two different paths.
    """
    p = Path(os.path.expandvars(os.path.expanduser(str(raw))))
    return (p if p.is_absolute() else PMTEST_ROOT / p).resolve()


def repo_dir(pm):
    """Source tree of an entry built from source (None if prebuilt).

    This is also the path the differential test bed must mount inside the
    container at its own host path: a PM binary may resolve its runtime
    data (portuale: `bin/`, `3rdparty/portage`) through a path baked in at
    compile time, which only exists inside its own checkout.
    """
    return resolve_path(pm["repo"]) if pm.get("repo") else None


def rust_dir(pm):
    """Cargo workspace of an entry built from source (None if prebuilt)."""
    if pm.get("rust_dir"):
        return resolve_path(pm["rust_dir"])
    if pm.get("repo"):
        return resolve_path(pm["repo"]) / "rust"
    return None


def _build_disabled():
    return os.environ.get("PMTEST_NO_BUILD", "") not in ("", "0")


def _cargo_build(rust_dir_, package):
    subprocess.run(
        ["cargo", "build", "--release", "--package", package],
        cwd=rust_dir_,
        check=True,
    )


def _provide(name, pm, package, binary, build=True):
    """`binary`, rebuilt first when the entry is built from source.

    An entry with a `rust_dir` is always rebuilt (cargo is its own
    up-to-date check, and a no-op when nothing changed): otherwise a run
    silently grades a stale binary after a source change. Set
    `$PMTEST_NO_BUILD=1` where the binary is deliberately prebuilt.
    """
    rd = rust_dir(pm)
    if build and rd is not None and not _build_disabled():
        if not rd.is_dir():
            raise RegistryError(
                f"PM {name!r}: rust dir {rd} does not exist "
                "(registry `repo`/`rust_dir` points nowhere)"
            )
        if shutil.which("cargo") is None:
            if not binary.exists():
                raise NotProvided(
                    f"PM {name!r}: {binary} not built and cargo not available"
                )
        else:
            _cargo_build(rd, package)
    if not binary.exists():
        if rd is None:
            raise NotProvided(
                f"PM {name!r}: {binary} not found and the registry entry "
                "has no repo to build it from"
            )
        raise RegistryError(f"PM {name!r}: cargo build of {package} produced no {binary}")
    return binary


def declared_applet(kind, name=None):
    """Where an applet *would* live -- no build, no existence check."""
    if kind not in APPLETS:
        raise RegistryError(f"unknown applet {kind!r} (expected one of {APPLETS})")
    name, pm = active_pm(name)
    if pm.get(kind):
        return resolve_path(pm[kind])
    rd = rust_dir(pm)
    if rd is None:
        raise NotProvided(f"PM {name!r}: no {kind} path and no repo in registry")
    return rd / "target" / "release" / pm.get("package", "portuale")


def applet(kind, name=None, build=True):
    """The `emerge`/`ebuild`/`mrg` entry point of the active PM."""
    name, pm = active_pm(name)
    return _provide(
        name, pm, pm.get("package", "portuale"),
        declared_applet(kind, name=name), build=build,
    )


def harness(kind, name=None, build=True):
    """A neutral CLI harness binary of the active PM.

    A prebuilt reference PM ships none: `NotProvided`, so the harness
    contracts can skip rather than fail.
    """
    if kind not in HARNESS_PACKAGES:
        raise RegistryError(
            f"unknown harness {kind!r} (expected one of {sorted(HARNESS_PACKAGES)})"
        )
    name, pm = active_pm(name)
    package = HARNESS_PACKAGES[kind]
    if pm.get(f"{kind}_harness"):
        binary = resolve_path(pm[f"{kind}_harness"])
    else:
        rd = rust_dir(pm)
        if rd is None:
            raise NotProvided(
                f"PM {name!r} ships no {package} harness "
                "(no repo in registry) -- harness contract not applicable"
            )
        binary = rd / "target" / "release" / package
    return _provide(name, pm, package, binary, build=build)


def product_binary(name=None, build=True):
    """The PM's own product binary (multicall dispatch target)."""
    name, pm = active_pm(name)
    if pm.get("binary"):
        binary = resolve_path(pm["binary"])
        if binary.exists():
            return binary
    return applet("emerge", name=name, build=build)


def _sh(argv):
    """Print `eval`-able assignments for the bash orchestrators."""
    build = "--no-build" not in argv
    name, pm = active_pm()
    if repo_dir(pm) is None:
        raise RegistryError(
            f"PM {name!r} has no `repo` in managers/managers.yaml: the "
            "differential test bed mounts the PM's own build dir and "
            "checkout, so it only runs PMs built from source (the real "
            "portage it compares against is the one inside the container)"
        )
    bins = {kind: declared_applet(kind, name=name) for kind in APPLETS}
    emerge = applet("emerge", name=name) if build else bins["emerge"]
    # The test bed mounts one directory as the container's /usr/local/bin:
    # a multicall PM keeps all three applets there. Anything else would
    # need a mount per applet -- say so instead of mounting half of it.
    stray = {k: str(v) for k, v in bins.items() if v.parent != emerge.parent}
    if stray:
        raise RegistryError(
            f"PM {name!r}: emerge/ebuild/mrg do not share one directory "
            f"({stray}); the differential test bed mounts a single bin dir"
        )
    repo = repo_dir(pm)
    rd = rust_dir(pm)
    out = {
        "PM_NAME": name,
        "PM_PACKAGE": pm.get("package", "portuale"),
        "PM_VERSION": str(pm.get("version", "")),
        "PM_EMERGE": str(emerge),
        "PM_BIN_DIR": str(emerge.parent),
        "PM_REPO": str(repo) if repo else "",
        "PM_RUST_DIR": str(rd) if rd else "",
    }
    for key, value in out.items():
        print(f"{key}={shlex.quote(value)}")


def main(argv):
    if "--sh" in argv:
        _sh(argv)
        return 0
    name, pm = active_pm()
    print(f"{name} ({pm.get('type', 'unknown')}, version {pm.get('version', '?')})")
    for kind in APPLETS:
        try:
            print(f"  {kind}: {declared_applet(kind, name=name)}")
        except RegistryError as exc:
            print(f"  {kind}: {exc}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except RegistryError as exc:
        print(f"!!! {exc}", file=sys.stderr)
        sys.exit(2)
