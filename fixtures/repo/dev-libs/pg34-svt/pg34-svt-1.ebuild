EAPI=8
DESCRIPTION="fixture package: #34 S5 G5 target (not installed; RDEPEND pulls both pg34-sv and pg34-svb, putting svb in the graph so Portage resolves sv's || to it); regressed = pubgrub plans N sva + N svx"
SLOT="0"
KEYWORDS="amd64"
RDEPEND="dev-libs/pg34-sv dev-libs/pg34-svb"
