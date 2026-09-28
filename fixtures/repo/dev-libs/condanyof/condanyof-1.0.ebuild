EAPI=8
DESCRIPTION="fixture package: a USE-conditional-only || group that reduces to empty must fail at EAPI 7+ (backlog #238)"
SLOT="0"
KEYWORDS="amd64"
IUSE="emptyanyof"
RDEPEND="|| ( emptyanyof? ( dev-libs/condanyofdep ) )"
