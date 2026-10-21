EAPI=8
DESCRIPTION="fixture package: needs f459-postinstfail (f459-top)"
SLOT="0"
KEYWORDS="amd64"
RDEPEND="dev-util/f459-postinstfail"
S="${WORKDIR}"

src_install() {
	keepdir /opt/f459-top
}
