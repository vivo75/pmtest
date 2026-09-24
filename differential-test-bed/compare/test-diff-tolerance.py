#!/usr/bin/env python3
"""Host-side self-test for diff.py's L2 additions.

Builds two synthetic normalised snapshot prefixes (the format
`normalize.py` emits) and pins:

  * default (L1) mode: size/sha differences are hard SIZE/CONTENT;
  * `--tolerate-payload`: same size/sha differences become non-fatal
    PAYLOAD, while a missing path stays a hard MISSING;
  * the allowlist `layer` filter: an `l2` entry applies only with
    `--layer l2`.

Run: python3 differential-test-bed/compare/test-diff-tolerance.py   (exit 0 = all good)
"""
from __future__ import annotations

import importlib.util
import io
import re
import shutil
import sys
import tarfile
import tempfile
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("compare_diff", HERE / "diff.py")
assert spec and spec.loader
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
# the R3 cases drive real raw snapshots through normalize.py and pin that
# build-id / split-debug twin differences disappear (the L2 e0/2277
# allowlist rows in known-divergences.yaml are retired on that proof).
spec_n = importlib.util.spec_from_file_location("normalize_mod", HERE / "normalize.py")
assert spec_n and spec_n.loader
norm_mod = importlib.util.module_from_spec(spec_n)
spec_n.loader.exec_module(norm_mod)

FAILED = 0


def check(label: str, cond: bool, detail: str = "") -> None:
    global FAILED
    if cond:
        print(f"ok   - {label}")
    else:
        FAILED += 1
        print(f"FAIL - {label}{(': ' + detail) if detail else ''}")


def write_side(root: Path, name: str, foo_sha: str, foo_md5: str, extra: bool) -> Path:
    prefix = root / name
    lines = [f"/usr/bin/foo\tf\t0755\t0\t0\t10\t{foo_sha}\t-\t-"]
    mtimes = ["/usr/bin/foo\t1000"]
    if extra:
        lines.append("/usr/share/extra\tf\t0644\t0\t0\t3\tshaX\t-\t-")
        mtimes.append("/usr/share/extra\t1000")
    (root / f"{name}.files.norm.tsv").write_text("\n".join(lines) + "\n")
    (root / f"{name}.mtimes.tsv").write_text("\n".join(mtimes) + "\n")
    vdb = prefix.parent / (prefix.name + ".vdb") / "pkg" / "cat" / "pf"
    vdb.mkdir(parents=True)
    (vdb / "CONTENTS").write_text(
        f"obj /usr/bin/foo {foo_md5} 0\n" "dir /usr\n"
    )
    return prefix


def run(args: list[str]) -> tuple[int, str]:
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = mod.main(args)
    return rc, buf.getvalue()


def run_norm(prefix: Path) -> None:
    with redirect_stdout(io.StringIO()):
        rc = norm_mod.main([str(prefix)])
    assert rc == 0, f"normalize.py failed with rc={rc} on {prefix}"


# --- R3: build-id / split-debug twin canonicalisation -------------------
# Each case builds a *raw* snapshot pair (the `<name>.files.tsv` +
# `<name>.vdb.tar` shape snapshot.sh + vdb.tar emit), first diffs them
# un-normalised to prove the synthetic data reproduces the real finding
# shapes, then runs normalize.py and pins a clean diff.  All shoe shapes
# come from the real Phase 7a L3 pair (logs/l3-20260923T080445Z) and the
# porttest/setuid triple from the allowlisted e0/2277 case.

REAL_A = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
REAL_B = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
DBG_A = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
DBG_B = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"


