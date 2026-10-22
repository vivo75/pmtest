EAPI=8
DESCRIPTION="fixture #484b P 1.0: installed and current; RDEPEND is || ( f484b-y f484b-x ) where f484b-y is tree-only and loses to the installed f484b-x-1.0 alternative. Exercises the || reuse of the in-graph installed node. A regressed PM upgrades f484b-x to 2.0 through this dep."
SLOT="0"
KEYWORDS="amd64"
RDEPEND="|| ( dev-lang/f484b-y dev-libs/f484b-x )"
