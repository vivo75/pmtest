EAPI=8
DESCRIPTION="fixture package: the splitdebug neighbour -- same -g build, no package.env entry (backlog #98)"
SLOT="0"
KEYWORDS="amd64"
IUSE=""

src_compile() {
	"${CC:-gcc}" -g -O2 -o splitnbr-hello "${FILESDIR}/hello.c" || die
}

src_install() {
	exeinto /usr/bin
	doexe splitnbr-hello || die
}
