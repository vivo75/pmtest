EAPI=8
DESCRIPTION="254 fixture: installed consumer whose := on abiprov sits under a USE conditional that is off in the tree ebuild"
SLOT="0"
KEYWORDS="amd64"
IUSE="cflag"
RDEPEND="cflag? ( app-misc/abiprov:= )"
