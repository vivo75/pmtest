EAPI=4
DESCRIPTION="fixture package: upstream test_required_use pg0 dev-libs/D-4 (bulk #50)"
SLOT="0"
KEYWORDS="amd64"
IUSE="+w x +y +z"
REQUIRED_USE="w? ( x || ( y z ) )"
