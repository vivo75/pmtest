#!/usr/bin/env python3
"""Check that a package-manager plan leaves a healthy system.

Input: the document printed by `portuale emerge --pretend -v --json`
(entries with `dependencies`, `use`, `iuse`, `required_use`, plus the
top-level `kept` list of installed packages the plan leaves alone).
Installed packages' own data (USE, dependencies, sub-slot) is read from the
VDB when one is given, or from fields embedded in the `kept` items.

Properties, from portuale's charter (PMS-based, no Portage involved):

1. Dependencies hold in the final set: every RDEPEND/PDEPEND atom of every
   package is matched, no blocker matches, REQUIRED_USE holds, and no
   slot holds two packages.
2. Order is legal: every DEPEND/BDEPEND/IDEPEND atom of a merged package is
   matched by a package present when it is merged (installed, or merged
   earlier), and that package is usable (PMS 8.1): its RDEPEND closure is
   met by then too, and no DEPEND/BDEPEND blocker matches a package present
   at that moment. A need only a later package of the same cycle can meet
   (build-time and runtime edges between merges) is noted as an
   unserializable cycle, not reported as a failure.

With a VDB, the system before the plan is the VDB itself, not the plan's
`kept` list, so an installed package the plan silently drops is seen.

The atom matcher, version comparison and dependency-string evaluator below
are written from PMS and share no code with portuale or Portage.

Usage: health_checker.py [--vdb /var/db/pkg] PLAN.json...
Prints one JSON object per plan: {"plan", "findings": [...], "refused"},
where `refused` says why portuale itself would not run the plan (its
findings are then expected, not failures). Exit 1 when a plan portuale
would run has a failure it introduces.
"""

from __future__ import annotations

import functools
import json
import re
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

MERGE_BOUND = {"new", "upgrade", "downgrade", "reinstall"}
RUNTIME_CLASSES = ("RDEPEND", "PDEPEND")
BUILD_CLASSES = ("DEPEND", "BDEPEND")
DEP_CLASSES = ("DEPEND", "BDEPEND", "RDEPEND", "PDEPEND", "IDEPEND")


@dataclass(frozen=True)
class Finding:
    """One broken property: which package, which atom, and why."""

    property: str  # runtime-deps, blocker, required-use, slot, build-order, cycle-noted
    package: str
    atom: str
    reason: str
    pre_existing: bool = False

    @property
    def is_failure(self) -> bool:
        return self.property != "cycle-noted"


# --- versions (PMS 3.2, 3.3) ------------------------------------------------

_VERSION = re.compile(
    r"^(\d+(?:\.\d+)*)([a-z]?)((?:_(?:alpha|beta|pre|rc|p)\d*)*)(?:-r(\d+))?$")
_SUFFIX = re.compile(r"_(alpha|beta|pre|rc|p)(\d*)")
_SUFFIX_RANK = {"alpha": 0, "beta": 1, "pre": 2, "rc": 3, "p": 5}
_NO_SUFFIX_RANK = 4


def is_version(text: str) -> bool:
    return _VERSION.match(text) is not None


def _cmp(a, b) -> int:
    return (a > b) - (a < b)


def vercmp(a: str, b: str) -> int:
    """-1, 0 or 1 as version `a` is lower, equal or higher than `b`."""
    ma, mb = _VERSION.match(a), _VERSION.match(b)
    if not ma or not mb:
        raise ValueError(f"not a version: {a!r} / {b!r}")
    na, nb = ma.group(1).split("."), mb.group(1).split(".")
    result = _cmp(int(na[0]), int(nb[0]))
    for x, y in zip(na[1:], nb[1:]):
        if result:
            return result
        if x.startswith("0") or y.startswith("0"):
            result = _cmp(x.rstrip("0"), y.rstrip("0"))
        else:
            result = _cmp(int(x), int(y))
    result = result or _cmp(len(na), len(nb))
    result = result or _cmp(ma.group(2), mb.group(2))
    if result:
        return result
    sa = [(_SUFFIX_RANK[s], int(n or 0)) for s, n in _SUFFIX.findall(ma.group(3))]
    sb = [(_SUFFIX_RANK[s], int(n or 0)) for s, n in _SUFFIX.findall(mb.group(3))]
    sa.append((_NO_SUFFIX_RANK, 0))
    sb.append((_NO_SUFFIX_RANK, 0))
    for x, y in zip(sa, sb):
        if x != y:
            return _cmp(x, y)
    return _cmp(int(ma.group(4) or 0), int(mb.group(4) or 0))


