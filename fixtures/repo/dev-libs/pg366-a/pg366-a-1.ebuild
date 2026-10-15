EAPI=8
DESCRIPTION="fixture package: #366 order-sensitive || group (not installed; first-lists pg366-x but the pg366-r targets also pull pg366-b into the graph, so Portage resolves to pg366-y in both dep orders)"
SLOT="0"
KEYWORDS="amd64"
RDEPEND="|| ( dev-libs/pg366-x dev-libs/pg366-y )"
