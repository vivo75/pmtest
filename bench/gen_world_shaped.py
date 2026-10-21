#!/usr/bin/env python3
"""Deterministic generator for the reproducible `@world`-shaped benchmark input.

Backlog #461 (from #455): the frozen host benchmark in
`portuale:LLM/evidence/2026-10-21-world-profile/` pins live-host VDB/config
state by content hash -- reproducible only on that machine. This script
generates a self-contained benchmark root (repo + VDB + world + config)
under `--out` at run time, so any machine can reproduce the workload with
no live host state and no network access.

Layout of OUT (mirrors the pmtest fixture tree the contract suite runs
against, cf. `pytests-contract-suite/conftest.py::fixture_env`):

    repo/                               synthetic repo `benchmain`
      profiles/{repo_name,make.defaults,packages}
      metadata/layout.conf
      <cat>/<pkg>/<pkg>-<ver>.ebuild    (~1200 ebuilds at defaults)
      metadata/md5-cache/<cat>/<pkg>-<ver>   (real md5 of the ebuild body)
    etc/portage/{repos.conf,make.conf,make.profile -> ../../repo/profiles,
                  binrepos.conf}
    binhost/Packages                    hermetic file:// binary index
    var/db/pkg/<cat>/<pf>/{CATEGORY,SLOT,repository,USE,RDEPEND,IUSE}
                                        (~4000 installed at defaults)
    var/lib/portage/world               the @world workload (~300 atoms)
    distfiles/                          empty (no SRC_URI is fetched: pretend)
    fingerprint.json                    params + per-file sha256 + tree digest

Workload shape (defaults; every count is a CLI knob, `--seed` fixes the
RNG): deep RDEPEND chains, diamonds, dual-slot packages with slot-atom
consumers, satisfied-block replacements (the host gtk-doc shape), USE
newuse reinstalls, `||` disjunctions, new installs, @system members, and
~3000 installed-only ballast packages that exist only to be scanned every
pass (the host VDB holds 2146 packages, most outside the merge).

The invocation the input is built for (same argv as the #455 evidence):

    PORTUALE_PROFILE=1 <portuale> emerge -puDN @world

with `EMERGE_DEFAULT_OPTS="--usepkg=n --getbinpkg=y --binpkg-respect-use=y"`
from the generated make.conf (the host's own defaults, cf. the evidence
README) and PORTAGE_BINHOST scrubbed by the runner, so both binrepo
indexes resolve to the local file:// read -- no network, deterministic.

Nothing is committed: OUT lives under /var/tmp (default
/var/tmp/pmtest-world-bench) and is regenerated deterministically; the
fingerprint check in world_shaped_benchmark.py refuses to run on drift.
"""

import argparse
import hashlib
import json
import os
import random
import sys
from pathlib import Path

GENERATOR_VERSION = 1
REPO_NAME = "benchmain"
PREFIX = "w461"
CATS = ("bench-libs", "bench-apps", "bench-sys")

DEFAULTS = {
    "seed": 461,
    "chains": 20,
    "chain_len": 18,
    "chain_fanout": 10,
    "diamonds": 100,
    "diamond_fanout": 6,
    "leaves": 120,
    "slots": 40,
    "blocks": 8,
    "usepkgs": 60,
    "alts": 20,
    "newpkgs": 60,
    "system": 8,
    "vdb_extra": 3000,
}


def ebuild_body(desc, slot="0", keywords="amd64", iuse="", rdepend="",
                depend="", bdepend="", pdepend="", required_use=""):
    lines = ["EAPI=8", f'DESCRIPTION="{desc}"', f'SLOT="{slot}"',
             f'KEYWORDS="{keywords}"']
    if iuse:
        lines.append(f'IUSE="{iuse}"')
    if rdepend:
        lines.append(f'RDEPEND="{rdepend}"')
    if depend:
        lines.append(f'DEPEND="{depend}"')
    if pdepend:
        lines.append(f'PDEPEND="{pdepend}"')
    if bdepend:
        lines.append(f'BDEPEND="{bdepend}"')
    if required_use:
        lines.append(f'REQUIRED_USE="{required_use}"')
    return "\n".join(lines) + "\n"


