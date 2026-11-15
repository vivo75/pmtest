EAPI=8
DESCRIPTION="fixture package: bootstrap refusal r1 (conditional BDEPEND on r2, soft path via r3)"
SLOT="0"
KEYWORDS="amd64"
IUSE="+user +use2"
BDEPEND="user? ( dev-libs/w753r2[use2] ) dev-libs/w753r3"
RDEPEND="dev-libs/w753r3"
