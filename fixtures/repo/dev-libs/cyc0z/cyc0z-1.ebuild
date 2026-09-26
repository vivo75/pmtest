EAPI=1
DESCRIPTION="fixture package: upstream test_circular_dependencies pg0 dev-libs/Z-1 (bulk #50)"
SLOT="0"
KEYWORDS="amd64"
IUSE="+foo bar"
DEPEND="foo? ( !bar? ( dev-libs/cyc0y ) )"
