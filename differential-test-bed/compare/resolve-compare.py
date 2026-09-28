#!/usr/bin/env python3
"""L0 -- resolver parity comparison (host half).

Usage: resolve-compare.py [--fs NAME] [--backend NAME] <dir> [allowlist]

Reads a directory produced by ``differential-test-bed/layers/l0/in-container.sh``::

    <dir>/real/<slug>.txt        raw `emerge -pv` output, real portage
    <dir>/portuale/<slug>.txt    raw `emerge -pv` output, portuale
    <dir>/meta.tsv               slug \\t kind \\t real_rc \\t ptl_rc
    <dir>/fingerprint.tsv        environment fingerprint

For every probe it normalises both merge lists and reports typed
findings (missing / extra / version / flags / use / order / error /
exit / totals / skipped-updates). A finding is *explained* when it
matches an entry in the allowlist (``known-divergences.yaml``); the run
is GREEN iff every finding is explained.

Outputs ``<dir>/l0-report.txt`` (human) and ``<dir>/l0-report.json``
(machine). Exit status: 0 green, 1 unexplained findings, 2 usage/IO.

stdlib + PyYAML only.
"""
from __future__ import annotations

import json
import re
import sys
from collections import Counter
from dataclasses import dataclass, field, asdict
from pathlib import Path

try:
    import yaml
except ModuleNotFoundError:  # pragma: no cover
    sys.exit("resolve-compare.py needs PyYAML (dev-python/pyyaml)")

ANSI = re.compile(r"\x1b\[[0-9;]*m")
# [ebuild   N     ] cat/pkg-1.2-r3::repo  USE="..."   -- the merge-list line
MERGE = re.compile(r"^\[(?P<type>[a-z]+)(?P<flags>[^\]]*)\]\s+(?P<rest>\S.*?)\s*$")
TOTAL = re.compile(r"^Total:\s*(\d+)\s*package")
ERRLINE = re.compile(r"^(emerge:|!!!|\s*\*\s*(ERROR|The following)|.*\bREQUIRED_USE\b)")
KV = re.compile(r'([A-Z0-9_]+)="([^"]*)"')
# version = first hyphen-component that starts with a digit (portage rule)
CPV = re.compile(r"^(?P<cp>.+?)-(?P<ver>\d[^-]*(?:-r\d+)?)(?:::(?P<repo>\S+))?$")

MERGE_TYPES = {"ebuild", "binary", "nomerge", "blocks", "uninstall"}


@dataclass
class Pkg:
    type: str
    cp: str
    ver: str
    slot: str
    repo: str
    flags: str
    use: dict[str, list[str]]
    raw: str


@dataclass
class Probe:
    slug: str
    kind: str
    real_rc: int
    ptl_rc: int
    findings: list[dict] = field(default_factory=list)


def strip_ansi(s: str) -> str:
    return ANSI.sub("", s)


def split_cpv(s: str) -> tuple[str, str, str]:
    m = CPV.match(s)
    if not m:
        return s, "", ""
    return m["cp"], m["ver"], m["repo"] or ""


def split_cpv_slot(tok: str) -> tuple[str, str, str, str]:
    """``cat/pkg-VER:SLOT/SUB::repo`` -> (cp, ver, slot, repo).

    A multi-slot package (``llvm-core/llvm-21.1.8:21/21.1`` alongside
    ``…-22.1.8:22/22.1``) must keep the slot in its identity key, or the
    two rows collapse and the survivor is compared against the wrong
    slot on the other side -- a phantom ``version`` finding.

    >>> split_cpv_slot("llvm-core/llvm-21.1.8:21/21.1::gentoo")
    ('llvm-core/llvm', '21.1.8', '21/21.1', 'gentoo')
    >>> split_cpv_slot("dev-lang/rust-bin-1.96.1:1.96.1::gentoo")
    ('dev-lang/rust-bin', '1.96.1', '1.96.1', 'gentoo')
    >>> split_cpv_slot("app-misc/tmux-3.4::gentoo")
    ('app-misc/tmux', '3.4', '', 'gentoo')
    >>> split_cpv_slot("sys-apps/hwdata-0.401")
    ('sys-apps/hwdata', '0.401', '', '')
    """
    repo = ""
    if "::" in tok:
        tok, repo = tok.split("::", 1)
    cp, ver, _ = split_cpv(tok)
    slot = ""
    if ver and ":" in ver:
        ver, slot = ver.split(":", 1)
    return cp, ver, slot, repo


