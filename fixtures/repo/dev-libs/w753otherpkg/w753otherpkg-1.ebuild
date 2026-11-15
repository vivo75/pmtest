EAPI=8
DESCRIPTION="fixture package: bootstrap cycle other side (USE-conditional BDEPEND on w753pkgnew)"
SLOT="0"
KEYWORDS="amd64"
IUSE="+useboh +useblah"
BDEPEND="useboh? ( dev-libs/w753pkgnew[use3] )"
S="${WORKDIR}"

src_install() {
	dodir /usr/share/w753
	if use useboh; then
		echo "USE=${USE}" > "${D}/usr/share/w753/${PN}-definitive-use.txt" || die
	else
		echo "USE=${USE}" > "${D}/usr/share/w753/${PN}-boot-use.txt" || die
	fi
}
