EAPI=8
DESCRIPTION="fixture package: #366 order shape (b) (not installed; lists pg366-b before pg366-a; pg366-a's disjunction still resolves after pg366-b is walked, so Portage resolves to pg366-y)"
SLOT="0"
KEYWORDS="amd64"
RDEPEND="dev-libs/pg366-b dev-libs/pg366-a"
