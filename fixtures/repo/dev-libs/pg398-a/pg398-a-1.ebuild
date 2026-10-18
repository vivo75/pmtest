EAPI=8
DESCRIPTION="fixture package: #398 flip-path || owner (not installed; flip off by default so the group is hidden until pg398-c's [flip] atom flips it on)"
SLOT="0"
KEYWORDS="amd64"
IUSE="flip"
RDEPEND="flip? ( || ( dev-libs/pg398-x dev-libs/pg398-y ) )"