def without_revision(version: str) -> str:
    return re.sub(r"-r\d+$", "", version)


# --- atoms (PMS 8.3) ---------------------------------------------------------

@dataclass(frozen=True)
class UseDep:
    flag: str
    kind: str  # "on", "off", "eq", "neq", "if-on", "if-off"
    default: bool | None  # (+) / (-): the target's state when it lacks the flag


@dataclass(frozen=True)
class Atom:
    text: str
    blocker: bool
    op: str  # "", "<", "<=", "=", "~", ">=", ">"
    cp: tuple[str, str]
    version: str
    glob: bool  # `=cat/pkg-1.2*`
    slot: str  # "" (any), or the slot name
    subslot: str
    use_deps: tuple[UseDep, ...]


_ATOM = re.compile(
    r"^(?P<blocker>!!?)?(?P<op><=|>=|<|>|=|~)?(?P<cat>[\w+][\w+.-]*)/(?P<rest>[^:\[]+)"
    r"(?::(?P<slot>[^:\[]*))?(?:::(?P<repo>[\w-]+))?(?:\[(?P<use>[^\]]*)\])?$")
_USE_DEP = re.compile(r"^(?P<neg>[!-])?(?P<flag>[\w+][\w+@.-]*)(?:\((?P<default>[+-])\))?(?P<mod>[=?])?$")


def parse_atom(text: str) -> Atom:
    """A PMS dependency atom; raises ValueError on anything else."""
    m = _ATOM.match(text)
    if not m:
        raise ValueError(f"not an atom: {text}")
    op, rest = m.group("op") or "", m.group("rest")
    glob = op == "=" and rest.endswith("*")
    rest = rest.removesuffix("*") if glob else rest
    pkg, version = rest, ""
    if op:
        pkg, _, version = rest.rpartition("-")
        if re.fullmatch(r"r\d+", version):
            pkg, _, base = pkg.rpartition("-")
            version = f"{base}-{version}"
        if not pkg or not is_version(version):
            raise ValueError(f"bad version in atom: {text}")
    slot = (m.group("slot") or "").rstrip("=")
    slot, _, subslot = slot.partition("/")
    return Atom(
        text=text,
        blocker=bool(m.group("blocker")),
        op=op,
        cp=(m.group("cat"), pkg),
        version=version,
        glob=glob,
        slot="" if slot == "*" else slot,
        subslot=subslot,
        use_deps=tuple(_parse_use_dep(u) for u in (m.group("use") or "").split(",") if u),
    )


def _parse_use_dep(text: str) -> UseDep:
    m = _USE_DEP.match(text)
    if not m:
        raise ValueError(f"bad USE dependency: {text}")
    neg, mod = m.group("neg"), m.group("mod")
    kind = {
        (None, None): "on", ("-", None): "off", (None, "="): "eq",
        ("!", "="): "neq", (None, "?"): "if-on", ("!", "?"): "if-off",
    }.get((neg, mod))
    if kind is None:
        raise ValueError(f"bad USE dependency: {text}")
    default = {"+": True, "-": False}.get(m.group("default"))
    return UseDep(m.group("flag"), kind, default)


# --- packages ----------------------------------------------------------------

