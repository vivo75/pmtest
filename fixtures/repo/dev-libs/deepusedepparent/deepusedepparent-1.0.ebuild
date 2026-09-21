EAPI=8
DESCRIPTION="fixture: installed -flip; its RDEPEND atom carries a flip= conditional use-dep (#132 arm A)"
SLOT="0"
KEYWORDS="amd64"
IUSE="flip"
RDEPEND="~dev-libs/deepusedepchild-1.0[flip=]"