def md5_cache_entry(body, keys):
    """Sorted KEY=VALUE lines for `keys` found in the body, then _md5_."""
    vals = {}
    for line in body.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            vals[k] = v.strip('"')
    out = []
    for k in sorted(keys):
        if k in vals:
            out.append(f"{k}={vals[k]}")
    digest = hashlib.md5(body.encode()).hexdigest()
    out.append(f"_md5_={digest}")
    return "\n".join(out) + "\n"


CACHE_KEYS = ("DEFINED_PHASES", "DESCRIPTION", "EAPI", "IUSE", "KEYWORDS",
              "RDEPEND", "DEPEND", "PDEPEND", "BDEPEND", "REQUIRED_USE", "SLOT")


class Tree:
    """Accumulates the generated tree, then writes it deterministically."""

    def __init__(self, out):
        self.out = Path(out)
        self.repo = self.out / "repo"
        self.ebuilds = {}   # (cat, pf) -> body
        self.vdb = {}       # (cat, pf) -> {file: content}
        self.index = []     # binhost entries, in insertion order
        self.world = []
        self.system = []

    def add_ebuild(self, cat, pn, ver, body, with_binary=True,
                   index_use=None, index_rdepend=None):
        pf = f"{pn}-{ver}"
        self.ebuilds[(cat, pf)] = body
        if with_binary:
            entry = {
                "BUILD_ID": "1",
                "CPV": f"{cat}/{pf}",
                "DEFINED_PHASES": "-",
                "DESCRIPTION": f"benchmark binary for {cat}/{pf}",
                "EAPI": "8",
                "SLOT": slot_of(body),
                "USE": index_use if index_use is not None else "",
                "IUSE": iuse_of(body),
                "KEYWORDS": "amd64",
                "REPO": REPO_NAME,
                "SIZE": "4096",
            }
            rd = index_rdepend if index_rdepend is not None else rdepend_of(body)
            if rd:
                entry["RDEPEND"] = rd
            self.index.append(entry)

    def add_vdb(self, cat, pn, ver, slot="0", use=None, rdepend="",
                iuse=""):
        pf = f"{pn}-{ver}"
        files = {"CATEGORY": cat + "\n", "SLOT": slot + "\n",
                 "repository": REPO_NAME + "\n"}
        if use is not None:
            files["USE"] = use + "\n" if use else ""
        if rdepend:
            files["RDEPEND"] = rdepend + "\n"
        if iuse:
            files["IUSE"] = iuse + "\n"
        self.vdb[(cat, pf)] = files

    def write(self):
        out, repo = self.out, self.repo
        if out.exists():
            for child in sorted(out.iterdir()):
                _remove(child)
        (repo / "profiles").mkdir(parents=True)
        (repo / "profiles" / "repo_name").write_text(REPO_NAME + "\n")
        (repo / "profiles" / "make.defaults").write_text(
            'ACCEPT_KEYWORDS="amd64"\nUSE="wfeat"\n')
        sys_lines = "".join(f"*{a}\n" for a in self.system)
        (repo / "profiles" / "packages").write_text(sys_lines)
        (repo / "metadata").mkdir(parents=True)
        (repo / "metadata" / "layout.conf").write_text(
            "profile-formats = portage-2\n")
        for (cat, pf), body in sorted(self.ebuilds.items()):
            pn = pf[: -len("-" + pf.rsplit("-", 1)[1])]
            d = repo / cat / pn
            d.mkdir(parents=True, exist_ok=True)
            (d / f"{pf}.ebuild").write_text(body)
            cdir = repo / "metadata" / "md5-cache" / cat
            cdir.mkdir(parents=True, exist_ok=True)
            (cdir / pf).write_text(
                "DEFINED_PHASES=-\n" + md5_cache_entry(body, CACHE_KEYS))
        cfg = out / "etc" / "portage"
        cfg.mkdir(parents=True)
        (cfg / "repos.conf").write_text(
            "[DEFAULT]\nmain-repo = benchmain\n\n"
            "[benchmain]\nlocation = repo\n")
        (cfg / "make.conf").write_text(
            'USE="wfeat"\n'
            'PKGDIR="${PORTAGE_CONFIGROOT}/pkgdir"\n'
            'FEATURES="-news"\n'
            'EMERGE_DEFAULT_OPTS="--usepkg=n --getbinpkg=y '
            '--binpkg-respect-use=y"\n')
        try:
            (cfg / "make.profile").symlink_to("../../repo/profiles")
        except FileExistsError:
            pass
        (cfg / "binrepos.conf").write_text(
            "[w461bench]\nsync-uri = file://${PORTAGE_CONFIGROOT}/binhost\n"
            "priority = 1\n")
        bh = out / "binhost"
        bh.mkdir(parents=True)
        idx = ["TIMESTAMP: 0", "VERSION: 0",
               f"PACKAGES: {len(self.index)}", ""]
        for e in self.index:
            for k in ("BUILD_ID", "CPV", "DEFINED_PHASES", "DESCRIPTION",
                      "EAPI", "SLOT", "USE", "IUSE", "KEYWORDS", "REPO",
                      "SIZE", "RDEPEND"):
                if k in e:
                    idx.append(f"{k}: {e[k]}")
            idx.append("")
        (bh / "Packages").write_text("\n".join(idx))
        for (cat, pf), files in sorted(self.vdb.items()):
            d = out / "var" / "db" / "pkg" / cat / pf
            d.mkdir(parents=True, exist_ok=True)
            for name, content in sorted(files.items()):
                (d / name).write_text(content)
        wdir = out / "var" / "lib" / "portage"
        wdir.mkdir(parents=True)
        (wdir / "world").write_text("".join(f"{a}\n" for a in self.world))
        (out / "distfiles").mkdir(exist_ok=True)
        (out / "pkgdir").mkdir(exist_ok=True)
        (out / "tmp").mkdir(exist_ok=True)


