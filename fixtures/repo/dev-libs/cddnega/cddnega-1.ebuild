EAPI=8
DESCRIPTION="#506 fixture: build cycle with dev-libs/cddnegb pulled in only while system-b is off (upstream testNegatedUseFlagInCycleMessage)"
SLOT="0"
KEYWORDS="amd64"
IUSE="system-b"
DEPEND="!system-b? ( dev-libs/cddnegb )"
