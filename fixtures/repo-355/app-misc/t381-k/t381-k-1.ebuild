# V3 (#381): the replaced instance is a keepdir `dir` entry; the replacer
# records a file under the symlinked spelling of that directory.
EAPI=8
DESCRIPTION="t381 keepdir probe replaced by a file under an alias"
HOMEPAGE="none"
LICENSE="MIT"
SLOT="0"
KEYWORDS="amd64"
S=${WORKDIR}

src_install() {
	keepdir /usr/share/t381/sub
}
