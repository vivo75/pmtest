EAPI=8
DESCRIPTION="fixture package: bootstrap cycle new side (USE-conditional BDEPEND on w753otherpkg)"
SLOT="0"
KEYWORDS="amd64"
IUSE="+usefoo +use3"
BDEPEND="usefoo? ( dev-libs/w753otherpkg[useblah] )"
S="${WORKDIR}"

src_install() {
	dodir /usr/share/w753
	if use usefoo; then
		echo "USE=${USE}" > "${D}/usr/share/w753/${PN}-definitive-use.txt" || die
	else
		echo "USE=${USE}" > "${D}/usr/share/w753/${PN}-boot-use.txt" || die
	fi
}
