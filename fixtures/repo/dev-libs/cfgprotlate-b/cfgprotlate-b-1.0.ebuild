EAPI=8
DESCRIPTION="fixture package: one file under a config-protected path, one under the env.d-added one (#333)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
IUSE=""

src_install() {
	insinto /usr/share/cfgprotme
	newins - x <<<'from-package'
	insinto /usr/share/cfgprotlate
	newins - y <<<'from-package'
}
