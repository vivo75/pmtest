# 442 S0 baseline: unchanged portuale against Portage 3.0.83 (backlog #499)

Date 2026-10-23. portuale HEAD `cf718727e8fe110ce194996592b0e989ca67fd51` (branch
`port-portage-3.0.83`, clean, release binary rebuilt once before the runs, not during).
pmtest branch `port-portage-3.0.83`, clean. Host `emerge --version`:
`Portage 3.0.83 (python 3.14.8-final-0, ...)`; the bed image `localhost/test-portuale:latest`
reports `Portage 3.0.83 (python 3.14.6-final-0, ...)` inside the L0 report. (The `-r1`
downstream patch to `bintree.py` is not visible in either version string and was not
verified here.) Pre-bump reference: L0 run `logs/l0-20261023T074350Z` (Portage 3.0.82.2,
same Gentoo tree commits, same atom list).

## (a) Terminal casts (pretend cells), `/var/tmp/casts-442-s0/`

8 cells, exit codes agree 8/8 (plain-new 0/0, blocker 0/0, masked-abort 1/1, autounmask 1/1,
tree 0/0, verbose-use 0/0, upgrade 0/0, triangle-conflict 1/1). Text and chunking differ on
all 8, max timing ratio 1.0x (0 flagged). This is the same picture as the 2026-10-20 recording
(`what-this-proves.md`, #443/#453: "exit codes agree 8/8 while text and chunking differ on all of
them"): Portage writes its repo-warning lines, a first-run "Performing Global Updates" pass,
the spinner, and a title escape; portuale prints the rows in one write. The merge-list rows
themselves are the same. No change attributable to 3.0.83. Report: `/var/tmp/casts-442-s0/report.md`.

## (b) Contract suite, `scripts/pytest-parallel.sh`

`4294 passed, 2 skipped, 2 xfailed, 0 failed` (108 s). Zero failing test names, so nothing to
compare by name. (A stale root-owned `/var/tmp/pytest-parallel` from an earlier run first had
to be removed with sudo; that was a setup error, not a result.)

One corpus drift warning (a warning, not a failure):
`test_pretend_case_exit_code[--color=y -pc: coloured advisory block ...]#0: stdout changed`.
Reproduced twice, deterministic. The diff is two added blocks in the portuale output,
`dev-libs/f490-top` and `dev-libs/f490-cons` (`selected: 1.0 / protected: none / omitted: none`)
inserted in the advisory list. This is the portuale/pmtest side (fixtures `f490-*` newer than
the stored corpus entry; last corpus commit `d3cd441`), not the Portage bump: the contract
suite runs portuale for this case and the delta is new fixture packages. Not blessed.
Suggested owner action: review as part of the f490 work, not S0.

## (c) L0 resolver parity, `differential-test-bed/run/l0-resolver.sh`

Run with `L0_SKIP_PORTAGE_UPGRADE=1`, `GENTOO_MIRRORS=http://10.48.0.229:8080`.
Exit code 1 (unexplained present). Report:
`differential-test-bed/logs/l0-20261023T122000Z/l0-report.txt` (+ `.json`).
Invariants: 120 probes, 0 portuale violations, 0 control violations on Portage output.

| | 3.0.82.2 (074350Z) | 3.0.83 (122000Z) |
|---|---|---|
| probes | 120 | 120 |
| clean | 101 | 101 |
| explained findings | 6 | 6 |
| UNEXPLAINED findings | 31 (advice 9, error 6, order 14, truncated 2) | 31 (same split) |

Delta: none. `diff` of the two `l0-report.txt` files differs only in the date and the Portage
version line; the `probes` array of the two JSON reports is identical (0 differing probes), and
every probe's exit-code pair is unchanged. No cell moved in either direction.

Per-cell verdicts (identical before and after):
- Clean: 101 probes (all not listed below).
- Explained only: `gnome-base_gnome-shell` (4 findings) by `gnome-shell-cluster-a-abort`
  (owner `deepseek-v4.1-flash`).
- Explained plus unexplained: `gnome-base_nautilus` and `app-editors_gedit`, each one order
  finding explained by `gedit-nautilus-cluster-a-rewalk-abort` (owner `claude-opus-5`);
  each also has unexplained findings (below).
- Unexplained (18 cells, 31 findings; exit codes in parentheses are Portage/portuale):
  - order: dev-lang_ruby (0/0, #20 did_you_mean vs matrix), dev-ruby_rake (0/0, same),
    kde-apps_kdecore-meta (0/0, #95), gui-libs_gtk_4 (1/1, #30), x11-libs_gtk__3 (1/1, #30),
    net-misc_networkmanager (0/0, #26), www-client_firefox (1/1, #37),
    mail-client_thunderbird (1/1, #38), app-office_libreoffice (1/1, #28),
    media-gfx_gimp (1/1, #54), net-analyzer_wireshark (1/1, #47), media-video_vlc (0/0, #7),
    x11-base_xorg-server (0/0, #74), MULTI_emptytree-system (0/0, #304 real sys-auth/pambase vs
    portuale sys-apps/portage).
  - truncated/advice/error: app-containers_podman (1/1, truncated: Portage `Total 8`, portuale
    `Total 43`), kde-plasma_plasma-meta (1/1, truncated + real-only masked `xwayland[libei]`),
    gnome-base_nautilus and app-editors_gedit (1/1, real-only masked
    `>=app-crypt/gcr-3.27.90:0=[gtk]` block).
  Full hunks are in the L0 report (not re-quoted: byte-identical to the pre-bump report).

## Reconciliation with section 1 of the plan ("Observable divergences")

The baseline shows no resolver-level (L0) or pretend-output (contract/cast) divergence caused by
Portage 3.0.82.2 -> 3.0.83. The 31 unexplained findings are pre-existing backlog (the
cluster-A/world-trajectory order work and the autounmask-backtracking truncations), not new.
The section 1 items are therefore not visible at this level: they sit in paths this baseline
does not exercise (gpkg hostile archives, digest-less binhost records, the User-Agent string,
new options, `--info` repository block, `bin/` re-sync, grammar, mixed binhosts, scheduler,
virtuals), which the slice-specific cells S1-S13 must prove. No divergence outside section 1
was found, so no new backlog number is needed from S0.

Not run here: L1/L2/L3 (not requested), the fixture oracle.