@dataclass
class Package:
    category: str
    package: str
    version: str
    slot: str
    subslot: str = ""
    use: frozenset = frozenset()
    iuse: frozenset = frozenset()
    dependencies: dict = field(default_factory=dict)
    required_use: str = ""
    binary: bool = False
    known: bool = True  # False when nothing beyond name and slot could be read

    @property
    def cp(self) -> tuple[str, str]:
        return (self.category, self.package)

    @property
    def cpv(self) -> str:
        return f"{self.category}/{self.package}-{self.version}"


def _flag_state(pkg: Package, use_dep: UseDep) -> bool:
    if use_dep.flag not in pkg.iuse and use_dep.default is not None:
        return use_dep.default
    return use_dep.flag in pkg.use


def _use_deps_hold(atom: Atom, pkg: Package, parent_use: frozenset) -> bool:
    for dep in atom.use_deps:
        state, parent = _flag_state(pkg, dep), dep.flag in parent_use
        wanted = {
            "on": True, "off": False, "eq": parent, "neq": not parent,
            "if-on": True if parent else None, "if-off": False if not parent else None,
        }[dep.kind]
        if wanted is not None and state != wanted:
            return False
    return True


def _version_holds(atom: Atom, version: str) -> bool:
    if not atom.op:
        return True
    if atom.glob:
        return version.startswith(atom.version)
    if atom.op == "~":
        return vercmp(without_revision(version), without_revision(atom.version)) == 0
    c = vercmp(version, atom.version)
    return {"<": c < 0, "<=": c <= 0, "=": c == 0, ">=": c >= 0, ">": c > 0}[atom.op]


def matches(atom: Atom, pkg: Package, parent_use: frozenset = frozenset()) -> bool:
    """Whether `pkg` matches `atom` (blocker flag ignored), with the
    parent's USE for conditional USE dependencies."""
    if atom.cp != pkg.cp or not _version_holds(atom, pkg.version):
        return False
    if atom.slot and atom.slot != pkg.slot:
        return False
    if atom.subslot and atom.subslot != (pkg.subslot or pkg.slot):
        return False  # PMS 7.2: no sub-slot means the sub-slot is the slot
    return _use_deps_hold(atom, pkg, parent_use)


# --- dependency strings (PMS 8.2) -------------------------------------------
# A parsed string is a list of nodes: ("atom", Atom), ("all", [nodes]),
# ("any", [nodes]), ("one", [nodes]), ("most", [nodes]),
# ("if", flag, negated, [nodes]), ("flag", flag, negated) -- the last
# three kinds and "one"/"most" appear only in REQUIRED_USE.

_GROUPS = {"||": "any", "^^": "one", "??": "most"}


@functools.lru_cache(maxsize=None)
def parse_dep_string(text: str, required_use: bool = False) -> list:
    """Parse a dependency string (or a REQUIRED_USE string) into nodes.
    Cached: callers must not mutate the result."""
    tokens = text.split()
    nodes, pos = _parse_seq(tokens, 0, required_use)
    if pos != len(tokens):
        raise ValueError(f"unbalanced ')' in: {text}")
    return nodes


def _parse_seq(tokens: list[str], pos: int, required_use: bool) -> tuple[list, int]:
    nodes = []
    while pos < len(tokens) and tokens[pos] != ")":
        token = tokens[pos]
        if token == "(":
            children, pos = _parse_group(tokens, pos, required_use)
            nodes.append(("all", children))
        elif token in _GROUPS:
            children, pos = _parse_group(tokens, pos + 1, required_use)
            nodes.append((_GROUPS[token], children))
        elif token.endswith("?"):
            children, pos = _parse_group(tokens, pos + 1, required_use)
            nodes.append(("if", token[:-1].lstrip("!"), token.startswith("!"), children))
        elif required_use:
            nodes.append(("flag", token.lstrip("!"), token.startswith("!")))
            pos += 1
        else:
            nodes.append(("atom", parse_atom(token)))
            pos += 1
    return nodes, pos


