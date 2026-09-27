EAPI=8
DESCRIPTION="fixture: installed -flip; its RDEPEND atom carries a flip= conditional use-dep, so --autounmask-use=n aborts with real's parent-flip row beside the child row (#135 (a) S0)"
SLOT="0"
KEYWORDS="amd64"
IUSE="flip"
RDEPEND="~dev-libs/r135leaf-1.0[flip=]"
