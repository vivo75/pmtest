EAPI=8
DESCRIPTION="#506 fixture: as dev-lang/cddgo, the self branch carries a conditional USE dependency (upstream testUseDependencyAlternative)"
SLOT="0"
KEYWORDS="amd64"
IUSE="+cgo"
BDEPEND="|| ( dev-lang/cddgou[cgo?] dev-lang/cddgou-bootstrap )"
