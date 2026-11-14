EAPI=8
DESCRIPTION="fixture package: bootstrap cycle other side (USE-conditional BDEPEND on w753pkgnew)"
SLOT="0"
KEYWORDS="amd64"
IUSE="+useboh +useblah"
BDEPEND="useboh? ( dev-libs/w753pkgnew[use3] )"