def write_raw_side(root: Path, name: str, fs_rows: list[str], pkgs: dict[str, str]) -> Path:
    prefix = root / name
    (root / f"{name}.files.tsv").write_text("\n".join(fs_rows) + "\n")
    (root / f"{name}.mtimes.tsv").write_text("")
    with tarfile.open(root / f"{name}.vdb.tar", "w") as tf:
        for pkg, contents in pkgs.items():
            b = contents.encode()
            ti = tarfile.TarInfo(name=f"pkg/{pkg}/CONTENTS")
            ti.size = len(b)
            ti.mode = 0o644
            tf.addfile(ti, io.BytesIO(b))
    # materialise the raw snapshot the way the harness hands it to diff.py
    # (normalise has not run yet), so the negative control is honest.
    (root / f"{name}.files.norm.tsv").write_text("\n".join(fs_rows) + "\n")
    dest = root / f"{name}.vdb"
    shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir(parents=True)
    with tarfile.open(root / f"{name}.vdb.tar") as tf:
        tf.extractall(dest, filter="data")
    return prefix


def write_r3_sides(root: Path, name: str, a_rows: list[str], b_rows: list[str],
                   a_pkgs: dict[str, str], b_pkgs: dict[str, str]) -> tuple[Path, Path]:
    a = write_raw_side(root, f"{name}a", a_rows, a_pkgs)
    b = write_raw_side(root, f"{name}b", b_rows, b_pkgs)
    return a, b


def r3_case(label: str, a: Path, b: Path, must_have: list[str]) -> None:
    if must_have:
        rc, out = run(["--tolerate-payload", str(a), str(b)])
        missing = [t for t in must_have if f"[{t}]" not in out]
        check(f"R3/{label}: raw diff reproduces the finding shape",
              rc != 0 and not missing, f"rc={rc} missing={missing}")
    run_norm(a)
    run_norm(b)
    rc, out = run(["--tolerate-payload", str(a), str(b)])
    clean = re.search(r"unexplained\s*:\s*0", out, re.I) and \
        not re.search(r"\[(MISSING|SYMLINK|CONTENT|CONTENTS|VDB)\]", out)
    check(f"R3/{label}: normalised diff is clean (0 unexplained)",
          rc == 0 and clean,
          (f"rc={rc}\n" + "\n".join(out.splitlines()[:25])) if not clean else "")