ADVICE_ATOM = re.compile(r"^[<>=~]*[a-z0-9][a-z0-9+._-]*/\S+(?:\s+\S+)*\s*$")
MASKED = re.compile(r'have been masked|is required to complete your request')
REQUSE = re.compile(r'REQUIRED_USE (?:flag constraints are unsatisfied|not satisfied)')


# Backlog #227: real `_show_missed_update_slot_conflicts`
# (`3rdparty/portage/lib/_emerge/depgraph.py:1652`, 3.0.82.2) prints one
# `WARNING: One or more updates/rebuilds have been skipped due to a
# dependency conflict:` block after the merge list (rc 0) -- one
# `<slot_atom>` header per missed upgrade with its `conflicts with`
# detail rows underneath. Portuale renders the same block from
# `GraphResult::skipped_updates` (`rust/portuale/src/pretend.rs`,
# "Backlog #90 (S2) + #92"). The block used to be silently dropped by
# this comparator (none of its lines match MERGE/TOTAL/ERRLINE), so the
# r25 cell reported 0 unexplained while portuale printed the warning
# and real did not.
SKIPPED_HEADER = (
    "WARNING: One or more updates/rebuilds have been skipped "
    "due to a dependency conflict:"
)


def _norm_skipped_detail(s: str) -> str:
    """Normalise volatile bits out of a skipped-block detail line.

    Real appends the target root to scheduled-for-merge consumers
    (`merge to '<ROOT>'`) and to group headers (`for <ROOT>`); the
    staged path varies per run dir, so only its presence is signal --
    the path itself becomes a placeholder (same treatment as
    `<builddir>` for error lines).
    """
    s = re.sub(r"/var/tmp/portage/\S+", "<builddir>", s)
    s = re.sub(r"'[^']*'", "'<root>'", s)
    return re.sub(r"\s+", " ", s).strip()


def _skipped_row_key(s: str) -> str:
    """Package-identity key of a skipped-block detail line.

    Strips the `KEY="..."` USE/USE_EXPAND displays (real's
    `pkg_use_display` renders USE plus ABI_X86/ELIBC/... expansions,
    portuale's `render_pkg_use_display` only USE) and the normalised
    root suffixes -- those belong to the explanation text, compared
    separately. What remains is which packages were skipped and which
    atoms block them.
    """
    s = KV.sub("", s)
    s = re.sub(r"\s+to\s+'<root>'", "", s)
    # real's installed parents carry ` in '<root>'` (`Package.__str__`)
    s = re.sub(r"\s+in\s+'<root>'", "", s)
    return re.sub(r"\s+", " ", s).strip()


def _is_skipped_group_header(s: str) -> bool:
    """A group header is a `cat/pkg:slot` token (real's
    `str(pkg.slot_atom)`, portuale's `{category}/{package}:{slot}`),
    optionally followed by real's ` for <root>`.

    Any other non-indented line (the `!!!` abbreviated tail, autounmask
    advice, `emerge:` errors, ...) ends the block instead.
    """
    toks = s.strip().split()
    # Real appends ` for <root>` when ROOT != "/" (`depgraph.py:1662-1664`);
    # the staged fixture oracle always runs with such a root.
    if not (len(toks) == 1 or (len(toks) == 3 and toks[1] == "for")):
        return False
    tok = toks[0]
    return "/" in tok and ":" in tok and not tok.startswith(("!", "#", "["))