def _parse_group(tokens: list[str], pos: int, required_use: bool) -> tuple[list, int]:
    """Parse `( ... )` starting at `pos`; returns the children and the
    position after `)`."""
    if pos >= len(tokens) or tokens[pos] != "(":
        raise ValueError(f"expected '(' at token {pos}")
    children, pos = _parse_seq(tokens, pos + 1, required_use)
    if pos >= len(tokens):
        raise ValueError("missing ')'")
    return children, pos + 1


def reduce_use(nodes: list, use: frozenset) -> list:
    """Drop the conditionals `use` turns off and splice in the ones it turns on."""
    out = []
    for node in nodes:
        if node[0] == "if":
            _, flag, negated, children = node
            if (flag in use) != negated:
                out.extend(reduce_use(children, use))
        elif node[0] in ("all", "any", "one", "most"):
            out.append((node[0], reduce_use(node[1], use)))
        else:
            out.append(node)
    return out


def render(node) -> str:
    if node[0] == "atom":
        return node[1].text
    if node[0] == "flag":
        return ("!" if node[2] else "") + node[1]
    prefix = {"all": "", "any": "|| ", "one": "^^ ", "most": "?? "}[node[0]]
    return prefix + "( " + " ".join(render(c) for c in node[1]) + " )"


def required_use_holds(text: str, use: frozenset) -> list[str]:
    """The top-level REQUIRED_USE items `use` breaks (empty when it holds)."""
    nodes = reduce_use(parse_dep_string(text, required_use=True), use)
    return [render(n) for n in nodes if not _required_use_node(n, use)]


def _required_use_node(node, use: frozenset) -> bool:
    if node[0] == "flag":
        return (node[1] in use) != node[2]
    values = [_required_use_node(c, use) for c in node[1]]
    if not values or node[0] == "all":
        return all(values)
    count = sum(values)
    return {"any": count >= 1, "one": count == 1, "most": count <= 1}[node[0]]


# --- satisfaction ------------------------------------------------------------

def _plain_atoms(nodes: list) -> list[Atom]:
    """Every non-blocker atom in a reduced tree, alternatives included."""
    out = []
    for node in nodes:
        if node[0] == "atom":
            if not node[1].blocker:
                out.append(node[1])
        else:
            out.extend(_plain_atoms(node[1]))
    return out


Index = dict  # (category, package) -> [Package]


def index(packages: list[Package]) -> Index:
    out: Index = {}
    for p in packages:
        out.setdefault(p.cp, []).append(p)
    return out


def _satisfied(node, available: Index, parent: Package) -> bool:
    if node[0] == "atom":
        atom = node[1]
        if atom.blocker:
            return True  # blockers are checked on the final set only
        return any(matches(atom, p, parent.use) for p in available.get(atom.cp, ()))
    values = [_satisfied(c, available, parent) for c in node[1]]
    return any(values) if node[0] == "any" and values else all(values)


def _blocker_hits(nodes: list, final: Index, owner: Package) -> list[tuple[Atom, Package]]:
    hits = []
    for node in nodes:
        if node[0] == "atom":
            atom = node[1]
            if atom.blocker:
                hits += [(atom, p) for p in final.get(atom.cp, ())
                         if p.cpv != owner.cpv and matches(atom, p, owner.use)]
        elif node[0] == "all":
            hits += _blocker_hits(node[1], final, owner)
    return hits


def _reduced(pkg: Package, dep_class: str) -> list:
    """The class's dependency tree under the package's USE; empty when the
    string does not parse (`check_plan` reports that once)."""
    try:
        return reduce_use(parse_dep_string(pkg.dependencies.get(dep_class, "")), pkg.use)
    except ValueError:
        return []


# --- loading a plan ----------------------------------------------------------

def _split_slot(slot: str) -> tuple[str, str]:
    main, _, sub = slot.partition("/")
    return main, sub