def build_r3_cases(root: Path) -> None:
    # Case 1 -- porttest/setuid: three byte-identical setuid binaries share
    # one .build-id (e0/2277…); estrip links the shared links at whichever
    # copy won the race, so real and portuale disagree about the target.
    # This is exactly the allowlisted l2-gpkg-dostrip-splitdebug pair.
    pt = "\t".join(["", "f", "4755", "0", "0", "9", "11" * 32, "-", "-"])
    pt_rows = [
        "/usr/bin/pt-setuid" + pt,
        "/usr/bin/pt-setgid" + pt,
        "/usr/bin/pt-sticky" + pt,
    ]
    a, b = write_r3_sides(
        root, "setuid",
        pt_rows + [
            "/usr/lib/debug/.build-id/e0/2277abc" + "\tl\t777\t0\t0\t32\t-\t../../../../../usr/bin/pt-setuid\t-",
            "/usr/lib/debug/.build-id/e0/2277abc.debug" + "\tl\t777\t0\t0\t42\t-\t../../usr/bin/pt-setuid.debug\t-",
            "/usr/lib/debug/usr/bin/pt-setuid.debug" + "\tf\t644\t0\t0\t11\t" + DBG_A + "\t-\t-",
        ],
        pt_rows + [
            "/usr/lib/debug/.build-id/e0/2277abc" + "\tl\t777\t0\t0\t34\t-\t../../../../../usr/bin/pt-sticky\t-",
            "/usr/lib/debug/.build-id/e0/2277abc.debug" + "\tl\t777\t0\t0\t43\t-\t../../usr/bin/pt-sticky.debug\t-",
            "/usr/lib/debug/usr/bin/pt-sticky.debug" + "\tf\t644\t0\t0\t11\t" + DBG_A + "\t-\t-",
        ],
        {"porttest/setuid-1.0": (
            "obj /usr/bin/pt-setuid 11111111111111111111111111111111 1000\n"
            "obj /usr/bin/pt-setgid 11111111111111111111111111111111 1000\n"
            "obj /usr/bin/pt-sticky 11111111111111111111111111111111 1000\n"
            "dir /usr/lib/debug/.build-id\n"
            "dir /usr/lib/debug/.build-id/e0\n"
            "sym /usr/lib/debug/.build-id/e0/2277abc -> ../../../../../usr/bin/pt-setuid 1000\n")},
        {"porttest/setuid-1.0": (
            "obj /usr/bin/pt-setuid 11111111111111111111111111111111 1000\n"
            "obj /usr/bin/pt-setgid 11111111111111111111111111111111 1000\n"
            "obj /usr/bin/pt-sticky 11111111111111111111111111111111 1000\n"
            "dir /usr/lib/debug/.build-id\n"
            "dir /usr/lib/debug/.build-id/e0\n"
            "sym /usr/lib/debug/.build-id/e0/2277abc -> ../../../../../usr/bin/pt-sticky 1000\n")},
    )
    r3_case("setuid-triple-e0-2277", a, b, ["SYMLINK", "MISSING", "CONTENTS"])

    # Case 2 -- binutils: ld/ld.bfd are twin copies under the keyed
    # libexec dir; the shared .build-id link (and the .debug pair) arrow at
    # the winning twin name, which differs between the two sides.
    a_row = "\t".join(["/usr/x86_64-pc-linux-gnu/binutils-bin/2.46.1/ld", "f",
                       "755", "0", "0", "1346392", REAL_A, "-", "-"])
    b_row = "\t".join(["/usr/x86_64-pc-linux-gnu/binutils-bin/2.46.1/ld", "f",
                       "755", "0", "0", "1346400", REAL_B, "-", "-"])
    a, b = write_r3_sides(
        root, "binutils",
        [a_row, a_row.replace("/2.46.1/ld\t", "/2.46.1/ld.bfd\t"),
         "/usr/lib/debug/.build-id/ac/77d1abc" + "\tl\t777\t0\t0\t40\t-\t../../../../../usr/x86_64-pc-linux-gnu/binutils-bin/2.46.1/ld\t-",
         "/usr/lib/debug/.build-id/ac/77d1abc.debug" + "\tl\t777\t0\t0\t55\t-\t../../usr/x86_64-pc-linux-gnu/binutils-bin/2.46.1/ld.debug\t-",
         "/usr/lib/debug/usr/x86_64-pc-linux-gnu/binutils-bin/2.46.1/ld.debug" + "\tf\t644\t0\t0\t4096\t" + DBG_A + "\t-\t-"],
        [b_row, b_row.replace("/2.46.1/ld\t", "/2.46.1/ld.bfd\t"),
         "/usr/lib/debug/.build-id/ac/77d1abc" + "\tl\t777\t0\t0\t43\t-\t../../../../../usr/x86_64-pc-linux-gnu/binutils-bin/2.46.1/ld.bfd\t-",
         "/usr/lib/debug/.build-id/ac/77d1abc.debug" + "\tl\t777\t0\t0\t58\t-\t../../usr/x86_64-pc-linux-gnu/binutils-bin/2.46.1/ld.bfd.debug\t-",
         "/usr/lib/debug/usr/x86_64-pc-linux-gnu/binutils-bin/2.46.1/ld.bfd.debug" + "\tf\t644\t0\t0\t4096\t" + DBG_A + "\t-\t-"],
        {"sys-devel/binutils-2.46.1": (
            "dir /usr/lib/debug/.build-id\n"
            "dir /usr/x86_64-pc-linux-gnu/binutils-bin/2.46.1\n"
            "sym /usr/lib/debug/.build-id/ac/77d1abc -> ../../../../../usr/x86_64-pc-linux-gnu/binutils-bin/2.46.1/ld 1000\n"
            "obj /usr/lib/debug/usr/x86_64-pc-linux-gnu/binutils-bin/2.46.1/ld.debug d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0 1000\n")},
        {"sys-devel/binutils-2.46.1": (
            "dir /usr/lib/debug/.build-id\n"
            "dir /usr/x86_64-pc-linux-gnu/binutils-bin/2.46.1\n"
            "sym /usr/lib/debug/.build-id/ac/77d1abc -> ../../../../../usr/x86_64-pc-linux-gnu/binutils-bin/2.46.1/ld.bfd 1000\n"
            "obj /usr/lib/debug/usr/x86_64-pc-linux-gnu/binutils-bin/2.46.1/ld.bfd.debug d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0 1000\n")},
    )
    r3_case("binutils-ld-twin", a, b, ["SYMLINK", "MISSING", "CONTENTS"])

    # Case 3 -- gcc: cc1/cc1plus land in a different .build-id hash dir per
    # side (5d/a2 vs 5a/c9), so the symlink paths *and* the vdb CONTENTS
    # dir/sym entries disagree even though both sides point at the same
    # binaries.  The twin real files themselves are different builds
    # (legit payload).
    a, b = write_r3_sides(
        root, "gcc",
        ["/usr/libexec/gcc/x86_64-pc-linux-gnu/15/cc1" + "\tf\t755\t0\t0\t100\t" + REAL_A + "\t-\t-",
         "/usr/libexec/gcc/x86_64-pc-linux-gnu/15/cc1plus" + "\tf\t755\t0\t0\t200\t" + DBG_A + "\t-\t-",
         "/usr/lib/debug/.build-id/5d/3e73abc" + "\tl\t777\t0\t0\t42\t-\t../../../../../usr/libexec/gcc/x86_64-pc-linux-gnu/15/cc1plus\t-",
         "/usr/lib/debug/.build-id/a2/4af8abc" + "\tl\t777\t0\t0\t33\t-\t../../../../../usr/libexec/gcc/x86_64-pc-linux-gnu/15/cc1\t-",
         "/usr/lib/debug/.build-id/5d/3e73abc.debug" + "\tl\t777\t0\t0\t56\t-\t../../usr/libexec/gcc/x86_64-pc-linux-gnu/15/cc1plus.debug\t-",
         "/usr/lib/debug/.build-id/a2/4af8abc.debug" + "\tl\t777\t0\t0\t47\t-\t../../usr/libexec/gcc/x86_64-pc-linux-gnu/15/cc1.debug\t-",
         "/usr/lib/debug/usr/libexec/gcc/x86_64-pc-linux-gnu/15/cc1.debug" + "\tf\t644\t0\t0\t111\t" + DBG_B + "\t-\t-",
         "/usr/lib/debug/usr/libexec/gcc/x86_64-pc-linux-gnu/15/cc1plus.debug" + "\tf\t644\t0\t0\t222\t" + DBG_A + "\t-\t-"],
        ["/usr/libexec/gcc/x86_64-pc-linux-gnu/15/cc1" + "\tf\t755\t0\t0\t101\t" + REAL_B + "\t-\t-",
         "/usr/libexec/gcc/x86_64-pc-linux-gnu/15/cc1plus" + "\tf\t755\t0\t0\t201\t" + DBG_B + "\t-\t-",
         "/usr/lib/debug/.build-id/5a/efdbabc" + "\tl\t777\t0\t0\t33\t-\t../../../../../usr/libexec/gcc/x86_64-pc-linux-gnu/15/cc1\t-",
         "/usr/lib/debug/.build-id/c9/dfcdabc" + "\tl\t777\t0\t0\t42\t-\t../../../../../usr/libexec/gcc/x86_64-pc-linux-gnu/15/cc1plus\t-",
         "/usr/lib/debug/.build-id/5a/efdbabc.debug" + "\tl\t777\t0\t0\t47\t-\t../../usr/libexec/gcc/x86_64-pc-linux-gnu/15/cc1.debug\t-",
         "/usr/lib/debug/.build-id/c9/dfcdabc.debug" + "\tl\t777\t0\t0\t56\t-\t../../usr/libexec/gcc/x86_64-pc-linux-gnu/15/cc1plus.debug\t-",
         "/usr/lib/debug/usr/libexec/gcc/x86_64-pc-linux-gnu/15/cc1.debug" + "\tf\t644\t0\t0\t111\t" + DBG_B + "\t-\t-",
         "/usr/lib/debug/usr/libexec/gcc/x86_64-pc-linux-gnu/15/cc1plus.debug" + "\tf\t644\t0\t0\t222\t" + DBG_A + "\t-\t-"],
        {"sys-devel/gcc-15.3.0": (
            "dir /usr/lib/debug/.build-id\n"
            "dir /usr/lib/debug/.build-id/5d\n"
            "dir /usr/lib/debug/.build-id/a2\n"
            "sym /usr/lib/debug/.build-id/5d/3e73abc -> ../../../../../usr/libexec/gcc/x86_64-pc-linux-gnu/15/cc1plus 1000\n"
            "sym /usr/lib/debug/.build-id/a2/4af8abc -> ../../../../../usr/libexec/gcc/x86_64-pc-linux-gnu/15/cc1 1000\n"
            "obj /usr/lib/debug/usr/libexec/gcc/x86_64-pc-linux-gnu/15/cc1.debug e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0 1000\n"
            "obj /usr/lib/debug/usr/libexec/gcc/x86_64-pc-linux-gnu/15/cc1plus.debug f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0 1000\n")},
        {"sys-devel/gcc-15.3.0": (
            "dir /usr/lib/debug/.build-id\n"
            "dir /usr/lib/debug/.build-id/5a\n"
            "dir /usr/lib/debug/.build-id/c9\n"
            "sym /usr/lib/debug/.build-id/5a/efdbabc -> ../../../../../usr/libexec/gcc/x86_64-pc-linux-gnu/15/cc1 1000\n"
            "sym /usr/lib/debug/.build-id/c9/dfcdabc -> ../../../../../usr/libexec/gcc/x86_64-pc-linux-gnu/15/cc1plus 1000\n"
            "obj /usr/lib/debug/usr/libexec/gcc/x86_64-pc-linux-gnu/15/cc1.debug e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0 1000\n"
            "obj /usr/lib/debug/usr/libexec/gcc/x86_64-pc-linux-gnu/15/cc1plus.debug f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0 1000\n")},
    )
    r3_case("gcc-cc1-hash-dir", a, b, ["MISSING", "CONTENTS"])


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="difftol.") as td:
        root = Path(td)
        a = write_side(root, "a", "a" * 64, "d" * 32, extra=False)
        b = write_side(root, "b", "b" * 64, "e" * 32, extra=False)

        rc, out = run([str(a), str(b)])
        check("default: sha/md5 diff is hard", rc == 1 and "[CONTENT]" in out and "[CONTENTS]" in out, out)

        rc, out = run(["--tolerate-payload", str(a), str(b)])
        check("tolerate: payload diff is non-fatal", rc == 0 and "[PAYLOAD]" in out, out)
        check("tolerate: payload line counted", "payload diffs     : 2" in out, out)

        # a missing path stays hard in tolerated mode
        c = write_side(root, "c", "a" * 64, "d" * 32, extra=True)
        rc, out = run(["--tolerate-payload", str(a), str(c)])
        check("tolerate: missing path is still hard", rc == 1 and "[MISSING]" in out, out)

        # layer filter: l2 entries apply only under --layer l2
        allow = root / "known.yaml"
        allow.write_text(
            "- id: l2-only\n"
            "  layer: l2\n"
            "  category: MISSING\n"
            "  path_glob: /usr/share/extra\n"
            "  reason: test entry\n"
        )
        rc, out = run(["--layer", "l1", "--tolerate-payload", str(a), str(c), str(allow)])
        check("layer l1 ignores an l2 entry", rc == 1, out)
        rc, out = run(["--layer", "l2", "--tolerate-payload", str(a), str(c), str(allow)])
        check("layer l2 applies an l2 entry", rc == 0 and "l2-only" in out, out)

        build_r3_cases(root)

    print(f"\ntest-diff-tolerance: {'OK' if FAILED == 0 else f'{FAILED} failure(s)'}")
    return 1 if FAILED else 0


if __name__ == "__main__":
    raise SystemExit(main())