def _parse_skipped_block(lines: list[str], i: int) -> tuple[dict, int]:
    """Parse the skipped-update block starting at the WARNING header.

    `lines[i]` is the header line. Returns (groups, next_i) where
    groups maps header slot-atom -> {"with": sorted deduped missed-
    version keys, "rows": sorted conflict-atom identity keys,
    "expl": sorted normalised detail lines} (duplicate headers, as
    portuale emits one block per rejecting parent while real groups
    parents under one header, merge back together -- the per-group
    `conflicts with` line is a per-header attribute, not a per-row
    one, so it compares as a set), and next_i is the first unconsumed
    line so a following section (`!!!` tail, autounmask advice, ...)
    still flows through normal parsing.
    """
    groups: dict[str, dict[str, list[str]]] = {}
    n = len(lines)
    i += 1
    while True:
        while i < n and not strip_ansi(lines[i]).strip():
            i += 1
        if i >= n:
            break
        if not _is_skipped_group_header(strip_ansi(lines[i]).rstrip()):
            break
        header = strip_ansi(lines[i]).strip().split()[0]
        i += 1
        while i < n and not strip_ansi(lines[i]).strip():
            i += 1
        if i >= n:
            break
        with_line = strip_ansi(lines[i]).rstrip()
        if not with_line[:1].isspace() or not with_line.strip().endswith("conflicts with"):
            # malformed group: drop the header, resume normal parsing here
            break
        g = groups.setdefault(header, {"with": [], "rows": [], "expl": []})
        g["expl"].append(_norm_skipped_detail(with_line))
        g["with"].append(_skipped_row_key(_norm_skipped_detail(with_line)))
        i += 1
        while True:
            while i < n and not strip_ansi(lines[i]).strip():
                i += 1
            if i >= n:
                break
            atom_line = strip_ansi(lines[i]).rstrip()
            if not atom_line[:1].isspace():
                break  # next group header or next section
            g["expl"].append(_norm_skipped_detail(atom_line))
            g["rows"].append(_skipped_row_key(_norm_skipped_detail(atom_line)))
            i += 1
            # The `^` marker line mirrors real's operator/version spans
            # (`format_unmatched_atom`, `resolver/output.py:892`); an
            # empty/all-space marker rstrips to a blank line, which the
            # skip above already tolerates -- but a present marker is
            # explanation text, so consume exactly one line when it
            # looks like one rather than letting it masquerade as the
            # next atom row.
            if i < n and re.fullmatch(r"\s*(\^.*)?", strip_ansi(lines[i]).rstrip()):
                marker = strip_ansi(lines[i]).rstrip()
                if marker.strip():
                    g["expl"].append(_norm_skipped_detail(marker))
                i += 1
    for g in groups.values():
        g["with"] = sorted(set(g["with"]))
        g["rows"].sort()
        g["expl"].sort()
    return groups, i