@functools.lru_cache(maxsize=None)
def read_vdb(vdb: Path | None, category: str, package: str, version: str) -> dict | None:
    """One installed package's VDB record as a `kept`-style dict, or None.
    Cached: callers must not mutate the result."""
    if vdb is None:
        return None
    d = vdb / category / f"{package}-{version}"
    if not d.is_dir():
        return None

    def read(key: str) -> str:
        f = d / key
        return f.read_text(errors="replace").strip() if f.is_file() else ""

    iuse = read("IUSE_EFFECTIVE") or read("IUSE")
    return {
        "slot": read("SLOT"),
        "use": read("USE").split(),
        "iuse": [f.lstrip("+-") for f in iuse.split()],
        "dependencies": {c: read(c) for c in DEP_CLASSES if read(c)},
        "required_use": read("REQUIRED_USE"),
    }


@functools.lru_cache(maxsize=None)
def installed_cpvs(vdb: Path) -> tuple[tuple[str, str, str], ...]:
    """(category, package, version) of every package in the VDB."""
    out = []
    for d in sorted(vdb.glob("*/*")):
        m = re.match(r"^(.+?)-(\d[^-]*(?:-r\d+)?)$", d.name)
        if d.is_dir() and m and is_version(m.group(2)):
            out.append((d.parent.name, m.group(1), m.group(2)))
    return tuple(out)


def _package(category, package, version, slot, data: dict | None, binary=False) -> Package:
    known = data is not None and "dependencies" in data
    data = data or {}
    main, sub = _split_slot(data.get("slot") or slot or "")
    return Package(
        category=category, package=package, version=version, slot=main,
        subslot=data.get("sub_slot") or sub,
        use=frozenset(data.get("use", ())), iuse=frozenset(data.get("iuse", ())),
        dependencies=dict(data.get("dependencies", {})),
        required_use=data.get("required_use", ""), binary=binary, known=known)


@dataclass
class Plan:
    merges: list[tuple[int, Package]]  # (merge order, package)
    kept: list[Package]
    replaced: list[tuple[int, Package]]  # installed, removed at that merge order
    dropped: list[Package] = field(default_factory=list)  # in the VDB, not kept or replaced

    @property
    def final(self) -> list[Package]:
        return self.kept + [p for _, p in self.merges]

    @property
    def initial(self) -> list[Package]:
        return self.kept + [p for _, p in self.replaced] + self.dropped

    def available_at(self, order: int) -> list[Package]:
        """What is installed when the merge at `order` starts."""
        return (self.kept + [p for o, p in self.replaced if o >= order]
                + [p for o, p in self.merges if o < order])


def load_plan(doc: dict, vdb: Path | None = None) -> Plan:
    merges, replaced = [], []
    for e in doc["entries"]:
        cat, pkg, order = e["category"], e["package"], e["merge_order"]
        outcome = e["outcome"]
        old = {"upgrade": e.get("from_version"), "downgrade": e.get("from_version"),
               "reinstall": e.get("version"), "uninstall": e.get("version")}.get(outcome)
        if old:
            replaced.append((order, _package(cat, pkg, old, e.get("slot"),
                                             read_vdb(vdb, cat, pkg, old))))
        if outcome in MERGE_BOUND:
            merges.append((order, _package(cat, pkg, e["version"], e.get("slot"), e,
                                           binary=e.get("source") == "binary")))
    kept = [_package(k["category"], k["package"], k["version"], k["slot"],
                     k if "dependencies" in k else read_vdb(vdb, k["category"], k["package"], k["version"]))
            for k in doc.get("kept", [])]
    known = {p.cpv for p in kept} | {p.cpv for _, p in replaced}
    dropped = [] if vdb is None else [
        _package(c, p, v, "", read_vdb(vdb, c, p, v)) for c, p, v in installed_cpvs(vdb)
        if f"{c}/{p}-{v}" not in known]
    return Plan(merges, kept, replaced, dropped)


# --- the checks --------------------------------------------------------------