def _remove(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
    else:
        for child in sorted(path.iterdir()):
            _remove(child)
        path.rmdir()


def slot_of(body):
    for line in body.splitlines():
        if line.startswith("SLOT="):
            return line.split("=", 1)[1].strip('"')
    return "0"


def iuse_of(body):
    for line in body.splitlines():
        if line.startswith("IUSE="):
            return line.split("=", 1)[1].strip('"')
    return ""


def rdepend_of(body):
    for line in body.splitlines():
        if line.startswith("RDEPEND="):
            return line.split("=", 1)[1].strip('"')
    return ""


def fingerprint(out, params):
    """tree digest over sorted relpaths + contents.

    `fingerprint.json` itself is excluded, as is `var/cache/` and `tmp/`:
    a run writes its regenerable binhost cache under `var/cache/edb/`,
    which is runtime state, not input (the runner wipes it before every
    run, so it must not affect the digest).
    """
    out = Path(out)
    h = hashlib.sha256()
    files = {}
    for p in sorted(out.rglob("*")):
        if not p.is_file() or p.name == "fingerprint.json":
            continue
        rel = str(p.relative_to(out))
        if rel == "var/cache" or rel.startswith("var/cache/"):
            continue
        if rel == "tmp" or rel.startswith("tmp/"):
            continue
        digest = hashlib.sha256(p.read_bytes()).hexdigest()
        files[rel] = digest
        h.update(rel.encode() + b"\0" + digest.encode() + b"\0")
    return {"generator": GENERATOR_VERSION, "params": params, "files": files,
            "tree_digest": h.hexdigest(),
            "file_count": len(files),
            "total_bytes": sum(
                (out / rel).stat().st_size for rel in files)}


def generate(out, params):
    rng = random.Random(params["seed"])
    cats = list(CATS)
    t = Tree(out)
    cat_of = lambda i: cats[i % len(cats)]

    # 0. Shared leaf pool: reached only through dependencies (never in
    #    world), each with two acyclic leaf-deps on higher-index leaves.
    leaves = [f"{PREFIX}leaf{i:03d}" for i in range(params["leaves"])]
    leaf_cats = [cat_of(i) for i in range(params["leaves"])]
    for i, name in enumerate(leaves):
        cat = leaf_cats[i]
        deps = [f"{leaf_cats[j]}/{leaves[j]}"
                for j in rng.sample(range(i + 1, len(leaves)),
                                    min(2, len(leaves) - i - 1))]
        body = ebuild_body(f"benchmark shared leaf {i}",
                           rdepend=" ".join(deps))
        t.add_ebuild(cat, name, "2", body)
        t.add_vdb(cat, name, "1", rdepend=" ".join(deps))

    def fanout(n):
        return [f"{leaf_cats[j]}/{leaves[j]}"
                for j in (rng.randrange(len(leaves)) for _ in range(n))]

    # 1. Deep chains: head updated, whole spine walked, plus fan-out.
    for c in range(params["chains"]):
        cat = cat_of(c)
        names = [f"{PREFIX}chain{c:02d}{j:02d}" for j in range(params["chain_len"])]
        for j, name in enumerate(names):
            deps = ([f"{cat}/{names[j + 1]}"] if j + 1 < len(names) else [])
            deps += fanout(params["chain_fanout"])
            rd = " ".join(deps)
            body = ebuild_body(f"benchmark chain {c} level {j}", rdepend=rd)
            t.add_ebuild(cat, name, "2", body)
            t.add_vdb(cat, name, "1", rdepend=rd)
        t.world.append(f"{cat}/{names[0]}")

    # 2. Diamonds: shared leaf resolved once, three parents updated.
    for i in range(params["diamonds"]):
        cat = cat_of(i)
        a, b, c, d = (f"{PREFIX}dia{i:03d}{s}" for s in "abcd")
        t.add_ebuild(cat, a, "2", ebuild_body(
            f"benchmark diamond {i} top",
            rdepend=f"{cat}/{b} {cat}/{c} " + " ".join(
                fanout(params["diamond_fanout"]))))
        t.add_ebuild(cat, b, "2", ebuild_body(
            f"benchmark diamond {i} left",
            rdepend=f"{cat}/{d} " + " ".join(fanout(2))))
        t.add_ebuild(cat, c, "2", ebuild_body(
            f"benchmark diamond {i} right",
            rdepend=f"{cat}/{d} " + " ".join(fanout(2))))
        t.add_ebuild(cat, d, "2", ebuild_body(f"benchmark diamond {i} leaf"))
        for n, rd in ((a, rdepend_of(t.ebuilds[(cat, f"{a}-2")])),
                      (b, rdepend_of(t.ebuilds[(cat, f"{b}-2")])),
                      (c, rdepend_of(t.ebuilds[(cat, f"{c}-2")])),
                      (d, "")):
            t.add_vdb(cat, n, "1", rdepend=rd)
        t.world.append(f"{cat}/{a}")

    # 3. Dual slots with a consumer on both slot atoms.
    for i in range(params["slots"]):
        cat = cat_of(i)
        pn, cn = f"{PREFIX}slot{i:03d}", f"{PREFIX}slotc{i:03d}"
        t.add_ebuild(cat, pn, "1.0", ebuild_body(f"benchmark slot {i} one",
                                                slot="1"))
        t.add_ebuild(cat, pn, "2.0", ebuild_body(f"benchmark slot {i} two",
                                                slot="2"))
        rd = f"{cat}/{pn}:1 {cat}/{pn}:2"
        t.add_ebuild(cat, cn, "2", ebuild_body(f"benchmark slot {i} consumer",
                                              rdepend=rd))
        t.add_vdb(cat, pn, "1.0", slot="1")
        t.add_vdb(cat, cn, "1", rdepend=rd)
        t.world.append(f"{cat}/{cn}")

    # 4. Satisfied blocks: new version replaces the blocked installed one
    #    in its slot (the host gtk-doc shape, backlog #68).
    for i in range(params["blocks"]):
        cat = cat_of(i)
        pn = f"{PREFIX}blk{i:02d}"
        t.add_ebuild(cat, pn, "2", ebuild_body(
            f"benchmark satisfied block {i}",
            rdepend=f"!={cat}/{pn}-1"))
        t.add_vdb(cat, pn, "1")
        t.world.append(f"{cat}/{pn}")

    # 5. USE newuse: profile enables wfeat, installed records it off.
    for i in range(params["usepkgs"]):
        cat = cat_of(i)
        pn, un = f"{PREFIX}use{i:03d}", f"{PREFIX}udep{i:03d}"
        rd = f"wfeat? ( {cat}/{un} )"
        t.add_ebuild(cat, pn, "2", ebuild_body(f"benchmark newuse {i}",
                                              iuse="wfeat", rdepend=rd),
                     index_use="wfeat", index_rdepend=f"{cat}/{un}")
        t.add_ebuild(cat, un, "1", ebuild_body(f"benchmark newuse leaf {i}"),
                     with_binary=False)
        t.add_vdb(cat, pn, "1", use="", rdepend=rd, iuse="wfeat")
        t.world.append(f"{cat}/{pn}")

    # 6. Disjunctions for the dep_zapdeps bins.
    for i in range(params["alts"]):
        cat = cat_of(i)
        pn = f"{PREFIX}alt{i:02d}"
        aa, ab = f"{PREFIX}alta{i:02d}", f"{PREFIX}altb{i:02d}"
        t.add_ebuild(cat, pn, "2", ebuild_body(
            f"benchmark alternative {i}",
            rdepend=f"|| ( {cat}/{aa} {cat}/{ab} )"))
        t.add_ebuild(cat, aa, "1", ebuild_body(f"benchmark alt {i} a"),
                     with_binary=False)
        t.add_ebuild(cat, ab, "1", ebuild_body(f"benchmark alt {i} b"),
                     with_binary=False)
        t.add_vdb(cat, pn, "1",
                  rdepend=f"|| ( {cat}/{aa} {cat}/{ab} )")
        t.world.append(f"{cat}/{pn}")

    # 7. Plain new installs.
    for i in range(params["newpkgs"]):
        cat = cat_of(i)
        pn = f"{PREFIX}new{i:03d}"
        t.add_ebuild(cat, pn, "1", ebuild_body(f"benchmark new {i}"),
                     with_binary=False)
        t.world.append(f"{cat}/{pn}")

    # 8. @system members, installed at the same version (no-op arm).
    for i in range(params["system"]):
        cat = cat_of(i)
        pn = f"{PREFIX}sys{i:02d}"
        t.add_ebuild(cat, pn, "1", ebuild_body(f"benchmark system {i}"),
                     with_binary=False)
        t.add_vdb(cat, pn, "1")
        t.system.append(f"{cat}/{pn}")

    # 9. Installed-only ballast: scanned every pass, never merged. Each
    #    carries full flag metadata (USE/IUSE reads) and one installed dep
    #    edge, so the installed-graph walk has something to follow.
    for i in range(params["vdb_extra"]):
        cat = cat_of(i)
        nxt = f" {cat_of(i + 1)}/{PREFIX}old{i + 1:04d}" \
            if i + 1 < params["vdb_extra"] else ""
        t.add_vdb(cat, f"{PREFIX}old{i:04d}", "1", use="", iuse="",
                  rdepend=nxt.strip())

    # Deterministic world order: shuffled with the seeded RNG (a sorted
    # world would walk in an unrealistically friendly order).
    rng.shuffle(t.world)
    t.write()
    fp = fingerprint(out, params)
    (Path(out) / "fingerprint.json").write_text(json.dumps(fp, indent=2) + "\n")
    return fp


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", required=True)
    for key, default in DEFAULTS.items():
        ap.add_argument(f"--{key.replace('_', '-')}", type=int, default=default)
    args = ap.parse_args()
    params = {k: getattr(args, k) for k in DEFAULTS}
    fp = generate(args.out, params)
    print(f"generated {fp['file_count']} files, "
          f"{fp['total_bytes']} bytes, tree {fp['tree_digest'][:16]}...")


if __name__ == "__main__":
    main()