def parse(path: Path) -> tuple[list[Pkg], list[str], int | None, set[str], bool, dict]:
    """Return (merge-list, error lines, Total-or-None, advice set,
    backtracking-terminated-early flag, skipped-update groups).

    The *advice set* is the actionable "you must change something"
    diagnostics -- needed USE-flag changes, masked-package requirements,
    unsatisfied REQUIRED_USE -- normalised so real and portuale can be
    compared even when one truncates its merge list and the other does
    not (the autounmask exit-code divergence).

    *backtracking-terminated-early* is real's own marker that it stopped
    after the first autounmask batch (`--autounmask-backtrack=n`); when
    it fires and the two Total counts are far apart, the merge lists are
    a truncated-vs-complete pair and set/order comparison is meaningless.
    """
    pkgs: list[Pkg] = []
    errs: list[str] = []
    total: int | None = None
    advice: set[str] = set()
    terminated_early = False
    skipped: dict = {}
    if not path.exists():
        return pkgs, ["<no output file>"], None, advice, terminated_early, skipped
    in_use_block = False
    raw_lines = path.read_text(errors="replace").splitlines()
    i = 0
    while i < len(raw_lines):
        line = raw_lines[i]
        i += 1
        if "backtracking has terminated early" in line:
            terminated_early = True
        line = strip_ansi(line).rstrip()
        if not line:
            continue
        m = MERGE.match(line)
        if m and m["type"] in MERGE_TYPES:
            rest = m["rest"]
            tok = rest.split()[0]
            if m["type"] in ("blocks", "uninstall"):
                # the token is an atom / cpv, not necessarily splittable
                cp, ver, slot, repo = tok, "", "", ""
            else:
                cp, ver, slot, repo = split_cpv_slot(tok)
            use = {k: sorted(v.split()) for k, v in KV.findall(rest)}
            pkgs.append(
                Pkg(
                    type=m["type"],
                    cp=cp,
                    ver=ver,
                    slot=slot,
                    repo=repo,
                    flags=" ".join(m["flags"].split()),
                    use=use,
                    raw=line,
                )
            )
            continue
        mt = TOTAL.match(line)
        if mt:
            total = int(mt.group(1))
            continue
        if line.strip() == SKIPPED_HEADER:
            # Backlog #227: the skipped-update block used to fall
            # through to the error-line match below (or, worse, be
            # dropped silently) -- parse it as its own category.
            # `_parse_skipped_block` takes raw lines + the index of
            # the line after the header (`i` already advanced past
            # it) and returns the resume index.
            # (real and portuale each print at most one; a second
            # block merges into the first rather than replacing it)
            new_groups, i = _parse_skipped_block(raw_lines, i)
            for h, g in new_groups.items():
                old = skipped.setdefault(h, {"with": [], "rows": [], "expl": []})
                old["with"].extend(g["with"])
                old["rows"].extend(g["rows"])
                old["expl"].extend(g["expl"])
                old["with"] = sorted(set(old["with"]))
                old["rows"].sort()
                old["expl"].sort()
            continue
        stripped = line.strip()
        if stripped.startswith("The following USE changes are necessary"):
            in_use_block = True
            continue
        if in_use_block:
            if not stripped or stripped.startswith("#") or stripped.startswith("("):
                if not stripped:
                    in_use_block = False
                continue
            if ADVICE_ATOM.match(stripped):
                # Real `_display_autounmask` joins a package's flipped
                # flags in Python `set` iteration order, which is
                # PYTHONHASHSEED-randomised -- three `emerge -pv` runs of
                # the same resolve give `cairo lcms` / `cairo lcms` /
                # `lcms cairo`. Canonicalise to `<atom> <sorted flags>`
                # so the flag *set* is what's compared, not its order.
                parts = re.sub(r"\s+", " ", stripped).split(" ")
                canon = parts[0] + " " + " ".join(sorted(parts[1:]))
                advice.add("use-change: " + canon.strip())
                continue
            in_use_block = False
        if MASKED.search(line):
            advice.add("masked: " + re.sub(r"\s+", " ", stripped))
        if REQUSE.search(line):
            advice.add("required-use: " + re.sub(r"\s+", " ", stripped))
        m2 = re.search(r'"([^"]+)" have been masked', line)
        if m2:
            advice.add(f"masked-atom: {m2.group(1)}")

        if ERRLINE.match(line):
            # normalise volatile bits out of error/message lines
            n = re.sub(r"/var/tmp/portage/\S+", "<builddir>", line)
            n = re.sub(r"\b\d{4}-\d\d-\d\d\b", "<date>", n)
            n = re.sub(r"\s+", " ", n).strip()
            errs.append(n)
    return pkgs, errs, total, advice, terminated_early, skipped


