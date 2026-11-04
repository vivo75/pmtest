EAPI=8
DESCRIPTION="fixture package: #652 (fresh-only driver virtual (no installed instance; 5.44-first-arm || with a ~pin at a version with no ebuild, 5.42 fallback arm like the live new-text virtuals)))"
SLOT="0"
KEYWORDS="amd64"
RDEPEND="|| ( =dev-libs/p651prov-5.44* =dev-libs/p651prov-5.42* ~dev-libs/p652foocore-2.223.0 ) dev-libs/p651prov:= !<dev-libs/p652foocore-2.223.0 !>dev-libs/p652foocore-2.223.0-r999"
