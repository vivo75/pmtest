EAPI=8
DESCRIPTION="fixture package: installs /etc/env.d/99envdreload (ENVDRELOAD_VAR=1) so a later package task must see it (#332)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
IUSE=""

src_install() {
	dodir /etc/env.d
	echo 'ENVDRELOAD_VAR=1' > "${D}/etc/env.d/99envdreload" || die
}