def compare(slug: str, kind: str, rrc: int, prc: int, rp: Path, pp: Path) -> Probe:
    pr = Probe(slug=slug, kind=kind, real_rc=rrc, ptl_rc=prc)
    rpk, rerr, rtot, radv, r_trunc, rskip = parse(rp)
    ppk, perr, ptot, padv, p_trunc, pskip = parse(pp)

    def add(cat: str, detail: str) -> None:
        pr.findings.append({"category": cat, "detail": detail})

    # -- actionable advice (needed USE changes / masks / REQUIRED_USE) ----
    # compared even when exit codes differ (autounmask truncates one side)
    for a in sorted(radv - padv):
        add("advice", f"real-only: {a}")
    for a in sorted(padv - radv):
        add("advice", f"portuale-only: {a}")

    # -- skipped-update warning block (backlog #227) ---------------------
    # Real `_show_missed_update_slot_conflicts` and portuale's
    # `GraphResult::skipped_updates` rendering print this after the
    # merge list with rc 0. Like advice it is compared on every path
    # (even when exit codes differ): presence on one side only, and a
    # different skipped package list, are findings; the explanation
    # text (USE displays, `^` markers, root suffixes) is compared only
    # when both sides print the block.
    add_skipped_findings(pr, rskip, pskip)

    # -- autounmask merge-list truncation --------------------------------
    # Real, with `--autounmask-backtrack=n` (the default), can stop the
    # resolve at the first autounmask-blocked node and emit only a
    # partial merge list (`* backtracking has terminated early`). When it
    # does AND the two Total counts are far apart, portuale's fuller list
    # is not "extra packages" -- it is what real *would* have shown had it
    # kept going. Comparing set/order/totals then is truncated-vs-complete
    # noise (the same reason the `rrc != prc` branch above bails). Compare
    # advice + errors and report the shape. `known-divergences.yaml` can
    # still adjudicate the one residual "portuale does not truncate"
    # divergence; this keeps it from fanning out to ~500 findings.
    def _far_apart(a: int | None, b: int | None) -> bool:
        return a is not None and b is not None and min(a, b) * 2 < max(a, b)

    if (r_trunc or p_trunc) and _far_apart(rtot, ptot):
        add(
            "truncated",
            f"autounmask backtracking terminated early (real Total {rtot} / "
            f"{len(rpk)} lines, portuale Total {ptot} / {len(ppk)} lines) -- "
            "merge-list set/order/totals comparison suppressed",
        )
        rset, pset = set(rerr), set(perr)
        for e in sorted(rset - pset):
            add("error", f"real-only message: {e}")
        for e in sorted(pset - rset):
            add("error", f"portuale-only message: {e}")
        return pr

    if rrc != prc:
        add("exit", f"real rc={rrc} portuale rc={prc}")
        # the merge lists are a complete-vs-truncated comparison here --
        # every missing/extra/order/totals finding would be downstream
        # noise. Report the shapes and stop.
        add(
            "exit",
            f"merge-list comparison suppressed: real {len(rpk)} lines / "
            f"Total {rtot}, portuale {len(ppk)} lines / Total {ptot}",
        )
        rset, pset = set(rerr), set(perr)
        for e in sorted(rset - pset):
            add("error", f"real-only message: {e}")
        for e in sorted(pset - rset):
            add("error", f"portuale-only message: {e}")
        return pr

    # -- package identity keyed by (type, cp, slot) ------------------------
    # slot is load-bearing: a package installed in two slots at once
    # (llvm-core/llvm:21 + :22) must not collapse to one map entry.
    rmap = {(p.type, p.cp, p.slot): p for p in rpk}
    pmap = {(p.type, p.cp, p.slot): p for p in ppk}
    def ident(p: Pkg) -> str:
        s = f":{p.slot}" if p.slot else ""
        return f"{p.type} {p.cp}-{p.ver}{s}" if p.ver else f"{p.type} {p.cp}{s}"

    for key in rmap.keys() - pmap.keys():
        add("missing", f"{ident(rmap[key])} present for real, absent for portuale")
    for key in pmap.keys() - rmap.keys():
        add("extra", f"{ident(pmap[key])} present for portuale, absent for real")

    # A multi-slot package reinstalled/merged in several slots at once
    # (app-text/docbook-xml-dtd:4.2 + :4.4 + :4.5 ...) shows no `:slot` at
    # verbosity 2 (`emerge -pe`, no `-v`), so every slot collapses to the
    # same `(type, cp, "")` map key and only the last-seen survives. A
    # `version` finding off that survivor is pure position noise -- the
    # underlying lists carry the identical slot set. Suppress `version`
    # for any cp that appears more than once on either side without slot
    # disambiguation; the reordering still surfaces as an `order` finding.
    rcp_count: dict[str, int] = {}
    pcp_count: dict[str, int] = {}
    for x in rpk:
        rcp_count[x.cp] = rcp_count.get(x.cp, 0) + 1
    for x in ppk:
        pcp_count[x.cp] = pcp_count.get(x.cp, 0) + 1

    for key in rmap.keys() & pmap.keys():
        r, p = rmap[key], pmap[key]
        s = f":{r.slot}" if r.slot else ""
        if r.ver != p.ver and not (
            not r.slot and (rcp_count.get(r.cp, 0) > 1 or pcp_count.get(r.cp, 0) > 1)
        ):
            add("version", f"{r.cp}{s}: real {r.ver} vs portuale {p.ver}")
        if r.flags != p.flags:
            add("flags", f"{r.cp}: real flags [{r.flags}] vs portuale [{p.flags}]")
        for uk in r.use.keys() | p.use.keys():
            rv, pv = r.use.get(uk, []), p.use.get(uk, [])
            if rv != pv:
                add("use", f"{r.cp} {uk}: real {rv} vs portuale {pv}")

    # -- merge order (over the common set) --------------------------------
    # `[blocks ...]` lines are not merge tasks -- real prints them in
    # `_blocker_parents` (a digraph) iteration order, which is
    # PYTHONHASHSEED-randomised (a two-blocker package flips between runs)
    # -- so they're excluded from the ordered comparison (still compared
    # for identity above).
    common = [
        (x.type, x.cp, x.slot) for x in rpk if x.type != "blocks" and (x.type, x.cp, x.slot) in pmap
    ]
    pcommon = [
        (x.type, x.cp, x.slot) for x in ppk if x.type != "blocks" and (x.type, x.cp, x.slot) in rmap
    ]
    if common != pcommon and sorted(common) == sorted(pcommon):
        # first divergent position, for a readable detail
        for i, (a, b) in enumerate(zip(common, pcommon)):
            if a != b:
                add(
                    "order",
                    f"merge order diverges at #{i}: real {a[1]} vs portuale {b[1]}",
                )
                break

    # -- Total: count ----------------------------------------------------
    if rtot is not None and ptot is not None and rtot != ptot:
        add("totals", f"real Total {rtot} vs portuale Total {ptot}")

    # -- error / message lines -----------------------------------------
    rset, pset = set(rerr), set(perr)
    for e in sorted(rset - pset):
        add("error", f"real-only message: {e}")
    for e in sorted(pset - rset):
        add("error", f"portuale-only message: {e}")

    return pr