def check_final_state(plan: Plan) -> list[Finding]:
    """Property 1 on the set the plan leaves installed."""
    final, initial = index(plan.final), index(plan.initial)
    kept_ids = {id(p) for p in plan.kept}
    findings = []
    for pkg in plan.final:
        was_there = id(pkg) in kept_ids
        for dep_class in RUNTIME_CLASSES:
            for node in _reduced(pkg, dep_class):
                if not _satisfied(node, final, pkg):
                    findings.append(Finding(
                        "runtime-deps", pkg.cpv, render(node),
                        f"{dep_class} not matched by any package in the final set",
                        pre_existing=was_there and not _satisfied(node, initial, pkg)))
            for atom, hit in _blocker_hits(_reduced(pkg, dep_class), final, pkg):
                findings.append(Finding(
                    "blocker", pkg.cpv, atom.text, f"blocks {hit.cpv}, which stays installed",
                    pre_existing=was_there and hit in initial.get(hit.cp, ())))
        if pkg.required_use:
            for item in required_use_holds(pkg.required_use, pkg.use):
                findings.append(Finding(
                    "required-use", pkg.cpv, item,
                    f"REQUIRED_USE broken by USE=\"{' '.join(sorted(pkg.use))}\"",
                    pre_existing=was_there))
    by_slot: dict = {}
    for pkg in plan.final:
        by_slot.setdefault((pkg.cp, pkg.slot), []).append(pkg.cpv)
    initial_cpvs = {p.cpv for p in plan.initial}
    for (cp, slot), cpvs in sorted(by_slot.items()):
        if len(cpvs) > 1:
            findings.append(Finding("slot", "/".join(cp), f"{'/'.join(cp)}:{slot}",
                                    "slot holds " + ", ".join(sorted(cpvs)),
                                    pre_existing=initial_cpvs.issuperset(cpvs)))
    return findings


def _build_atoms(pkg: Package) -> list:
    classes = ("IDEPEND",) if pkg.binary else BUILD_CLASSES + ("IDEPEND",)
    return [(c, node) for c in classes for node in _reduced(pkg, c)]


def _merges_by_cp(plan: Plan) -> dict:
    out: dict = {}
    for order, pkg in plan.merges:
        out.setdefault(pkg.cp, []).append((order, pkg))
    return out


def _matching_merges(by_cp: dict, nodes: list, parent: Package) -> set[int]:
    """Orders of the merges matching any plain atom of `nodes`."""
    return {o for a in _plain_atoms(nodes) for o, p in by_cp.get(a.cp, ())
            if matches(a, p, parent.use)}


def _build_graph(plan: Plan) -> dict[int, set[int]]:
    """order -> orders of the merges that must be usable before it: those its
    build-time atoms name (to build it) and those its RDEPEND names (for it
    to be usable), unless an installed package meets the atom already. A
    cycle in this graph cannot be serialized."""
    by_cp, initial = _merges_by_cp(plan), index(plan.initial)
    graph = {}
    for order, pkg in plan.merges:
        nodes = [n for _, n in _build_atoms(pkg)] + _reduced(pkg, "RDEPEND")
        needs = [[("atom", a) for a in atoms] for atoms in _choices(nodes)
                 if not any(matches(a, p, pkg.use) for a in atoms for p in initial.get(a.cp, ()))]
        graph[order] = {o for n in needs for o in _matching_merges(by_cp, n, pkg)} - {order}
    return graph


