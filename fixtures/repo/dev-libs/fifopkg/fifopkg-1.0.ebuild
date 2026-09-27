EAPI=8
DESCRIPTION="fixture package: real FIFO node CONTENTS support (fif node type, mkfifo)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"

src_install() {
	dodir /usr/lib/fifopkg
	mkfifo "${D}/usr/lib/fifopkg/myfifo" || die
}