# --------------------------------------------------------------------------
# skipped-update block comparison (backlog #227)
# --------------------------------------------------------------------------
def _only_in(a: list[str], b: list[str]) -> list[str]:
    """Multiset difference, sorted (duplicate detail lines are real:
    portuale emits one block per rejecting parent)."""
    diff = Counter(a) - Counter(b)
    return sorted(diff.elements())


def add_skipped_findings(pr: Probe, rskip: dict, pskip: dict) -> None:
    def add(detail: str) -> None:
        pr.findings.append({"category": "skipped-updates", "detail": detail})

    if bool(rskip) != bool(pskip):
        side = "real" if rskip else "portuale"
        missing = "portuale" if rskip else "real"
        present = sorted(rskip if rskip else pskip)
        add(
            f"skipped-update block present for {side}, "
            f"absent for {missing}: {', '.join(present)}"
        )
        return
    if not rskip:
        return
    for h in sorted(set(rskip) - set(pskip)):
        add(f"skipped package present for real, absent for portuale: {h}")
    for h in sorted(set(pskip) - set(rskip)):
        add(f"skipped package present for portuale, absent for real: {h}")
    for h in sorted(set(rskip) & set(pskip)):
        r_w, p_w = rskip[h]["with"], pskip[h]["with"]
        r_rows, p_rows = rskip[h]["rows"], pskip[h]["rows"]
        if r_w != p_w:
            bits = []
            r_only = _only_in(r_w, p_w)
            p_only = _only_in(p_w, r_w)
            if r_only:
                bits.append("real-only: " + "; ".join(r_only))
            if p_only:
                bits.append("portuale-only: " + "; ".join(p_only))
            add(f"{h}: skipped package list differs: {' | '.join(bits)}")
        elif r_rows != p_rows:
            bits = []
            r_only = _only_in(r_rows, p_rows)
            p_only = _only_in(p_rows, r_rows)
            if r_only:
                bits.append("real-only: " + "; ".join(r_only))
            if p_only:
                bits.append("portuale-only: " + "; ".join(p_only))
            add(f"{h}: skipped package list differs: {' | '.join(bits)}")
        elif rskip[h]["expl"] != pskip[h]["expl"]:
            # Same packages, different explanation text (USE/USE_EXPAND
            # displays, `^` markers, `to '<root>'` suffixes). Cap the
            # quoted lines so one noisy block cannot flood the report.
            bits = []
            r_only = _only_in(rskip[h]["expl"], pskip[h]["expl"])
            p_only = _only_in(pskip[h]["expl"], rskip[h]["expl"])
            if r_only:
                shown = "; ".join(r_only[:3])
                if len(r_only) > 3:
                    shown += f"; (+{len(r_only) - 3} more)"
                bits.append(f"real-only ({len(r_only)}): {shown}")
            if p_only:
                shown = "; ".join(p_only[:3])
                if len(p_only) > 3:
                    shown += f"; (+{len(p_only) - 3} more)"
                bits.append(f"portuale-only ({len(p_only)}): {shown}")
            add(f"{h}: skipped-update explanation differs: {' | '.join(bits)}")


