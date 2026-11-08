EAPI=8
DESCRIPTION="elimination fixture: := consumer whose deps hide behind an arch flag and a USE-dependency conditional"
SLOT="0/1"
KEYWORDS="amd64"
IUSE="soflag"
RDEPEND="amd64? ( dev-libs/souprov:= ) dev-libs/soulib[soflag?]"
