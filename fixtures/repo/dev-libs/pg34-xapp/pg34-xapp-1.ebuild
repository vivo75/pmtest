EAPI=8
DESCRIPTION="fixture package: #34 S5 G2 round 2 untaken-branch control target (not installed; the || takes installed pg34-xalt, and the bare xlib dep keeps installed xlib-1 in the plan as a hidden leaf for the false R to render against); regressed = round-1 pubgrub plans N xdep + R xlib + N xapp"
SLOT="0"
KEYWORDS="amd64"
RDEPEND="|| ( dev-libs/pg34-xq dev-libs/pg34-xalt ) dev-libs/pg34-xlib"
