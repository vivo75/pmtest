EAPI=8
DESCRIPTION="fixture package: #34 S5 G7 fresh target soft-blocking an installed package (not installed; RDEPEND blocks installed pg34-sblk while installed pg34-shold still needs it transitively); regressed = pubgrub schedules an uninstall where Portage keeps the block unresolved"
SLOT="0"
KEYWORDS="amd64"
RDEPEND="dev-libs/pg34-shold !dev-libs/pg34-sblk"
