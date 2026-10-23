EAPI=8
DESCRIPTION="#506 fixture: dev-libs/cddunrb both under unrelated? ( ) and unconditional, so the flag is not blamed (upstream testUnrelatedUseFlagNotReported)"
SLOT="0"
KEYWORDS="amd64"
IUSE="+unrelated"
DEPEND="unrelated? ( dev-libs/cddunrb ) dev-libs/cddunrb"
