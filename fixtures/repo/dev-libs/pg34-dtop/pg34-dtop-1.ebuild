EAPI=8
DESCRIPTION="fixture package: #34 S4 deep in-slot upgrade target (not installed, depends on installed pg34-dlib with -2 in repo); regressed = -pvuD misses U pg34-dlib, -pvu plans it without -D, or -pvO plans deps"
SLOT="0"
KEYWORDS="amd64"
RDEPEND="dev-libs/pg34-dlib"
