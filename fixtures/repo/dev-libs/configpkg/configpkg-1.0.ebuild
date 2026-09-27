EAPI=8
DESCRIPTION="fixture package: CONFIG_PROTECT (real path matching + rename-on-change + cfgfiledict memory)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"

src_install() {
	echo "new content from configpkg" > "${T}/configpkg.conf" || die
	insinto /etc
	doins "${T}/configpkg.conf"
}
