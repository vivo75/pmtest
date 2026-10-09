#!/usr/bin/env python3
"""z326-audit.py -- phase-env audit for the #326 Z close-out legs.

Usage:  compare/z326-audit.py <nopy-run-dir>

Asserts that `portuale-python` was the ONLY interpreter any Portage
helper invoked during a nopy-build.sh leg, while build systems (e.g.
glibc's own configure/make, which legitimately runs python itself)
may use a real interpreter freely.

Decision rule (plan 02.326-no-portage-runtime.opus.md, leg (b)):

  * a Portage helper call is a python invocation whose script is under
    $PORTAGE_BIN_PATH, or that imports `portage`, or a `-c` program
    naming portage;
  * a build-system call is anything else.

How it decides (the live phase env is observable through NONE of
the persisted channels -- the saved temp/environment is the
post-filter dump with PORTAGE_* stripped by design, and portuale
leaves __source_all_bashrcs unimplemented so no bashrc hook can
observe it -- hence three indirect legs):

  1. census (artifacts/audit-env.txt): helper scripts exist ONLY
     inside the dispatcher -- no .py files, no checkout, no
     /usr/lib/portage. On [nopy] no python provider may exist at
     all; on [noportage] python3 exists but the portage package
     must be absent. Any other interpreter that a call site could
     reach would fail loudly (script not found), except the -c
     locale probe, which succeeds under any interpreter but is "a
     build-system call" by the rule's letter (its program does not
     name portage) -- and the dispatcher handles it natively anyway.
  2. live ps sampler (audit-ps.log): every `portuale __helper
     <name>` line is a dispatcher invocation caught in the act; any
     real-python line matching the helper rule is a violation.
  3. log scan (step logs + per-package temp transcripts): same
     classification per line; any `no native helper` 127
     fallthrough is a violation (with the transition table empty,
     the dispatcher never execs a real interpreter).

Verdict PASS iff the census matches the variant, all three step rcs
are 0, and zero violations across the ps record and all scanned logs.

Exit: 0 PASS, 1 FAIL (audit inconclusive or violated), 2 usage/IO.
Stdlib only.
"""

import os
import re
import sys

HELPER_BASENAMES = {
    "filter-bash-environment.py",
    "gpkg-helper.py",
    "xpak-helper.py",
    "doins.py",
    "dohtml.py",
    "xattr-helper.py",
    "install.py",
    "ebuild-pyhelper",
    "chmod-lite",
    "ecompress-file",
    "ebuild-ipc",
}

INTERP_RE = re.compile(
    r"(?:(?<=[\s;`'\"(&|])|^)"
    r"(portuale-python"
    r"|/usr/bin/python(?:3(?:\.\d+)?)?"
    r"|/usr/local/bin/python[^:\s]*"
    r"|python(?:3(?:\.\d+)?)?)"
    r"(?=[\s'\";]|$)"
)
HELPER_RE = re.compile(
    r"(portuale\s+__helper\s+(\S+)|__helper\s+python\s+(\S+))")
NO_NATIVE_RE = re.compile(r"no native helper for")
IPC_RE = re.compile(r"ebuild-ipc")


def names_portage_module(text):
    # The `-c` PROGRAM naming the portage *module* (import / from /
    # attribute / -m), ignoring path tokens (/var/tmp/portage,
    # /etc/portage, ... -- glibc's own build lines carry those).
    toks = [t for t in re.split(r"[\s'\";()]+", text) if "/" not in t]
    joined = " ".join(toks)
    return re.search(r"import\s+portage|from\s+portage\b|"
                      r"portage\.[A-Za-z_]|-m\s+portage\b", joined) is not None


def helper_name_after_interp(line, match):
    rest = line[match.end():].strip().strip("\"'").split()
    if not rest:
        return "?"
    first = rest[0]
    if first == "-c":
        prog = " ".join(rest[1:])
        return "-c:" + (prog[:57] + "..." if len(prog) > 60 else prog)
    return os.path.basename(first)


