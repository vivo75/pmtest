EAPI=8
DESCRIPTION="#506 fixture: dev-libs/cddsevb under both doc? and nls?, so both flags are blamed (upstream testSeveralUseFlagsInCycleMessage)"
SLOT="0"
KEYWORDS="amd64"
IUSE="+doc +nls"
DEPEND="doc? ( dev-libs/cddsevb ) nls? ( dev-libs/cddsevb )"
