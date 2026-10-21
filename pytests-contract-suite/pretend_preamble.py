"""Backlog #466: Portage's `--pretend` resolution preamble and a view without it.

A completed `--pretend` resolve prints, before the merge rows, the banner
(`These are the packages that would be merged, in order:`, or `... in reverse
order:` under `--tree`, `... merged:` under `--tree --unordered-display`,
`... built, in order:` under `--buildpkgonly`), then
`Calculating dependencies ... done!` and the timing line (the wall-clock
seconds are cut). Oracle: host `emerge` 3.0.82.2, `LLM/evidence/2026-10-21-r463/`.
`--nodeps` drops the last two lines, `--quiet` drops all three.

The hundreds of older pins describe the merge ROWS; `strip_pretend_preamble`
gives them the output without that preamble. The preamble itself is pinned by
`test_pretend_success_prints_the_resolution_preamble_like_portage`.
"""

import re

_ANSI = re.compile(r"\x1b\[[0-9;]*m")
_BANNERS = (
    "These are the packages that would be merged, in order:",
    "These are the packages that would be merged, in reverse order:",
    "These are the packages that would be built, in order:",
    "These are the packages that would be merged:",  # --unordered-display
)


def strip_pretend_preamble(text: str) -> str:
    """`text` without a leading `--pretend` resolution preamble (unchanged when
    it has none)."""
    lines = text.split("\n")
    if not (len(lines) > 3 and lines[0] == "" and _ANSI.sub("", lines[1]) in _BANNERS and lines[2] == ""):
        return text
    i = 3
    if _ANSI.sub("", lines[i]).startswith("Calculating dependencies"):
        if (
            len(lines) < i + 3
            or not _ANSI.sub("", lines[i + 1]).startswith("Dependency resolution took")
            or lines[i + 2] != ""
        ):
            return text
        i += 3
    return "\n".join(lines[i:])
