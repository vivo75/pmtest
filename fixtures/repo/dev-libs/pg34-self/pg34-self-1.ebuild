EAPI=8
DESCRIPTION="fixture package: #34 S5 G3 go-shaped self cycle (not installed; BDEPEND alternatives itself or the bootstrap sibling); regressed = pubgrub picks itself, reports a circular self-dependency and exits 1 where Portage picks the bootstrap sibling"
SLOT="0"
KEYWORDS="amd64"
BDEPEND="|| ( dev-libs/pg34-self dev-libs/pg34-selfboot )"
