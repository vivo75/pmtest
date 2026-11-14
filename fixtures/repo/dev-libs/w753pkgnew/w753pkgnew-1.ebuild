EAPI=8
DESCRIPTION="fixture package: bootstrap cycle new side (USE-conditional BDEPEND on w753otherpkg)"
SLOT="0"
KEYWORDS="amd64"
IUSE="+usefoo +use3"
BDEPEND="usefoo? ( dev-libs/w753otherpkg[useblah] )"