# --------------------------------------------------------------------------
# allowlist
# --------------------------------------------------------------------------
def load_allowlist(path: Path) -> list[dict]:
    if not path.exists():
        return []
    data = yaml.safe_load(path.read_text()) or []
    if not isinstance(data, list):
        sys.exit(f"{path}: expected a top-level YAML list")
    return data


def glob_match(pat: str, s: str) -> bool:
    return re.fullmatch(re.escape(pat).replace(r"\*", ".*"), s) is not None


def explained(finding: dict, slug: str, kind: str, allow: list[dict],
              run_fs: str | None = None,
              run_backend: str | None = None) -> dict | None:
    for e in allow:
        if e.get("layer", "l0") != "l0":
            continue
        fs = e.get("fs")
        if fs is not None:
            fs = [fs] if isinstance(fs, str) else list(fs)
            # An fs-qualified entry only explains runs on those
            # filesystems (VM bed matrix); unqualified entries match all.
            # A run without --fs is explained by nothing fs-qualified.
            if run_fs not in fs:
                continue
        if e.get("backend") is not None and run_backend != e["backend"]:
            # Backend-qualified entries (VM-only guest-state findings)
            # never explain container runs and vice versa.
            continue
        cats = e.get("categories") or ([e["category"]] if "category" in e else [])
        if cats and finding["category"] not in cats:
            continue
        slugs = e.get("slugs") or []
        if slugs and not any(glob_match(g, slug) for g in slugs):
            continue
        sub = e.get("match")
        if sub and sub not in finding["detail"]:
            continue
        if not (cats or slugs or sub):
            continue  # an entry that constrains nothing matches nothing
        return e
    return None