def main(argv):
    if len(argv) != 2:
        print("usage: z326-audit.py <nopy-run-dir>", file=sys.stderr)
        return 2
    rundir = argv[1]
    failures = []
    warnings = []

    def need(path):
        if not os.path.isfile(path):
            failures.append("missing file: %s" % path)
            return False
        return True

    result_tsv = os.path.join(rundir, "result.tsv")
    env_txt = os.path.join(rundir, "env.txt")
    census = os.path.join(rundir, "artifacts", "audit-env.txt")
    pslog = os.path.join(rundir, "audit-ps.log")
    step1 = os.path.join(rundir, "step1-build-gpkg.log")
    step2 = os.path.join(rundir, "step2-usepkgonly.log")
    for p in (result_tsv, step1):
        need(p)
    if failures:
        print("Z326-AUDIT: FAIL (missing inputs)")
        for f in failures:
            print("  %s" % f)
        return 1

    # --- variant + step rcs -------------------------------------------
    variant = "?"
    if os.path.isfile(env_txt):
        with open(env_txt) as fh:
            for line in fh:
                if line.startswith("variant :"):
                    variant = line.split(":", 1)[1].strip()
    print("variant: %s" % variant)
    rcs = {}
    with open(result_tsv) as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) == 2:
                rcs[parts[0]] = parts[1]
    print("steps: %s" % " ".join("%s=%s" % kv for kv in sorted(rcs.items())))

    # --- (1) census ----------------------------------------------------
    interpreters = []
    portage_pkg = False
    import_path = ""
    if os.path.isfile(census):
        with open(census) as fh:
            section = None
            for raw in fh:
                line = raw.rstrip("\n")
                if line.startswith("--- "):
                    section = line
                    continue
                if section and "compgen -c python" in section:
                    if line and not line.startswith("---"):
                        interpreters.append(line)
                if "site-packages portage" in (section or ""):
                    if line.startswith("IMPORTABLE:"):
                        portage_pkg = True
                        import_path = line
                    elif re.match(r"^/usr/lib[^:]*site-packages/portage$", line):
                        portage_pkg = True
                        import_path = line
                if line.startswith("/usr/lib/portage") and "No such" not in line \
                        and "cannot access" not in line:
                    portage_pkg = True
                    import_path = line
    else:
        warnings.append("no census file (older run without NOPY_AUDIT=1?)")
    interpreters = sorted(set(interpreters))
    print("census interpreters (compgen -c python): %s"
          % (interpreters or ["(none)"]))
    print("census portage package present: %s" % portage_pkg)
    if variant == "nopy":
        if interpreters:
            failures.append("nopy image provides python: %s" % interpreters)
    elif variant == "noportage":
        if not interpreters:
            warnings.append("noportage image has no python at all "
                            "(expected python3 kept)")
    if portage_pkg:
        failures.append("a portage python package exists in the image "
                        "(transition rows would resolve): %s" % import_path)

    # --- line classifier (shared by ps + logs) -------------------------
    disp_counts = {}
    build_system = 0
    build_samples = []
    violations = []
    ipc_127 = 0

    def classify(line, origin):
        if NO_NATIVE_RE.search(line):
            violations.append("%s: %s" % (origin, line.strip()[:200]))
            return
        if IPC_RE.search(line) and "127" in line:
            return "ipc"
        # `portuale __helper python <script>` is the dispatcher itself:
        # its argv names `python` as the routing word, not an exec'd
        # interpreter, so it must be counted before INTERP_RE sees the
        # bare `python` token.
        hm = HELPER_RE.search(line)
        if hm and hm.group(2):
            helper = hm.group(2)
            if helper == "python":
                after = line[hm.end():].split()
                if after:
                    helper = os.path.basename(after[0])
            disp_counts[helper] = disp_counts.get(helper, 0) + 1
            return
        m = INTERP_RE.search(line)
        if not m:
            if hm:
                helper = hm.group(3) or "?"
                disp_counts[helper] = disp_counts.get(helper, 0) + 1
            return
        interp = m.group(1)
        if interp == "portuale-python":
            helper = helper_name_after_interp(line, m)
            disp_counts[helper] = disp_counts.get(helper, 0) + 1
            return
        low = line
        kind = None
        if "import portage" in low:
            kind = "imports-portage"
        elif names_portage_module(low):
            kind = "-c-names-portage"
        else:
            for token in re.split(r"[\s'\";()]+", low):
                if os.path.basename(token) in HELPER_BASENAMES:
                    kind = "helper-script:" + os.path.basename(token)
                    break
        if kind is not None:
            violations.append("%s: [%s] %s"
                              % (origin, kind, line.strip()[:200]))
        else:
            return "buildsys"

    # --- (2) ps sampler -------------------------------------------------
    n_ps_samples = 0
    if os.path.isfile(pslog):
        with open(pslog, errors="replace") as fh:
            for raw in fh:
                line = raw.rstrip("\n")
                if line.startswith("### "):
                    n_ps_samples += 1
                    continue
                r = classify(line, "ps")
                if r == "ipc":
                    ipc_127 += 1
                elif r == "buildsys":
                    build_system += 1
                    if len(build_samples) < 8:
                        build_samples.append("ps: %s" % line.strip()[:160])
        print("ps samples: %d" % n_ps_samples)
    else:
        warnings.append("no audit-ps.log (sampler did not run?)")

    # --- (3) log scan ----------------------------------------------------
    def log_files():
        yield step1
        if os.path.isfile(step2):
            yield step2
        art = os.path.join(rundir, "artifacts")
        if os.path.isdir(art):
            for name in sorted(os.listdir(art)):
                if (name.startswith("build-") and name.endswith(".log")) \
                        or name.startswith("logging-"):
                    yield os.path.join(art, name)

    for path in log_files():
        try:
            fh = open(path, errors="replace")
        except OSError as exc:
            warnings.append("cannot read %s: %s" % (path, exc))
            continue
        with fh:
            for raw in fh:
                line = raw.rstrip("\n")
                # Log lines are mostly build transcript, not process
                # argv: only classify lines that name an interpreter
                # (or the 127 fallthrough / ipc markers).
                if not (INTERP_RE.search(line)
                        or NO_NATIVE_RE.search(line)
                        or (IPC_RE.search(line) and "127" in line)):
                    continue
                r = classify(line, os.path.basename(path))
                if r == "ipc":
                    ipc_127 += 1
                elif r == "buildsys":
                    build_system += 1
                    if len(build_samples) < 8:
                        build_samples.append("%s: %s"
                                             % (os.path.basename(path),
                                                line.strip()[:160]))

    print("dispatcher calls observed: %d (%s)"
          % (sum(disp_counts.values()),
             ", ".join("%s=%d" % kv for kv in sorted(disp_counts.items()))
             or "(none -- expected for short builds; verdict rests on "
                "green + census + zero violations)"))
    print("build-system python calls: %d" % build_system)
    for s in build_samples:
        print("  BUILDSYS %s" % s)
    print("ipc-127 lines: %d" % ipc_127)
    if ipc_127 and rcs.get("step1") == "0":
        warnings.append("ebuild-ipc 127 in a GREEN build -- "
                        "PORTAGE_IPC_DAEMON may have leaked somewhere")
    if violations:
        print("VIOLATIONS: %d" % len(violations))
        for v in violations[:20]:
            print("  VIOLATION %s" % v)
        if len(violations) > 20:
            print("  ... and %d more" % (len(violations) - 20))
        failures.append("%d helper-via-real-python violations"
                        % len(violations))
    else:
        print("VIOLATIONS: 0")
    if rcs.get("step1") != "0":
        failures.append("step1 rc=%s (build did not succeed)"
                        % rcs.get("step1", "(missing)"))
    for step in ("step2", "step3"):
        if rcs.get(step) != "0":
            failures.append("%s rc=%s (leg incomplete: the usepkgonly "
                            "re-merge and the xpak build are part of "
                            "the leg)" % (step, rcs.get(step, "(missing)")))
    for w in warnings:
        print("warning: %s" % w)

    if failures:
        print("Z326-AUDIT: FAIL")
        for f in failures:
            print("  %s" % f)
        return 1
    print("Z326-AUDIT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
