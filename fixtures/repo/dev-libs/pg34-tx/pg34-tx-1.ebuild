EAPI=8
DESCRIPTION="fixture package: #34 S5 G5/G6c root-target || member (not installed; RDEPEND first-lists installed pg34-info but the target pg34-tt is itself in the graph, so Portage takes tt, the texinfo/info-manual/emacs shape); regressed = pubgrub takes installed info"
SLOT="0"
KEYWORDS="amd64"
RDEPEND="|| ( dev-libs/pg34-info dev-libs/pg34-tt )"
