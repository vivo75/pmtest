EAPI=8
DESCRIPTION="fixture package: independent binary merge (f459-good)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"

src_install() {
	keepdir /opt/f459-good
}
