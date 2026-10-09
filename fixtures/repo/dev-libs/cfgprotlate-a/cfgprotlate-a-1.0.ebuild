EAPI=8
DESCRIPTION="fixture package: adds /usr/share/cfgprotlate to CONFIG_PROTECT through /etc/env.d (#333)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
IUSE=""

src_install() {
	dodir /etc/env.d
	echo 'CONFIG_PROTECT="/usr/share/cfgprotlate"' > "${D}/etc/env.d/99cfgprotlate" || die
}
