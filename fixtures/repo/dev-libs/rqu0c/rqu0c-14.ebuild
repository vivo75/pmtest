EAPI=8
DESCRIPTION="fixture package: upstream test_required_use pg0 dev-libs/C-14 (bulk #50)"
SLOT="0"
KEYWORDS="amd64"
IUSE="+foo bar"
REQUIRED_USE="!foo? ( !bar )"
