"""Black-box contract suite for the use_reduce(flat=True) portuale (see
LLM/agent-context.md and crates/use-reduce-harness/src/use_reduce.rs).
Drives the Python harness (a thin wrapper around Portage's
`portage.dep.use_reduce`) and the Rust harness identically via subprocess,
and asserts their outputs are byte-for-byte the same.
"""

import subprocess

import pytest

# (mode, uselist_arg, tokens)
REDUCE_CASES = [
    ("normal", "-", []),  # empty depstr
    ("normal", "-", ["dev-libs/a", "dev-libs/b"]),  # no conditionals at all
    ("normal", "bar", ["dev-libs/foo", "bar?", "(", "dev-libs/baz", ")", "!bar?", "(", "dev-libs/qux", ")"]),
    ("normal", "-", ["dev-libs/foo", "bar?", "(", "dev-libs/baz", ")", "!bar?", "(", "dev-libs/qux", ")"]),
    ("normal", "-", ["||", "(", "dev-libs/a", "dev-libs/b", ")"]),
    ("normal", "foo", ["foo?", "(", "||", "(", "dev-libs/a", "dev-libs/b", ")", ")"]),
    ("normal", "-", ["foo?", "(", "||", "(", "dev-libs/a", "dev-libs/b", ")", ")"]),
    ("normal", "foo,bar", ["dev-libs/a", "foo?", "(", "dev-libs/b", "bar?", "(", "dev-libs/c", ")", ")"]),
    ("normal", "foo", ["dev-libs/a", "foo?", "(", "dev-libs/b", "bar?", "(", "dev-libs/c", ")", ")"]),
    ("normal", "foo", ["foo?", "(", "dev-libs/a", ")", "foo?", "(", "dev-libs/b", ")"]),  # dup conditional
    ("normal", "-", ["!foo?", "(", "dev-libs/a", ")"]),
    ("normal", "foo", ["!foo?", "(", "dev-libs/a", ")"]),
    ("matchall", "-", ["foo?", "(", "dev-libs/a", ")", "!bar?", "(", "dev-libs/b", ")"]),
    ("matchnone", "-", ["foo?", "(", "dev-libs/a", ")", "!bar?", "(", "dev-libs/b", ")"]),
    ("matchall", "-", ["!foo?", "(", "dev-libs/a", ")"]),  # matchall: negated still active
    # nested parens with no conditional at all: redundant brackets collapse
    ("normal", "-", ["(", "(", "dev-libs/a", ")", ")"]),
    ("normal", "-", ["dev-libs/a", "(", "dev-libs/b", "(", "dev-libs/c", ")", ")"]),
    # a leading digit is a *valid* USE flag name start (surprising but
    # confirmed against Portage's `useflag_re`: ^[A-Za-z0-9][A-Za-z0-9+_@-]*$)
    ("normal", "1notaflag", ["1notaflag?", "(", "dev-libs/a", ")"]),
]

REDUCE_ERROR_CASES = [
    ("normal", "-", ["dev-libs/a", "("]),  # unclosed paren
    ("normal", "-", [")"]),  # unmatched close
    ("normal", "-", ["foo?"]),  # dangling conditional, no bracket
    ("normal", "-", ["foo?", "dev-libs/a"]),  # conditional not followed by "("
    ("normal", "-", ["(", ")"]),  # literal empty parens
    ("normal", "-", ["||", "(", ")"]),  # || with literal empty parens
    ("normal", "-", ["foo?", "(", ")"]),  # conditional with literal empty parens
    ("normal", "-", ["||"]),  # dangling ||, no bracket
    ("normal", "-", ["||", "dev-libs/a"]),  # || not followed by "("
    ("normal", "-", ["dev-libs/a", "->", "b.tar.gz"]),  # SRC_URI arrow: out of v1 scope
    ("normal", "-", ["_badflag?", "(", "dev-libs/a", ")"]),  # invalid flag name in conditional (leading "_")
]


def _run(cmd: list[str], *args: str) -> str:
    result = subprocess.run(
        [*cmd, *args], capture_output=True, text=True, check=True
    )
    return result.stdout.strip()


@pytest.mark.parametrize("mode,uselist,tokens", REDUCE_CASES)
def test_reduce_matches_between_implementations(
    mode, uselist, tokens, use_reduce_harness_python, use_reduce_harness_rust
):
    python_result = _run(use_reduce_harness_python, "reduce", mode, uselist, *tokens)
    rust_result = _run([str(use_reduce_harness_rust)], "reduce", mode, uselist, *tokens)
    assert rust_result == python_result
    assert python_result != "ERROR"


@pytest.mark.parametrize("mode,uselist,tokens", REDUCE_ERROR_CASES)
def test_reduce_error_matches_between_implementations(
    mode, uselist, tokens, use_reduce_harness_python, use_reduce_harness_rust
):
    python_result = _run(use_reduce_harness_python, "reduce", mode, uselist, *tokens)
    rust_result = _run([str(use_reduce_harness_rust)], "reduce", mode, uselist, *tokens)
    assert python_result == "ERROR"
    assert rust_result == python_result