def _components(graph: dict[int, set[int]]) -> dict[int, int]:
    """Strongly connected component id per node (Tarjan, iterative)."""
    index, low, comp, stack, on_stack, counter = {}, {}, {}, [], set(), [0]
    for root in graph:
        if root in index:
            continue
        work = [(root, iter(sorted(graph[root])))]
        index[root] = low[root] = counter[0]
        counter[0] += 1
        stack.append(root)
        on_stack.add(root)
        while work:
            node, children = work[-1]
            child = next(children, None)
            if child is None:
                work.pop()
                if work:
                    low[work[-1][0]] = min(low[work[-1][0]], low[node])
                if low[node] == index[node]:
                    while True:
                        member = stack.pop()
                        on_stack.discard(member)
                        comp[member] = node
                        if member == node:
                            break
            elif child not in index:
                index[child] = low[child] = counter[0]
                counter[0] += 1
                stack.append(child)
                on_stack.add(child)
                work.append((child, iter(sorted(graph.get(child, ())))))
            elif child in on_stack:
                low[node] = min(low[node], index[child])
    return comp


def _order_finding(plan: Plan, component, order: int, pkg: Package, node,
                   what: str, owner: Package | None = None, later=None) -> Finding:
    """A build-time need of `pkg` (merged at `order`) that is not met when it
    starts: noted as a cycle when a later package of its cycle meets it.
    `owner` is the package whose dependency `node` is (default: `pkg`);
    `later` the merges that would meet it (default: those matching `node`)."""
    if later is None:
        later = sorted((o, p) for o, p in plan.merges if o > order
                       and o in _matching_merges(_merges_by_cp(plan), [node], owner or pkg))
    if any(component.get(o) == component[order] for o, _ in later):
        return Finding("cycle-noted", pkg.cpv, render(node),
                       f"{what} is only met by a later package of the same cycle")
    if later:
        return Finding("build-order", pkg.cpv, render(node),
                       f"{what} is met only by {later[0][1].cpv}, merged later "
                       f"(#{later[0][0]} > #{order}): merge it first")
    return Finding("build-order", pkg.cpv, render(node),
                   f"{what} is not matched by anything installed or merged before it")


def _choices(nodes: list) -> list[list[Atom]]:
    """The atoms of a reduced tree as lists of alternatives, one of each
    list to be met (an `all` group splits, an `any` group is one list)."""
    out = []
    for node in nodes:
        if node[0] == "atom":
            out += [] if node[1].blocker else [[node[1]]]
        elif node[0] == "all":
            out += _choices(node[1])
        else:
            out.append(_plain_atoms([node]))
    return out


@dataclass
class _Moment:
    """The system when one merge starts, for the usability walk."""

    available: Index
    initial: Index
    merged: set  # id() of the packages the plan merges
    gaps: dict = field(default_factory=dict)  # id(package) -> its gap, or None

    def providers(self, atoms: list[Atom], parent: Package) -> list[Package]:
        return [p for a in atoms for p in self.available.get(a.cp, ()) if matches(a, p, parent.use)]

    def gap(self, pkg: Package) -> tuple[Package, tuple] | None:
        """Why `pkg` is not usable now (PMS 8.1): the first package in its
        RDEPEND closure with an RDEPEND atom the plan left unmet, and that
        atom. An atom an installed package already missed before the plan
        does not count; a runtime cycle counts as usable."""
        if id(pkg) in self.gaps:
            return self.gaps[id(pkg)]
        self.gaps[id(pkg)] = None  # a cycle back here counts as usable
        found = None
        for node in _reduced(pkg, "RDEPEND"):
            if not _satisfied(node, self.available, pkg):
                if id(pkg) in self.merged or _satisfied(node, self.initial, pkg):
                    found = (pkg, node)
                    break
                continue
            for atoms in _choices([node]):
                sub = [self.gap(p) for p in self.providers(atoms, pkg)]
                if sub and all(sub):
                    found = sub[0]
                    break
            if found:
                break
        self.gaps[id(pkg)] = found
        return found


def _unusable(node, moment: _Moment, pkg: Package) -> tuple[Package, tuple] | None:
    """When no package meeting build-time `node` of `pkg` is usable: the
    first gap found."""
    for atoms in _choices([node]):
        gaps = [moment.gap(p) for p in moment.providers(atoms, pkg)]
        if gaps and all(gaps):
            return gaps[0]
    return None


