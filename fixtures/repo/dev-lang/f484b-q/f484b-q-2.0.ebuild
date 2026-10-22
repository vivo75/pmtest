EAPI=8
DESCRIPTION="fixture #484b Q 2.0: upgrade target (installed 1.0); RDEPEND pins ~f484b-x-1.0, which puts the installed X-1.0 node in the graph before P's || dep is resolved. A regressed PM upgrades X to 2.0 anyway."
SLOT="0"
KEYWORDS="amd64"
RDEPEND="~dev-libs/f484b-x-1.0"
