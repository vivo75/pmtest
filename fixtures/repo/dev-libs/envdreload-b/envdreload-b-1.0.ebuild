EAPI=8
DESCRIPTION="fixture package: records ${ENVDRELOAD_VAR} as its src_install sees it (#332, after envdreload-a's env.d merge)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
IUSE=""

src_install() {
	echo "ENVDRELOAD_VAR=${ENVDRELOAD_VAR}" > "${T}/envdreload-seen.txt" || die
}
