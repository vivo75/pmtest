EAPI=8
DESCRIPTION="fixture package: #34 S5 G5 in-graph || alternative (not installed; RDEPEND first-lists pg34-sva but the pg34-svt target also pulls pg34-svb into the graph, so Portage takes svb); regressed = pubgrub takes first-listed sva plus its svx subtree"
SLOT="0"
KEYWORDS="amd64"
RDEPEND="|| ( dev-libs/pg34-sva dev-libs/pg34-svb )"
