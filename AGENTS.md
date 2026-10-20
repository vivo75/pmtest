# AGENTS.md (pmtest)

This repo is the test half of the portuale project: contract suite, fixtures,
the differential test bed and the harvested corpus.

**Plans, the backlog, the agent context and the working rules do not live
here.** Start in `../portuale/AGENTS.md` and `../portuale/LLM/agent-context.md`;
plans are `../portuale/LLM/<tier>.<item>-*.opus.md`, numbered from the one global
`../portuale/LLM/backlog-tasks.md`. Do not create an `LLM/` folder here.

What does live here (read when working in this repo):

- `USAGE.AGENTS.md` — how to run the suite and the bed.
- `differential-test-bed/README.md` — the bed layers and cells.
- `differential-test-bed/repo-pins.txt` — the gentoo / buildovl versions the
  bed depends on; check with `scripts/repo-pins.sh`.

Branches and commits are paired with portuale (same branch name, pmtest
committed first); see "Two repos, one project" in `../portuale/AGENTS.md`.
