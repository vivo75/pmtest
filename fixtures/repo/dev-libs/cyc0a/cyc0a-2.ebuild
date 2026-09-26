EAPI=4
DESCRIPTION="fixture package: upstream test_circular_dependencies pg0 app-misc/A-2 (bulk #50)"
SLOT="0"
KEYWORDS="amd64"
IUSE="+foo bar"
REQUIRED_USE="^^ ( foo bar )"
DEPEND="foo? ( =dev-libs/cyc0b-2 ) bar? ( =dev-libs/cyc0b-2 )"
