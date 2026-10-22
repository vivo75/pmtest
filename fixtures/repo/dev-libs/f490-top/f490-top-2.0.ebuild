EAPI=8
DESCRIPTION="fixture #490 top 2.0: upgrade of installed top-1.0 (RDEPEND on cons); depends on lib directly, so cons loses its only parent once top is replaced and is uninstalled, releasing its =f490-lib-1.0* pin on the lib upgrade."
SLOT="0"
KEYWORDS="amd64"
RDEPEND="dev-libs/f490-lib"
