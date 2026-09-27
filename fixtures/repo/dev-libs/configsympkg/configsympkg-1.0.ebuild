EAPI=8
DESCRIPTION="fixture package: real symlink CONFIG_PROTECT (target-string MD5 comparison)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"

src_install() {
	dodir /etc
	dosym new-target /etc/configsympkg.conf
}
