EAPI=8
DESCRIPTION="fixture package: #34 S5 G2 round 2 untaken-branch control (installed with USE empty, repo IUSE +f default-on with f? dep on pg34-xdep; pg34-xq requires xlib[f] but the solve takes the installed pg34-xalt branch, so no reinstall); regressed = round-1 pubgrub plans R xlib + N xdep"
SLOT="0"
KEYWORDS="amd64"
IUSE="+f"
RDEPEND="f? ( dev-libs/pg34-xdep )"
