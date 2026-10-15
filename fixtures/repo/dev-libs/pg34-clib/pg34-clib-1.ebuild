EAPI=8
DESCRIPTION="fixture package: #34 S5 G2 parent USE-atom reinstall (installed with USE empty, repo IUSE +f default-on with f? dep on pg34-cdep; a parent requiring clib[f] reinstalls it); regressed = -pv on pg34-capp plans no R clib and no N cdep"
SLOT="0"
KEYWORDS="amd64"
IUSE="+f"
RDEPEND="f? ( dev-libs/pg34-cdep )"
