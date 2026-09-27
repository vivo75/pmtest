EAPI=7
DESCRIPTION="fixture package: upstream test_circular_choices.py pg3 virtual/cmake-0 (bulk #50)"
SLOT="0"
KEYWORDS="amd64"
IUSE="+bootstrap"
RDEPEND="bootstrap? ( dev-libs/ccd3b ) !bootstrap? ( dev-libs/ccd3c )"