# (eapi, validflags_arg, tokens, expected): the S4 `validate` shape --
# `use_reduce(matchall=True, flat=True, token_class=Atom,
# is_valid_flag=…)` with Portage's `_metadata_exception` message selection
# (a categorized inner error prints bare, anything else the outer
# `InvalidDependString` text). Expected strings verified live against
# Portage 3.0.82.2 (installed tree, 2026-10-12); the S0 t341 cells pin the
# same texts end to end in test_emerge_pretend_contract.py.
VALIDATE_CASES = [
    ("8", "x", ["dev-libs/a"], "OK"),
    ("8", "-", ["dev-libs/a::gentoo"],
     "ERR:dependency.syntax:Invalid atom (dev-libs/a::gentoo), token 1"),
    ("8", "x", ["x?", "(", "dev-libs/a", ")", "dev-libs/a::gentoo"],
     "ERR:dependency.syntax:Invalid atom (dev-libs/a::gentoo), token 5"),
    ("8", "-", ["=dev-libs/a-1-2"],
     "ERR:dependency.syntax:Invalid atom (=dev-libs/a-1-2), token 1"),
    ("8", "-", ["dev-libs/a:0*"],
     "ERR:dependency.syntax:Invalid atom (dev-libs/a:0*), token 1"),
    ("8", "-", ["y?", "(", "dev-libs/a", ")"],
     "ERR:IUSE.missing:USE flag 'y' referenced in conditional 'y?' is not in IUSE"),
    ("8", "-", ["??", "(", "dev-libs/a", ")"],
     "ERR:IUSE.missing:USE flag '?' referenced in conditional '??' is not in IUSE"),
    ("8", "-", ["^^", "(", "dev-libs/a", "dev-libs/b", ")"],
     "ERR:dependency.syntax:Invalid atom (^^), token 1"),
    ("8", "x", ["x?", "(", ")"],
     "ERR:dependency.syntax:expected: dependency string, got: ')', token 2"),
    ("8", "x", ["dev-libs/a("],
     "ERR:dependency.syntax:missing whitespace around '(' at 'dev-libs/a(', token 1"),
    # atom inside the bad conditional wins over the conditional (t341-condfirst)
    ("8", "-", ["y?", "(", "dev-libs/a::x", ")"],
     "ERR:dependency.syntax:Invalid atom (dev-libs/a::x), token 3"),
    # categorized in-atom conditional prints bare (no token suffix)
    ("8", "-", ["dev-libs/a[x?]"],
     "ERR:IUSE.missing:USE flag 'x' referenced in conditional 'x?' in atom 'dev-libs/a[x?]' is not in IUSE"),
    ("7", "-", ["dev-libs/a[x(+)]"], "OK"),
    ("3", "-", ["dev-libs/a[x(+)]"],
     "ERR:EAPI.incompatible:Use dep defaults are not allowed in EAPI 3: 'dev-libs/a[x(+)]'"),
    # eapi=None allows ::repo, skips in-atom conditional checks, but group
    # conditionals are still validated (is_active ignores eapi)
    ("None", "-", ["dev-libs/a::gentoo"], "OK"),
    ("None", "-", ["y?", "(", "dev-libs/a", ")"],
     "ERR:IUSE.missing:USE flag 'y' referenced in conditional 'y?' is not in IUSE"),
    ("None", "-", ["dev-libs/a[x?]"], "OK"),
]


@pytest.mark.parametrize("eapi,validflags,tokens,expected", VALIDATE_CASES)
def test_validate_matches_portage_with_pinned_text(
    eapi, validflags, tokens, expected,
    use_reduce_harness_python, use_reduce_harness_rust,
):
    python_result = _run(
        use_reduce_harness_python, "validate", eapi, validflags, *tokens
    )
    rust_result = _run(
        [str(use_reduce_harness_rust)], "validate", eapi, validflags, *tokens
    )
    assert rust_result == python_result
    assert python_result == expected


def test_batch_mode_output_matches(use_reduce_harness_python, use_reduce_harness_rust):
    """Exercises benchmark-shaped batch mode: many operations fed to a
    single process invocation via stdin."""
    lines = [
        f"reduce {mode} {uselist} {' '.join(tokens)}".rstrip()
        for mode, uselist, tokens in REDUCE_CASES + REDUCE_ERROR_CASES
    ]
    stdin_data = "\n".join(lines) + "\n"

    python_out = subprocess.run(
        [*use_reduce_harness_python, "batch"],
        input=stdin_data,
        capture_output=True,
        text=True,
        check=True,
    ).stdout

    rust_out = subprocess.run(
        [str(use_reduce_harness_rust), "batch"],
        input=stdin_data,
        capture_output=True,
        text=True,
        check=True,
    ).stdout

    assert rust_out == python_out
    assert len(rust_out.splitlines()) == len(lines)