def _build_blockers(pkg: Package, available: Index) -> list[tuple[Atom, Package]]:
    """DEPEND/BDEPEND blockers of `pkg` matching a package present when it builds."""
    return [hit for c in BUILD_CLASSES for hit in _blocker_hits(_reduced(pkg, c), available, pkg)]


def check_order(plan: Plan) -> list[Finding]:
    """Property 2: build-time atoms are matched, by usable packages, when
    each merge starts."""
    component = _components(_build_graph(plan))
    merged = {id(p) for _, p in plan.merges}
    initial = index(plan.initial)
    findings = []
    for order, pkg in plan.merges:
        available = index(plan.available_at(order))
        moment = _Moment(available, initial, merged)
        if not pkg.binary:
            findings += [Finding("blocker", pkg.cpv, atom.text,
                                 f"build-time blocker: {hit.cpv} is installed when it builds")
                         for atom, hit in _build_blockers(pkg, available)]
        for dep_class, node in _build_atoms(pkg):
            if not _satisfied(node, available, pkg):
                findings.append(_order_finding(plan, component, order, pkg, node, dep_class))
                continue
            hit = _unusable(node, moment, pkg)
            if hit:
                provider, unmet = hit
                # An installed copy the plan rebuilds later is fixed by that rebuild.
                rebuild = [(o, p) for o, p in plan.merges if o > order and any(
                    r is provider and ro == o for ro, r in plan.replaced)]
                findings.append(_order_finding(
                    plan, component, order, pkg, unmet,
                    f"{dep_class} {render(node)} is not usable yet: RDEPEND of {provider.cpv}",
                    provider, rebuild or None))
    return findings


def check_plan(doc: dict, vdb: Path | None = None) -> list[Finding]:
    """Every finding for one `--pretend -v --json` document."""
    plan = load_plan(doc, vdb)
    limits = [Finding("checker-limitation", p.cpv, "", "no dependency data for this package")
              for p in plan.final if not p.known]
    for pkg in plan.final:
        for dep_class, text in pkg.dependencies.items():
            try:
                parse_dep_string(text)
            except ValueError as err:
                limits.append(Finding("checker-limitation", pkg.cpv, dep_class, f"cannot parse: {err}"))
    return limits + check_final_state(plan) + check_order(plan)


def refusal(doc: dict) -> str:
    """Why portuale itself refuses to run this plan ("" when it would run it):
    a slot conflict, a needed configuration change, or an unsolvable blocker."""
    reasons = []
    if doc.get("slot_conflicts"):
        reasons.append("slot conflict")
    if any(doc.get(f"autounmask_{k}_changes") for k in ("keyword", "use", "license", "mask")):
        reasons.append("needs configuration changes")
    if any(b.get("unsolvable") for e in doc["entries"] for b in e.get("blockers", ())):
        reasons.append("unsolvable blocker")
    return ", ".join(reasons)


def parse_json_output(text: str) -> dict | None:
    """The `--json` document in a captured stdout, or None."""
    for line in text.splitlines():
        if line.startswith('{"entries":'):
            return json.loads(line)
    return None


def main(argv: list[str]) -> int:
    vdb = None
    if len(argv) >= 2 and argv[0] == "--vdb":
        vdb, argv = Path(argv[1]), argv[2:]
    failed = False
    for name in argv:
        doc = parse_json_output(Path(name).read_text(errors="replace"))
        record = {"plan": name}
        if doc is None:
            record["skipped"] = "no --json document"
        elif doc.get("aborted"):
            record["skipped"] = f"plan aborted: {doc['aborted'].get('reason')}"
        else:
            start = time.monotonic()
            findings = check_plan(doc, vdb)
            record["seconds"] = round(time.monotonic() - start, 3)
            record["findings"] = [asdict(f) for f in findings]
            record["refused"] = refusal(doc)
            failed |= not record["refused"] and any(
                f.is_failure and not f.pre_existing for f in findings)
        print(json.dumps(record, sort_keys=True))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
