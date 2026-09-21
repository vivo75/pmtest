EAPI=8
DESCRIPTION="fixture package: per-package FEATURES=splitdebug probe (backlog #98)"
SLOT="0"
KEYWORDS="amd64"
IUSE=""

src_compile() {
	# A plain -g build gives estrip debug info to split; ${CC:-gcc}
	# honors a package.env toolchain without requiring one.
	"${CC:-gcc}" -g -O2 -o splitdbg-hello "${FILESDIR}/hello.c" || die
}

src_install() {
	exeinto /usr/bin
	doexe splitdbg-hello || die
}
