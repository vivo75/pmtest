EAPI=8
DESCRIPTION="fixture package: upstream test_circular_dependencies pg0 dev-libs/Z-3 (bulk #50)"
SLOT="0"
KEYWORDS="amd64"
IUSE="+foo bar"
DEPEND="foo? ( !bar? ( dev-libs/cyc0y ) ) foo? ( dev-libs/cyc0y ) !bar? ( dev-libs/cyc0y )"