# --------------------------------------------------------------------------
def main(argv: list[str]) -> int:
    run_fs: str | None = None
    run_backend: str | None = None
    pos: list[str] = []
    i = 0
    while i < len(argv):
        if argv[i] == "--fs":
            i += 1
            if i >= len(argv):
                print(__doc__)
                return 2
            run_fs = argv[i]
        elif argv[i] == "--backend":
            i += 1
            if i >= len(argv):
                print(__doc__)
                return 2
            run_backend = argv[i]
        else:
            pos.append(argv[i])
        i += 1
    if not 1 <= len(pos) <= 2:
        print(__doc__)
        return 2
    d = Path(pos[0])
    allow = load_allowlist(
        Path(pos[1]) if len(pos) == 2 else Path(__file__).with_name("known-divergences.yaml")
    )
    meta = d / "meta.tsv"
    if not meta.exists():
        sys.exit(f"{meta} not found -- run the in-container half first")

    probes: list[Probe] = []
    for row in meta.read_text().splitlines():
        if not row.strip():
            continue
        slug, kind, rrc, prc = row.split("\t")
        probes.append(
            compare(slug, kind, int(rrc), int(prc), d / "real" / f"{slug}.txt", d / "portuale" / f"{slug}.txt")
        )

    # classify
    unexplained: list[tuple[str, dict]] = []
    explained_hits: list[tuple[str, dict, str]] = []
    for pr in probes:
        for f in pr.findings:
            e = explained(f, pr.slug, pr.kind, allow, run_fs, run_backend)
            if e:
                f["explained_by"] = e.get("id", "<unnamed>")
                explained_hits.append((pr.slug, f, e.get("id", "<unnamed>")))
            else:
                unexplained.append((pr.slug, f))

    by_cat: dict[str, int] = {}
    for _, f in unexplained:
        by_cat[f["category"]] = by_cat.get(f["category"], 0) + 1

    n_probes = len(probes)
    n_clean = sum(1 for p in probes if not p.findings)
    parity = n_clean / n_probes if n_probes else 1.0

    # -- text report ---------------------------------------------------
    fp = (d / "fingerprint.tsv").read_text() if (d / "fingerprint.tsv").exists() else "(none)\n"
    lines = [
        "# L0 resolver-parity report",
        "",
        "## environment",
        *("  " + x for x in fp.splitlines()),
        "",
        "## summary",
        f"  probes           : {n_probes}",
        f"  clean            : {n_clean}",
        f"  parity_rate      : {parity:.3f}",
        f"  explained        : {len(explained_hits)}",
        f"  UNEXPLAINED      : {len(unexplained)}",
        *(f"    {c:12s} : {n}" for c, n in sorted(by_cat.items())),
        "",
    ]
    if unexplained:
        lines.append("## unexplained findings")
        cur = None
        for slug, f in unexplained:
            if slug != cur:
                lines.append(f"\n### {slug}")
                cur = slug
            lines.append(f"  [{f['category']}] {f['detail']}")
        lines.append("")
    if explained_hits:
        lines.append("## explained (allowlisted) findings")
        cur = None
        for slug, f, eid in explained_hits:
            if slug != cur:
                lines.append(f"\n### {slug}")
                cur = slug
            lines.append(f"  [{f['category']}] ({eid}) {f['detail']}")
        lines.append("")

    unused = [
        e.get("id", "<unnamed>")
        for e in allow
        if e.get("layer", "l0") == "l0"
        # An fs-qualified entry for another fs is out of scope here,
        # not a removal candidate.
        and (e.get("fs") is None or run_fs in (
            [e["fs"]] if isinstance(e["fs"], str) else list(e["fs"])))
        # Same for backend-qualified entries (VM-only findings never
        # flag container runs and vice versa).
        and (e.get("backend") is None or run_backend == e["backend"])
        and not any(eid == e.get("id", "<unnamed>") for _, _, eid in explained_hits)
    ]
    if unused:
        lines += ["## allowlist entries that matched nothing (candidates for removal)",
                  *(f"  {u}" for u in unused), ""]

    (d / "l0-report.txt").write_text("\n".join(lines))
    (d / "l0-report.json").write_text(
        json.dumps(
            {
                "summary": {
                    "probes": n_probes,
                    "clean": n_clean,
                    "parity_rate": parity,
                    "explained": len(explained_hits),
                    "unexplained": len(unexplained),
                    "by_category": by_cat,
                    "fs": run_fs,
                    "backend": run_backend,
                },
                "probes": [asdict(p) for p in probes],
            },
            indent=2,
        )
    )
    print("\n".join(lines))
    print(f"\nwrote {d/'l0-report.txt'} and {d/'l0-report.json'}")
    return 1 if unexplained else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
